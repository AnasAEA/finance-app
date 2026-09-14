/// Pure baseline comparison: what the checkpoint source holds, against what
/// the period means now.
///
/// ## What this file may know
///
/// Two values and nothing else. `PeriodCheckpointBaselineSource` is what a
/// read of the checkpoint history returned — a failure, an empty history, or
/// the latest accepted revision. `PeriodCheckpointCurrentState` is the
/// period's current canonical semantic projection, or the reasons it cannot be
/// compared. No repository, no clock, no store, no SwiftData, and no write of
/// any kind: Phase 2.9C-B adds no persistence.
///
/// ## Comparison authority
///
/// Canonical `SemanticPeriodProjection` payloads only. Nothing here reads
/// `ReviewTotals`, `ReviewResult.totals` or `Economics.totals`, and nothing
/// diffs JSON, SwiftData or a `ReviewResult`.

// MARK: - Baseline input

/// A baseline as the checkpoint source holds it.
///
/// Construction from a `PeriodCheckpointRevision` inherits that type's own
/// validation: its payload is a reconstructed, re-encoded canonical projection
/// and its digest is derived from those exact bytes, so payload/digest/format
/// consistency is structural rather than re-checked here.
public struct PeriodCheckpointBaseline: Sendable {

    public let period: SemanticInterval
    public let periodKind: ReviewPeriodKind

    /// The quality the revision recorded. An audit fact, never recomputed.
    public let previousQuality: PeriodCheckpointQuality

    /// The format token the baseline was written under.
    public let formatToken: String

    /// The validated canonical payload, present exactly when `formatToken`
    /// names a projection format this build can read.
    public let payload: CanonicalSemanticPeriodProjection?

    /// The ordinary path: a revision this build wrote and validated.
    public init(_ revision: PeriodCheckpointRevision) {
        period = revision.period
        periodKind = revision.periodKind
        previousQuality = revision.quality
        formatToken = revision.projectionFormatVersion.token
        payload = revision.canonicalProjection
    }

    /// A baseline stored under a projection format this build cannot read.
    ///
    /// No bytes are accepted, because bytes in an unknown format cannot be
    /// parsed into this build's types — which is the whole reason the state
    /// exists. A token this build *does* support is rejected rather than
    /// quietly believed: that would weaken V1 validation by letting an
    /// unvalidated V1 baseline in through the back door.
    public init(
        period: SemanticInterval,
        periodKind: ReviewPeriodKind,
        previousQuality: PeriodCheckpointQuality,
        unreadableFormatToken token: String
    ) throws {
        guard (try? SemanticPeriodProjectionFormat(token: token)) == nil else {
            throw PeriodCheckpointComparisonError.supportedFormatDeclaredUnreadable
        }
        self.period = period
        self.periodKind = periodKind
        self.previousQuality = previousQuality
        self.formatToken = token
        self.payload = nil
    }
}

/// What a read of the checkpoint history returned for one period.
///
/// The distinction this type exists to make: a store that could not be read is
/// not a store that was read and holds nothing. The first establishes no
/// baseline state at all; the second establishes that the period has never
/// been closed.
public enum PeriodCheckpointBaselineSource: Sendable {

    /// The source could not be read, or a stored payload could not be
    /// validated.
    case unavailable(PeriodCheckpointBaselineComparison.Unavailability)

    /// The source was read successfully and holds no revision for this period.
    case noRevision

    /// The source was read successfully; this is its latest accepted revision.
    case latest(PeriodCheckpointBaseline)
}

// MARK: - Current input

/// The period as it stands now, for comparison purposes only.
///
/// Either the current canonical projection, or the reasons the period cannot
/// presently be compared. Never both, and never neither: a period with no
/// usable projection always states why.
public struct PeriodCheckpointCurrentState: Sendable {

    public enum Comparability: Sendable {
        /// The current semantic state can stand against a baseline.
        case comparable(CanonicalSemanticPeriodProjection)
        /// It cannot, for these reasons.
        case limited(PeriodCheckpointComparabilityLimits)
    }

    public let period: SemanticInterval
    public let kind: ReviewPeriodKind
    public let comparability: Comparability

    /// A period whose current canonical projection is available. Period and
    /// kind come from the payload, so they cannot disagree with what will be
    /// compared.
    public init(_ payload: CanonicalSemanticPeriodProjection) {
        period = payload.projection.period
        kind = payload.projection.kind
        comparability = .comparable(payload)
    }

    /// A period that currently cannot be compared, and why.
    public init(
        period: SemanticInterval,
        kind: ReviewPeriodKind,
        limits: PeriodCheckpointComparabilityLimits
    ) {
        self.period = period
        self.kind = kind
        self.comparability = .limited(limits)
    }

