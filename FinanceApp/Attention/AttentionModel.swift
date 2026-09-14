import Foundation

/// The Financial Attention Loop's NOW question — "is there anything I should
/// do?" — expressed as product-facing value types.
///
/// ## Ownership
///
/// This file holds **vocabulary and shape only**. It computes nothing.
/// `AttentionCoordinator` decides what is primary; `AttentionFactAdapters`
/// turns authoritative engine results into proposals. Neither of those, and
/// nothing here, recalculates a balance, a holding, spending, income, a
/// budget, a forecast, a first risk, an expected occurrence, or the economics
/// of a piece of evidence. Every figure on a candidate is carried verbatim
/// from the engine that owns it.
///
/// Deliberately free of `FinanceCore` and `SwiftData`, so Phase 2.9B can
/// consume these types from SwiftUI without a screen importing either.

// MARK: - Candidate kinds

/// The closed vocabulary of things a person may be asked to do.
///
/// There is deliberately no candidate for normal budget progress, ordinary
/// spending, a healthy balance, complete coverage, pending or provisional
/// evidence, a floor-only warning, the aggregate model limitation itself, or a
/// suggested transfer source. Those are states of the world, not tasks.
enum AttentionCandidateKind: String, Hashable, Sendable, CaseIterable, Comparable {

    /// Money will be missing on a specific day, by a specific amount.
    case requiredFundingGap

    /// A provider connection is in a state that explicitly requires a person.
    case authorityNeedsAttention

    /// Provider and ledger disagree in a way that compromises something else.
    case currentAccountDrift

    /// A booked provider observation is waiting for an economic decision.
    case unresolvedBookedEvidence

    /// An expected charge's day passed with nothing settling it.
    case overdueExpectedOccurrence

    /// A period is ready to be closed.
    case monthReadyToClose

    /// Nominal precedence, 1 (highest) to 6. Validity gating overrides it:
    /// occupying a high slot never makes an ineligible candidate primary.
    var nominalPrecedence: Int {
        switch self {
        case .requiredFundingGap: 1
        case .authorityNeedsAttention: 2
        case .currentAccountDrift: 3
        case .unresolvedBookedEvidence: 4
        case .overdueExpectedOccurrence: 5
        case .monthReadyToClose: 6
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.nominalPrecedence < rhs.nominalPrecedence
    }
}

// MARK: - Dependencies

/// The closed set of things a candidate can depend on.
///
/// A small typed vocabulary on purpose: eligibility is a set comparison, not a
/// runtime graph. Adding a key is a deliberate semantic act, not configuration.
enum AttentionDependencyKey: String, Hashable, Sendable, CaseIterable, Comparable {

    /// Current account balances and holdings mean what they say.
    case currentAccountTruth

    /// Provider connection authority is usable.
    case providerAuthority

    /// One successful authoritative forecast result exists.
    case forecastProjection

    /// The evidence review queue is readable and its resolutions are explicit.
    case evidenceReviewQueue

    /// Expected occurrences and their settlements could be expanded.
    case expectedOccurrenceLedger

    /// One successful review of the period in question.
    case periodReview

    /// Authoritative prior-close state for the period. Phase 2.9A has no
    /// checkpoint persistence, so this is always unavailable here.
    case periodCheckpointBaseline

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Which question a source bears on. Refinement A: assessment completeness is
/// domain-scoped, so an unavailable source poisons only the domains that
/// actually require it.
enum AttentionSourceDomain: String, Hashable, Sendable, CaseIterable {

    /// "Is there anything I should do right now?"
    case currentAttention

    /// "Can I close this period?"
    case periodCheckpoint

    /// "Has this period already been closed, and has it changed since?"
    case checkpointBaseline

    /// The keys a domain needs before it may return a *negative* answer.
    ///
    /// These are the keys required for the domain to say "nothing here"; a
    /// domain may still produce candidates from the keys that did succeed.
    var requiredKeys: Set<AttentionDependencyKey> {
        switch self {
        case .currentAttention:
            [.currentAccountTruth, .providerAuthority, .forecastProjection,
             .evidenceReviewQueue, .expectedOccurrenceLedger]
        case .periodCheckpoint:
            [.periodReview]
        case .checkpointBaseline:
            [.periodCheckpointBaseline]
        }
    }
}

/// Why a source could not be used. Distinguishing absent from incoherent
/// matters: an absent source is a gap, an incoherent one is a contradiction.
enum AttentionSourceStatus: Hashable, Sendable {
    case available
    /// The source did not produce a result at all.
    case unavailable(AttentionSourceFailure)
    /// The source produced a result that does not hold together.
    case incoherent(AttentionSourceFailure)

    var isAvailable: Bool { self == .available }
}

/// Named, non-private reasons a source failed.
enum AttentionSourceFailure: String, Hashable, Sendable, Error {
    case notEvaluated
    case engineDidNotProduceResult
    case notImplementedInThisBuild
    case resultInternallyInconsistent
    case currencyMismatch
    case amountOutsideExpectedRange
    case dayOutsideEvaluatedHorizon
}

/// Per-key source outcomes, read through a domain scope.
///
/// The whole of refinement A lives here: nothing asks "did every source
/// succeed?", only "did every source *this question needs* succeed?".
struct AttentionSourceAvailability: Hashable, Sendable {

