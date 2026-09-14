/// Whether a period may be closed, and what closing it would be allowed to
/// claim.
///
/// ## Ownership
///
/// This file owns *period* semantics only. It decides nothing about current
/// attention: a period that cannot be closed because August's archive coverage
/// is unknown says nothing at all about whether today's balances, forecast or
/// funding risk are trustworthy. Keeping those two questions apart is
/// refinement A, and it is enforced at the app layer by
/// `AttentionSourceAvailability`, which scopes source domains rather than
/// pooling every optional source into one global verdict.
///
/// ## Purity
///
/// `PeriodCheckpointEvaluator` reads no clock, no store and no SwiftData. Every
/// input — the period, the as-of day, the already-successful review, the typed
/// exceptions, the projection, the acknowledgments — arrives on the request.

// MARK: - Blockers

/// A reason the period cannot be closed at all.
///
/// A blocker is **never** acknowledgeable. That is the whole difference
/// between a blocker and an exception: an exception is a limitation a person
/// may knowingly carry, a blocker is a state in which "closed" would be a
/// false statement. Coverage incompleteness is deliberately on this side of
/// the line — a total behind uncovered days is not a total, and no amount of
/// acknowledgment covers a day.
public enum PeriodCheckpointBlockerKind: String, Sendable, Hashable, Codable, CaseIterable {

    /// The requested interval is not a period (end before start).
    case invalidPeriod

    /// The period has not finished yet, measured against the caller's `asOf`.
    case periodNotEnded

    /// No successful review of the period was supplied. The checkpoint never
    /// runs a review of its own.
    case reviewUnavailable

    /// The supplied review is about a different period or a different kind.
    case reviewPeriodMismatch

    /// Coverage — no affirmative coverage evidence at all.
    case coverageMetadataAbsent
    /// Coverage — archive-era days with no archive to establish them.
    case archiveHistoryAbsent
    /// Coverage — archive days the archive does not cover.
    case missingArchiveInterval
    /// Coverage — live days no affirmative provider fetch covers.
    case missingLiveInterval
    /// Coverage — a declared gap in a source.
    case sourceGap

    /// A semantic projection was required for this checkpoint and could not be
    /// built.
    case semanticProjectionUnavailable

    /// Two or more carried exceptions share an identifier. Invalid independently
    /// of semantic subject binding: revisions require unique identities, and
    /// exception ordering is not total without them.
    case duplicateExceptionIdentity

    /// At least one confirmed subject is not carried exactly once by whole
    /// value. Stale or foreign authority blocks the entire application.
    /// In-memory only; no persistence or wire meaning.
    case confirmedAcknowledgmentSubjectMismatch

    /// Whether this blocker comes from coverage evidence. Coverage blockers are
    /// the ones a person most wants to override, and the ones that must never
    /// be overridable.
    public var isCoverageDerived: Bool {
        switch self {
        case .coverageMetadataAbsent, .archiveHistoryAbsent, .missingArchiveInterval,
             .missingLiveInterval, .sourceGap:
            true
        case .invalidPeriod, .periodNotEnded, .reviewUnavailable, .reviewPeriodMismatch,
             .semanticProjectionUnavailable, .duplicateExceptionIdentity,
             .confirmedAcknowledgmentSubjectMismatch:
            false
        }
    }

    /// Total and constant: acknowledgment never clears a blocker of any kind.
    public var isAcknowledgeable: Bool { false }

    /// Deterministic order for reporting, independent of discovery order.
    var rank: Int {
        switch self {
        case .invalidPeriod: 0
        case .periodNotEnded: 1
        case .reviewUnavailable: 2
        case .reviewPeriodMismatch: 3
        case .coverageMetadataAbsent: 4
        case .archiveHistoryAbsent: 5
        case .missingArchiveInterval: 6
        case .missingLiveInterval: 7
        case .sourceGap: 8
        case .semanticProjectionUnavailable: 9
        case .duplicateExceptionIdentity: 10
        case .confirmedAcknowledgmentSubjectMismatch: 11
        }
    }
}

public struct PeriodCheckpointBlocker: Hashable, Sendable, Comparable {

    public let kind: PeriodCheckpointBlockerKind
    /// The days the blocker concerns, when it names any.
    public let interval: SemanticInterval?
    /// Source names already present in the coverage reason. Never a private
    /// identifier and never free text about a counterparty.
    public let affectedSources: [String]

    public init(
        kind: PeriodCheckpointBlockerKind,
        interval: SemanticInterval? = nil,
        affectedSources: [String] = []
    ) {
        self.kind = kind
        self.interval = interval
        self.affectedSources = affectedSources.sorted()
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.rank < rhs.kind.rank }
        switch (lhs.interval, rhs.interval) {
        case let (left?, right?) where left != right: return left < right
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            return lhs.affectedSources.lexicographicallyPrecedes(rhs.affectedSources)
        }
    }
}

