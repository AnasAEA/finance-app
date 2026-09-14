import FinanceCore
import Foundation

// MARK: - Application result

/// What one ended-month checkpoint write did.
///
/// Engine-aware application vocabulary, not presentation. The distinctions are
/// the point: a first close is not a reverify, already-current is not a store
/// success, a policy refusal is not a period that could not be classified, and
/// a repository rejection is not semantic already-current.
enum EndedMonthCheckpointWriteResult: Sendable {

    /// Revision 1, no predecessor, just stored.
    case storedFirstClose(PeriodCheckpointRevision)

    /// Tip + 1, predecessor = tip.id, just stored.
    case storedReverify(PeriodCheckpointRevision)

    /// The latest accepted revision already represents the period exactly as
    /// it stands. Not an error, and not a write: identity, time and store are
    /// all untouched.
    case alreadyCurrent

    /// `CheckpointClosePolicy` refused. Nothing was minted and nothing was stored.
    case refused(CheckpointClosePolicyRefusal)

    /// The action never reached classification. Weekly, unended, unreadable
    /// review, or a store that is not writable.
    case notWritable(EndedMonthCheckpointNotWritableReason)

    /// The repository refused or failed. Typed, and never retried.
    case storeRefused(PeriodCheckpointStoreError)

    /// `PeriodCheckpointRepository.store` returned `.alreadyStored` on a
    /// same-turn fresh-UUID append. That is not semantic already-current —
    /// already-current is decided before any identity is minted — and it is
    /// not treated as success.
    case storeUnexpectedAlreadyStored
}

/// Why the write never entered `CheckpointClosePolicy`.
///
/// Kept apart from `CheckpointClosePolicyRefusal` so a weekly selection or a
/// failed load cannot be reported as a refusal the policy never issued.
enum EndedMonthCheckpointNotWritableReason: String, Sendable, Hashable, CaseIterable {

    /// `FinanceStore.loadFailure` is set. The served document is fallback or
    /// empty, and must not be checkpointed as a verified month.
    case storeFailedToLoad

    /// Fixed snapshot / preview facade, the same read-only rule other
    /// `FinanceStore` mutations already use.
    case storeIsReadOnly

    /// `ReviewPeriodSelection.scope == .week`. Weekly checkpoint writes are
    /// unauthorized; weekly read support is unchanged.
    case weeklySelection

    /// The selected month has not ended, or has not started: its calendar end
    /// is not strictly before the action's as-of day.
    case periodNotEnded

    /// The selected period could not be reviewed at all.
    case reviewUnavailable
}

// MARK: - Writer

/// The one production path that durably stores an ended-month checkpoint.
///
/// ## Sequence
///
/// Classification is metadata-free. Identity and `closedAt` are obtained only
/// after an append plan exists, then `materialize`, then exactly one
/// `repository.store`. Already-current and refusal mint nothing, sample
/// nothing, and store nothing.
///
/// ## ACTION_ENFORCES_FRESH_SAME_TURN_WRITE
///
/// This type is a synchronous `@MainActor` function. It does not suspend, hop,
/// enqueue or retry. Freshness of readiness and of the chain tip is the
/// caller's: `FinanceStore` recomputes both, from one tip observation, in the
/// same turn that calls this.
///
/// ## What this type does not do
///
/// It does not construct a `PeriodCheckpointRevision` itself — materialization
/// remains `CheckpointClosePolicy`. It does not read the repository for the
/// tip. It does not confirm acknowledgments, run the E1 matcher, or present
/// anything.
@MainActor
enum EndedMonthCheckpointWriter {

    /// Classify, and only then mint, materialize and store.
    ///
    /// `makeCandidateIdentity` and `closedAt` are invoked only after
    /// classification returns an append plan. Storage uses the repository's
    /// ordinary transaction, with no caller-controlled pre-save work.
    static func write(
        readiness: PeriodCheckpointReadiness,
        chainTip: PeriodCheckpointStoredRead,
        repository: PeriodCheckpointRepository,
        makeCandidateIdentity: () -> UUID = UUID.init,
        closedAt: () -> Date
    ) -> EndedMonthCheckpointWriteResult {

        switch CheckpointClosePolicy.classify(
            currentReadiness: readiness,
            currentChainTip: chainTip
        ) {
        case .alreadyCurrent:
            return .alreadyCurrent

        case let .refused(reason):
            return .refused(reason)

        case let .firstClose(plan):
            return persist(
                plan,
                as: .firstClose,
                repository: repository,
                makeCandidateIdentity: makeCandidateIdentity,
                closedAt: closedAt
            )

        case let .reverify(plan):
            return persist(
                plan,
                as: .reverify,
                repository: repository,
                makeCandidateIdentity: makeCandidateIdentity,
                closedAt: closedAt
            )
        }
    }

    private enum PersistAs {
        case firstClose
        case reverify
    }

    /// Identity and time exist only because classification produced a plan.
    private static func persist(
        _ plan: CheckpointClosePolicy.AppendPlan,
        as operation: PersistAs,
        repository: PeriodCheckpointRepository,
        makeCandidateIdentity: () -> UUID,
        closedAt: () -> Date
    ) -> EndedMonthCheckpointWriteResult {

        let identity = CheckpointAppendIdentity(
            candidateID: makeCandidateIdentity(),
            closedAt: closedAt()
        )

        switch CheckpointClosePolicy.materialize(plan: plan, identity: identity) {
        case let .refused(reason):
            return .refused(reason)

        case let .candidate(revision):
            do {
                let outcome = try repository.store(revision)
                switch outcome {
                case .stored:
                    switch operation {
                    case .firstClose: return .storedFirstClose(revision)
                    case .reverify: return .storedReverify(revision)
                    }
                case .alreadyStored:
                    return .storeUnexpectedAlreadyStored
                }
            } catch let error as PeriodCheckpointStoreError {
                return .storeRefused(error)
            } catch {
                return .storeRefused(.persistenceFailed(String(describing: type(of: error))))
            }
        }
    }
}