    private var statuses: [AttentionDependencyKey: AttentionSourceStatus]

    init(_ statuses: [AttentionDependencyKey: AttentionSourceStatus] = [:]) {
        self.statuses = statuses
    }

    /// A key never explicitly recorded is `.unavailable(.notEvaluated)`.
    /// Absence is never success.
    func status(_ key: AttentionDependencyKey) -> AttentionSourceStatus {
        statuses[key] ?? .unavailable(.notEvaluated)
    }

    mutating func record(_ key: AttentionDependencyKey, _ status: AttentionSourceStatus) {
        statuses[key] = status
    }

    func recording(
        _ key: AttentionDependencyKey,
        _ status: AttentionSourceStatus
    ) -> AttentionSourceAvailability {
        var copy = self
        copy.record(key, status)
        return copy
    }

    /// Every key the domain requires resolved successfully.
    func isFullyEvaluated(for domain: AttentionSourceDomain) -> Bool {
        domain.requiredKeys.allSatisfy { status($0).isAvailable }
    }

    /// The domain's failed keys, sorted. Empty exactly when fully evaluated.
    func failedKeys(for domain: AttentionSourceDomain) -> [AttentionDependencyKey] {
        domain.requiredKeys.filter { !status($0).isAvailable }.sorted()
    }
}

// MARK: - Eligibility

/// Whether a proposal may be shown, and if not, why.
///
/// Validity comes before priority, always. A suppressed candidate keeps its
/// reason so the suppression is a diagnostic rather than a silence.
enum AttentionEligibility: Hashable, Sendable {

    /// May become primary.
    case eligible

    /// The candidate is real, but a dependency it rests on is compromised and
    /// something else is going to say so. It may be secondary, never primary.
    case secondaryOnlyBecauseDependencyCompromised(AttentionDependencyKey)

    /// A source this candidate needs produced no result.
    case suppressedBecauseSourceUnavailable(AttentionDependencyKey)

    /// A source this candidate needs produced an incoherent result — including
    /// a compromised dependency that nothing eligible is reporting.
    case suppressedBecauseSourceIncoherent(AttentionDependencyKey)

    /// The condition that would have made this a task no longer holds.
    case suppressedBecauseConditionResolved

    /// A real fact with nothing for a person to do about it. This is the
    /// nuisance guard: comparable drift and ordinary freshness live here.
    case suppressedBecauseNotActionable

    /// Another candidate already says this.
    case suppressedBecauseRepresentedBy(AttentionCandidateKind)

    var canBePrimary: Bool { self == .eligible }

    var canBeSecondary: Bool {
        switch self {
        case .eligible, .secondaryOnlyBecauseDependencyCompromised: true
        default: false
        }
    }

    var isSuppressed: Bool { !canBeSecondary }
}

// MARK: - Subjects and details

/// Who or what the action is about.
///
/// `.paymentPool` exists so a less specific truth stays less specific. When
/// the engine proved a single account, the subject names it; when it proved
/// only a pool of eligible accounts, the subject says so rather than picking
/// one. Neither form ever names a *source* to move money from — inferring a
/// transfer source is not this layer's to do.
enum AttentionSubject: Hashable, Sendable {
    case account(id: String, name: String)
    case paymentPool(eligibleAccountIDs: [String], currencyCode: String)
    case providerConnection(providerName: String)
    case observation(id: String)
    case expectedOccurrence(obligationID: String, name: String)
    case period(label: String)
}

/// The funding fact, carried atomically.
///
/// Every field comes from one `ForecastResult.FirstRisk` and the applied event
/// it names. `minimumBridgeRequired` is deliberately absent: it is a
/// horizon-wide up-front bridge and pairing it with a first-risk day would
/// weld an amount and a date from two different computations.
struct RequiredFundingGapFact: Hashable, Sendable {

    enum RiskKind: String, Hashable, Sendable {
        case poolDeficit
        case belowSafetyFloor
    }

