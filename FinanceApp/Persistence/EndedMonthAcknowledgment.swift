import FinanceCore
import Foundation
import Observation

/// The ended-month acknowledgment interaction: its ephemeral state, and the
/// engine-free vocabulary the screen renders it with.
///
/// ## What an acknowledgment is here
///
/// An explicit statement that a person has seen a limitation this month
/// carries and accepts it for the purpose of this verification. It repairs
/// nothing: no amount, sign, day, total or balance moves, and the period's
/// safe claims are unchanged — `PeriodCheckpointEvaluator` derives those from
/// the exceptions themselves, never from whether somebody decided on them.
///
/// ## What it is not
///
/// It is not a close. Nothing in this file writes a revision, reaches a
/// repository, or asks the store to remember anything. The authority produced
/// here lives in memory for as long as the screen that made it, and leaving
/// that screen discards it. Write policy is a later, separately authorized
/// question, and this interaction deliberately cannot answer it.
///
/// It is also not a carry-forward. The E1 matcher reconstructs which current
/// exceptions correspond to acknowledgments on a *previous* revision; no
/// previous revision is read here, no candidate is derived, and nothing is
/// proposed to a person on its own initiative. Every decision in this file is
/// a first-time decision, stated by hand.
///
/// ## Why this file sits below the screen
///
/// `App`, `Components`, `Features` and `Surface` may not import the engine, so
/// a checkpoint subject cannot appear on a view. It must not be replaced by an
/// identifier either: an identifier that survives while its kind, day or
/// amount changes underneath describes something the person never saw, and
/// confirming against one is exactly the substitution E2 exists to refuse. So
/// the subject travels through the screen sealed inside
/// `AcknowledgmentSubject` — whole, unnamed and unforgeable — and is unsealed
/// only here, where confirmation happens.

// MARK: - Subjects

/// One exact current checkpoint subject, sealed.
///
/// The screen can carry one and hand it back; it cannot read it, name its
/// type, or make one up. Every decision is stated with the value inside,
/// never with anything rendered from it.
struct AcknowledgmentSubject: Hashable, Sendable {
    fileprivate let exception: PeriodCheckpointException
}

// MARK: - Rows

/// One current checkpoint exception, as a row a person can decide on.
struct EndedMonthAcknowledgmentRow: Identifiable, Hashable, Sendable {

    /// The sealed subject this row is about.
    let subject: AcknowledgmentSubject

    let title: String
    let detail: String
    let amount: Amount?

    /// Whether the evaluator counted this exception as acknowledged in the
    /// readiness this row was built from. Read from the evaluator's own
    /// partition; never inferred from what the screen last did.
    let isAcknowledged: Bool

    /// For `ForEach` only. Identity orders and diffs a list; it decides
    /// nothing and grants nothing.
    let id: String
}

// MARK: - Readiness, in the screen's words

/// How the ended month stands, named rather than decided.
///
/// Every case is a direct reading of `PeriodCheckpointDisposition`. The screen
/// does not work out for itself that a month is ready, still undecided or
/// blocked — that is the evaluator's answer, and this only gives it words.
enum EndedMonthAcknowledgmentReadinessState: Hashable, Sendable {

    /// Blockers. A blocker is never acknowledgeable, and no decision here
    /// clears one.
    case blocked

    /// Exceptions remain that nobody has decided on.
    case needsDecisions(remaining: Int)

    /// Every carried exception is explicitly accepted and nothing blocks the
    /// month. Nothing has been written: this states where the decisions stand,
    /// not that the month was closed.
    case readyWithAcknowledgments

    /// The month carries no exceptions at all.
    case nothingToDecide
}

// MARK: - The screen's content

/// The acknowledgment part of the ended-month verification screen.
struct EndedMonthAcknowledgmentSection: Hashable, Sendable {
    let statement: String
    let rows: [EndedMonthAcknowledgmentRow]

    /// False while blockers stand. Acknowledgment never overrides a blocker,
    /// so the month must not offer a decision that would look like progress.
    let allowsConfirmation: Bool
}

/// Everything the ended-month verification screen renders, engine-free.
struct EndedMonthVerificationScreen: Hashable, Sendable {
    let verification: PeriodVerificationPresentation

    /// Where the month stands, as the evaluator answered it.
    ///
    /// Carried beside the section rather than inside it because the section is
    /// nil whenever the month carries no exception — and a month with no
    /// exception is not necessarily ready. Blockers are a separate axis, so
    /// `.blocked` and `.nothingToDecide` both present no rows. A screen that
    /// read readiness from the section's presence would offer to verify a
    /// month the evaluator has blocked.
    let readinessState: EndedMonthAcknowledgmentReadinessState

