import CryptoKit
import Foundation

/// Where the service lives.
///
/// The URL is configuration, not a literal buried in a call site: a build that
/// pointed at the wrong host should be a visibly wrong Info.plist rather than a
/// line of Swift nobody re-reads. It is not a secret — the service is public
/// and authenticates callers by signature — but it is also not something an
/// arbitrary source file should be free to invent.
enum BankSyncConfiguration {
    static let infoKey = "BankSyncBaseURL"

    static func baseURL(from bundle: Bundle = .main) -> URL? {
        baseURL(fromValue: bundle.object(forInfoDictionaryKey: infoKey) as? String)
    }

    /// The policy itself, separated from where the value came from.
    static func baseURL(fromValue raw: String?) -> URL? {
        guard let raw, !raw.isEmpty,
              // An unsubstituted build setting must not be treated as a host.
              !raw.hasPrefix("$("),
              let url = URL(string: raw.hasSuffix("/") ? String(raw.dropLast()) : raw)
        else { return nil }
        return isSecure(url) ? url : nil
    }

    /// HTTPS only. `http://` is refused here rather than at the transport, so a
    /// misconfigured build fails at startup instead of sending a signed request
    /// — and the signature with it — over a readable connection.
    static func isSecure(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }
}

enum BankSyncClientError: Error, Equatable {
    case notConfigured
    case insecureEndpoint
    case notPaired
    case pairingRejected
    case pairingRateLimited
    case deviceRevoked
    case unauthorized
    case unsupportedContract(Int)
    case offline
    case server(status: Int)
    case malformedResponse

    /// Deliberately vague about the service's internals. A person can act on
    /// "pair again"; they cannot act on a status code or a provider stack trace.
    var message: String {
        switch self {
        case .notConfigured: "Bank sync is not configured in this build."
        case .insecureEndpoint: "Bank sync must use a secure connection."
        case .notPaired: "This device is not paired yet."
        case .pairingRejected: "That pairing code was not accepted. Ask for a new one."
        case .pairingRateLimited: "Too many pairing attempts. Wait a few minutes and try again."
        case .deviceRevoked: "This device was disconnected. Pair it again to resume syncing."
        case .unauthorized: "This device could not authenticate. Pair it again."
        case .unsupportedContract: "This version of the app is too old to sync. Update it."
        case .offline: "No connection. Everything already on this device still works."
        case .server: "The sync service is unavailable. Nothing was changed."
        case .malformedResponse: "The sync service sent something this app could not read."
        }
    }
}

/// Builds the exact bytes the Worker verifies.
///
/// Kept separate from the transport so it can be tested directly: the property
/// that matters is that changing any part of the request changes the string.
enum BankSyncRequestSigner {
    static func canonicalRequest(
        method: String,
        pathAndQuery: String,
        bodySHA256: String,
        timestamp: String,
        nonce: String,
        deviceID: String
    ) -> String {
        [
            method.uppercased(),
            pathAndQuery,
            bodySHA256,
            timestamp,
            nonce,
            deviceID,
        ].joined(separator: "\n")
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

/// The only thing in the app that performs network I/O.
///
/// Nothing above this type sees a URL, a header or a status code, and nothing
/// below the persistence layer reaches it: SwiftUI asks `FinanceStore` to sync
/// and gets a result or a sanitized error.
struct BankSyncClient: Sendable {
    let baseURL: URL
    let session: URLSession
    let identity: DeviceIdentityStore

    init(baseURL: URL, session: URLSession = .shared, identity: DeviceIdentityStore = .init()) {
        self.baseURL = baseURL
        self.session = session
        self.identity = identity
    }

    // MARK: - Pairing

    /// Claims a pairing code with a freshly generated (or existing) device key.
    ///
    /// The code is used once, here, and never written to disk: it is a bearer
    /// credential for its ten-minute life, and the device id it produces is not.
    func pair(code: String, label: String) async throws -> String {
        let key = try identity.loadOrCreateKey()
        var request = URLRequest(url: baseURL.appending(path: "/v1/mobile/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            PairRequest(
                code: code,
                publicKey: key.publicKeyX963.base64EncodedString(),
                label: label
            )
        )

        let (data, response) = try await perform(request)
        switch response.statusCode {
        case 200:
            guard let decoded = try? JSONDecoder().decode(PairResponse.self, from: data) else {
                throw BankSyncClientError.malformedResponse
            }
            try identity.storePairedDeviceID(decoded.deviceID)
            return decoded.deviceID
        case 429:
            throw BankSyncClientError.pairingRateLimited
        case 400:
            throw BankSyncClientError.pairingRejected
        default:
            throw BankSyncClientError.server(status: response.statusCode)
        }
    }

    // MARK: - Signed calls

    func snapshot(since: String?) async throws -> MobileSnapshot {
        var pathAndQuery = "/v1/mobile/snapshot"
        if let since, !since.isEmpty {
            // The query is signed, so it must be built once and used verbatim.
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "since", value: since)]
            if let query = components.percentEncodedQuery { pathAndQuery += "?\(query)" }
        }
        let data = try await signed(method: "GET", pathAndQuery: pathAndQuery, body: Data())
        guard let snapshot = try? Self.decoder.decode(MobileSnapshot.self, from: data) else {
            throw BankSyncClientError.malformedResponse
        }
        guard snapshot.contractVersion == MobileSnapshot.supportedContractVersion else {
            throw BankSyncClientError.unsupportedContract(snapshot.contractVersion)
        }
        return snapshot
    }

