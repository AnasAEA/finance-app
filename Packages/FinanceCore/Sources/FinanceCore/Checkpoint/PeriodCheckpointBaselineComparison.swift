/// Where this period stands against its own last close, and — when it has
/// moved — along which semantic dimensions.
///
/// ## The two questions this type keeps apart
///
/// 1. *Did we establish the baseline state at all?* — `isEstablished`.
/// 2. *Is the comparison conclusive enough to act on?* — `isConclusive`.
///
/// They are not the same question, and conflating them is what the earlier
/// modelling got wrong. A checkpoint source that is read successfully and
/// holds nothing has established a real fact — "this period has never been
/// closed" — and `.unavailable` must never be used to say it. Equally, a
/// baseline that exists but cannot presently be compared has still been
/// established; it simply cannot yet be called changed or unchanged.
///
/// ## Authority
///
/// `SemanticPeriodProjection`, canonicalized, is the only comparison
/// authority. `ReviewTotals`, `ReviewResult.totals` and `Economics.totals` are
/// never consulted: they are presentation of a period, not its meaning.
///
/// ## Purity
///
/// Nothing here reads a clock, a store or SwiftData. The baseline arrives on
/// the request as a value; see `PeriodCheckpointBaselineSource`. Phase 2.9C-B
/// implements no persistence, so no production caller yet produces
/// `.notPreviouslyClosed` — that wiring belongs to the phase that adds the
/// checkpoint repository.

// MARK: - Change classes

/// The semantic dimension along which a period moved since it was closed.
///
/// A class is a *deterministic statement about which projected dimension
/// differs*, never a causal explanation. "Economics changed" does not say a
/// person spent differently; it says the projected economic facts of this
/// period are not the ones that were closed.
///
/// The vocabulary is closed and finite on purpose. There is no `other` and no
/// `unknownChange`: a digest difference that maps to no class is a failure of
/// this classifier or of the canonical serializer, not a legitimate answer.
public enum PeriodCheckpointChangeClass: String, Sendable, Hashable, Codable, CaseIterable {

    /// `SemanticCoverage` differs — completeness, status, missing intervals or
    /// reason kinds.
    ///
    /// This class means *comparable coverage moved*. A current period whose
    /// coverage is too weak to compare at all is not classified here; it makes
    /// the whole comparison `.indeterminate`.
    case coverageChanged

    /// The period's economic meaning differs.
    ///
    /// Two independent sources feed it, and both are required:
    ///
    /// - the raw `SemanticTransactionFact` economics — membership, economic
    ///   day, kind, lifecycle, factivity, legs, income source and owned share;
    /// - `SemanticBudgetFact.periodEconomicSpending`, the *resolved* figure.
    ///
    /// The second is not redundant. A cross-period linked original can change
    /// this period's resolved economic spending while every transaction fact
    /// inside the period stays byte-identical, and calling that mere budget
    /// attribution would understate what moved.
    case economicsChanged

    /// Resolved attribution differs — `SemanticBudgetFact.attributions`,
    /// `SemanticBudgetFact.uncategorized`, or a transaction's `categoryKey`.
    ///
    /// Budget ceilings, remaining and overage are deliberately outside
    /// `SemanticPeriodProjection` and therefore outside this class.
    case budgetAttributionChanged

    /// Observation evidence differs — membership, the evidential content of an
    /// observation (amount, currency, economic day), its resolution, or its
    /// links to transactions.
    ///
    /// Provider-reported state and the aggregate relationship have their own
    /// classes and are excluded here, so a provider change is never hidden
    /// behind "the observation differs".
    case evidenceChanged

    /// Provider-reported state of an observation that exists on both sides
    /// differs — `statusToken`, `identity`,
    /// `providerEligibleForEconomicActual` or `bindingIsActive`.
    ///
    /// These move no euro and change what the period may claim, which is
    /// exactly why they are classified apart. Operational sync clocks are not
    /// in the projection and can never produce this class.
    case providerStateChanged

