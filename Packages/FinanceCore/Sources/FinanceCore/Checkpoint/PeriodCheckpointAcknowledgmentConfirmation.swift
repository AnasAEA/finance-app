/// The boundary between *what the matcher found* and *what a person accepted*.
///
/// E1 reconstructs, purely and deterministically, which current exceptions
/// represent the same semantic issue as acknowledgments on the previous
/// revision. That reconstruction is evidence. It is never a decision.
///
/// This file makes that difference a type difference rather than a prose
/// warning. A `PeriodCheckpointAcknowledgmentCandidate` is advisory: it names a
/// proposed carry and the matcher relationship it came from, and it carries no
/// authority of any kind. `PeriodCheckpointConfirmedAcknowledgments` is the
/// confirmed set, and the only way to obtain one is `confirm`, which re-checks
/// the candidate's whole semantic subject against the exceptions the caller is
/// actually carrying now.
///
/// ## The law
///
/// Matcher evidence is not a committed acknowledgment. None of the following
/// produces a confirmed set: running the matcher, a candidate existing, a
/// candidate surviving across revisions, a unique one-to-one pairing, or any
/// notion of confidence. Confirmation is a separate event with its own call.
///
/// ## Why the subject is rechecked
///
/// Identifiers are joins, not semantic truth — the accepted E1 rule — so
/// `confirm` never trusts one. A decision is honoured only when its exception
/// is value-equal to exactly one carried exception, comparing kind, aggregate
/// basis, day and amount together with the identifier. An identifier that
/// survives while its subject changes underneath confirms nothing.
///
/// ## Where authority actually lives
///
/// `PeriodCheckpointRequest` accepts a `PeriodCheckpointConfirmedAcknowledgments`
/// and nothing else: there is no raw identifier set a caller can supply, and
/// the property cannot be reassigned after the request is built. The evaluator
/// applies authority through whole-value subject equality. Confirmed authority
/// retains the exact semantic exceptions; identifiers are derived diagnostics
/// only. Duplicate identifiers are independently invalid, and stale subjects
/// block application of the entire confirmation set.
///
/// ## Scope
///
/// Pure FinanceCore. No persistence layer, no database, no UI, no store and no
/// clock. Nothing here mutates a request, evaluates readiness, writes a revision, or
/// takes part in any canonical projection or checkpoint digest. Candidates are
/// advisory state and never enter canonical bytes. Applying a confirmed set to
/// `PeriodCheckpointRequest` remains the caller's own explicit step.

// MARK: - Candidate

/// One advisory carry-forward candidate, derived from a single E1 match.
///
/// Only `PeriodCheckpointAcknowledgmentMatchResult.carryForwardCandidates`
/// vends these: the initializer is internal, so no caller outside FinanceCore
/// can fabricate a candidate for a relationship the matcher never established.
/// Ambiguous, unmatchable and disappeared relationships never become
/// candidates, because they never become matches.
public struct PeriodCheckpointAcknowledgmentCandidate: Sendable, Equatable {

    /// The previously acknowledged exception this candidate carries forward
    /// from. Provenance: it proves which matcher relationship produced the
    /// candidate, and is never itself confirmable.
    public let previousException: PeriodCheckpointException

    /// The current exception proposed for acknowledgment. Confirmation
    /// compares this whole value against what is actually carried.
    public let currentException: PeriodCheckpointException

    init(previousException: PeriodCheckpointException, currentException: PeriodCheckpointException) {
        self.previousException = previousException
        self.currentException = currentException
    }
}

extension PeriodCheckpointAcknowledgmentMatchResult {

    /// The advisory candidates for this match result, in matcher output order.
    ///
    /// Derived from `matched` only. This is evidence, not a decision: a
    /// candidate becomes an acknowledgment only through `confirm`.
    public var carryForwardCandidates: [PeriodCheckpointAcknowledgmentCandidate] {
        matched.map {
            PeriodCheckpointAcknowledgmentCandidate(
                previousException: $0.previous.exception,
                currentException: $0.current
            )
        }
    }
}

// MARK: - Confirmed acknowledgments

/// An explicit, verified acknowledgment decision for the current revision.
///
/// This is the evaluator's acknowledgment authority — not a label on one, and
/// not an advisory hint beside one. `PeriodCheckpointRequest` accepts this type
/// and no raw alternative, so the only way an exception becomes acknowledged is
/// a decision that passed `confirm`'s whole-value check.
///
/// Deliberately not constructible outside FinanceCore and deliberately not a
/// `Set<String>`: a bare identifier set is interchangeable with matcher output
/// by accident, which is the exact confusion this type exists to prevent.
///
/// `Hashable` so `PeriodCheckpointRequest` keeps its own `Hashable` conformance.
public struct PeriodCheckpointConfirmedAcknowledgments: Sendable, Hashable {

