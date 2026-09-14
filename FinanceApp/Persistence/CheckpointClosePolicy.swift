import FinanceCore
import Foundation

// MARK: - What the policy was asked to decide

/// What should happen to an ended month, given where it stands and what its
/// own checkpoint history already says.
///
/// Four outcomes, and the distinctions between them are the point:
///
/// - an **append plan** — `firstClose` or `reverify` — retains validated inputs
///   for a revision. Identity and time are supplied only after this decision;
/// - `alreadyCurrent` is a successful no-op. The period is already closed at
///   exactly the state it is in now, and closing it again would record a
///   second revision that says nothing the first did not;
/// - `refused` is fail-closed. Nothing is written and nothing is claimed.
///
/// `firstClose` and `reverify` carry the same type and differ only in which
/// one of them the chain says this is. They are kept apart because a caller
/// and a reviewer both want to know which happened without re-deriving it from
/// `revisionNumber`.
enum CheckpointClosePolicyDecision: Sendable {

    /// This period has never been closed. Revision 1, no predecessor.
    case firstClose(CheckpointClosePolicy.AppendPlan)

    /// This period was closed before and has moved, or was closed under a
    /// projection format this build cannot compare against. Appends after the
    /// exact chain tip.
    case reverify(CheckpointClosePolicy.AppendPlan)

    /// The latest accepted revision already represents the period exactly as
    /// it stands. Not an error, and not a revision: the right answer to
    /// "close it again" is that it is already closed.
    case alreadyCurrent

    /// Nothing may be written, and why.
    case refused(CheckpointClosePolicyRefusal)
}

/// Materialization can still fail the domain's construction invariants, for
/// example a non-finite timestamp or an identity equal to its predecessor.
/// Classification and ordinary refusals never require this operation.
enum CheckpointClosePolicyMaterialization: Sendable {
    case candidate(PeriodCheckpointRevision)
    case refused(CheckpointClosePolicyRefusal)
}

/// Why a close was refused.
///
/// Engine-aware application vocabulary, deliberately not presentation: these
/// are the distinctions a test and a reviewer need, not sentences a person
/// reads. A future action that wants to say something to a person decides that
/// wording itself, from the case and from the readiness it already holds.
enum CheckpointClosePolicyRefusal: String, Sendable, Hashable, CaseIterable {

    /// The period is not a monthly product close: a weekly period, or an
    /// interval that is not exactly one whole calendar month.
    case unsupportedWriteScope

    /// The period has not ended, measured by the evaluator against the as-of
    /// day the readiness was computed with. Read from the blocker the
    /// evaluator already produced; this policy runs no calendar rule of its own.
    case periodNotEnded

    /// Blocked, or carrying a decision nobody has made. Never "mostly ready".
    case readinessNotReady

    /// The readiness carries no semantic projection, or one that does not
    /// canonicalize. A checkpoint with no projected meaning cannot be compared
    /// or closed, and nothing here invents one.
    case semanticProjectionUnavailable

    /// The chain tip is a revision written under a projection format this
    /// build does not implement. Readable as a header, and **not absent**: a
    /// period whose history this build cannot extend is refused, never
    /// restarted at revision 1.
    case previousRevisionFormatUnsupported

    /// The checkpoint history for this period exists and cannot be trusted.
    /// Also **not absent**.
    case previousRevisionCorrupt

    /// The chain tip belongs to another period.
    case previousRevisionPeriodMismatch

    /// The chain tip belongs to another period kind.
    case previousRevisionKindMismatch

    /// The comparison the readiness carries is not the comparison this tip
    /// produces. Comparison semantics disagree; no append is permitted.
    case inconsistentPreviousObservation

    /// A prior revision exists but the current period cannot presently be
    /// compared to it. Defence in depth — see `outcome(for:)`.
    case comparisonIndeterminate

    /// Baseline state could not be established at all. Defence in depth — see
    /// `outcome(for:)`.
    case comparisonUnavailable

