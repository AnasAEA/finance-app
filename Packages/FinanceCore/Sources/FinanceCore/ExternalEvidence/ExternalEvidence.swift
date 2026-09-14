import Foundation

/// A provider label, deliberately separate from provider account identity.
/// Unknown providers round-trip without being coerced into a known case.
public struct ExternalProvider: RawRepresentable, Hashable, Sendable, Codable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.lowercased()
    }

    public static let bnp = ExternalProvider(rawValue: "bnp")
    public static let paypal = ExternalProvider(rawValue: "paypal")
    public static let revolut = ExternalProvider(rawValue: "revolut")

    public static func < (lhs: ExternalProvider, rhs: ExternalProvider) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The backend's opaque account is bound to one user-owned ledger account.
/// `remoteOpaqueAccountID` is an internal backend id, never an IBAN, provider
/// account uid, identification hash or Enable Banking session id.
public struct ExternalAccountBinding: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let provider: ExternalProvider
    public let remoteOpaqueAccountID: String
    public let localAccountID: String

    /// Opening balance is authoritative through this day. Only provider rows
    /// proven to be strictly later may enter the active review queue.
    public let syncStartBoundary: Day
    public var isActive: Bool
    public let createdAt: Date

    public init(
        id: String,
        provider: ExternalProvider,
        remoteOpaqueAccountID: String,
        localAccountID: String,
        syncStartBoundary: Day,
        isActive: Bool = true,
        createdAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.remoteOpaqueAccountID = remoteOpaqueAccountID
        self.localAccountID = localAccountID
        self.syncStartBoundary = syncStartBoundary
        self.isActive = isActive
        self.createdAt = createdAt
    }
}

/// Provider state, normalized without losing a state this build has not seen.
public enum ExternalObservationStatus: Hashable, Sendable, Codable {
    case booked
    case pending
    case rejected
    case other(String)

    public init(providerToken: String) {
        switch providerToken.uppercased() {
        case "BOOK", "BOOKED": self = .booked
        case "PDNG", "PENDING", "HOLD": self = .pending
        case "RJCT", "REJECTED": self = .rejected
        default: self = .other(providerToken)
        }
    }

