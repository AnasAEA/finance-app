import FinanceCore
import Foundation

/// The ended-month verify action as a screen may hold it: one attempt, and what
/// a person is told about it.
///
/// ## Why this is not the writer's own vocabulary
///
/// `EndedMonthCheckpointWriteResult` distinguishes a first close from a
/// re-verification, a policy refusal from a period that never reached
/// classification, and a repository rejection from semantic already-current.
/// Those distinctions are load-bearing for the writer and meaningless to a
/// person, and their payloads are engine types a view may not import. So the
/// result is translated here, once, and the screen never sees it.
enum EndedMonthCheckpointActionOutcome: Hashable, Sendable {

    /// The writer accepted the attempt: a revision was appended, or the stored
    /// checkpoint already represented this month exactly as it stands.
    ///
    /// **Not a verification claim.** Whether the month now reads "Verified."
    /// is decided by the next read of the stored checkpoint, never by this
    /// value. Nothing may hold it as state and nothing may render it.
    case written

    /// Nothing was stored. The message is the whole of what a person is told:
    /// no engine case name, no revision number, no predecessor, no hash.
    case failed(String)
}

/// The one production path from a screen to the ended-month checkpoint writer.
///
/// ## What this type is for
///
/// `FinanceStore.writeEndedMonthCheckpoint` is engine-aware in both directions:
/// it takes a typed `PeriodCheckpointConfirmedAcknowledgments` and returns a
/// result carrying `PeriodCheckpointRevision`, `CheckpointClosePolicyRefusal`
/// and `PeriodCheckpointStoreError`. `App`, `Components`, `Features` and
/// `Surface` may not import the engine, so the call cannot be made from a view.
/// This is where it is made, in the same arrangement
/// `EndedMonthAcknowledgmentModel.confirmSelection(for:in:)` already uses: the
/// screen states the intent, this layer speaks to the store.
///
/// ## What it does not do
///
/// It reads no repository, holds no state, caches no result, classifies
/// nothing, constructs no revision and restates no close policy. It does not
/// suspend: the writer is a synchronous `@MainActor` action whose freshness
/// guarantee depends on readiness, chain tip, classification and store landing
/// in one turn, and wrapping it in a `Task` would break exactly that.
@MainActor
enum EndedMonthCheckpointAction {

    /// Attempt one ended-month checkpoint write.
    ///
    /// The authority is the caller's two values and nothing else: the period
    /// selected, and the acknowledgment decisions a person has explicitly
    /// confirmed. No identifier is rebuilt, no readiness is carried in, and no
    /// baseline comparison is passed as permission to write.
    static func perform(
        for selection: ReviewPeriodSelection,
        confirming acknowledgments: PeriodCheckpointConfirmedAcknowledgments,
        in store: FinanceStore
    ) -> EndedMonthCheckpointActionOutcome {
        outcome(
            for: store.writeEndedMonthCheckpoint(
                selection, confirmedAcknowledgments: acknowledgments
            )
        )
    }

    /// One writer result in the screen's words.
    ///
    /// Total over the result, and separated from `perform` so the whole mapping
    /// is reachable from a test without a store.
    static func outcome(
        for result: EndedMonthCheckpointWriteResult
    ) -> EndedMonthCheckpointActionOutcome {
        switch result {

        // An append, or a stored checkpoint that already says exactly this.
        // Already-current is a race, not a fault: the person asked for a state
        // that already holds, and telling them off for it would be wrong.
        case .storedFirstClose, .storedReverify, .alreadyCurrent:
            .written

        case let .refused(reason):
            .failed(message(for: reason))

        case let .notWritable(reason):
            .failed(message(for: reason))

        // The repository refused or failed.
        case .storeRefused:
            .failed(Message.saveFailed)

        // A fresh-UUID append that the store said it already had. This is not
        // semantic already-current — that is decided before any identity is
        // minted — so it is reported as the invariant failure it is and never
        // as success.
        case .storeUnexpectedAlreadyStored:
            .failed(Message.saveFailed)
        }
    }

    /// The three things a person can usefully be told.
    ///
    /// Deliberately few. A person cannot act on the difference between an
    /// indeterminate comparison and an unreadable baseline, and naming it would
    /// leak the checkpoint chain into a screen that is not allowed to know it
    /// exists.
    enum Message {

        /// The month moved out from under the decision being made. Re-reading
        /// it is the action that helps.
        static let reviewAgain = "This month changed. Review it again before verifying."

        /// Nothing is wrong with the month; this build cannot verify it right
        /// now. Includes every history this build cannot safely extend.
        static let unavailable = "Verification isn't available right now."

        /// The attempt was well-formed and the save did not happen.
        static let saveFailed = "Couldn't verify this month. Try again."
    }

    /// Why the policy refused, as one of the three.
    private static func message(for refusal: CheckpointClosePolicyRefusal) -> String {
        switch refusal {

        // The month is not in the state the decision assumed: either readiness
        // moved, or the comparison the readiness carries disagrees with the tip
        // this turn observed. Both are answered by looking again.
        case .readinessNotReady, .inconsistentPreviousObservation:
            Message.reviewAgain

        // A history or a period this build cannot safely close. Nothing a
        // person does on this screen changes any of them.
        case .unsupportedWriteScope, .periodNotEnded, .semanticProjectionUnavailable,
             .previousRevisionFormatUnsupported, .previousRevisionCorrupt,
             .previousRevisionPeriodMismatch, .previousRevisionKindMismatch,
             .comparisonIndeterminate, .comparisonUnavailable:
            Message.unavailable

        // The candidate could not be built. An invariant failure, not a state.
        case .revisionNumberUnrepresentable, .revisionConstructionRefused:
            Message.saveFailed
        }
    }

    /// Why the action never reached classification, as one of the three.
    ///
    /// All five are availability: a store that cannot be written, or a period
    /// this screen should never have offered. None of them is a save failure,
    /// because nothing was attempted.
    private static func message(for reason: EndedMonthCheckpointNotWritableReason) -> String {
        switch reason {
        case .storeFailedToLoad, .storeIsReadOnly, .weeklySelection,
             .periodNotEnded, .reviewUnavailable:
            Message.unavailable
        }
    }
}