    /// The aggregate relationship of an observation that exists on both sides
    /// differs — its `basis` or its paired transaction identities.
    ///
    /// Paired identities are part of the class because the same structural
    /// limitation can point at a different candidate relationship while its
    /// basis is unchanged.
    case aggregateRelationshipChanged

    /// `SemanticExpectationFact` differs — membership, obligation, expected
    /// day, amount, currency, standing, or the transaction that settled it.
    case expectationChanged

    /// Deterministic order for reporting, independent of discovery order.
    var rank: Int {
        switch self {
        case .coverageChanged: 0
        case .economicsChanged: 1
        case .budgetAttributionChanged: 2
        case .evidenceChanged: 3
        case .providerStateChanged: 4
        case .aggregateRelationshipChanged: 5
        case .expectationChanged: 6
        }
    }
}

/// A non-empty, deduplicated, deterministically ordered set of change classes.
///
/// Non-emptiness is structural rather than conventional: `changedSinceClose`
/// can hold nothing else, so "changed, for no stated reason" is unsayable.
public struct PeriodCheckpointChangeClasses: Hashable, Sendable {

    /// Sorted by `PeriodCheckpointChangeClass.rank`. Never empty.
    public let classes: [PeriodCheckpointChangeClass]

    /// nil when `classes` is empty — the caller has not established a change.
    public init?(_ classes: some Sequence<PeriodCheckpointChangeClass>) {
        let unique = Set(classes).sorted { $0.rank < $1.rank }
        guard !unique.isEmpty else { return nil }
        self.classes = unique
    }

    public init(_ first: PeriodCheckpointChangeClass,
                _ rest: PeriodCheckpointChangeClass...) {
        classes = Set([first] + rest).sorted { $0.rank < $1.rank }
    }

    public func contains(_ changeClass: PeriodCheckpointChangeClass) -> Bool {
        classes.contains(changeClass)
    }
}

// MARK: - Comparability limits

/// Why a period that *has* a baseline cannot presently be compared to it.
///
/// The reasons are the checkpoint's own blocker taxonomy, not a parallel
/// vocabulary invented for comparison: a period the evaluator refuses to close
/// is a period whose current semantic state cannot be trusted to stand against
/// a prior close either.
public struct PeriodCheckpointComparabilityLimits: Hashable, Sendable {

    /// Sorted by `PeriodCheckpointBlockerKind.rank`. Never empty.
    public let blockers: [PeriodCheckpointBlockerKind]

    /// nil when `blockers` is empty — nothing limits comparability.
    public init?(_ blockers: some Sequence<PeriodCheckpointBlockerKind>) {
        let unique = Set(blockers).sorted { $0.rank < $1.rank }
        guard !unique.isEmpty else { return nil }
        self.blockers = unique
    }

    public init(_ first: PeriodCheckpointBlockerKind,
                _ rest: PeriodCheckpointBlockerKind...) {
        blockers = Set([first] + rest).sorted { $0.rank < $1.rank }
    }
}

// MARK: - Baseline comparison

/// Whether this checkpoint can be compared against a prior close, and what the
/// comparison says.
///
/// A separate axis from disposition and quality on purpose: what a period is
/// worth saying today does not depend on whether it was said before.
public enum PeriodCheckpointBaselineComparison: Hashable, Sendable {

    /// A genuine inability to establish baseline state.
    ///
    /// Only a source or read failure belongs here. "The source was read and
    /// holds nothing" is `.notPreviouslyClosed`, which is an established fact
    /// about the period, not an absence of one.
    public enum Unavailability: String, Sendable, Hashable, Codable {

        /// Checkpoint persistence does not exist in this build. Nothing can be
        /// read, so nothing — not even emptiness — can be established.
        case noBaselinePersistence

        /// A prior close exists but its stored projection could not be read or
        /// validated. Distinct from a readable payload in an unsupported
        /// format, which is `.requiresReverification`.
        case baselineProjectionUnreadable
    }

    /// The baseline source could not be established at all.
    case unavailable(Unavailability)

    /// The baseline source was read successfully and holds no revision for
    /// this period: it has never been closed.
    ///
    /// There is no previous quality, because there is no previous close. This
    /// is an *established* state — the first close is an ordinary close, not a
    /// structurally unavailable one.
    case notPreviouslyClosed

