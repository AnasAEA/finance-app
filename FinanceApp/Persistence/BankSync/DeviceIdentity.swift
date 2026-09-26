import CryptoKit
import Foundation

/// What the app can do with its device key, and deliberately nothing more.
///
/// There is no "export" member because there is no supported way to obtain the
/// private key on the Secure Enclave path, and the software path must not be
/// allowed to grow one just because it could.
protocol DeviceSigningKey: Sendable {
    /// X9.63 uncompressed point (0x04 ‖ X ‖ Y). This is the only key material
    /// that ever leaves the device.
    var publicKeyX963: Data { get }
    /// DER (X9.62) ECDSA signature over SHA-256 of `message`.
    func signature(for message: Data) throws -> Data
    var isHardwareBacked: Bool { get }
}

struct SecureEnclaveSigningKey: DeviceSigningKey {
    let key: SecureEnclave.P256.Signing.PrivateKey

    var publicKeyX963: Data { key.publicKey.x963Representation }
    var isHardwareBacked: Bool { true }

    func signature(for message: Data) throws -> Data {
        try key.signature(for: message).derRepresentation
    }
}

/// Simulator and test path. Same curve, same canonical bytes, same wire format,
/// so what the tests exercise is the real signer rather than a stand-in for it.
struct SoftwareSigningKey: DeviceSigningKey {
    let key: P256.Signing.PrivateKey

    var publicKeyX963: Data { key.publicKey.x963Representation }
    var isHardwareBacked: Bool { false }

    func signature(for message: Data) throws -> Data {
        try key.signature(for: message).derRepresentation
    }
}

enum DeviceIdentityError: Error, Equatable {
    case keychainFailure(OSStatus)
    case keyUnusable

    var message: String {
        switch self {
        case .keychainFailure: "This device's secure storage is unavailable."
        case .keyUnusable: "This device's sync key could not be used. Pair the device again."
        }
    }
}

/// Creates, stores and reloads the device's signing key and its paired id.
///
/// The private key is held by the Secure Enclave where the hardware provides
/// one; the persisted blob is then an encrypted wrapper that only this Enclave
/// can unwrap, so a Keychain dump on a stolen backup yields nothing usable.
/// Everything is `ThisDeviceOnly`: a restored backup deliberately cannot sync,
/// and the person pairs again. Designing a way around that would mean building
/// a device credential that survives leaving the device, which is the thing the
/// whole scheme exists to avoid.
struct DeviceIdentityStore {
    /// Key material, and the paired device id, live under separate accounts so
    /// that clearing the pairing cannot leave a key orphaned behind an id.
    private static let service = "com.anasait.financeapp.banksync"
    private static let keyAccount = "device-signing-key"
    private static let deviceAccount = "paired-device-id"
    /// Distinguishes an Enclave-wrapped blob from a raw software key, so a
    /// build that gains hardware support never tries to unwrap the wrong one.
    private static let hardwareAccount = "device-key-is-hardware"

    private let service: String
    private let usesSecureEnclave: Bool

    init(service: String = DeviceIdentityStore.service, forcesSoftwareKey: Bool = false) {
        self.service = service
        self.usesSecureEnclave = !forcesSoftwareKey && SecureEnclave.isAvailable
    }

    // MARK: - Signing key

    func loadOrCreateKey() throws -> any DeviceSigningKey {
        if let existing = try loadKey() { return existing }
        return try createKey()
    }

    func loadKey() throws -> (any DeviceSigningKey)? {
        guard let blob = try read(account: Self.keyAccount) else { return nil }
        let hardware = try read(account: Self.hardwareAccount).map { $0 == Data([1]) } ?? false
        do {
            if hardware {
                return SecureEnclaveSigningKey(
                    key: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
                )
            }
            return SoftwareSigningKey(key: try P256.Signing.PrivateKey(rawRepresentation: blob))
        } catch {
            // A blob that no longer unwraps is not recoverable by retrying: the
            // Enclave that made it is gone. Say so rather than looping.
            throw DeviceIdentityError.keyUnusable
        }
    }

    @discardableResult
    private func createKey() throws -> any DeviceSigningKey {
        if usesSecureEnclave {
            // `.privateKeyUsage` only. Adding `.userPresence` here would demand
            // Face ID for every signed request, including a background refresh,
            // which turns routine sync into a prompt the person cannot answer.
            let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.privateKeyUsage],
                nil
            )
            guard let access,
                  let key = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            else {
                throw DeviceIdentityError.keyUnusable
            }
            try write(key.dataRepresentation, account: Self.keyAccount)
            do { try write(Data([1]), account: Self.hardwareAccount) }
            catch { try? delete(account: Self.keyAccount); throw error }
            return SecureEnclaveSigningKey(key: key)
        }

        let key = P256.Signing.PrivateKey()
        try write(key.rawRepresentation, account: Self.keyAccount)
        do { try write(Data([0]), account: Self.hardwareAccount) }
        catch { try? delete(account: Self.keyAccount); throw error }
        return SoftwareSigningKey(key: key)
    }

    // MARK: - Paired device id

    /// The device id is an opaque backend handle, not a credential: it proves
    /// nothing without a signature from the key above.
    var pairedDeviceID: String? {
        guard let data = try? read(account: Self.deviceAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func storePairedDeviceID(_ deviceID: String) throws {
        try write(Data(deviceID.utf8), account: Self.deviceAccount)
    }

    /// Unpairs. The key is destroyed with the id, because a key the backend no
    /// longer knows is not a credential worth keeping.
    func clear() throws {
        for account in [Self.keyAccount, Self.deviceAccount, Self.hardwareAccount] {
            try delete(account: account)
        }
    }

    // MARK: - Keychain

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(account: String) throws -> Data? {
        var request = query(account: account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw DeviceIdentityError.keychainFailure(status) }
        return item as? Data
    }

    private func write(_ data: Data, account: String) throws {
        let updates: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query(account: account) as CFDictionary, updates as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw DeviceIdentityError.keychainFailure(updated) }
        var request = query(account: account)
        request[kSecValueData as String] = data
        // Never synchronized to iCloud, never restored to another device.
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        guard status == errSecSuccess else { throw DeviceIdentityError.keychainFailure(status) }
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceIdentityError.keychainFailure(status)
        }
    }
}