// MARK: - Disposition and quality

/// Where the period stands.
public enum PeriodCheckpointDisposition: String, Sendable, Hashable, Codable {

    /// One or more blockers. Nothing may be claimed and nothing may be closed.
    case blocked

    /// No blockers, but exceptions a person has not seen and accepted yet.
    case needsDecisions

    /// No blockers and no exceptions.
    case readyClean

    /// No blockers, and every exception is acknowledged and carried.
    case readyWithAcknowledgedExceptions

    public var isReady: Bool {
        self == .readyClean || self == .readyWithAcknowledgedExceptions
    }
}

/// What closing this period would record about it. Orthogonal to disposition:
/// quality is about the *period*, disposition is about the *decision*.
public enum PeriodCheckpointQuality: String, Sendable, Hashable, Codable {
    case clean
    case withExceptions
}

// Baseline comparison is its own axis and lives in
// `PeriodCheckpointBaselineComparison.swift`, beside the comparator that
// derives it. This file keeps period semantics; that one keeps the question of
// what the period was last closed as.

// MARK: - Request

/// Everything the evaluator is allowed to know.
public struct PeriodCheckpointRequest: Hashable, Sendable {

    public var period: ReviewInterval
    public var kind: ReviewPeriodKind

    /// The caller's as-of day. Supplied, never read from a clock.
    public var asOf: Day

    /// One already-successful review of exactly this period. The evaluator
    /// never runs a review, and never recomputes coverage, totals or findings.
    public var review: ReviewResult?

    /// Typed exceptions the caller's fact adapters established. The evaluator
    /// takes them as given and derives only their impact.
    public var exceptions: [PeriodCheckpointException]

    /// The acknowledgment decisions a person has explicitly confirmed.
    ///
    /// Typed, and `let`: there is no raw identifier set to inject and no way to
    /// re-authorize a request after it is built. The only producer is
    /// `PeriodCheckpointAcknowledgmentConfirmation.confirm`, which honours a
    /// decision only when it is value-equal to exactly one carried exception —
    /// so matcher output, which is advisory evidence, cannot reach here by
    /// itself. The evaluator rechecks these exact subjects against this request;
    /// any missing or substituted subject blocks the whole application.
    public let confirmedAcknowledgments: PeriodCheckpointConfirmedAcknowledgments

    /// The period's conceptual projection, when the caller could build one.
    public var projection: SemanticPeriodProjection?

    /// Whether this checkpoint requires a projection to be closeable.
    public var requiresSemanticProjection: Bool

    /// Comparison against a prior close. Its own axis; see the type.
    public var baselineComparison: PeriodCheckpointBaselineComparison

    public init(
        period: ReviewInterval,
        kind: ReviewPeriodKind,
        asOf: Day,
        review: ReviewResult? = nil,
        exceptions: [PeriodCheckpointException] = [],
        confirmedAcknowledgments: PeriodCheckpointConfirmedAcknowledgments = .noDecisions,
        projection: SemanticPeriodProjection? = nil,
        requiresSemanticProjection: Bool = false,
        baselineComparison: PeriodCheckpointBaselineComparison = .unavailable(.noBaselinePersistence)
    ) {
        self.period = period
        self.kind = kind
        self.asOf = asOf
        self.review = review
        self.exceptions = exceptions
        self.confirmedAcknowledgments = confirmedAcknowledgments
        self.projection = projection
        self.requiresSemanticProjection = requiresSemanticProjection
        self.baselineComparison = baselineComparison
    }
}

// MARK: - Readiness

public struct PeriodCheckpointReadiness: Hashable, Sendable {

    public let period: SemanticInterval
    public let kind: ReviewPeriodKind
    public let disposition: PeriodCheckpointDisposition
    public let quality: PeriodCheckpointQuality

    /// Sorted, deduplicated. Empty exactly when `disposition != .blocked`.
    public let blockers: [PeriodCheckpointBlocker]

    /// Every carried exception, sorted by kind then id.
    public let exceptions: [PeriodCheckpointException]
    /// The subset a person has acknowledged, in the same order.
    public let acknowledgedExceptions: [PeriodCheckpointException]
    /// The subset still awaiting a decision, in the same order.
    public let undecidedExceptions: [PeriodCheckpointException]

    public let safeClaims: PeriodCheckpointSafeClaims
    public let baselineComparison: PeriodCheckpointBaselineComparison

    /// The projection, when one was supplied. Carried so a caller can hold it
    /// beside the disposition it produced.
    public let projection: SemanticPeriodProjection?
}