    /// The exact semantic subjects validated by the explicit confirmation.
    /// Retained whole so authority cannot transfer across requests by identifier.
    let confirmedExceptions: Set<PeriodCheckpointException>

    /// Read-only diagnostic/join information, never evaluator authority.
    public var confirmedAcknowledgmentIDs: Set<String> {
        Set(confirmedExceptions.map(\.id))
    }

    init(confirmedExceptions: Set<PeriodCheckpointException>) {
        self.confirmedExceptions = confirmedExceptions
    }

    /// No decision has been made. The state every request starts in, and the
    /// state production is in today: nothing acknowledged, everything undecided.
    public static let noDecisions = PeriodCheckpointConfirmedAcknowledgments(
        confirmedExceptions: []
    )
}

/// Why a proposed confirmation was refused. Payload-free: a refusal names the
/// rule that failed, never the subject's own content.
public enum PeriodCheckpointAcknowledgmentConfirmationError: Error, Equatable {

    /// No carried exception is value-equal to the candidate's current
    /// exception. The subject changed, or was never carried.
    case candidateSubjectNotCarried

    /// Several carried exceptions are value-equal to the candidate's current
    /// exception, so the acknowledgment would be ambiguous.
    case candidateSubjectAmbiguous

    /// The same current exception was offered more than once. A confirmation
    /// states each decision exactly once.
    case duplicateCandidate
}

public enum PeriodCheckpointAcknowledgmentConfirmation {

    /// Confirm explicitly chosen carry-forward candidates against the
    /// exceptions carried now.
    ///
    /// The caller decides which candidates to offer; this function decides
    /// whether each one still describes something real. Every candidate must
    /// match exactly one carried exception by full value. Any refusal refuses
    /// the whole confirmation: a partially honoured decision would be a
    /// decision nobody made.
    ///
    /// An empty offer confirms nothing and is not an error.
    public static func confirm(
        _ candidates: [PeriodCheckpointAcknowledgmentCandidate],
        carriedExceptions: [PeriodCheckpointException]
    ) throws -> PeriodCheckpointConfirmedAcknowledgments {
        try confirm(subjects: candidates.map(\.currentException),
                    carriedExceptions: carriedExceptions)
    }

    /// Confirm exceptions a person is deciding on directly, with no previous
    /// revision behind them.
    ///
    /// Most acknowledgments are not carries: an exception a person is seeing
    /// for the first time has no matcher candidate and never will. Such a
    /// decision is still stated as a whole exception value, never as an
    /// identifier, and is checked by exactly the same rule — one value-equal
    /// carried exception, all-or-nothing. Provenance is the only difference
    /// between this entry point and the candidate one; the authority it
    /// produces is identical, and neither can be reached with an identifier.
    public static func confirm(
        decisions: [PeriodCheckpointException],
        carriedExceptions: [PeriodCheckpointException]
    ) throws -> PeriodCheckpointConfirmedAcknowledgments {
        try confirm(subjects: decisions, carriedExceptions: carriedExceptions)
    }

    /// The one rule, and the module's only construction site for a confirmed
    /// value. Both public entry points reduce to it, so provenance can differ
    /// while the semantic check never does.
    private static func confirm(
        subjects: [PeriodCheckpointException],
        carriedExceptions: [PeriodCheckpointException]
    ) throws -> PeriodCheckpointConfirmedAcknowledgments {
        var confirmed: Set<PeriodCheckpointException> = []
        for subject in subjects {
            var carriedCount = 0
            for carried in carriedExceptions where carried == subject {
                carriedCount += 1
            }
            guard carriedCount > 0 else {
                throw PeriodCheckpointAcknowledgmentConfirmationError.candidateSubjectNotCarried
            }
            guard carriedCount == 1 else {
                throw PeriodCheckpointAcknowledgmentConfirmationError.candidateSubjectAmbiguous
            }
            guard !confirmed.contains(where: { $0.id == subject.id }) else {
                throw PeriodCheckpointAcknowledgmentConfirmationError.duplicateCandidate
            }
            confirmed.insert(subject)
        }
        return PeriodCheckpointConfirmedAcknowledgments(confirmedExceptions: confirmed)
    }
}
