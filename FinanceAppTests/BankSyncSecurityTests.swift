import CryptoKit
import Foundation
import Testing
import FinanceCore
@testable import FinanceApp

/// Device authentication, and the things that must not be in the app.
///
/// The property under test is that the binary is worthless to an attacker: it
/// carries no credential, and the one secret that exists — the device's private
/// key — cannot be read out of it.
// Serialized: the scripted transport is process-wide, so two of these running
// at once would answer each other's requests.
@Suite("Bank sync device security", .serialized)
struct BankSyncSecurityTests {

    private func store(_ name: String = UUID().uuidString) -> DeviceIdentityStore {
        DeviceIdentityStore(service: "test.banksync.\(name)")
    }

    // MARK: - Key generation

    @Test("Hardware is used when the device has it, software only when it does not")
    func keyBackingFollowsHardware() throws {
        let identity = store()
        defer { try? identity.clear() }

        let key = try identity.loadOrCreateKey()

        // The policy, asserted on whatever this test is running on: a Secure
        // Enclave device must not silently fall back to a software key, and a
        // simulator must not claim hardware it does not have.
        #expect(key.isHardwareBacked == SecureEnclave.isAvailable)
    }

    @Test("The simulator and test path is a real P-256 signer behind the same protocol")
    func softwareKeySignsRealSignatures() throws {
        let identity = store()
        defer { try? identity.clear() }

        let key = try DeviceIdentityStore(
            service: "test.banksync.software", forcesSoftwareKey: true
        ).loadOrCreateKey()
        defer { try? DeviceIdentityStore(service: "test.banksync.software").clear() }

        #expect(key.isHardwareBacked == false)
        let message = Data("canonical".utf8)
        let signature = try key.signature(for: message)

        // Verifiable against the public key it published — the same check the
        // Worker performs, so this is the real signer, not a stand-in.
        let publicKey = try P256.Signing.PublicKey(x963Representation: key.publicKeyX963)
        let parsed = try P256.Signing.ECDSASignature(derRepresentation: signature)
        #expect(publicKey.isValidSignature(parsed, for: message))
    }

    @Test("Only a public key is ever exposed, in the exact format the service imports")
    func publicKeyIsX963() throws {
        let identity = store()
        defer { try? identity.clear() }

        let key = try identity.loadOrCreateKey()

        // 0x04 ‖ X ‖ Y — 65 bytes uncompressed, what WebCrypto imports as "raw".
        #expect(key.publicKeyX963.count == 65)
        #expect(key.publicKeyX963.first == 0x04)
    }

    @Test("The signing key exposes no way to export the private half")
    func privateKeyIsNotExportable() throws {
        let identity = store()
        defer { try? identity.clear() }
        let key = try identity.loadOrCreateKey()

        // The protocol has publicKeyX963, signature(for:) and isHardwareBacked.
        // There is deliberately no export member, so no caller — including a
        // future one — can obtain the private key through this type.
        let mirror = Mirror(reflecting: key)
        #expect(!mirror.children.contains { ($0.label ?? "").lowercased().contains("raw") })

        if key.isHardwareBacked {
            let enclave = try #require(key as? SecureEnclaveSigningKey)
            // What is persisted is an Enclave-wrapped blob, not the 32-byte
            // scalar: it is longer, and it is useless on any other device.
            #expect(enclave.key.dataRepresentation.count > 32)
        }
    }