    public var token: String {
        switch self {
        case .booked: "booked"
        case .pending: "pending"
        case .rejected: "rejected"
        case let .other(token): token
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(providerToken: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }
}

/// Account-movement direction. This is evidence, not an economic category.
public enum ExternalCreditDebitIndicator: Hashable, Sendable, Codable {
    case credit
    case debit
    case other(String)

    public init(providerToken: String) {
        switch providerToken.uppercased() {
        case "CRDT", "CREDIT": self = .credit
        case "DBIT", "DEBIT": self = .debit
        default: self = .other(providerToken)
        }
    }

    public var token: String {
        switch self {
        case .credit: "credit"
        case .debit: "debit"
        case let .other(token): token
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(providerToken: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }
}

/// Whether the provider supplied durable identity for the row. A provisional
/// pending snapshot is never fingerprinted into identity by FinanceCore.
public enum ExternalObservationIdentity: String, Hashable, Sendable, Codable {
    case durable
    case provisionalSnapshot
}

public enum DerivedExternalDateProvenance: Hashable, Sendable, Codable {
    case parsedFromProviderRemittance
    case other(String)

    public init(providerToken: String) {
        switch providerToken {
        case "parsedFromProviderRemittance": self = .parsedFromProviderRemittance
        default: self = .other(providerToken)
        }
    }

    public var token: String {
        switch self {
        case .parsedFromProviderRemittance: "parsedFromProviderRemittance"
        case let .other(token): token
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(providerToken: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }
}

/// A normalized provider observation. It has no category, transaction kind or
/// economic effect. All provider dates remain independent facts.
public struct ExternalObservation: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let bindingID: String
    public let provider: ExternalProvider
    public let identity: ExternalObservationIdentity
    public let status: ExternalObservationStatus
    public let creditDebitIndicator: ExternalCreditDebitIndicator

    /// Signed account movement: positive enters the provider account, negative
    /// leaves it. Sign still says nothing about income or spending.
    public let amount: Money

    public let bookingDate: Day?
    public let transactionDate: Day?
    public let valueDate: Day?
    public let derivedTransactionDate: Day?
    public let derivedDateProvenance: DerivedExternalDateProvenance?

    public let rawMerchantText: String?
    public let structuredMerchantName: String?
    public let merchantEmail: String?
    public let remittance: String?
    public let bankTransactionCode: String?
    public let bankTransactionSubCode: String?

    /// The backend eligibility assertion is retained, but FinanceCore applies
    /// its own booked + durable safeguards as well.
    public let providerEligibleForEconomicActual: Bool
    public let observedAt: Date

    public init(
        id: String,
        bindingID: String,
        provider: ExternalProvider,
        identity: ExternalObservationIdentity = .durable,
        status: ExternalObservationStatus,
        creditDebitIndicator: ExternalCreditDebitIndicator,
        amount: Money,
        bookingDate: Day? = nil,
        transactionDate: Day? = nil,
        valueDate: Day? = nil,
        derivedTransactionDate: Day? = nil,
        derivedDateProvenance: DerivedExternalDateProvenance? = nil,
        rawMerchantText: String? = nil,
        structuredMerchantName: String? = nil,
        merchantEmail: String? = nil,
        remittance: String? = nil,
        bankTransactionCode: String? = nil,
        bankTransactionSubCode: String? = nil,
        eligibleForEconomicActual: Bool,
        observedAt: Date
    ) {
        self.id = id
        self.bindingID = bindingID
        self.provider = provider
        self.identity = identity
        self.status = status
        self.creditDebitIndicator = creditDebitIndicator
        self.amount = amount
        self.bookingDate = bookingDate
        self.transactionDate = transactionDate
        self.valueDate = valueDate
        self.derivedTransactionDate = derivedTransactionDate
        self.derivedDateProvenance = derivedDateProvenance
        self.rawMerchantText = rawMerchantText
        self.structuredMerchantName = structuredMerchantName
        self.merchantEmail = merchantEmail
        self.remittance = remittance
        self.bankTransactionCode = bankTransactionCode
        self.bankTransactionSubCode = bankTransactionSubCode
        self.providerEligibleForEconomicActual = eligibleForEconomicActual
        self.observedAt = observedAt
    }

    public var eligibleForEconomicActual: Bool {
        providerEligibleForEconomicActual && status == .booked && identity == .durable
    }

    /// Boundary comparison is about whether the movement was already included
    /// in an opening balance. Booking evidence therefore wins, followed by the
    /// other provider dates; a parsed date is the conservative last resort.
    public var cutoverComparisonDate: Day? {
        bookingDate ?? transactionDate ?? valueDate ?? derivedTransactionDate
    }

    /// **The** day this observation's economics belong to, and the single
    /// implementation of that rule.
    ///
    /// The order is not arbitrary. A provider-stated `transactionDate` is the
    /// economic occurrence where a provider gives one (PayPal always does).
    /// `derivedTransactionDate` outranks booking because for a BNP card
    /// purchase the parsed capture day *is* when the money was spent and
    /// booking is only when the bank posted it — the two differ by up to a
    /// fortnight. Booking and value are the remaining evidence, in that order.
    ///
    /// Every consumer that asks "which review or checkpoint period is this
    /// observation in?" must read this property and must not restate the
    /// chain: the semantic projection, the checkpoint exception adapters and
    /// `ReviewEngine` all resolve to this one expression, so they cannot
    /// drift apart. `cutoverComparisonDate` above is a *different* question —
    /// whether the movement was already inside an opening balance — and is
    /// deliberately booking-first.
    public var economicPeriodDay: Day? {
        transactionDate ?? derivedTransactionDate ?? bookingDate ?? valueDate
    }

    /// Best proposed economic day for a person to review. The same day as
    /// `economicPeriodDay`, under the name the review and rule paths already
    /// use; it delegates rather than repeating the chain. This does not alter
    /// or flatten any of the evidence date fields above.
    public var suggestedEconomicDate: Day? { economicPeriodDay }

    public var observedMerchant: String? {
        structuredMerchantName ?? rawMerchantText ?? remittance
    }
}

/// Provider balance evidence stays separate from the ledger's stored anchor.
/// Its type is an extensible token because CLBD, XPCD and ITAV all carry
/// different information. `CurrentHoldings` selects one canonical type per
/// known provider for display; the stored `AccountBalance` is never overwritten.
public struct ProviderBalanceSnapshot: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let bindingID: String
    public let provider: ExternalProvider
    public let balanceType: String
    public let name: String?
    public let amount: Money
    public let referenceDate: Day?
    public let observedAt: Date

    public init(
        id: String,
        bindingID: String,
        provider: ExternalProvider,
        balanceType: String,
        name: String? = nil,
        amount: Money,
        referenceDate: Day? = nil,
        observedAt: Date
    ) {
        self.id = id
        self.bindingID = bindingID
        self.provider = provider
        self.balanceType = balanceType
        self.name = name
        self.amount = amount
        self.referenceDate = referenceDate
        self.observedAt = observedAt
    }
}

/// How provider evidence supports a user-confirmed economic transaction.
public enum ExternalEvidenceRole: String, Hashable, Sendable, Codable, CaseIterable {
    case accountMovement
    case merchantEnrichment
    case supportingEvidence
}

public struct ExternalEvidenceLink: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let observationID: String
    public let transactionID: String
    public let role: ExternalEvidenceRole

    public init(id: String, observationID: String, transactionID: String, role: ExternalEvidenceRole) {
        self.id = id
        self.observationID = observationID
        self.transactionID = transactionID
        self.role = role
    }
}

/// Every observation has an explicit state. Absence never means reviewed.
public enum ObservationResolutionState: String, Hashable, Sendable, Codable, CaseIterable {
    case unreviewed
    case linkedToTransaction
    case noEconomicEffect
    case outsideSyncBoundary
    case provisional
    case economicallyIneligible
}

public extension ExternalObservation {

    /// A row that exists only to carry a provider's current pending view.
    ///
    /// Both halves are required, and the pair is the whole point. Pending
    /// snapshot rows are keyed per sync run, so a fresh set of ids arrives
    /// with every successful sync and `importBatch` never removes the old
    /// ones — matching on identity alone would keep readmitting transport
    /// noise, and matching on the resolution alone would throw away a real
    /// row that has regressed.
    ///
    /// A *durable* observation whose provider status falls back to pending is
    /// reclassified `.provisional` by `reclassifyIfUnresolved` while keeping
    /// `.durable` identity, so it is not transport-only and stays visible.
    func isTransportOnlyProvisionalSnapshot(
        resolution: ObservationResolutionState
    ) -> Bool {
        identity == .provisionalSnapshot && resolution == .provisional
    }

    /// Whether this observation is part of what a period *means*.
    ///
    /// Two exclusions, and no others. `.outsideSyncBoundary` rows sit before
    /// the binding's own start and are deliberately outside the live economic
    /// evidence surface. Transport-only pending snapshots carry no economic,
    /// plan, budget, forecast, rule or automation effect anywhere else in the
    /// product, and must not carry one here either.
    ///
    /// Everything else stays — including a row a person has already resolved
    /// whose provider identity or status has since degraded. That is exactly
    /// the state a `providerStatusConflict` describes, so dropping it would
    /// hide an exception from the period that carries it.
    func isCheckpointSemanticObservation(
        resolution: ObservationResolutionState
    ) -> Bool {
        resolution != .outsideSyncBoundary
            && !isTransportOnlyProvisionalSnapshot(resolution: resolution)
    }
}

public struct ExternalObservationResolution: Identifiable, Hashable, Sendable, Codable {
    public var id: String { observationID }
    public let observationID: String
    public var state: ObservationResolutionState
    public var resolvedAt: Date?

    public init(observationID: String, state: ObservationResolutionState, resolvedAt: Date? = nil) {
        self.observationID = observationID
        self.state = state
        self.resolvedAt = resolvedAt
    }
}

/// The backend's conservative PayPal pairing result. Even `.unique` is only a
/// suggestion; this record never creates an evidence link by itself.
public enum CrossProviderCandidateState: Hashable, Sendable, Codable {
    case unique
    case ambiguous
    case unresolved
    case other(String)

    public init(providerToken: String) {
        switch providerToken.lowercased() {
        case "unique": self = .unique
        case "ambiguous": self = .ambiguous
        case "unresolved": self = .unresolved
        default: self = .other(providerToken)
        }
    }

    public var token: String {
        switch self {
        case .unique: "unique"
        case .ambiguous: "ambiguous"
        case .unresolved: "unresolved"
        case let .other(token): token
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(providerToken: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(token)
    }
}

public struct CrossProviderCandidate: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let bankObservationID: String
    public let walletObservationID: String?
    public let state: CrossProviderCandidateState
    public let candidateCount: Int
    public let amount: Money
    public let dayOffset: Int?
    public let rule: String
    public let computedAt: Date

    public init(
        id: String,
        bankObservationID: String,
        walletObservationID: String?,
        state: CrossProviderCandidateState,
        candidateCount: Int,
        amount: Money,
        dayOffset: Int? = nil,
        rule: String,
        computedAt: Date
    ) {
        self.id = id
        self.bankObservationID = bankObservationID
        self.walletObservationID = walletObservationID
        self.state = state
        self.candidateCount = candidateCount
        self.amount = amount
        self.dayOffset = dayOffset
        self.rule = rule
        self.computedAt = computedAt
    }
}

/// One local feed read. Phase 2.4C uses synthetic/local implementations; a
/// device-authenticated transport can supply the same value in Phase 2.4D.
public struct ExternalEvidenceBatch: Hashable, Sendable {
    public var observations: [ExternalObservation]
    public var balances: [ProviderBalanceSnapshot]
    public var candidates: [CrossProviderCandidate]

    public init(
        observations: [ExternalObservation] = [],
        balances: [ProviderBalanceSnapshot] = [],
        candidates: [CrossProviderCandidate] = []
    ) {
        self.observations = observations
        self.balances = balances
        self.candidates = candidates
    }
}