    /// Nil when the month carries no limitation to decide on.
    let acknowledgment: EndedMonthAcknowledgmentSection?
}

// MARK: - Mapping

/// Readiness → rows and state. Pure, and deliberately incurious: it reads the
/// exceptions, the evaluator's own acknowledged/undecided partition and the
/// disposition, and nothing else.
///
/// In particular it never reads `baselineComparison`, so no changed, unchanged
/// or previously-verified claim can leave it.
enum EndedMonthAcknowledgmentMapper {

    static func rows(for readiness: PeriodCheckpointReadiness) -> [EndedMonthAcknowledgmentRow] {
        let acknowledged = Set(readiness.acknowledgedExceptions)
        return readiness.exceptions.map { exception in
            EndedMonthAcknowledgmentRow(
                subject: AcknowledgmentSubject(exception: exception),
                title: title(for: exception.kind),
                detail: detail(for: exception.kind),
                amount: exception.amount.map(DomainMapper.amount),
                isAcknowledged: acknowledged.contains(exception),
                id: "acknowledgment:\(exception.id)"
            )
        }
    }

    static func state(
        for readiness: PeriodCheckpointReadiness
    ) -> EndedMonthAcknowledgmentReadinessState {
        switch readiness.disposition {
        case .blocked: .blocked
        case .needsDecisions: .needsDecisions(remaining: readiness.undecidedExceptions.count)
        case .readyWithAcknowledgedExceptions: .readyWithAcknowledgments
        case .readyClean: .nothingToDecide
        }
    }

    /// The whole acknowledgment section, or nil when there is nothing to
    /// decide on.
    static func section(
        for readiness: PeriodCheckpointReadiness
    ) -> EndedMonthAcknowledgmentSection? {
        let rows = rows(for: readiness)
        guard !rows.isEmpty else { return nil }
        let state = state(for: readiness)
        return EndedMonthAcknowledgmentSection(
            statement: statement(for: state),
            rows: rows,
            allowsConfirmation: state != .blocked
        )
    }

    /// Where the month stands, in one sentence.
    ///
    /// Deliberately says nothing about durability. No decision made on this
    /// screen is stored, so no wording here may suggest that one was.
    static func statement(for state: EndedMonthAcknowledgmentReadinessState) -> String {
        switch state {
        case .blocked:
            "Records for this month are incomplete. Accepting a limitation does not change that."
        case let .needsDecisions(remaining):
            remaining == 1
                ? "One limitation still needs a decision."
                : "\(remaining) limitations still need a decision."
        case .readyWithAcknowledgments:
            "Every limitation this month carries has been accepted."
        case .nothingToDecide:
            "This month carries no limitations to decide on."
        }
    }

    /// The same product vocabulary the verification preview uses, shortened to
    /// a row. No checkpoint enum name reaches a screen.
    private static func title(for kind: PeriodCheckpointExceptionKind) -> String {
        switch kind {
        case .unknownBookedEconomics: "A bank movement's meaning isn't decided"
        case .unresolvedEvidenceLinkage: "An amount has no linked bank record"
        case .aggregateEvidenceModelLimitation: "One movement, two existing records"
        case .unresolvedEconomicClassification: "A movement's economic kind isn't decided"
        case .unresolvedIncomeClassificationOrOwnership: "An inflow's source or share isn't decided"
        case .uncategorizedEconomicSpending: "Some spending isn't assigned"
        case .overdueExpectedOccurrence: "A scheduled payment wasn't seen"
        case .providerStatusConflict: "The bank's status conflicts with an earlier decision"
        case .acceptedReconciliationAmountDifference: "An accepted difference stays on the record"
        }
    }