    @Test("Pairing stores the device id and never the pairing code")
    func pairingStoresIdNotCode() async throws {
        let service = "test.banksync.pairing"
        let identity = DeviceIdentityStore(service: service)
        defer { try? identity.clear() }
        let code = "WXYZ-2345-6789"
        let session = StubURLProtocol.session()
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"deviceId":"dev_abc123"}"#.utf8))
        }
        let client = BankSyncClient(
            baseURL: URL(string: "https://example.invalid")!,
            session: session,
            identity: identity
        )

        let deviceID = try await client.pair(code: code, label: "Test")

        #expect(deviceID == "dev_abc123")
        #expect(identity.pairedDeviceID == "dev_abc123")
        // The code was a bearer credential for ten minutes and is now spent.
        // Nothing in the Keychain may still hold it.
        for account in ["device-signing-key", "paired-device-id", "device-key-is-hardware"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
            ]
            var item: CFTypeRef?
            _ = SecItemCopyMatching(query as CFDictionary, &item)
            if let data = item as? Data {
                #expect(!data.contains(Data(code.utf8)))
                #expect(!data.contains(Data("WXYZ".utf8)))
            }
        }
    }

    // MARK: - Request canonicalization

    @Test("Canonicalization is deterministic")
    func canonicalIsDeterministic() {
        let build = {
            BankSyncRequestSigner.canonicalRequest(
                method: "GET", pathAndQuery: "/v1/mobile/snapshot",
                bodySHA256: BankSyncRequestSigner.sha256Hex(Data()),
                timestamp: "2026-08-28T12:00:00.000Z",
                nonce: "n0nce", deviceID: "dev_1"
            )
        }
        #expect(build() == build())
        #expect(build().split(separator: "\n").count == 6)
    }

    @Test("Changing the path or the body changes what gets signed")
    func canonicalCoversPathAndBody() {
        let base = BankSyncRequestSigner.canonicalRequest(
            method: "GET", pathAndQuery: "/v1/mobile/snapshot",
            bodySHA256: BankSyncRequestSigner.sha256Hex(Data()),
            timestamp: "2026-08-28T12:00:00.000Z", nonce: "n0nce", deviceID: "dev_1"
        )
        let otherPath = BankSyncRequestSigner.canonicalRequest(
            method: "GET", pathAndQuery: "/v1/mobile/snapshot?since=x",
            bodySHA256: BankSyncRequestSigner.sha256Hex(Data()),
            timestamp: "2026-08-28T12:00:00.000Z", nonce: "n0nce", deviceID: "dev_1"
        )
        let otherBody = BankSyncRequestSigner.canonicalRequest(
            method: "POST", pathAndQuery: "/v1/mobile/snapshot",
            bodySHA256: BankSyncRequestSigner.sha256Hex(Data("{}".utf8)),
            timestamp: "2026-08-28T12:00:00.000Z", nonce: "n0nce", deviceID: "dev_1"
        )

        #expect(base != otherPath)
        #expect(base != otherBody)

        // And the signatures differ too, not just the strings.
        let key = P256.Signing.PrivateKey()
        let signed = { (message: String) in
            try! key.signature(for: Data(message.utf8)).derRepresentation
        }
        #expect(signed(base) != signed(otherPath))
    }

    @Test("Nonces do not repeat")
    func noncesAreUnique() {
        let nonces = Set((0..<500).map { _ in BankSyncRequestSigner.nonce() })
        #expect(nonces.count == 500)
        // Long enough that the service accepts them: it refuses anything under
        // 16 characters as too small a space to be unguessable.
        #expect(BankSyncRequestSigner.nonce().count >= 16)
    }

    // MARK: - Transport

    @Test("Only HTTPS is accepted")
    func httpsRequired() async throws {
        #expect(BankSyncConfiguration.isSecure(URL(string: "https://example.com")!))
        #expect(!BankSyncConfiguration.isSecure(URL(string: "http://example.com")!))

        let identity = store()
        defer { try? identity.clear() }
        try identity.storePairedDeviceID("dev_1")
        _ = try identity.loadOrCreateKey()
        let client = BankSyncClient(
            baseURL: URL(string: "http://example.invalid")!,
            session: StubURLProtocol.session(),
            identity: identity
        )
        StubURLProtocol.handler = { _ in (200, Data("{}".utf8)) }

        // Refused before the request is sent, so a signature never travels over
        // a readable connection.
        await #expect(throws: BankSyncClientError.insecureEndpoint) {
            _ = try await client.snapshot(since: nil)
        }
    }

    @Test("A cleartext, empty, unsubstituted or placeholder endpoint is refused as configuration")
    func configurationRejectsUnusableEndpoints() {
        #expect(BankSyncConfiguration.baseURL(fromValue: "http://example.com") == nil)
        #expect(BankSyncConfiguration.baseURL(fromValue: "") == nil)
        #expect(BankSyncConfiguration.baseURL(fromValue: nil) == nil)
        // A build setting that never expanded is a misconfiguration, not a host.
        #expect(BankSyncConfiguration.baseURL(fromValue: "$(BANK_SYNC_HOST)") == nil)
        // A scheme with no host behind it is not an endpoint either.
        #expect(BankSyncConfiguration.baseURL(fromValue: "https://") == nil)
        // The tracked placeholder is "not configured", not a service: .invalid
        // is reserved so it can never resolve.
        #expect(BankSyncConfiguration.baseURL(fromValue: "https://finance-bank-sync.example.invalid") == nil)
        #expect(BankSyncConfiguration.baseURL(fromValue: "https://anything.invalid") == nil)
        #expect(BankSyncConfiguration.isPlaceholder("host.example.invalid"))
        #expect(!BankSyncConfiguration.isPlaceholder("host.example.com"))
        // A real deployment is accepted.
        #expect(BankSyncConfiguration.baseURL(fromValue: "https://example.com") != nil)
    }

    @Test("A checkout with no local configuration reads as not configured, and says so")
    func trackedCheckoutIsNotConfigured() {
        // The tracked xcconfig points at the placeholder host, so the build
        // under test must substitute *something* …
        let raw = Bundle.main.object(forInfoDictionaryKey: BankSyncConfiguration.infoKey) as? String
        let value = try! #require(raw)
        #expect(!value.hasPrefix("$("), "BANK_SYNC_HOST did not substitute")
        #expect(value.hasPrefix("https://"), "the scheme is fixed in the Info.plist")
        // … and, with only the tracked default in place, that resolves to no
        // usable endpoint rather than to a host nobody owns. A developer who
        // adds Config/BankSync.local.xcconfig gets a real URL here instead,
        // which is the one case this may legitimately be non-nil.
        if BankSyncConfiguration.isPlaceholder(URL(string: value)?.host() ?? "") {
            #expect(BankSyncConfiguration.baseURL() == nil)
        } else {
            #expect(BankSyncConfiguration.baseURL() != nil)
        }
    }

    @Test("Revocation and expiry are reported distinctly, and neither leaks detail")
    func serverErrorsAreSanitized() async throws {
        let identity = store()
        defer { try? identity.clear() }
        try identity.storePairedDeviceID("dev_1")
        _ = try identity.loadOrCreateKey()
        let client = BankSyncClient(
            baseURL: URL(string: "https://example.invalid")!,
            session: StubURLProtocol.session(),
            identity: identity
        )

        StubURLProtocol.handler = { _ in (403, Data(#"{"error":"device_revoked"}"#.utf8)) }
        await #expect(throws: BankSyncClientError.deviceRevoked) {
            _ = try await client.snapshot(since: nil)
        }

        StubURLProtocol.handler = { _ in (401, Data(#"{"error":"bad_signature"}"#.utf8)) }
        await #expect(throws: BankSyncClientError.unauthorized) {
            _ = try await client.snapshot(since: nil)
        }

        // Nothing a person reads names a status code, a header or a provider.
        for error: BankSyncClientError in [
            .deviceRevoked, .unauthorized, .offline, .server(status: 500),
            .malformedResponse, .pairingRejected,
        ] {
            #expect(!error.message.contains("40"))
            #expect(!error.message.contains("50"))
            #expect(!error.message.lowercased().contains("http"))
        }
    }

    @Test("An unknown contract version is refused rather than half-understood")
    func contractVersionIsChecked() async throws {
        let identity = store()
        defer { try? identity.clear() }
        try identity.storePairedDeviceID("dev_1")
        _ = try identity.loadOrCreateKey()
        let client = BankSyncClient(
            baseURL: URL(string: "https://example.invalid")!,
            session: StubURLProtocol.session(),
            identity: identity
        )
        StubURLProtocol.handler = { _ in
            (200, Data(#"""
            {"contractVersion":99,"serverTime":"2026-08-28T00:00:00.000Z","connections":[],
             "accounts":[],"balances":[],"observations":[],"pending":[],"candidates":[],
             "nextSince":null}
            """#.utf8))
        }

        await #expect(throws: BankSyncClientError.unsupportedContract(99)) {
            _ = try await client.snapshot(since: nil)
        }
    }

    @Test("An unpaired device cannot make a signed call at all")
    func unpairedCannotCall() async throws {
        let identity = store()
        defer { try? identity.clear() }
        let client = BankSyncClient(
            baseURL: URL(string: "https://example.invalid")!,
            session: StubURLProtocol.session(),
            identity: identity
        )

        await #expect(throws: BankSyncClientError.notPaired) {
            _ = try await client.snapshot(since: nil)
        }
    }

    // MARK: - What must not be in the app

    @Test("No backend credential or bank secret exists in app sources")
    func noCredentialsInSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "FinanceApp")
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        )
        var combined = ""
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            combined += try String(contentsOf: url, encoding: .utf8)
        }

        for forbidden in [
            "ADMIN_API_TOKEN",
            "Authorization",
            "Bearer ",
            "ENABLE_BANKING",
            "BEGIN RSA PRIVATE KEY",
            "BEGIN PRIVATE KEY",
            "identification_hash",
            "entry_reference",
            "session_id",
        ] {
            #expect(!combined.contains(forbidden), "app sources contain '\(forbidden)'")
        }
    }

    @Test("Device authentication is not part of the portable finance document")
    func documentCarriesNoDeviceAuth() throws {
        let identity = store()
        defer { try? identity.clear() }
        try identity.storePairedDeviceID("dev_secret_handle")
        _ = try identity.loadOrCreateKey()

        var document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [Account(id: "a", name: "A", currency: .eur, kind: .bank, supportedRails: [])],
            balances: [AccountBalance(
                accountID: "a", balance: Money(minorUnits: 0, currency: .eur),
                asOf: Day(year: 2026, month: 8, day: 22)
            )]
        )
        document.externalAccountBindings = [
            ExternalAccountBinding(
                id: "binding", provider: .bnp, remoteOpaqueAccountID: "acct_opaque",
                localAccountID: "a", syncStartBoundary: Day(year: 2026, month: 8, day: 22),
                createdAt: Date(timeIntervalSince1970: 0)
            )
        ]

        let encoded = try Interchange.encode(document)
        let text = try #require(String(data: encoded, encoding: .utf8))

        // A backup is a financial document. It must restore onto a machine that
        // was never paired, so it carries no device id, key or endpoint.
        #expect(!text.contains("dev_secret_handle"))
        #expect(!text.contains("deviceId"))
        #expect(!text.lowercased().contains("publickey"))
        #expect(!text.contains("workers.dev"))
        // The opaque account handle is legitimately part of the binding.
        #expect(text.contains("acct_opaque"))
    }

    @Test("Screens never see a remote account identifier")
    func surfaceOmitsRemoteAccountIdentity() {
        let binding = ProviderAccountBinding(
            id: "binding-acct_00000000000000000000000000000001",
            providerName: "BNP",
            localAccountID: "bnp",
            localAccountName: "BNP",
            syncStartBoundary: CalendarDay(year: 2026, month: 8, day: 22),
            isActive: true
        )
        // The binding id embeds the handle for lookup, but no screen field does.
        #expect(!binding.providerName.contains("acct_"))
        #expect(!binding.localAccountName.contains("acct_"))
        #expect(!binding.localAccountID.contains("acct_"))
    }
}

// MARK: - Test doubles

/// A scripted HTTP transport. Nothing in these tests reaches the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, data) = Self.handler?(request) ?? (200, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
