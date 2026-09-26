import Foundation

/// The `/v1/mobile/snapshot` payload, exactly as documented in the service's
/// `docs/mobile-api.md`.
///
/// Every optional here is optional in the contract too. Decoding is total: a
/// field the service later adds must not break an installed app, and a field it
/// omits must not crash one.
struct MobileSnapshot: Decodable, Sendable {
    static let supportedContractVersion = 1

    let contractVersion: Int
    let serverTime: String
    let connections: [Connection]
    let accounts: [Account]
    let balances: [Balance]
    let observations: [Observation]
    let pending: [Pending]
    let candidates: [Candidate]
    let nextSince: String?
    /// Last booked key delivered, including on the terminal page. Absent on
    /// older Workers; the app then keeps using a full read.
    var highWater: String? = nil

    struct Connection: Decodable, Sendable {
        let id: String
        let provider: String
        let institution: String?
        let status: String
        let validUntil: String?
        let lastSuccessfulSyncAt: String?
        let lastErrorCode: String?
    }

    struct Account: Decodable, Sendable {
        let id: String
        let provider: String
        let connectionId: String?
        let displayName: String?
        let product: String?
        let cashAccountType: String?
        let usage: String?
        let currency: String?
        let syncedFrom: String?
        let syncedThrough: String?
    }

    struct Balance: Decodable, Sendable {
        let accountId: String
        let type: String
        let name: String?
        /// Decimal string. Parsing this as a Double is how 7.99 becomes
        /// 7.989999999999999, so it stays a string until `Money` reads it.
        let amount: String
        let currency: String?
        let referenceDate: String?
        let observedAt: String
    }

    struct Observation: Decodable, Sendable {
        let id: String
        let accountId: String
        let provider: String
        let status: String
        let creditDebitIndicator: String
        let amount: String
        let currency: String?
        let bookingDate: String?
        let transactionDate: String?
        let valueDate: String?
        let derivedTransactionDate: String?
        let derivedDateProvenance: String?
        let rawMerchantText: String?
        let structuredMerchantName: String?
        let merchantEmail: String?
        let bankTransactionCode: String?
        let bankTransactionSubCode: String?
        let eligibleForEconomicActual: Bool
        let observedAt: String
    }

    struct Pending: Decodable, Sendable {
        let id: String
        let accountId: String
        let status: String
        let creditDebitIndicator: String?
        let amount: String
        let currency: String?
        let bookingDate: String?
        let transactionDate: String?
        let valueDate: String?
        let rawMerchantText: String?
        let observedAt: String
        let durableIdentity: Bool
        let eligibleForEconomicActual: Bool
    }

    struct Candidate: Decodable, Sendable {
        let bankObservationId: String
        let walletObservationId: String?
        let state: String
        let candidateCount: Int
        let amount: String
        let currency: String?
        let dayOffset: Int?
        let rule: String
        let computedAt: String
    }
}

struct MobileSyncRun: Decodable, Sendable {
    let provider: String
    let state: String?
    let outcome: String?
    let errorCode: String?

    init(provider: String, outcome: String?, errorCode: String?, state: String? = nil) {
        self.provider = provider
        self.state = state
        self.outcome = outcome
        self.errorCode = errorCode
    }
}

struct MobileSyncJob: Decodable, Sendable {
    let jobId: String
    let createdAt: String
    let complete: Bool
    let runs: [MobileSyncRun]
}

struct MobileCurrentSyncResponse: Decodable, Sendable {
    let job: MobileSyncJob?
}

/// The already-deployed Worker returns terminal runs inline. Kept only so an
/// app update can arrive before the queue-backed Worker update.
struct LegacyMobileSyncResponse: Decodable, Sendable {
    let runs: [MobileSyncRun]
}