    /// What the month loses by carrying it — the honest cost, stated before a
    /// person decides, so accepting is a decision rather than a dismissal.
    private static func detail(for kind: PeriodCheckpointExceptionKind) -> String {
        switch kind {
        case .unknownBookedEconomics:
            "Real money moved and nothing says what it was, so the month's totals may be incomplete."
        case .unresolvedEvidenceLinkage:
            "The amount is counted. Only the bank record behind it isn't linked."
        case .aggregateEvidenceModelLimitation:
            "One bank movement stands against two existing records, and that relationship can't be kept."
        case .unresolvedEconomicClassification:
            "Whether this is spending, a transfer, or neither hasn't been decided."
        case .unresolvedIncomeClassificationOrOwnership:
            "Money arrived, and what it is — or how much of it is yours — hasn't been decided."
        case .uncategorizedEconomicSpending:
            "The amount is counted in the total, but belongs to no budget line."
        case .overdueExpectedOccurrence:
            "Nothing settled it, so neither \u{201C}it happened\u{201D} nor \u{201C}it didn't\u{201D} is established."
        case .providerStatusConflict:
            "The bank has withdrawn its side of a decision that still stands here."
        case .acceptedReconciliationAmountDifference:
            "A difference was accepted as explained, and stays on the record as a note."
        }
    }
}

// MARK: - The interaction

/// Live acknowledgment state for one ended-month verification screen.
///
/// Ephemeral by construction. There is no initializer that restores a previous
/// state, no store of its own, no `UserDefaults`, no file and no shared
/// instance: a new model is a month with nothing decided, and dropping the
/// model drops every decision made through it. Losing an acknowledgment by
/// leaving the screen is the intended behaviour of this slice, not a gap in it.
@MainActor
@Observable
final class EndedMonthAcknowledgmentModel {

    /// The typed authority the evaluator is given. `.noDecisions` until an
    /// explicit confirmation succeeds.
    private(set) var confirmedAcknowledgments: PeriodCheckpointConfirmedAcknowledgments
        = .noDecisions

    /// The whole subjects behind `confirmedAcknowledgments`, in decision order.
    ///
    /// Retained because confirmed authority deliberately does not vend its
    /// subjects back, and because a cumulative decision has to be *restated* as
    /// whole values against whatever the month carries now. Merging by
    /// identifier would let a changed subject inherit an earlier decision.
    private(set) var decidedSubjects: [AcknowledgmentSubject] = []

    /// What a person has ticked and not yet confirmed.
    ///
    /// Selection is not authority. Nothing in here reaches the evaluator, and
    /// a selection left unconfirmed accepts nothing.
    private(set) var selectedSubjects: [AcknowledgmentSubject] = []

    /// Set when the last explicit confirmation was refused, so the screen can
    /// say so. A refusal is never silent and never partial.
    private(set) var lastConfirmationWasRefused = false

    init() {}

    var hasSelection: Bool { !selectedSubjects.isEmpty }

    func isSelected(_ row: EndedMonthAcknowledgmentRow) -> Bool {
        selectedSubjects.contains(row.subject)
    }

    /// Tick or untick one row. Selecting grants nothing.
    func toggle(_ row: EndedMonthAcknowledgmentRow) {
        lastConfirmationWasRefused = false
        if let index = selectedSubjects.firstIndex(of: row.subject) {
            selectedSubjects.remove(at: index)
        } else {
            selectedSubjects.append(row.subject)
        }
    }

    /// Drop local state for subjects the month no longer carries, and restate
    /// the survivors as authority. Returns whether anything was dropped.
    ///
    /// The month can change underneath a screen that stays open — resolving an
    /// observation from a linked Decision removes the exception it raised — and
    /// a decision made about an exception that is gone describes nothing. E2
    /// already refuses such authority, which is correct and stays correct; what
    /// it cannot do is tidy up after a person who is still standing on the
    /// screen. That is this, and it is the whole of it: local hygiene, not a
    /// second opinion about what the evaluator decided.
    ///
    /// The test is the same one confirmation and E2 apply — value-equal to
    /// exactly one carried exception — so a subject survives only while it is
    /// still *exactly* what was decided on. A changed subject does not inherit
    /// its predecessor's decision, a disappeared one is dropped, and an
    /// identifier never joins anything. Nothing is ever added here: a current
    /// exception nobody has decided on stays undecided, and no acknowledgment
    /// is carried forward on anybody's behalf.
    @discardableResult
    func reconcile(carrying exceptions: [PeriodCheckpointException]) -> Bool {
        func survives(_ subject: AcknowledgmentSubject) -> Bool {
            exceptions.filter { $0 == subject.exception }.count == 1
        }
        let decided = decidedSubjects.filter(survives)
        let selected = selectedSubjects.filter(survives)
        guard decided.count != decidedSubjects.count
                || selected.count != selectedSubjects.count
        else { return false }

        decidedSubjects = decided
        selectedSubjects = selected
        // Restated through the one authority path an explicit confirmation
        // uses, never assembled here. Every survivor already satisfies that
        // path's rule, so the refusal branch is unreachable; it drops the whole
        // set rather than inventing a partial one if that ever stops being true.
        confirmedAcknowledgments = (try? PeriodCheckpointAcknowledgmentConfirmation.confirm(
            decisions: decided.map(\.exception),
            carriedExceptions: exceptions
        )) ?? .noDecisions
        return true
    }