    /// The next revision number does not fit. Unreachable in any real history;
    /// refused rather than wrapped.
    case revisionNumberUnrepresentable

    /// `PeriodCheckpointRevision` refused to accept the candidate. The domain
    /// has the last word on what a revision may be, and this policy does not
    /// restate its rules or work around a refusal. Returned by materialization,
    /// after classification has produced a plan.
    case revisionConstructionRefused
}

// MARK: - What an append needs that the policy may not create

/// The identity and time a candidate revision is stamped with.
///
/// Both are supplied. This is the whole reason the type exists: a pure policy
/// that generated a UUID would be untestable, and one that read a clock would
/// decide a different thing every time it ran. The caller mints a fresh UUID
/// only after classification returns an append plan, then takes `closedAt`
/// from its own clock. Neither value is an input to classification.
///
/// `closedAt` is audit metadata. It records when an append was accepted and it
/// orders nothing: the chain is ordered by `revisionNumber`, and
/// `PeriodCheckpointRepository.latestRevision` says so in as many words.
struct CheckpointAppendIdentity: Sendable, Hashable {

    let candidateID: UUID
    let closedAt: Date

    init(candidateID: UUID, closedAt: Date) {
        self.candidateID = candidateID
        self.closedAt = closedAt
    }
}

// MARK: - The policy

/// Producer policy for checkpoint closes: **what revision, if any, should be
/// written** for an ended month.
///
/// ## Why this exists
///
/// `PeriodCheckpointRevision.init(id:revisionNumber:predecessorID:closedAt:readiness:canonicalProjection:)`
/// requires four values from its caller and derives none of them.
/// `PeriodCheckpointRepository` deliberately derives none of them either — it
/// stores an already-created revision and says, in its own comment, that it
/// "never computes a revision number or chooses a predecessor". That half of
/// the contract had no home. This is it.
///
/// ## What this type does not do
///
/// It reads no store, calls no repository, reads no clock, generates no
/// identity, touches no SwiftData and renders nothing. It returns a candidate;
/// executing one is a separate, separately-authorized action that does not yet
/// exist. `CheckpointClosePolicyBoundaryTests` holds all of that from outside
/// by reading this file.
///
/// ## POLICY_REQUIRES_FRESH_SAME_TURN_INPUTS
///
/// A pure function cannot prove when its arguments were read, and this one does
/// not pretend to. What it *can* do is refuse an incoherent pair: the
/// comparison is derived here, from the chain tip it was handed, and checked
/// against the comparison the readiness is carrying. Disagreement is
/// `inconsistentPreviousObservation`. Different observations can produce equal
/// comparisons: equality does not prove observation identity. Chain metadata
/// still comes exclusively from the supplied full tip.
///
/// That narrows the window; it does not close it. The future action still owes
/// the real guarantee: recompute readiness, read the exact chain tip, classify,
/// obtain append metadata, materialize and store in one synchronous
/// `@MainActor` turn with no suspension point between them. This policy states that requirement and fails closed on
/// the part of it that is visible from inside; it does not enforce store
/// freshness, and no test here should claim it does.
enum CheckpointClosePolicy {

    /// Validated inputs for one append. Only this file can create a plan or
    /// access its contents; callers pass it unchanged to `materialize`.
    /// This value holds no observation source or deferred work. It must remain
    /// within the future action's fresh synchronous turn, never a UI cache.
    struct AppendPlan: Sendable {
        fileprivate let readiness: PeriodCheckpointReadiness
        fileprivate let canonicalProjection: CanonicalSemanticPeriodProjection
        fileprivate let revisionNumber: Int64
        fileprivate let predecessorID: UUID?

        fileprivate init(
            readiness: PeriodCheckpointReadiness,
            canonicalProjection: CanonicalSemanticPeriodProjection,
            revisionNumber: Int64,
            predecessorID: UUID?
        ) {
            self.readiness = readiness
            self.canonicalProjection = canonicalProjection
            self.revisionNumber = revisionNumber
            self.predecessorID = predecessorID
        }
    }