    /// A prior revision exists and the current canonical semantic state equals
    /// the state that was accepted. Carries the quality recorded by that
    /// revision, never a quality recomputed from today's facts.
    case unchangedSinceClose(previousQuality: PeriodCheckpointQuality)

    /// A prior revision exists, the current state is comparable, and it
    /// differs. Carries the *previous* revision's quality and the semantic
    /// dimensions that moved.
    case changedSinceClose(previousQuality: PeriodCheckpointQuality,
                           changes: PeriodCheckpointChangeClasses)

    /// A prior revision exists, but the current period's own evidence or
    /// coverage cannot support a comparison. Neither changed nor unchanged may
    /// be claimed; the baseline itself is not in doubt.
    case indeterminate(previousQuality: PeriodCheckpointQuality,
                       blockers: PeriodCheckpointComparabilityLimits)

    /// A prior revision exists and is readable, but it was written under a
    /// projection format this build cannot compare against. The period must be
    /// verified and closed again under the current format. Neither changed nor
    /// unchanged may be claimed, and no digest is compared.
    case requiresReverification(previousQuality: PeriodCheckpointQuality,
                                storedFormatToken: String,
                                comparisonFormat: SemanticPeriodProjectionFormat)

    /// Whether baseline state was successfully established.
    ///
    /// This answers "did we learn what the checkpoint source says about this
    /// period?" — **not** "may we assert unchanged?". A never-closed period, a
    /// period whose comparison is indeterminate and a period whose stored
    /// format needs re-verification have all established their baseline state;
    /// only a source or read failure has not. For "may we act on the
    /// comparison?", use `isConclusive`.
    public var isEstablished: Bool {
        if case .unavailable = self { return false }
        return true
    }

    /// Whether the comparison reached a conclusion a caller may act on.
    ///
    /// False for `.unavailable`, and false for the two established-but-
    /// inconclusive states, so an indeterminate comparison can never be
    /// mistaken for a settled one.
    public var isConclusive: Bool {
        switch self {
        case .notPreviouslyClosed, .unchangedSinceClose, .changedSinceClose: true
        case .unavailable, .indeterminate, .requiresReverification: false
        }
    }

    /// The quality recorded by the latest accepted revision, when one exists.
    ///
    /// It is an audit fact carried forward from that revision and is never
    /// recomputed from current facts: a period that has moved since a
    /// `.withExceptions` close still reports `.withExceptions` here.
    /// nil for `.unavailable` — an unreadable source proves no quality — and
    /// for `.notPreviouslyClosed`, which has no prior close to have a quality.
    public var previousQuality: PeriodCheckpointQuality? {
        switch self {
        case .unavailable, .notPreviouslyClosed:
            nil
        case let .unchangedSinceClose(quality),
             let .changedSinceClose(quality, _),
             let .indeterminate(quality, _),
             let .requiresReverification(quality, _, _):
            quality
        }
    }

    /// The dimensions that moved, when the comparison concluded that the
    /// period changed. nil in every other state.
    public var changes: PeriodCheckpointChangeClasses? {
        if case let .changedSinceClose(_, changes) = self { return changes }
        return nil
    }
}

// MARK: - Errors

/// A precondition the comparison request itself violated, or an invariant the
/// classifier failed to uphold. None of these is a statement about the period.
public enum PeriodCheckpointComparisonError: Error, Equatable, Sendable {

    /// The stored baseline and the current state describe different intervals.
    /// Comparing them would report August against September as a change.
    case periodMismatch

    /// The stored baseline and the current state describe different period
    /// kinds. A weekly close does not speak for a monthly period.
    case periodKindMismatch

    /// A baseline was declared unreadable under a format token this build in
    /// fact supports. A readable format must arrive as a validated payload.
    case supportedFormatDeclaredUnreadable

    /// Same-format canonical payloads differ but no change class was derived.
    /// The invariant is that a digest difference always has a named dimension;
    /// reaching this means the classifier or the serializer is wrong, and the
    /// comparison refuses to claim an unexplained change.
    case unclassifiedChange
}