    /// From an evaluated readiness.
    ///
    /// Blockers win: a period the evaluator will not let a person close is a
    /// period whose current meaning cannot be asserted against a prior close
    /// either. A projection that is absent or that fails to canonicalize is
    /// itself a comparability limit — `.semanticProjectionUnavailable` — and
    /// never a claim that the period changed.
    public init(_ readiness: PeriodCheckpointReadiness) {
        period = readiness.period
        kind = readiness.kind
        if let limits = PeriodCheckpointComparabilityLimits(readiness.blockers.map(\.kind)) {
            comparability = .limited(limits)
        } else if let projection = readiness.projection,
                  let payload = try? CanonicalSemanticPeriodProjection(projection) {
            comparability = .comparable(payload)
        } else {
            comparability = .limited(
                PeriodCheckpointComparabilityLimits(.semanticProjectionUnavailable)
            )
        }
    }
}

// MARK: - Comparator

/// Pure `(baseline, current)` → `PeriodCheckpointBaselineComparison`.
public enum PeriodCheckpointBaselineComparator {

    /// The projection format this build compares in. A stored baseline written
    /// under any other format cannot be compared and must be re-verified.
    public static let comparisonFormat: SemanticPeriodProjectionFormat = .v1

    /// Compare one period's current state against its checkpoint baseline.
    ///
    /// Precedence, and the reason for it:
    ///
    /// 1. Period and period kind are preconditions. A revision for August
    ///    compared against September is a caller error, never a change.
    /// 2. Format incompatibility outranks current comparability. It is a
    ///    durable property of the stored baseline that better current evidence
    ///    will never resolve, whereas an indeterminate current period is
    ///    transient; reporting the durable answer keeps the state stable.
    /// 3. Current comparability outranks any digest comparison. A period whose
    ///    own evidence is insufficient is `.indeterminate`, never `.changed`.
    /// 4. Digest equality decides unchanged. Only a difference is explained by
    ///    decoding and classifying the payloads.
    ///
    /// - Throws: `PeriodCheckpointComparisonError` for a request precondition
    ///   or a classifier invariant failure. Never for a period that has simply
    ///   moved.
    public static func compare(
        baseline: PeriodCheckpointBaselineSource,
        current: PeriodCheckpointCurrentState
    ) throws -> PeriodCheckpointBaselineComparison {

        switch baseline {
        case let .unavailable(reason):
            return .unavailable(reason)

        case .noRevision:
            return .notPreviouslyClosed

        case let .latest(stored):
            guard stored.period == current.period else {
                throw PeriodCheckpointComparisonError.periodMismatch
            }
            guard stored.periodKind == current.kind else {
                throw PeriodCheckpointComparisonError.periodKindMismatch
            }

            guard let storedPayload = stored.payload,
                  storedPayload.format == comparisonFormat
            else {
                return .requiresReverification(
                    previousQuality: stored.previousQuality,
                    storedFormatToken: stored.formatToken,
                    comparisonFormat: comparisonFormat
                )
            }

            let currentPayload: CanonicalSemanticPeriodProjection
            switch current.comparability {
            case let .limited(limits):
                return .indeterminate(previousQuality: stored.previousQuality,
                                      blockers: limits)
            case let .comparable(payload):
                currentPayload = payload
            }

            // The digest is the equality shortcut and nothing more. Both sides
            // are validated canonical payloads whose digests are derived from
            // their own bytes, so equal digests mean equal canonical bytes and
            // therefore equal semantic state.
            if storedPayload.digest == currentPayload.digest {
                return .unchangedSinceClose(previousQuality: stored.previousQuality)
            }

            // The canonical payload, not the digest, is the explanation source.
            let derived = try PeriodCheckpointChangeClassifier.classes(
                from: storedPayload.projection, to: currentPayload.projection
            )
            guard let changes = PeriodCheckpointChangeClasses(derived) else {
                throw PeriodCheckpointComparisonError.unclassifiedChange
            }
            return .changedSinceClose(previousQuality: stored.previousQuality,
                                      changes: changes)
        }
    }
}

// MARK: - Classifier

/// Which semantic dimensions two projections of the same period differ along.
///
/// Deterministic and field-structural: every canonical V1 field is compared by
/// the class it belongs to, so a difference can never fall between the
/// classes. One mutation may legitimately produce several classes when it
/// really did move several independent dimensions; exclusivity is not forced.
///
/// Acknowledgment identity, safe claims and checkpoint quality are not
/// compared here. Safe claims are derived from exception semantics, which the
/// projection-equality invariant already ties to the projection; carrying-
/// forward acknowledgments needs a semantic key that does not exist yet.
public enum PeriodCheckpointChangeClassifier {

    /// - Returns: every class along which the two projections differ. Empty
    ///   when every classified dimension is equal.
    /// - Throws: `.periodMismatch` / `.periodKindMismatch`. Period and kind are
    ///   preconditions of a comparison, never dimensions of a change.
    public static func classes(
        from previous: SemanticPeriodProjection,
        to current: SemanticPeriodProjection
    ) throws -> Set<PeriodCheckpointChangeClass> {

        guard previous.period == current.period else {
            throw PeriodCheckpointComparisonError.periodMismatch
        }
        guard previous.kind == current.kind else {
            throw PeriodCheckpointComparisonError.periodKindMismatch
        }

        var found: Set<PeriodCheckpointChangeClass> = []

        if previous.coverage != current.coverage {
            found.insert(.coverageChanged)
        }

        // The resolved period figure is economics, not attribution: a
        // cross-period linked original can move it while this period's own
        // transaction facts are identical.
        if previous.budget.periodEconomicSpending != current.budget.periodEconomicSpending {
            found.insert(.economicsChanged)
        }
        if previous.budget.uncategorized != current.budget.uncategorized
            || counted(previous.budget.attributions) != counted(current.budget.attributions) {
            found.insert(.budgetAttributionChanged)
        }

        found.formUnion(transactionClasses(previous.transactions, current.transactions))
        found.formUnion(observationClasses(previous.observations, current.observations))

        if counted(previous.expectations) != counted(current.expectations) {
            found.insert(.expectationChanged)
        }

        return found
    }