    /// Classify an ended month without obtaining any append identity or time.
    ///
    /// - Parameters:
    ///   - currentReadiness: freshly evaluated readiness for this exact period.
    ///     Not a value held from an earlier screen state — see the type comment.
    ///   - currentChainTip: the exact-period history read, in the repository's
    ///     own four-state vocabulary. Never flattened to an optional: an
    ///     unsupported or corrupt tip is not an absent one.
    static func classify(
        currentReadiness readiness: PeriodCheckpointReadiness,
        currentChainTip tip: PeriodCheckpointStoredRead
    ) -> CheckpointClosePolicyDecision {

        // 1. Product write scope, first and unconditionally.
        //
        // Monthly-only is a product decision, and it is enforced here rather
        // than inferred from which screen happens to call this. A weekly period
        // that is perfectly ready is still not something this product writes.
        guard isMonthlyProductScope(period: readiness.period, kind: readiness.kind) else {
            return .refused(.unsupportedWriteScope)
        }

        // 2. The evaluator's verdict. Endedness is its blocker, not a second
        //    calendar rule invented here.
        guard readiness.disposition.isReady else {
            return .refused(
                readiness.blockers.contains(where: { $0.kind == .periodNotEnded })
                    ? .periodNotEnded
                    : .readinessNotReady
            )
        }

        // 3. The projection this readiness produced, and no other. Not fetched,
        //    not rebuilt, not reconstructed from a screen.
        guard let projection = readiness.projection,
              let canonical = try? CanonicalSemanticPeriodProjection(projection)
        else {
            return .refused(.semanticProjectionUnavailable)
        }

        // 4. What the history says. Absence must be genuine absence.
        let previous: PeriodCheckpointRevision?
        switch tip {
        case .empty:
            previous = nil
        case let .supported(revision):
            guard revision.period == readiness.period else {
                return .refused(.previousRevisionPeriodMismatch)
            }
            guard revision.periodKind == readiness.kind else {
                return .refused(.previousRevisionKindMismatch)
            }
            previous = revision
        case .unsupportedFormat:
            return .refused(.previousRevisionFormatUnsupported)
        case .corrupt:
            return .refused(.previousRevisionCorrupt)
        }

        // 5. One comparison, derived from the tip that was handed over, through
        //    the same pure machinery the product already uses. Deriving it here
        //    makes this tip's comparison the semantic authority. The carried
        //    comparison is a coherence witness, not observation identity.
        let comparison = PeriodCheckpointBaselineReader.comparison(
            baseline: PeriodCheckpointBaselineReader.source(for: tip),
            current: readiness
        )
        guard comparison == readiness.baselineComparison else {
            return .refused(.inconsistentPreviousObservation)
        }

        // 6. What that comparison permits.
        switch outcome(for: comparison, hasSupportedTip: previous != nil) {
        case .alreadyCurrent:
            return .alreadyCurrent
        case let .refuse(reason):
            return .refused(reason)
        case .append:
            break
        }

        // 7. Chain position. Contiguous, and named by the exact tip.
        let revisionNumber: Int64
        let predecessorID: UUID?
        if let previous {
            let (next, overflow) = previous.revisionNumber.addingReportingOverflow(1)
            guard !overflow else { return .refused(.revisionNumberUnrepresentable) }
            revisionNumber = next
            predecessorID = previous.id
        } else {
            revisionNumber = 1
            predecessorID = nil
        }

        // 8. Retain the validated inputs. No identity or timestamp exists yet.
        let plan = AppendPlan(
            readiness: readiness,
            canonicalProjection: canonical,
            revisionNumber: revisionNumber,
            predecessorID: predecessorID
        )
        return previous == nil ? .firstClose(plan) : .reverify(plan)
    }

