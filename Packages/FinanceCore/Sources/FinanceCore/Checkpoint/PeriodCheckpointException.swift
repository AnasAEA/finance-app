/// Typed exceptions a period checkpoint may carry, and what each one costs.
///
/// An exception is a *known, named* limitation of what the period can claim.
/// It is never a repair: acknowledging one changes no amount, no sign, no date
/// and no balance. It only records that a person has seen the limitation and
/// chose to close the period with it carried.
///
/// The impact of an exception is a **pure function of its typed kind and
/// basis**, computed here once. It is deliberately not a set of booleans a
/// caller supplies, because the whole point is that a presentation layer
/// cannot later decide that its own exception is harmless.

// MARK: - Kinds

public enum PeriodCheckpointExceptionKind: String, Sendable, Hashable, Codable, CaseIterable {

    /// A booked provider observation in the period whose economic meaning is
    /// still unknown. The movement is real; what it *means* is not decided.
    case unknownBookedEconomics

    /// The economics are known and recorded, but the provider evidence that
    /// supports them is not linked to its transaction.
    case unresolvedEvidenceLinkage

    /// One booked observation stands against several existing economic
    /// transactions. The evidence schema carries one observation to at most
    /// one transaction, so the relationship cannot be recorded at all.
    /// See `AggregateEvidenceBasis` — how strongly the relationship is
    /// established decides what the period may still claim.
    case aggregateEvidenceModelLimitation

    /// A recorded movement whose economic kind is undecided — whether it is
    /// economic spending, account movement, or neither.
    case unresolvedEconomicClassification

    /// An inflow whose income stream or owned share is undecided.
    case unresolvedIncomeClassificationOrOwnership

    /// Confirmed economic spending that is attributed to no budget line. The
    /// euro is counted; the line it belongs to is not known.
    case uncategorizedEconomicSpending

    /// An expected occurrence whose day passed inside the period with nothing
    /// settling it. Neither "it happened" nor "it did not" is established.
    case overdueExpectedOccurrence

    /// The provider has since withdrawn or downgraded a row a person already
    /// resolved. Their decision stands; the two records disagree.
    case providerStatusConflict

    /// A comparable provider/ledger amount difference a person has accepted as
    /// explained. It remains on the record as a reconciliation note.
    case acceptedReconciliationAmountDifference
}

/// How well an aggregate evidence relationship is established.
///
/// This distinction is the whole of refinement C. An arithmetic pairing that
/// *sums* to an observation is a structural candidate, not proof that the
/// observation is the same money: two unrelated charges can add up. Only
/// source-backed typed facts may license the stronger claim, and nothing in
/// the current schema produces them — see `PeriodCheckpointException`'s
/// ownership notes.
public enum AggregateEvidenceBasis: String, Sendable, Hashable, Codable, CaseIterable {

    /// Typed source facts — not an arithmetic heuristic — establish that the
    /// booked observation is the same money as the existing transactions.
    /// Economic totals are therefore already complete; only the *link* is
    /// unrecordable.
    case sourceEstablishedAggregateRelationship

    /// Only a structural/arithmetic pairing suggests the relationship. The
    /// observation may still be money that no transaction represents, so the
    /// period's totals stay questionable.
    case structuralCandidateOnly
}

// MARK: - Impact

/// What one exception costs the period, on three independent axes.
///
/// Each flag reads "this claim is **no longer safe**". They are derived here
/// so a later UI cannot re-decide them; see `PeriodCheckpointSafeClaims`.
public struct PeriodCheckpointExceptionImpact: Hashable, Sendable, Codable {

    /// The period's economic totals can no longer be called unquestionably
    /// complete. Calculated totals may still be *shown* as calculated.
    public let compromisesTotalsCompleteness: Bool

    /// Not every economic euro is attributed to a budget line.
    public let compromisesCategoryCompleteness: Bool

    /// Not every booked observation in the period has a settled, recorded
    /// evidence relationship.
    public let compromisesAuditCompleteness: Bool