    let riskKind: RiskKind
    let day: CalendarDay
    /// `FirstRisk.shortfall`, verbatim.
    let shortfall: Amount
    /// Resolved trigger label, or nil when the trigger cannot be named. Never
    /// an internal event id.
    let triggerLabel: String?
    /// Canonical forecast event identity, consumed only by the presentation
    /// mapper to avoid repeating this exact event in Home's short list.
    let triggerEventID: String
    let subject: AttentionSubject
    /// The settlement failure matching the trigger event, when there is one.
    let settlementFailure: SettlementFailureFact?
}

struct SettlementFailureFact: Hashable, Sendable {
    let day: CalendarDay
    let requested: Amount
    let settled: Amount
    let unsettled: Amount
    let eligibleAccountIDs: [String]
}

/// Provider and ledger disagree by a comparable, nonzero amount.
///
/// A *fact*, not a task. It becomes a candidate only under the policy in
/// `AttentionFactAdapters`; on its own it stays out of Home. See refinement B.
struct CurrentAccountDriftFact: Hashable, Sendable {
    let accountID: String
    let accountName: String
    /// Provider amount minus ledger amount, from `CurrentHoldings.Value`.
    let drift: Amount
    /// Whether the two sides were comparable at all (same currency, both
    /// present). A non-comparable pair produces no drift fact.
    let isComparable: Bool
}

/// The typed payload of a candidate. One case per kind, so a caller cannot
/// attach a funding fact to a close proposal.
enum AttentionCandidateDetail: Hashable, Sendable {
    case fundingGap(RequiredFundingGapFact)
    case authority(state: String)
    case drift(CurrentAccountDriftFact)
    case bookedEvidence(amount: Amount, day: CalendarDay?)
    case overdueOccurrence(amount: Amount, expectedDay: CalendarDay)
    case periodClose(quality: String)
}

// MARK: - Proposals and candidates

/// What a fact adapter produces. Validity has not been decided yet.
struct AttentionCandidateProposal: Hashable, Sendable {

    let kind: AttentionCandidateKind

    /// Stable, deterministic, non-private. Used for ordering and diagnostics,
    /// never rendered.
    let identity: String

    let subject: AttentionSubject
    let detail: AttentionCandidateDetail

    /// The keys this proposal's truth rests on.
    let dependencies: Set<AttentionDependencyKey>

    /// The keys this proposal reports as compromised. An integrity proposal
    /// declares them; every other proposal declares none.
    let compromisedDependencies: Set<AttentionDependencyKey>

    /// Whether a person has something to do about it. `false` is the nuisance
    /// guard, not a way to hide an inconvenient fact.
    let isActionable: Bool

    /// The condition has since been resolved.
    let conditionResolved: Bool

    /// Another kind already says this.
    let representedBy: AttentionCandidateKind?

    /// The day the action concerns, for ordering. nil sorts last.
    let orderingDay: CalendarDay?

    /// The magnitude at stake, for ordering within a kind and day.
    let orderingMinorUnits: Int64

    init(
        kind: AttentionCandidateKind,
        identity: String,
        subject: AttentionSubject,
        detail: AttentionCandidateDetail,
        dependencies: Set<AttentionDependencyKey>,
        compromisedDependencies: Set<AttentionDependencyKey> = [],
        isActionable: Bool = true,
        conditionResolved: Bool = false,
        representedBy: AttentionCandidateKind? = nil,
        orderingDay: CalendarDay? = nil,
        orderingMinorUnits: Int64 = 0
    ) {
        self.kind = kind
        self.identity = identity
        self.subject = subject
        self.detail = detail
        self.dependencies = dependencies
        self.compromisedDependencies = compromisedDependencies
        self.isActionable = isActionable
        self.conditionResolved = conditionResolved
        self.representedBy = representedBy
        self.orderingDay = orderingDay
        self.orderingMinorUnits = orderingMinorUnits
    }
}

/// A proposal with its verdict.
struct AttentionCandidate: Identifiable, Hashable, Sendable {
    let proposal: AttentionCandidateProposal
    let eligibility: AttentionEligibility

    var id: String { "\(proposal.kind.rawValue):\(proposal.identity)" }
    var kind: AttentionCandidateKind { proposal.kind }
    var subject: AttentionSubject { proposal.subject }
    var detail: AttentionCandidateDetail { proposal.detail }
}

// MARK: - Outcome and state

/// What may be said when there is nothing to do.
///
/// The horizon is quoted only from a successful authoritative forecast. When
/// no forecast succeeded, both fields are nil and the quiet statement claims
/// no period of safety at all.
struct AttentionQuiet: Hashable, Sendable {
    let horizonDays: Int?
    let horizonEnd: CalendarDay?

    static let unquantified = AttentionQuiet(horizonDays: nil, horizonEnd: nil)
}

enum AttentionOutcome: Hashable, Sendable {

    /// At least one candidate is eligible or secondary.
    case actionsAvailable

    /// Every source the current-attention question requires was evaluated
    /// successfully and produced nothing. **Not** a candidate.
    case noActionNeeded(AttentionQuiet)

    /// A source the current-attention question requires failed. Never
    /// no-action: the named keys are why.
    case indeterminate(failedKeys: [AttentionDependencyKey])
}

/// The answer to NOW.
struct AttentionState: Hashable, Sendable {

    /// Zero or one. Only an `.eligible` candidate may be here.
    let primary: AttentionCandidate?

    /// Zero to three, in the same deterministic order.
    let secondary: [AttentionCandidate]

    /// Every candidate that represents current actionable work, before the
    /// three-row secondary presentation cap. Display code uses this for a
    /// truthful review count and never reconstructs work from the capped list.
    let actionableCandidates: [AttentionCandidate]

    /// Everything that did not make it, with its reason. Diagnostics: this is
    /// what makes a suppression inspectable instead of invisible.
    let suppressed: [AttentionCandidate]

    let outcome: AttentionOutcome
}