    /// Construct from an opaque classified plan and metadata supplied later.
    /// No reclassification, observation or evaluator replay occurs here. The
    /// frozen domain initializer remains the final, fail-closed validation.
    static func materialize(
        plan: AppendPlan,
        identity: CheckpointAppendIdentity
    ) -> CheckpointClosePolicyMaterialization {
        guard let revision = try? PeriodCheckpointRevision(
            id: identity.candidateID,
            revisionNumber: plan.revisionNumber,
            predecessorID: plan.predecessorID,
            closedAt: identity.closedAt,
            readiness: plan.readiness,
            canonicalProjection: plan.canonicalProjection
        ) else {
            return .refused(.revisionConstructionRefused)
        }

        return .candidate(revision)
    }

    // MARK: - Comparison → what may happen

    /// What one baseline comparison permits, independent of chain arithmetic.
    ///
    /// Split out because it is the part of the policy whose vocabulary is
    /// closed and total: every `PeriodCheckpointBaselineComparison` has exactly
    /// one answer here, and a test can walk all six.
    ///
    /// Two of the answers are defence in depth rather than live paths.
    /// `classify` refuses a non-ready readiness before it reaches this function,
    /// and `PeriodCheckpointCurrentState(readiness)` is limited only when
    /// blockers exist — so `.indeterminate` cannot arrive here. `.unavailable`
    /// likewise cannot: the only production source of it is a corrupt read,
    /// which `classify` has already refused by name. Both are kept because
    /// "this comparison does not permit an append" is a property of the
    /// comparison itself, and a guard that states it outlives the ordering that
    /// currently makes it unnecessary.
    static func outcome(
        for comparison: PeriodCheckpointBaselineComparison,
        hasSupportedTip: Bool
    ) -> ComparisonOutcome {
        switch comparison {
        case .notPreviouslyClosed:
            // An established fact: the period has never been closed. It is only
            // an append when the tip agrees there is nothing there.
            return hasSupportedTip ? .refuse(.inconsistentPreviousObservation) : .append

        case .unchangedSinceClose:
            // Already closed at exactly this state. Closing again would record
            // a revision that says nothing new.
            return hasSupportedTip ? .alreadyCurrent : .refuse(.inconsistentPreviousObservation)

        case .changedSinceClose, .requiresReverification:
            // Moved since close, or closed under a format this build cannot
            // compare against. Either way the period is verified again, and
            // either way it appends after the tip — never over it.
            return hasSupportedTip ? .append : .refuse(.inconsistentPreviousObservation)

        case .indeterminate:
            return .refuse(.comparisonIndeterminate)

        case .unavailable:
            return .refuse(.comparisonUnavailable)
        }
    }

    /// What a comparison permits. Not the decision — chain arithmetic and
    /// revision construction still stand between this and a candidate.
    enum ComparisonOutcome: Sendable, Equatable {
        case append
        case alreadyCurrent
        case refuse(CheckpointClosePolicyRefusal)
    }

    // MARK: - Product scope

    /// Whether this period is one the product closes.
    ///
    /// Monthly kind **and** exactly one whole calendar month. The second half
    /// is not redundant: `ReviewPeriodKind.monthly` is a label on an interval,
    /// and `ReviewRequestBuilder` also builds month-to-date intervals that
    /// carry it. The shape checked here is exactly `ReviewInterval.month(_:)` —
    /// first day of a month through that month's last day — so a partial month,
    /// a month-to-date period and a multi-month span are all outside it.
    ///
    /// Weekly stays readable everywhere else in the system: the pure format,
    /// the domain and the repository all keep `ReviewPeriodKind.weekly`, and
    /// weekly verification stays a read. This is the *write* scope only.
    static func isMonthlyProductScope(period: SemanticInterval, kind: ReviewPeriodKind) -> Bool {
        guard kind == .monthly else { return false }
        return period.start == period.start.firstDayOfMonth
            && period.end == period.start.lastDayOfMonth
    }
}
