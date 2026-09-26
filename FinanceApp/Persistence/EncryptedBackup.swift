import Foundation
import CryptoKit
import Security
import CommonCrypto

/// Version 1: PBKDF2-HMAC-SHA256 + AES-256-GCM. Passwords are never persisted.
enum EncryptedBackup {
    static let key = "financeEncryptedBackup"
    static let iterations: UInt32 = 600_000
    private static let authentication = Data("finance-app/encrypted-backup/v1".utf8)
    private struct Envelope: Codable {
        let version: Int
        let iterations: UInt32
        let salt: Data
        let sealed: Data
    }

    static func isEncrypted(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?[key] != nil
    }

    static func encrypt(_ data: Data, password: String) throws -> Data {
        guard password.count >= 12, password.utf8.count <= 1024 else { throw AppImportError.backupPasswordInvalid }
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else { throw AppImportError.fileUnreadable }
        let saltData = Data(salt)
        let derived = try derive(password: password, salt: saltData)
        let box = try AES.GCM.seal(data, using: derived, authenticating: authentication)
        guard let combined = box.combined else { throw AppImportError.fileUnreadable }
        let envelope = Envelope(version: 1, iterations: iterations, salt: saltData, sealed: combined)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode([key: envelope])
        guard encoded.count <= DocumentImporter.maximumFileBytes else { throw AppImportError.fileUnreadable }
        return encoded
    }

    static func decrypt(_ data: Data, password: String?) throws -> Data {
        guard data.count <= DocumentImporter.maximumFileBytes,
              let decoded = try? JSONDecoder().decode([String: Envelope].self, from: data),
              decoded.count == 1, let envelope = decoded[key],
              envelope.version == 1, envelope.iterations == iterations,
              envelope.salt.count == 16, envelope.sealed.count >= 28 else { throw AppImportError.fileUnreadable }
        guard let password else { throw AppImportError.backupPasswordRequired }
        guard password.utf8.count <= 1024 else { throw AppImportError.backupPasswordInvalid }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed),
                                    using: derive(password: password, salt: envelope.salt),
                                    authenticating: authentication)
        } catch { throw AppImportError.backupPasswordInvalid }
    }

    private static func derive(password: String, salt: Data) throws -> SymmetricKey {
        var output = [UInt8](repeating: 0, count: 32)
        let status = password.withCString { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes, password.utf8.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &output, output.count)
            }
        }
        guard status == kCCSuccess else { throw AppImportError.fileUnreadable }
        defer { _ = output.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return SymmetricKey(data: output)
    }
}