    public init(
        compromisesTotalsCompleteness: Bool,
        compromisesCategoryCompleteness: Bool,
        compromisesAuditCompleteness: Bool
    ) {
        self.compromisesTotalsCompleteness = compromisesTotalsCompleteness
        self.compromisesCategoryCompleteness = compromisesCategoryCompleteness
        self.compromisesAuditCompleteness = compromisesAuditCompleteness
    }

    public static let none = PeriodCheckpointExceptionImpact(
        compromisesTotalsCompleteness: false,
        compromisesCategoryCompleteness: false,
        compromisesAuditCompleteness: false
    )
}

// MARK: - Exception

/// One carried limitation. Identity is caller-supplied and must be stable and
/// free of anything private: it exists so acknowledgment and ordering are
/// deterministic, not so a row can be traced back to a counterparty.
public struct PeriodCheckpointException: Identifiable, Hashable, Sendable {

    public let id: String
    public let kind: PeriodCheckpointExceptionKind

    /// Only meaningful for `.aggregateEvidenceModelLimitation`. Ignored — and
    /// required to be nil — for every other kind, so a basis cannot be smuggled
    /// onto an exception it does not describe.
    public let aggregateBasis: AggregateEvidenceBasis?

    /// The day inside the period the exception concerns, when it has one.
    public let day: Day?

    /// The amount at stake, when the exception has a single coherent one.
    /// Carried beside `day` from one source, never assembled from two.
    public let amount: Money?

    public init(
        id: String,
        kind: PeriodCheckpointExceptionKind,
        aggregateBasis: AggregateEvidenceBasis? = nil,
        day: Day? = nil,
        amount: Money? = nil
    ) {
        precondition(
            kind == .aggregateEvidenceModelLimitation || aggregateBasis == nil,
            "an aggregate basis only describes .aggregateEvidenceModelLimitation"
        )
        precondition(
            kind != .aggregateEvidenceModelLimitation || aggregateBasis != nil,
            "an aggregate model limitation must state how strongly it is established"
        )
        self.id = id
        self.kind = kind
        self.aggregateBasis = aggregateBasis
        self.day = day
        self.amount = amount
    }

    /// The cost of this exception. A pure function of `kind` and
    /// `aggregateBasis`; nothing else on the exception can change it.
    public var impact: PeriodCheckpointExceptionImpact {
        switch kind {
        case .unknownBookedEconomics:
            // Real money moved and nobody has said what it was. It could be
            // spending, a transfer, or somebody else's — every axis suffers.
            return PeriodCheckpointExceptionImpact(
                compromisesTotalsCompleteness: true,
                compromisesCategoryCompleteness: true,
                compromisesAuditCompleteness: true
            )

        case .unresolvedEvidenceLinkage:
            // The economics are recorded and counted. Only the evidence trail
            // is short, which is an audit fact and nothing more.
            return PeriodCheckpointExceptionImpact(
                compromisesTotalsCompleteness: false,
                compromisesCategoryCompleteness: false,
                compromisesAuditCompleteness: true
            )

        case .aggregateEvidenceModelLimitation:
            switch aggregateBasis {
            case .sourceEstablishedAggregateRelationship:
                // The money is proven to be the same money. Only the schema's
                // one-observation/one-transaction shape cannot record it.
                return PeriodCheckpointExceptionImpact(
                    compromisesTotalsCompleteness: false,
                    compromisesCategoryCompleteness: false,
                    compromisesAuditCompleteness: true
                )
            case .structuralCandidateOnly, .none:
                // An arithmetic sum is not a proof of identity. The
                // observation may be money no transaction represents.
                return PeriodCheckpointExceptionImpact(
                    compromisesTotalsCompleteness: true,
                    compromisesCategoryCompleteness: true,
                    compromisesAuditCompleteness: true
                )
            }

        case .unresolvedEconomicClassification:
            // Whether this euro is economic spending is undecided, so both the
            // total and the line it might belong to are open questions. The
            // evidence itself is present and linked.
            return PeriodCheckpointExceptionImpact(
                compromisesTotalsCompleteness: true,
                compromisesCategoryCompleteness: true,
                compromisesAuditCompleteness: false
            )

        case .unresolvedIncomeClassificationOrOwnership:
            // Personal income and the owned share are part of the period's
            // totals. Budget lines are a spending dimension and are untouched.
            return PeriodCheckpointExceptionImpact(
                compromisesTotalsCompleteness: true,
                compromisesCategoryCompleteness: false,
                compromisesAuditCompleteness: false
            )

        case .uncategorizedEconomicSpending:
            // The canonical category-only limitation: the euro is counted in
            // economic spending, it simply belongs to no line.
            return PeriodCheckpointExceptionImpact(
                compromisesTotalsCompleteness: false,
                compromisesCategoryCompleteness: true,
                compromisesAuditCompleteness: false
            )

        case .overdueExpectedOccurrence:
            // A missing period is never zero. Either the charge did not happen
            // or it happened and is unrecorded, and the two are not the same
            // answer.
            return PeriodCheckpointExceptionImpact(
                compromisesTotalsCompleteness: true,
                compromisesCategoryCompleteness: true,
                compromisesAuditCompleteness: false
            )

        case .providerStatusConflict:
            // The person's decision stands, but the provider has withdrawn its
            // side of it. The recorded amount is disputed, not merely unlinked.
            return PeriodCheckpointExceptionImpact(
                compromisesTotalsCompleteness: true,
                compromisesCategoryCompleteness: false,
                compromisesAuditCompleteness: true
            )

        case .acceptedReconciliationAmountDifference:
            // Accepted means explained. The ledger's totals stand; the
            // difference stays on the record as a reconciliation note.
            return PeriodCheckpointExceptionImpact(
                compromisesTotalsCompleteness: false,
                compromisesCategoryCompleteness: false,
                compromisesAuditCompleteness: true
            )
        }
    }
}