    /// The screen's content, re-evaluated through the real checkpoint path
    /// carrying whatever has been explicitly confirmed so far.
    ///
    /// A read. It closes nothing, writes nothing and decides nothing: the
    /// disposition it reports is the evaluator's answer to the authority this
    /// interaction is holding.
    ///
    /// Local state is reconciled against the exceptions the month carries now
    /// before that answer is reported. The first evaluation supplies them: E2
    /// blocking on stale authority does not hide what the period carries, it
    /// only refuses to apply a decision to it. When reconciliation drops
    /// something the month is read again, so the returned screen is always the
    /// evaluator's answer to the authority this model is actually holding.
    func screen(
        for selection: ReviewPeriodSelection, in store: FinanceStore
    ) -> EndedMonthVerificationScreen? {
        guard let verification = store.endedMonthVerification(
            selection, confirmedAcknowledgments: confirmedAcknowledgments
        ) else { return nil }
        guard reconcile(carrying: verification.readiness.exceptions) else {
            return Self.screen(from: verification)
        }
        guard let reconciled = store.endedMonthVerification(
            selection, confirmedAcknowledgments: confirmedAcknowledgments
        ) else { return nil }
        return Self.screen(from: reconciled)
    }

    private static func screen(
        from verification: EndedMonthVerification
    ) -> EndedMonthVerificationScreen {
        EndedMonthVerificationScreen(
            verification: verification.presentation,
            readinessState: EndedMonthAcknowledgmentMapper.state(for: verification.readiness),
            acknowledgment: EndedMonthAcknowledgmentMapper.section(for: verification.readiness)
        )
    }

    /// The explicit action, as the screen reaches it.
    ///
    /// Re-reads the month first, so a decision is always checked against the
    /// exceptions carried at the moment it is made rather than the ones that
    /// were on screen when the row was ticked.
    @discardableResult
    func confirmSelection(
        for selection: ReviewPeriodSelection, in store: FinanceStore
    ) -> Bool {
        guard let verification = store.endedMonthVerification(
            selection, confirmedAcknowledgments: confirmedAcknowledgments
        ) else { return false }
        // Reconciled here too, so the action does not depend on a read having
        // happened first. `exceptions` is what the period carries and does not
        // depend on the authority the evaluation was given, so the readiness
        // below is the right thing to decide against either way.
        reconcile(carrying: verification.readiness.exceptions)
        return confirmSelection(carrying: verification.readiness)
    }

    /// The authority event, and the only one.
    ///
    /// The intended decision set is everything already decided plus everything
    /// newly selected, restated whole and re-checked against the exceptions
    /// this month carries *now*. Nothing is merged by identifier and nothing is
    /// trusted because it was true a moment ago.
    ///
    /// All or nothing. If any subject is absent, ambiguous, duplicated or has
    /// changed underneath its identifier, `confirm` refuses the whole set: the
    /// previously confirmed authority stands exactly as it was, no part of the
    /// new decision is applied, and the selection is dropped so the screen
    /// restates itself from the exceptions carried now.
    @discardableResult
    func confirmSelection(carrying readiness: PeriodCheckpointReadiness) -> Bool {
        guard !selectedSubjects.isEmpty else { return false }
        var intended = decidedSubjects
        for subject in selectedSubjects where !intended.contains(subject) {
            intended.append(subject)
        }
        do {
            let authority = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
                decisions: intended.map(\.exception),
                carriedExceptions: readiness.exceptions
            )
            decidedSubjects = intended
            confirmedAcknowledgments = authority
            selectedSubjects = []
            lastConfirmationWasRefused = false
            return true
        } catch {
            selectedSubjects = []
            lastConfirmationWasRefused = true
            return false
        }
    }

    /// Back to nothing decided.
    ///
    /// Not an undo of a stored decision — there is none to undo. It is how the
    /// interaction starts over when the screen is pointed at a different month,
    /// so a decision made about one period can never be offered as authority
    /// for another.
    func reset() {
        confirmedAcknowledgments = .noDecisions
        decidedSubjects = []
        selectedSubjects = []
        lastConfirmationWasRefused = false
    }
}