    // MARK: Transactions

    /// A transaction's economic axis: every field except the category key,
    /// which is attribution. Identity is the grouping key, not a member.
    private struct TransactionEconomics: Hashable {
        let day: Day
        let kind: TransactionKind
        let lifecycle: TransactionLifecycle
        let factivity: Factivity
        let legs: [SemanticLegFact]
        let incomeSourceID: String?
        let ownedMinorUnits: Int64?

        init(_ fact: SemanticTransactionFact) {
            day = fact.day
            kind = fact.kind
            lifecycle = fact.lifecycle
            factivity = fact.factivity
            legs = fact.legs
            incomeSourceID = fact.incomeSourceID
            ownedMinorUnits = fact.ownedMinorUnits
        }
    }

    private static func transactionClasses(
        _ previous: [SemanticTransactionFact], _ current: [SemanticTransactionFact]
    ) -> Set<PeriodCheckpointChangeClass> {
        var found: Set<PeriodCheckpointChangeClass> = []
        let before = Dictionary(grouping: previous, by: \.id)
        let after = Dictionary(grouping: current, by: \.id)
        for id in Set(before.keys).union(after.keys) {
            guard let mine = before[id], let theirs = after[id] else {
                // Membership. A transaction that appeared or disappeared moved
                // the period's economics whatever else it carried.
                found.insert(.economicsChanged)
                continue
            }
            if counted(mine.map(TransactionEconomics.init))
                != counted(theirs.map(TransactionEconomics.init)) {
                found.insert(.economicsChanged)
            }
            if counted(mine.map(\.categoryKey)) != counted(theirs.map(\.categoryKey)) {
                found.insert(.budgetAttributionChanged)
            }
        }
        return found
    }

    // MARK: Observations

    /// What an observation says as evidence: its content, what a person
    /// decided about it, and what it is linked to.
    private struct ObservationEvidence: Hashable {
        let minorUnits: Int64
        let currencyCode: String
        let economicDay: Day?
        let resolution: ObservationResolutionState
        let links: [SemanticEvidenceLinkFact]

        init(_ fact: SemanticObservationFact) {
            minorUnits = fact.minorUnits
            currencyCode = fact.currencyCode
            economicDay = fact.economicDay
            resolution = fact.resolution
            links = fact.links
        }
    }

    /// What the provider says about the row, and whether its binding is live.
    private struct ObservationProviderState: Hashable {
        let statusToken: String
        let identity: ExternalObservationIdentity
        let providerEligibleForEconomicActual: Bool
        let bindingIsActive: Bool

        init(_ fact: SemanticObservationFact) {
            statusToken = fact.statusToken
            identity = fact.identity
            providerEligibleForEconomicActual = fact.providerEligibleForEconomicActual
            bindingIsActive = fact.bindingIsActive
        }
    }

    private static func observationClasses(
        _ previous: [SemanticObservationFact], _ current: [SemanticObservationFact]
    ) -> Set<PeriodCheckpointChangeClass> {
        var found: Set<PeriodCheckpointChangeClass> = []
        let before = Dictionary(grouping: previous, by: \.id)
        let after = Dictionary(grouping: current, by: \.id)
        for id in Set(before.keys).union(after.keys) {
            guard let mine = before[id], let theirs = after[id] else {
                // Membership is an evidence fact. Provider state and aggregate
                // relationship stay reserved for rows that exist on both sides,
                // so those classes keep meaning what they say.
                found.insert(.evidenceChanged)
                continue
            }
            if counted(mine.map(ObservationEvidence.init))
                != counted(theirs.map(ObservationEvidence.init)) {
                found.insert(.evidenceChanged)
            }
            if counted(mine.map(ObservationProviderState.init))
                != counted(theirs.map(ObservationProviderState.init)) {
                found.insert(.providerStateChanged)
            }
            if counted(mine.map(\.aggregate)) != counted(theirs.map(\.aggregate)) {
                found.insert(.aggregateRelationshipChanged)
            }
        }
        return found
    }

    // MARK: Multiset comparison

    /// Compares by membership and multiplicity rather than by array order.
    ///
    /// The projection's `Comparable` conformances order transactions,
    /// observations and expectations by identity alone, so two facts that
    /// compare equal may still hold different values and their relative order
    /// is not part of the meaning. Counting removes any dependence on it.
    private static func counted<T: Hashable>(_ values: [T]) -> [T: Int] {
        var result: [T: Int] = [:]
        for value in values { result[value, default: 0] += 1 }
        return result
    }
}