// MARK: - Safe claims

/// What a checkpoint may truthfully say about its period.
///
/// Derived from the actual carried exceptions, never from their count and
/// never from the disposition. A clean period claims everything; a period with
/// exceptions claims exactly what the impacts leave standing.
public struct PeriodCheckpointSafeClaims: Hashable, Sendable, Codable {

    /// Calculated figures may be displayed *as calculated*. False only when
    /// the period is blocked — a total behind uncovered days is not a total.
    public let mayShowCalculatedTotals: Bool

    /// The period's economic totals may be called unquestionably complete.
    public let unquestionablyCompleteTotals: Bool

    /// Every economic euro in the period is attributed to a budget line.
    public let completeCategoryAttribution: Bool

    /// Every booked observation in the period has a settled evidence
    /// relationship.
    public let completeEvidenceAudit: Bool

    public init(
        mayShowCalculatedTotals: Bool,
        unquestionablyCompleteTotals: Bool,
        completeCategoryAttribution: Bool,
        completeEvidenceAudit: Bool
    ) {
        self.mayShowCalculatedTotals = mayShowCalculatedTotals
        self.unquestionablyCompleteTotals = unquestionablyCompleteTotals
        self.completeCategoryAttribution = completeCategoryAttribution
        self.completeEvidenceAudit = completeEvidenceAudit
    }

    /// Nothing may be claimed — the period is blocked.
    public static let blocked = PeriodCheckpointSafeClaims(
        mayShowCalculatedTotals: false,
        unquestionablyCompleteTotals: false,
        completeCategoryAttribution: false,
        completeEvidenceAudit: false
    )

    /// Claims that survive `exceptions`. An unblocked period may always show
    /// its calculated figures.
    public static func surviving(_ exceptions: [PeriodCheckpointException]) -> PeriodCheckpointSafeClaims {
        var totals = true
        var category = true
        var audit = true
        for exception in exceptions {
            let impact = exception.impact
            if impact.compromisesTotalsCompleteness { totals = false }
            if impact.compromisesCategoryCompleteness { category = false }
            if impact.compromisesAuditCompleteness { audit = false }
        }
        return PeriodCheckpointSafeClaims(
            mayShowCalculatedTotals: true,
            unquestionablyCompleteTotals: totals,
            completeCategoryAttribution: category,
            completeEvidenceAudit: audit
        )
    }
}