    @discardableResult
    func runSync() async throws -> [MobileSyncRun] {
        // The service contacts three institutions in turn; the default 60s
        // would abandon a sync that is still perfectly healthy.
        let data = try await signed(
            method: "POST", pathAndQuery: "/v1/mobile/sync", body: Data(), timeout: 180
        )
        guard let decoded = try? Self.decoder.decode(MobileSyncResponse.self, from: data) else {
            throw BankSyncClientError.malformedResponse
        }
        return decoded.runs
    }

    private func signed(
        method: String,
        pathAndQuery: String,
        body: Data,
        timeout: TimeInterval = 30
    ) async throws -> Data {
        guard let deviceID = identity.pairedDeviceID else { throw BankSyncClientError.notPaired }
        guard let key = try identity.loadKey() else { throw BankSyncClientError.notPaired }

        let timestamp = BankSyncRequestSigner.timestampFormatter.string(from: Date())
        let nonce = BankSyncRequestSigner.nonce()
        let canonical = BankSyncRequestSigner.canonicalRequest(
            method: method,
            pathAndQuery: pathAndQuery,
            bodySHA256: BankSyncRequestSigner.sha256Hex(body),
            timestamp: timestamp,
            nonce: nonce,
            deviceID: deviceID
        )
        let signature = try key.signature(for: Data(canonical.utf8))

        guard let url = URL(string: baseURL.absoluteString + pathAndQuery) else {
            throw BankSyncClientError.notConfigured
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if !body.isEmpty { request.httpBody = body }
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        request.setValue(timestamp, forHTTPHeaderField: "X-Device-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Device-Nonce")
        request.setValue(signature.base64EncodedString(), forHTTPHeaderField: "X-Device-Signature")

        let (data, response) = try await perform(request)
        switch response.statusCode {
        case 200: return data
        case 401: throw BankSyncClientError.unauthorized
        case 403: throw BankSyncClientError.deviceRevoked
        default: throw BankSyncClientError.server(status: response.statusCode)
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, BankSyncConfiguration.isSecure(url) else {
            throw BankSyncClientError.insecureEndpoint
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw BankSyncClientError.malformedResponse
            }
            return (data, http)
        } catch let error as BankSyncClientError {
            throw error
        } catch let error as URLError {
            // Every transport failure is "offline" to the person, because every
            // one of them means the same thing: the local app is still fine.
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dataNotAllowed:
                throw BankSyncClientError.offline
            default:
                throw BankSyncClientError.offline
            }
        }
    }

    private static let decoder = JSONDecoder()

    private struct PairRequest: Encodable {
        let code: String
        let publicKey: String
        let label: String
    }

    private struct PairResponse: Decodable {
        let deviceID: String

        private enum CodingKeys: String, CodingKey { case deviceID = "deviceId" }
    }
}
