import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// The ended-month first-time acknowledgment interaction.
///
/// What this suite proves is that a person can explicitly accept a limitation
/// an ended month carries, that the acceptance reaches the real evaluator as
/// typed authority, and that it reaches nothing else. It is deliberately as
/// interested in the second half as the first: the slice's whole boundary is
/// that an acknowledgment made here exists in memory and nowhere else.
///
/// Every fixture is synthetic and every store is temporary. No real store,
/// device or provider is touched, and nothing here closes a period.
@MainActor
@Suite("Ended-month first-time acknowledgment interaction")
struct EndedMonthAcknowledgmentTests {

    // MARK: - Fixtures

    private static let period = ReviewInterval.month(MonthKey(year: 2026, month: 8))
    private let asOf = Day(year: 2026, month: 9, day: 3)

    private func day(_ iso: String) -> Day { Day(isoString: iso)! }
    private func euro(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .eur)! }

    /// One account with a dated balance: enough for the engine to review the
    /// period, and small enough that every exception below is one the fixture
    /// stated rather than one the fixture caused.
    private func document() -> FinanceDocument {
        let account = Account(
            id: "account-test", name: "Test current account", currency: .eur,
            kind: .bank, supportedRails: PaymentRail.euroBankRails
        )
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account],
            balances: [
                AccountBalance(
                    accountID: account.id, balance: euro("500.00"), asOf: Self.period.start
                )
            ],
            planning: FinanceDocument.Planning(defaultScenario: .base)
        )
    }

    /// A real review, produced by the authoritative engine — never assembled.
    private func review(coverage: ReviewCoverageInput? = nil) throws -> ReviewResult {
        try ReviewEngine.review(
            ReviewRequest(
                document: document(),
                kind: .monthly,
                interval: Self.period,
                asOf: Self.period.end,
                coverage: coverage ?? .liveCovered([Self.period])
            )
        )
    }

    /// Two ordinary exceptions, and a third that shares A's identifier while
    /// describing a different amount. `staleA` is the substitution the whole
    /// confirmation boundary exists to refuse.
    private var exceptionA: PeriodCheckpointException {
        PeriodCheckpointException(
            id: "occurrence:rent", kind: .overdueExpectedOccurrence,
            day: day("2026-08-05"), amount: euro("200.00")
        )
    }
    private var exceptionB: PeriodCheckpointException {
        PeriodCheckpointException(
            id: "uncategorized:2026-08", kind: .uncategorizedEconomicSpending,
            day: day("2026-08-31"), amount: euro("18.00")
        )
    }
    private var staleA: PeriodCheckpointException {
        PeriodCheckpointException(
            id: "occurrence:rent", kind: .overdueExpectedOccurrence,
            day: day("2026-08-05"), amount: euro("250.00")
        )
    }

    /// The rows a screen would render for this readiness, carrying the sealed
    /// exact subjects a decision is stated with.
    private func rows(
        _ readiness: PeriodCheckpointReadiness
    ) -> [EndedMonthAcknowledgmentRow] {
        EndedMonthAcknowledgmentMapper.rows(for: readiness)
    }

    /// Tick the row for one exception, exactly as tapping it would.
    private func select(
        _ exception: PeriodCheckpointException,
        of readiness: PeriodCheckpointReadiness,
        in model: EndedMonthAcknowledgmentModel
    ) throws {
        let row = try #require(
            rows(readiness).first { $0.id == "acknowledgment:\(exception.id)" }
        )
        model.toggle(row)
    }

    /// The evaluator's answer for these carried exceptions and this authority.
    /// Readiness always comes from here; nothing in this suite decides for it.
    private func readiness(
        carrying exceptions: [PeriodCheckpointException],
        confirmed: PeriodCheckpointConfirmedAcknowledgments = .noDecisions,
        coverage: ReviewCoverageInput? = nil
    ) throws -> PeriodCheckpointReadiness {
        PeriodCheckpointEvaluator.evaluate(
            PeriodCheckpointRequest(
                period: Self.period,
                kind: .monthly,
                asOf: asOf,
                review: try review(coverage: coverage),
                exceptions: exceptions,
                confirmedAcknowledgments: confirmed
            )
        )
    }

    /// An overdue occurrence, which the production adapter turns into exactly
    /// one exception. Used where the composition itself must derive the
    /// subjects rather than the test handing them over.
    private func overdue(_ obligationID: String, _ iso: String, _ decimal: String)
        -> ExpectedOccurrence {
        ExpectedOccurrence(
            obligationID: obligationID,
            name: obligationID.capitalized,
            expectedDay: day(iso),
            amount: euro(decimal),
            requirement: .euroBankPayment(),
            spendingClass: .essential,
            status: .overdue
        )
    }

    private func compositionInput(
        confirmed: PeriodCheckpointConfirmedAcknowledgments
    ) throws -> AttentionComposition.Input {
        AttentionComposition.Input(
            document: document(),
            asOf: asOf,
            review: try review(),
            occurrences: [
                overdue("rent", "2026-08-05", "200.00"),
                overdue("gym", "2026-08-11", "30.00"),
            ],
            observations: [],
            categoryKeys: [:],
            checkpointBaseline: .noRevision,
            confirmedAcknowledgments: confirmed,
            period: Self.period,
            periodKind: .monthly,
            periodLabel: "August 2026"
        )
    }

    /// The same input with the parameter omitted entirely — the shape every
    /// caller but the verification interaction uses.
    private func compositionInputWithoutAuthority() throws -> AttentionComposition.Input {
        AttentionComposition.Input(
            document: document(),
            asOf: asOf,
            review: try review(),
            occurrences: [
                overdue("rent", "2026-08-05", "200.00"),
                overdue("gym", "2026-08-11", "30.00"),
            ],
            observations: [],
            categoryKeys: [:],
            checkpointBaseline: .noRevision,
            period: Self.period,
            periodKind: .monthly,
            periodLabel: "August 2026"
        )
    }

    // MARK: - P — typed authority plumbing

    @Test("P1: omitting the authority is the same evaluation as supplying no decisions")
    func defaultAuthorityIsUnchangedBehaviour() throws {
        let omitted = AttentionComposition.readiness(
            for: try compositionInputWithoutAuthority()
        )
        let explicit = AttentionComposition.readiness(
            for: try compositionInput(confirmed: .noDecisions)
        )
        #expect(omitted == explicit)
        #expect(omitted.acknowledgedExceptions.isEmpty)
        #expect(omitted.disposition == .needsDecisions)
        // And the default really is the empty one, not a shape that happens to
        // behave like it here.
        #expect(try compositionInputWithoutAuthority().confirmedAcknowledgments == .noDecisions)
    }

    @Test("P2: confirmed authority reaches the real evaluator through the composition")
    func authorityReachesTheEvaluator() throws {
        let baseline = AttentionComposition.readiness(
            for: try compositionInput(confirmed: .noDecisions)
        )
        #expect(baseline.exceptions.count == 2)
        #expect(baseline.blockers.isEmpty)

        // Confirmed against the subjects the composition itself derived.
        let authority = try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            decisions: baseline.exceptions, carriedExceptions: baseline.exceptions
        )
        let acknowledged = AttentionComposition.readiness(
            for: try compositionInput(confirmed: authority)
        )
        #expect(acknowledged.acknowledgedExceptions == baseline.exceptions)
        #expect(acknowledged.undecidedExceptions.isEmpty)
        #expect(acknowledged.disposition == .readyWithAcknowledgedExceptions)
        // Acknowledgment repairs nothing: the period's claims are what its
        // exceptions leave standing, decided or not.
        #expect(acknowledged.safeClaims == baseline.safeClaims)
    }

    @Test("P4: Home's attention composition supplies no acknowledgment authority")
    func homeSuppliesNoAuthority() throws {
        let store = try Self.code("Persistence/FinanceStore.swift")
        let start = try #require(store.range(of: "func makeAttentionPresentation("))
        let end = try #require(store.range(of: "reconciliationLookbackDays"))
        let homePath = store[start.lowerBound..<end.lowerBound]
        #expect(homePath.contains("AttentionComposition.Input("))
        #expect(!homePath.contains("confirmedAcknowledgments"))

        // Home still cannot reach `monthReadyToClose` at all: it hands the
        // composition no review, which blocks the checkpoint outright.
        #expect(homePath.contains("review: nil"))
    }

    // MARK: - C — first-time confirmation

    @Test("C1: a visible exception nobody decided on stays undecided")
    func visibilityIsNotADecision() throws {
        let model = EndedMonthAcknowledgmentModel()
        let current = try readiness(carrying: [exceptionA])
        let rendered = rows(current)

        #expect(rendered.count == 1)
        #expect(rendered[0].isAcknowledged == false)
        #expect(model.confirmedAcknowledgments == .noDecisions)
        #expect(current.undecidedExceptions == [exceptionA])
        #expect(current.disposition == .needsDecisions)
    }

    @Test("C2: an explicit decision on A acknowledges A")
    func explicitDecisionAcknowledges() throws {
        let model = EndedMonthAcknowledgmentModel()
        let carried = [exceptionA, exceptionB]
        let before = try readiness(carrying: carried)

        try select(exceptionA, of: before, in: model)
        #expect(model.confirmSelection(carrying: before))

        let after = try readiness(carrying: carried, confirmed: model.confirmedAcknowledgments)
        #expect(after.acknowledgedExceptions == [exceptionA])
        #expect(after.blockers.isEmpty)
        #expect(rows(after).first { $0.id == "acknowledgment:\(exceptionA.id)" }?.isAcknowledged
                == true)
    }

    @Test("C3: one acknowledged and one unconfirmed still needs decisions")
    func partialAcknowledgmentStillNeedsDecisions() throws {
        let model = EndedMonthAcknowledgmentModel()
        let carried = [exceptionA, exceptionB]
        let before = try readiness(carrying: carried)
        try select(exceptionA, of: before, in: model)
        #expect(model.confirmSelection(carrying: before))

        let after = try readiness(carrying: carried, confirmed: model.confirmedAcknowledgments)
        #expect(after.acknowledgedExceptions == [exceptionA])
        #expect(after.undecidedExceptions == [exceptionB])
        #expect(after.disposition == .needsDecisions)
        #expect(EndedMonthAcknowledgmentMapper.state(for: after) == .needsDecisions(remaining: 1))
    }

    @Test("C4: two decisions, made one after the other, both hold")
    func cumulativeDecisionsAccumulate() throws {
        let model = EndedMonthAcknowledgmentModel()
        let carried = [exceptionA, exceptionB]
        let before = try readiness(carrying: carried)

        try select(exceptionA, of: before, in: model)
        #expect(model.confirmSelection(carrying: before))
        let midway = try readiness(carrying: carried, confirmed: model.confirmedAcknowledgments)
        try select(exceptionB, of: midway, in: model)
        #expect(model.confirmSelection(carrying: midway))

        // B did not replace A: the second confirmation restated the whole
        // intended set against what the month carries now.
        #expect(model.decidedSubjects.count == 2)

        let after = try readiness(carrying: carried, confirmed: model.confirmedAcknowledgments)
        #expect(after.acknowledgedExceptions.count == 2)
        #expect(after.undecidedExceptions.isEmpty)
        #expect(after.disposition == .readyWithAcknowledgedExceptions)
        #expect(EndedMonthAcknowledgmentMapper.state(for: after) == .readyWithAcknowledgments)
    }

    @Test("C5: a subject that changed under its identifier fails closed")
    func substitutedSubjectFailsClosed() throws {
        let model = EndedMonthAcknowledgmentModel()
        let before = try readiness(carrying: [exceptionA, exceptionB])
        try select(exceptionA, of: before, in: model)
        #expect(model.confirmSelection(carrying: before))
        let granted = model.confirmedAcknowledgments

        // The month now carries a different rent amount under the same id.
        let substituted = try readiness(carrying: [staleA, exceptionB], confirmed: granted)
        #expect(substituted.disposition == .blocked)
        #expect(substituted.blockers.map(\.kind).contains(.confirmedAcknowledgmentSubjectMismatch))
        #expect(substituted.acknowledgedExceptions.isEmpty)
        #expect(EndedMonthAcknowledgmentMapper.state(for: substituted) == .blocked)
        #expect(EndedMonthAcknowledgmentMapper.section(for: substituted)?.allowsConfirmation
                == false)

        // And a further confirmation against the substituted subject is
        // refused whole, leaving the earlier authority exactly as it was.
        try select(exceptionB, of: substituted, in: model)
        #expect(model.confirmSelection(carrying: substituted) == false)
        #expect(model.confirmedAcknowledgments == granted)
        #expect(model.decidedSubjects.count == 1)
        #expect(model.lastConfirmationWasRefused)
        #expect(model.hasSelection == false)
    }

    @Test("C5b: no part of a mixed valid/stale decision is applied")
    func mixedDecisionAppliesNothing() throws {
        let model = EndedMonthAcknowledgmentModel()
        // A is ticked while the month still carries it; by the time the
        // decision is made the month carries the substituted subject instead.
        let seen = try readiness(carrying: [exceptionA, exceptionB])
        try select(exceptionA, of: seen, in: model)
        try select(exceptionB, of: seen, in: model)

        let now = try readiness(carrying: [staleA, exceptionB])
        #expect(model.confirmSelection(carrying: now) == false)
        #expect(model.confirmedAcknowledgments == .noDecisions)
        #expect(model.decidedSubjects.isEmpty)

        // B was genuinely carried and is still undecided: a refusal applies
        // nothing at all, not the valid half.
        let after = try readiness(
            carrying: [staleA, exceptionB], confirmed: model.confirmedAcknowledgments
        )
        #expect(after.acknowledgedExceptions.isEmpty)
        #expect(after.undecidedExceptions.count == 2)
        #expect(after.blockers.isEmpty)
    }

    @Test("C6: two exceptions sharing an identifier block, and acknowledge nothing")
    func duplicateIdentifiersBlock() throws {
        let model = EndedMonthAcknowledgmentModel()
        let carried = [exceptionA, staleA]
        let before = try readiness(carrying: carried)
        #expect(before.blockers.map(\.kind).contains(.duplicateExceptionIdentity))

        let clean = try readiness(carrying: [exceptionA, exceptionB])
        try select(exceptionA, of: clean, in: model)
        #expect(model.confirmSelection(carrying: clean))

        let after = try readiness(carrying: carried, confirmed: model.confirmedAcknowledgments)
        #expect(after.blockers.map(\.kind).contains(.duplicateExceptionIdentity))
        #expect(after.disposition == .blocked)
        #expect(after.acknowledgedExceptions.isEmpty)
    }

    @Test("C7: a blocker survives every acknowledgment")
    func blockersAreNeverAcknowledgeable() throws {
        let model = EndedMonthAcknowledgmentModel()
        let carried = [exceptionA, exceptionB]
        let before = try readiness(carrying: carried)
        try select(exceptionA, of: before, in: model)
        try select(exceptionB, of: before, in: model)
        #expect(model.confirmSelection(carrying: before))

        // Coverage the review engine could not establish. Nothing decided here
        // covers a day.
        let after = try readiness(
            carrying: carried, confirmed: model.confirmedAcknowledgments, coverage: .absent
        )
        #expect(after.disposition == .blocked)
        #expect(after.blockers.contains { $0.kind.isCoverageDerived })
        #expect(EndedMonthAcknowledgmentMapper.state(for: after) == .blocked)
        #expect(after.safeClaims == .blocked)
        #expect(EndedMonthAcknowledgmentMapper.section(for: after)?.allowsConfirmation == false)
    }

    // MARK: - U — the explicit action boundary

    @Test("U1: building the interaction and its rows confirms nothing")
    func openingConfirmsNothing() throws {
        let model = EndedMonthAcknowledgmentModel()
        let current = try readiness(carrying: [exceptionA, exceptionB])
        _ = EndedMonthAcknowledgmentMapper.section(for: current)
        _ = PeriodVerificationMapper.present(
            current, periodLabel: "August 2026", observations: [], expectedPayments: []
        )
        #expect(model.confirmedAcknowledgments == .noDecisions)
        #expect(model.decidedSubjects.isEmpty)
        #expect(current.acknowledgedExceptions.isEmpty)
    }

    @Test("U3: selecting a row grants no authority")
    func selectionIsNotConfirmation() throws {
        let model = EndedMonthAcknowledgmentModel()
        let current = try readiness(carrying: [exceptionA, exceptionB])
        try select(exceptionA, of: current, in: model)
        try select(exceptionB, of: current, in: model)

        #expect(model.selectedSubjects.count == 2)
        #expect(model.hasSelection)
        #expect(model.confirmedAcknowledgments == .noDecisions)
        #expect(model.decidedSubjects.isEmpty)

        let after = try readiness(
            carrying: [exceptionA, exceptionB], confirmed: model.confirmedAcknowledgments
        )
        #expect(after.disposition == .needsDecisions)
        #expect(after.acknowledgedExceptions.isEmpty)
        #expect(rows(after).allSatisfy { !$0.isAcknowledged })

        // Unticking is equally inert.
        try select(exceptionA, of: current, in: model)
        #expect(model.selectedSubjects.count == 1)
        #expect(model.confirmedAcknowledgments == .noDecisions)
    }

    @Test("U4: confirmation is reached from exactly one place in the product")
    func confirmationHasOneProductionCaller() throws {
        var callers: [String] = []
        for file in try Self.swiftSources(under: [
            "App", "Components", "Features", "Surface", "Attention", "Persistence"
        ]) {
            let code = try Self.code(file.path)
            if code.contains("PeriodCheckpointAcknowledgmentConfirmation") {
                callers.append(file.path)
            }
        }
        #expect(callers == ["Persistence/EndedMonthAcknowledgment.swift"])

        let interaction = try Self.code("Persistence/EndedMonthAcknowledgment.swift")
        #expect(
            interaction.components(
                separatedBy: "PeriodCheckpointAcknowledgmentConfirmation.confirm("
            ).count - 1 == 1
        )
        // And it sits inside the explicit action, not in a mapper or an
        // initializer that something else could run for a person.
        let action = try #require(interaction.range(of: "func confirmSelection(carrying"))
        let after = try #require(interaction.range(of: "func reset("))
        #expect(
            interaction[action.lowerBound..<after.lowerBound]
                .contains("PeriodCheckpointAcknowledgmentConfirmation.confirm(")
        )

        // The screen never confirms for itself; it asks the interaction to,
        // from one button action and nowhere else.
        let view = try Self.code("Features/Insights/InsightsView.swift")
        #expect(!view.contains("PeriodCheckpointAcknowledgmentConfirmation"))
        #expect(view.components(separatedBy: "confirmSelection(").count - 1 == 1)
    }

    @Test("U5: nothing is selected, proposed or confirmed on the interaction's behalf")
    func nothingIsPreselected() throws {
        let model = EndedMonthAcknowledgmentModel()
        let current = try readiness(carrying: [exceptionA, exceptionB])
        let rendered = rows(current)

        #expect(rendered.count == 2)
        #expect(model.hasSelection == false)
        #expect(rendered.allSatisfy { !model.isSelected($0) })
        // Confirming an empty selection is a no-op, not an empty success.
        #expect(model.confirmSelection(carrying: current) == false)
        #expect(model.confirmedAcknowledgments == .noDecisions)
        #expect(model.lastConfirmationWasRefused == false)
    }

    // MARK: - E — ephemerality

    @Test("E1/E3: a new interaction is a month with nothing decided")
    func interactionStateStartsAndReturnsEmpty() throws {
        let carried = [exceptionA, exceptionB]
        let current = try readiness(carrying: carried)
        let first = EndedMonthAcknowledgmentModel()
        #expect(first.confirmedAcknowledgments == .noDecisions)

        try select(exceptionA, of: current, in: first)
        #expect(first.confirmSelection(carrying: current))
        #expect(
            try readiness(carrying: carried, confirmed: first.confirmedAcknowledgments)
                .acknowledgedExceptions == [exceptionA]
        )

        // Rebuilt, as leaving the screen rebuilds it. Nothing was kept, and
        // nothing goes looking for what the previous one decided.
        let second = EndedMonthAcknowledgmentModel()
        #expect(second.confirmedAcknowledgments == .noDecisions)
        #expect(second.decidedSubjects.isEmpty)
        let after = try readiness(carrying: carried, confirmed: second.confirmedAcknowledgments)
        #expect(after.acknowledgedExceptions.isEmpty)
        #expect(after == (try readiness(carrying: carried)))

        // Pointing the same interaction at another month starts over too.
        first.reset()
        #expect(first.confirmedAcknowledgments == .noDecisions)
        #expect(first.decidedSubjects.isEmpty)
    }

    @Test("E2/E4: acknowledging moves readiness in memory and writes nothing")
    func acknowledgmentWritesNothing() throws {
        let (store, container) = try Self.coveredStore()
        let selection = ReviewPeriodSelection(scope: .month, offset: -1)

        let model = EndedMonthAcknowledgmentModel()
        let preview = try #require(model.screen(for: selection, in: store))
        let section = try #require(preview.acknowledgment)
        #expect(!section.rows.isEmpty)
        #expect(section.rows.allSatisfy { !$0.isAcknowledged })
        #expect(section.allowsConfirmation)
        #expect(section.statement == "One limitation still needs a decision.")

        for row in section.rows { model.toggle(row) }
        #expect(model.confirmSelection(for: selection, in: store))

        // Readiness moves, in memory.
        let acknowledged = try #require(model.screen(for: selection, in: store))
        let after = try #require(acknowledged.acknowledgment)
        #expect(after.rows.allSatisfy { $0.isAcknowledged })
        #expect(after.statement == "Every limitation this month carries has been accepted.")

        // And the store is exactly as empty of checkpoint history as before.
        let context = container.mainContext
        #expect(try context.fetch(FetchDescriptor<StoredPeriodCheckpointDataset>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<StoredPeriodCheckpointRevision>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<StoredPeriodCheckpointAcknowledgment>()).isEmpty)
        #expect(store.checkpoints.occupancy() == .empty)

        // The store itself remembers no decision: a fresh interaction over the
        // same store is the month with nothing decided again.
        let reopened = try #require(
            EndedMonthAcknowledgmentModel().screen(for: selection, in: store)
        )
        #expect(reopened == preview)
    }

    @Test("A month whose records are incomplete stays blocked through the real store")
    func blockedMonthStaysBlockedThroughTheStore() throws {
        // The same document with no authoritative provider window: the month's
        // coverage is not established, so it is blocked whatever is accepted.
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = try FinanceStore(context: container.mainContext, now: fixtureInstant(asOf))
        try store.importDocument(Self.storeDocument())
        let selection = ReviewPeriodSelection(scope: .month, offset: -1)

        let model = EndedMonthAcknowledgmentModel()
        let section = try #require(model.screen(for: selection, in: store)?.acknowledgment)
        #expect(section.allowsConfirmation == false)
        #expect(section.statement
                == "Records for this month are incomplete. Accepting a limitation does not change that.")

        // Accepting everything does not move it.
        for row in section.rows { model.toggle(row) }
        #expect(model.confirmSelection(for: selection, in: store))
        let after = try #require(model.screen(for: selection, in: store)?.acknowledgment)
        #expect(after.allowsConfirmation == false)
        #expect(after.statement == section.statement)
    }

    @Test("The read-only preview is unchanged by the new parameter")
    func defaultPreviewIsUnchanged() throws {
        let (store, _) = try Self.coveredStore()
        let selection = ReviewPeriodSelection(scope: .month, offset: -1)

        let screen = try #require(store.review(selection))
        let direct = try #require(store.endedMonthVerification(selection))
        #expect(screen.verification == direct.presentation)

        // A running month and a week have no verification at all, with or
        // without the interaction.
        #expect(store.endedMonthVerification(ReviewPeriodSelection(scope: .month, offset: 0)) == nil)
        #expect(store.endedMonthVerification(ReviewPeriodSelection(scope: .week, offset: -1)) == nil)
        #expect(store.review(ReviewPeriodSelection(scope: .week, offset: -1))?.verification == nil)
        #expect(
            EndedMonthAcknowledgmentModel()
                .screen(for: ReviewPeriodSelection(scope: .month, offset: 0), in: store) == nil
        )
    }

    // MARK: - V — what the screen may say

    @Test("V1/V2/V3: readiness is named, never decided, and claims no durability")
    func presentationNamesTheEvaluatorsAnswer() throws {
        let carried = [exceptionA, exceptionB]
        let undecided = try readiness(carrying: carried)
        #expect(EndedMonthAcknowledgmentMapper.state(for: undecided)
                == .needsDecisions(remaining: 2))

        let model = EndedMonthAcknowledgmentModel()
        try select(exceptionA, of: undecided, in: model)
        try select(exceptionB, of: undecided, in: model)
        #expect(model.confirmSelection(carrying: undecided))
        let ready = try readiness(carrying: carried, confirmed: model.confirmedAcknowledgments)
        #expect(EndedMonthAcknowledgmentMapper.state(for: ready) == .readyWithAcknowledgments)
        #expect(EndedMonthAcknowledgmentMapper.section(for: ready)?.allowsConfirmation == true)

        // A clean month offers no section at all.
        let clean = try readiness(carrying: [])
        #expect(EndedMonthAcknowledgmentMapper.state(for: clean) == .nothingToDecide)
        #expect(EndedMonthAcknowledgmentMapper.section(for: clean) == nil)

        let blocked = try readiness(
            carrying: carried, confirmed: model.confirmedAcknowledgments, coverage: .absent
        )
        #expect(EndedMonthAcknowledgmentMapper.state(for: blocked) == .blocked)

        // Nothing was written, so no wording may suggest that something was.
        let states: [EndedMonthAcknowledgmentReadinessState] = [
            .blocked, .needsDecisions(remaining: 1), .needsDecisions(remaining: 3),
            .readyWithAcknowledgments, .nothingToDecide
        ]
        let everyKind = PeriodCheckpointExceptionKind.allCases.enumerated().map { index, kind in
            PeriodCheckpointException(
                id: "kind-\(index)", kind: kind,
                aggregateBasis: kind == .aggregateEvidenceModelLimitation
                    ? .structuralCandidateOnly : nil
            )
        }
        let rowText = rows(try readiness(carrying: everyKind))
            .flatMap { [$0.title, $0.detail] }
        #expect(rowText.count == PeriodCheckpointExceptionKind.allCases.count * 2)
        let visible = (states.map(EndedMonthAcknowledgmentMapper.statement(for:)) + rowText)
            .joined(separator: " ")
            .lowercased()
        for forbidden in [
            "saved", "persisted", "permanently", "verified", "closed", "close the month",
            "ready to close", "re-verify", "reverify", "checkpoint", "revision",
            "changed since", "unchanged since", "last verified",
        ] {
            #expect(!visible.contains(forbidden), "\(forbidden)")
        }
        // And no checkpoint enum name reaches a row either.
        for kind in PeriodCheckpointExceptionKind.allCases {
            #expect(!visible.contains(kind.rawValue.lowercased()))
        }
    }

    @Test("V4/V5: no baseline claim, and no write path outside the action adapter")
    func noBaselineClaimAndNoWriteAction() throws {
        let interaction = try Self.code("Persistence/EndedMonthAcknowledgment.swift")
        let view = try Self.code("Features/Insights/InsightsView.swift")

        // The D comparison presentation stays deferred: the interaction never
        // reads the axis it would have to read to make such a claim.
        for surface in [interaction, view] {
            for forbidden in [
                "baselineComparison", "unchangedSinceClose", "changedSinceClose",
                "requiresReverification", "notPreviouslyClosed", "previousQuality",
            ] {
                #expect(!surface.contains(forbidden), "\(forbidden)")
            }
        }

        // No revision, no repository, no matcher, and no second action that
        // would imply a close of its own.
        for surface in [interaction, view] {
            for forbidden in [
                "PeriodCheckpointRevision", "PeriodCheckpointRepository", "checkpoints.store(",
                "repository.store(", "compareAndAppend", "rehydratingStoredSnapshot",
                "PeriodCheckpointAcknowledgmentMatcher", "carryForwardCandidate",
                "PeriodCheckpointAcknowledgmentCandidate", "Close month",
                "Save checkpoint", "Confirm & close", "Reverify", "Re-verify",
            ] {
                #expect(!surface.contains(forbidden), "\(forbidden)")
            }
        }

        // The acknowledgment interaction still offers no verify action at all:
        // accepting a limitation remains an in-memory statement that stores
        // nothing, and it has not become the durability moment.
        #expect(!interaction.contains("Verify month"))

        // The view does now own the canonical checkpoint CTA. That supersedes
        // this test's original reading — that the build had no verify action
        // anywhere — under the Ended-Month Checkpoint Action UI authorization.
        // What has not changed is how it reaches the writer: through the action
        // adapter alone, never a store, a policy or a revision of its own.
        #expect(view.contains("Verify month"))
        #expect(view.contains("EndedMonthCheckpointAction.perform("))
    }

    // MARK: - Scope pins

    @Test("Authority is a typed subject set, never an identifier set")
    func noRawIdentifierAuthorityInTheProduct() throws {
        var offenders: [String] = []
        for file in try Self.swiftSources(under: [
            "App", "Components", "Features", "Surface", "Attention", "Persistence"
        ]) {
            let code = try Self.code(file.path)
            for forbidden in [
                "acknowledgedExceptionIDs", "confirmedAcknowledgmentIDs",
                "acknowledgedIDs", "carryForwardCandidateIDs",
            ] where code.contains(forbidden) {
                offenders.append("\(file.path): \(forbidden)")
            }
        }
        #expect(offenders.isEmpty, "an identifier set is being treated as authority: \(offenders)")

        // The interaction holds whole subjects, sealed, and the confirmation it
        // makes is stated with them.
        let interaction = try Self.code("Persistence/EndedMonthAcknowledgment.swift")
        #expect(interaction.contains("fileprivate let exception: PeriodCheckpointException"))
        #expect(interaction.contains("decidedSubjects: [AcknowledgmentSubject]"))
        #expect(interaction.contains("selectedSubjects: [AcknowledgmentSubject]"))
        #expect(interaction.contains("decisions: intended.map(\\.exception)"))
        #expect(!interaction.contains("Set<String>"))

        // A screen cannot make a subject, because it cannot see inside one.
        let view = try Self.code("Features/Insights/InsightsView.swift")
        #expect(!view.contains("AcknowledgmentSubject("))
        #expect(!view.contains(".subject"))

        // And the request-side authority is still the typed one.
        let composition = try Self.code("Attention/AttentionComposition.swift")
        #expect(composition.contains(
            "confirmedAcknowledgments: PeriodCheckpointConfirmedAcknowledgments"
        ))
        #expect(composition.contains("confirmedAcknowledgments: input.confirmedAcknowledgments"))
    }

    @Test("The interaction owns no persistence of any kind")
    func interactionHoldsNoPersistence() throws {
        let interaction = try Self.code("Persistence/EndedMonthAcknowledgment.swift")
        for forbidden in [
            "SwiftData", "ModelContext", "ModelContainer", "UserDefaults", "AppStorage",
            "FileManager", "static let shared", "SceneStorage", "NSUbiquitous",
        ] {
            #expect(!interaction.contains(forbidden), "\(forbidden)")
        }
        // The only initializer is the empty one: there is no state to restore.
        #expect(interaction.components(separatedBy: "init(").count - 1 == 1)
        #expect(interaction.contains("init() {}"))
    }

    /// Store calls are permitted in exactly one named production file, and
    /// revision construction remains permitted in exactly one other.
    ///
    /// Store, compare-and-append, matcher and the frozen close/reverify
    /// function names stay forbidden everywhere but the storage primitive —
    /// except the one approved writer, `Persistence/EndedMonthCheckpointWriter.swift`,
    /// which may contain the store call and nothing else from that list.
    ///
    /// `PeriodCheckpointRevision(` remains permitted only in
    /// `Persistence/CheckpointClosePolicy.swift`. The writer consumes a
    /// materialized candidate; it does not construct one. The exceptions are
    /// named files, not a relaxed directory.
    @Test("No production path stores a checkpoint, closes a period, or runs the matcher")
    func theSliceStartsNoWritePath() throws {
        let neverInProduction = [
            "compareAndAppend",
            "rehydratingStoredSnapshot",
            "PeriodCheckpointAcknowledgmentMatcher", "carryForwardCandidates",
            "func closePeriod", "func closeMonth", "func reverify",
            "func acknowledgeAndClose",
        ]
        let constructionOnlyInThePolicy = ["PeriodCheckpointRevision("]

        let storagePrimitive = "Persistence/PeriodCheckpointRepository.swift"
        let approvedStoreCaller = "Persistence/EndedMonthCheckpointWriter.swift"
        let policyBoundary = "Persistence/CheckpointClosePolicy.swift"

        var offenders: [String] = []
        for file in try Self.swiftSources(under: [
            "App", "Components", "Features", "Surface", "Attention", "Persistence"
        ]) where file.path != storagePrimitive {
            let code = try Self.code(file.path)
            for forbidden in neverInProduction where code.contains(forbidden) {
                offenders.append("\(file.path): \(forbidden)")
            }
            guard file.path != policyBoundary else { continue }
            for forbidden in constructionOnlyInThePolicy where code.contains(forbidden) {
                offenders.append("\(file.path): \(forbidden)")
            }
        }
        #expect(offenders.isEmpty, "the slice opened a write or matcher path: \(offenders)")
        // The single-authorized-writer guard itself lives once, in
        // EndedMonthCheckpointWriteTests ("W22"); this case owns the scan above.
        let writer = try Self.code(approvedStoreCaller)
        #expect(writer.contains("repository.store("))
        #expect(!writer.contains("PeriodCheckpointRevision("))

        // The construction exception is real, not a spelling that quietly
        // matches nothing: the policy file exists and does construct a
        // revision. If it stops doing so, the exception must go with it.
        #expect(try Self.code(policyBoundary).contains("PeriodCheckpointRevision("))
    }

    // MARK: - Reading the product's own source

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)   // …/FinanceAppTests/EndedMonthAcknowledgmentTests.swift
            .deletingLastPathComponent()  // …/FinanceAppTests
            .deletingLastPathComponent()  // …/finance-app
            .appendingPathComponent("FinanceApp")
    }

    /// Source with its line comments removed. These audits ask what the code
    /// *does*; the files involved explain at length what they deliberately do
    /// not do, and matching that prose would make the explanation the offence.
    private static func code(_ relativePath: String) throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    private static func swiftSources(under layers: [String]) throws -> [(path: String, text: String)] {
        let manager = FileManager.default
        var found: [(String, String)] = []
        for layer in layers {
            let directory = sourceRoot.appendingPathComponent(layer)
            guard let enumerator = manager.enumerator(atPath: directory.path) else { continue }
            for case let relative as String in enumerator where relative.hasSuffix(".swift") {
                found.append((
                    "\(layer)/\(relative)",
                    try String(
                        contentsOf: directory.appendingPathComponent(relative), encoding: .utf8
                    )
                ))
            }
        }
        return found
    }

    // MARK: - A store-backed month

    /// A store whose August is covered by an authoritative provider window, so
    /// the month's readiness turns on the exception it carries rather than on
    /// records nobody established.
    private static func coveredStore() throws -> (FinanceStore, ModelContainer) {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        var metadata = AppPersistenceMetadata.empty
        metadata.authoritativeLiveCoverage = [
            "synthetic-remote": AuthoritativeLiveCoverage(
                provider: .bnp,
                remoteOpaqueAccountID: "synthetic-remote",
                localAccountID: "bank",
                syncedFrom: Day(year: 2026, month: 8, day: 1),
                syncedThrough: Day(year: 2026, month: 9, day: 3),
                authoritativeAt: Date(timeIntervalSince1970: 1_788_000_000)
            )
        ]
        try StoredDocumentGraph.replace(
            with: storeDocument(), in: container.mainContext,
            writtenOn: Day(year: 2026, month: 9, day: 3),
            appMetadata: metadata
        )
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 9, day: 3))
        )
        return (store, container)
    }

    // MARK: - A store-backed document

    /// One bank-bound, booked, unreviewed August observation: the shape that
    /// produces a real checkpoint exception through the production adapters.
    private static func storeDocument() -> FinanceDocument {
        let bank = Account(
            id: "bank", name: "Current", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 0
        )
        var document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [bank],
            balances: [
                AccountBalance(
                    accountID: "bank",
                    balance: Money(minorUnits: 44_747, currency: .eur),
                    asOf: Day(year: 2026, month: 8, day: 1)
                )
            ]
        )
        document.externalAccountBindings = [
            ExternalAccountBinding(
                id: "binding", provider: .bnp,
                remoteOpaqueAccountID: "synthetic-remote", localAccountID: "bank",
                syncStartBoundary: Day(year: 2026, month: 1, day: 1),
                createdAt: Date(timeIntervalSince1970: 0)
            )
        ]
        document.externalObservations = [
            ExternalObservation(
                id: "observation", bindingID: "binding", provider: .bnp,
                identity: .durable, status: .booked, creditDebitIndicator: .debit,
                amount: Money(minorUnits: -2_000, currency: .eur),
                bookingDate: Day(year: 2026, month: 8, day: 15),
                eligibleForEconomicActual: true,
                observedAt: Date(timeIntervalSince1970: 1_000)
            )
        ]
        // Unreviewed, and explicitly so: external evidence must always state a
        // resolution, and "nobody has decided" is a state rather than a gap.
        document.observationResolutions = [
            ExternalObservationResolution(observationID: "observation", state: .unreviewed)
        ]
        return document
    }
}
