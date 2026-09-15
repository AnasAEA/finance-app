import Foundation
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

/// The safety reserve is a planning floor the person can see and change.
///
/// The amount is `document.planning.safetyFloor`. The forecast already uses it.
/// These tests pin the product boundary: mapping, mutation, persistence,
/// recomputation, and the things a reserve change is not allowed to rewrite.
///
/// All values and identities are synthetic.
@MainActor
@Suite("Safety reserve")
struct SafetyReserveTests {

    private static let today = Day(year: 2026, month: 9, day: 3)
    private static let civilToday = CalendarDay(year: 2026, month: 9, day: 3)
    private static var todayDate: Date { fixtureInstant(today) }

    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    private func account() -> Account {
        Account(
            id: "current", name: "Current", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 0
        )
    }

    private func obligation(_ id: String, _ amount: String, onDay: Int) -> RecurringObligation {
        RecurringObligation(
            id: id, name: id.capitalized, amount: euro(amount),
            spec: .monthly(
                onDay: onDay,
                from: MonthKey(year: 2026, month: 9),
                through: MonthKey(year: 2026, month: 9)
            ),
            requirement: .euroBankPayment(),
            spendingClass: .essential
        )
    }

    private func document(
        balance: String,
        safetyFloor: String? = nil,
        obligations: [RecurringObligation] = [],
        transactions: [Transaction] = [],
        schemaVersion: String = Interchange.currentSchemaVersion
    ) -> FinanceDocument {
        var planning = FinanceDocument.Planning(
            defaultScenario: .base,
            recurringObligations: obligations
        )
        planning.safetyFloor = safetyFloor.map(euro)
        return FinanceDocument(
            schemaVersion: schemaVersion,
            documentKind: "TEST",
            accounts: [account()],
            balances: [
                AccountBalance(accountID: "current", balance: euro(balance), asOf: Self.today)
            ],
            transactions: transactions,
            planning: planning
        )
    }

    private func liveStore(
        balance: String,
        safetyFloor: String? = nil,
        obligations: [RecurringObligation] = [],
        transactions: [Transaction] = []
    ) -> FinanceStore {
        FinanceStore(
            document: document(
                balance: balance,
                safetyFloor: safetyFloor,
                obligations: obligations,
                transactions: transactions
            ),
            today: Self.today,
            scenario: .base
        )
    }

    @MainActor
    private struct Harness {
        let container: ModelContainer
        let store: FinanceStore

        func reopened() throws -> FinanceStore {
            try FinanceStore(context: container.mainContext, now: SafetyReserveTests.todayDate)
        }
    }

    private func harness(_ document: FinanceDocument) throws -> Harness {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = try FinanceStore(context: container.mainContext, now: Self.todayDate)
        try store.importDocument(document)
        return Harness(container: container, store: store)
    }

    // MARK: - Mapping

    @Test("A configured reserve maps onto the snapshot")
    func configuredReserveMaps() {
        let store = liveStore(balance: "500.00", safetyFloor: "400.00")
        #expect(store.snapshot.safetyReserve == Amount.eur(400))
        #expect(store.snapshot.firstBelowReserveDate == nil)
    }

    @Test("No reserve maps as none")
    func missingReserveMapsAsNone() {
        let store = liveStore(balance: "500.00")
        #expect(store.snapshot.safetyReserve == nil)
        #expect(store.snapshot.firstBelowReserveDate == nil)
        #expect(SafetyReserveExplanation.make(
            from: store.snapshot, isAvailable: store.safeToUseIsAvailable
        ) == .none)
    }

    @Test("Zero is a configured reserve, not the absence of one")
    func zeroReserveIsConfigured() throws {
        let store = liveStore(balance: "500.00", safetyFloor: "0.00")
        #expect(store.snapshot.safetyReserve == .zeroEUR)
        let explanation = SafetyReserveExplanation.make(
            from: store.snapshot, isAvailable: store.safeToUseIsAvailable
        )
        guard case let .configured(breakdown) = explanation else {
            Issue.record("zero reserve must be configured, not none")
            return
        }
        #expect(breakdown.amount.isZero)
        guard case let .staysAbove(lowest, headroom) = breakdown.comparison else {
            Issue.record("a solvent run against a zero floor stays above it")
            return
        }
        #expect(lowest == Amount.eur(500))
        #expect(headroom == Amount.eur(500))
    }

    @Test("A reserve breach carries the first below-floor day")
    func breachMapsTheDate() throws {
        let store = liveStore(
            balance: "500.00", safetyFloor: "400.00",
            obligations: [obligation("gym", "150.00", onDay: 6)]
        )
        #expect(store.snapshot.safetyReserve == Amount.eur(400))
        #expect(store.snapshot.firstBelowReserveDate == CalendarDay(year: 2026, month: 9, day: 6))
        #expect(store.snapshot.firstRisk?.kind == .reserveWarning)
        #expect(store.snapshot.lowestPoint.projectedBalance == Amount.eur(350))

        let explanation = SafetyReserveExplanation.make(
            from: store.snapshot, isAvailable: true
        )
        guard case let .configured(breakdown) = explanation,
              case let .dipsBelow(lowest, gap, firstDate) = breakdown.comparison else {
            Issue.record("expected a below-reserve comparison, got \(explanation)")
            return
        }
        #expect(lowest == Amount.eur(350))
        #expect(gap == Amount.eur(50))
        #expect(firstDate == CalendarDay(year: 2026, month: 9, day: 6))
        #expect(breakdown.summary.contains("50"))
        #expect(!breakdown.summary.lowercased().contains("above"))
    }

    @Test("Projected cash above the reserve reports headroom, not a gap")
    func aboveReserveIsNotAGap() {
        let comparison = SafetyReserveExplanation.comparison(
            amount: .eur(400),
            lowest: .eur(520),
            firstBelowDate: nil,
            isAvailable: true
        )
        #expect(comparison == .staysAbove(lowest: .eur(520), headroom: .eur(120)))
        #expect(comparison != .dipsBelow(lowest: .eur(520), gap: .eur(120), firstDate: nil))
    }

    @Test("A mixed-currency pair produces no comparison")
    func mixedCurrencyIsUnavailable() {
        let comparison = SafetyReserveExplanation.comparison(
            amount: .eur(400),
            lowest: Amount(minorUnits: 52_000, currencyCode: "MAD"),
            firstBelowDate: Self.civilToday,
            isAvailable: true
        )
        #expect(comparison == .unavailable)
    }

    @Test("An unavailable projection does not fabricate a comparison")
    func unavailableProjectionFabricatesNothing() {
        let comparison = SafetyReserveExplanation.comparison(
            amount: .eur(400),
            lowest: .eur(520),
            firstBelowDate: Self.civilToday,
            isAvailable: false
        )
        #expect(comparison == .unavailable)

        var snapshot = FinanceAppSnapshot.empty(asOf: Self.civilToday)
        snapshot.safetyReserve = .eur(400)
        snapshot.lowestPoint = RiskPoint(
            date: Self.civilToday, projectedBalance: .eur(520),
            triggerLabel: nil, triggerAmount: nil, kind: nil, riskAmount: nil
        )
        let explanation = SafetyReserveExplanation.make(from: snapshot, isAvailable: false)
        guard case let .configured(breakdown) = explanation else {
            Issue.record("the configured amount still shows when the projection does not")
            return
        }
        #expect(breakdown.amount == .eur(400))
        #expect(breakdown.comparison == .unavailable)
        #expect(breakdown.summary.contains("won't guess"))
    }

    // MARK: - Mutation

    @Test("Negative input is refused and writes nothing")
    func negativeInputIsRefused() throws {
        let store = liveStore(balance: "500.00", safetyFloor: "400.00")
        #expect(throws: AppManagementError.invalidSafetyReserve) {
            try store.setSafetyReserve(Amount.eur(-1))
        }
        #expect(throws: Amount.ParseFailure.notANumber) {
            try Amount.parse("-10", currencyCode: "EUR", fractionDigits: 2)
        }
        #expect(store.snapshot.safetyReserve == Amount.eur(400))
        #expect(try store.exportDocument().planning.safetyFloor == euro("400.00"))
    }

    @Test("A non-euro amount is refused")
    func nonEuroIsRefused() throws {
        let store = liveStore(balance: "500.00", safetyFloor: "400.00")
        #expect(throws: AppManagementError.invalidSafetyReserve) {
            try store.setSafetyReserve(Amount(minorUnits: 40_000, currencyCode: "MAD"))
        }
        #expect(store.snapshot.safetyReserve == Amount.eur(400))
    }

    @Test("Zero can be set explicitly")
    func zeroCanBeSet() throws {
        let store = liveStore(balance: "500.00", safetyFloor: "400.00")
        try store.setSafetyReserve(.zeroEUR)
        #expect(store.snapshot.safetyReserve == .zeroEUR)
        #expect(try store.exportDocument().planning.safetyFloor == euro("0.00"))
    }

    @Test("Clearing the reserve is distinct from setting zero")
    func clearingIsNotZero() throws {
        let store = liveStore(balance: "500.00", safetyFloor: "400.00")
        try store.setSafetyReserve(nil)
        #expect(store.snapshot.safetyReserve == nil)
        #expect(try store.exportDocument().planning.safetyFloor == nil)
    }

    @Test("Updating the reserve persists and survives a reopen")
    func updatePersists() throws {
        let harness = try harness(document(balance: "500.00", safetyFloor: "80.00"))
        try harness.store.setSafetyReserve(.eur(400))
        #expect(harness.store.snapshot.safetyReserve == Amount.eur(400))
        #expect(try harness.store.exportDocument().planning.safetyFloor == euro("400.00"))

        let reopened = try harness.reopened()
        #expect(reopened.snapshot.safetyReserve == Amount.eur(400))
        #expect(try reopened.exportDocument().planning.safetyFloor == euro("400.00"))
    }

    @Test("The mutation writes against current store state, not a UI copy")
    func writeUsesCurrentStoreState() throws {
        let harness = try harness(document(balance: "500.00", safetyFloor: "80.00"))
        try harness.store.setSafetyReserve(.eur(400))
        try harness.store.setSafetyReserve(.eur(200))
        #expect(harness.store.snapshot.safetyReserve == Amount.eur(200))
        #expect(try harness.reopened().snapshot.safetyReserve == Amount.eur(200))
    }

    @Test("Changing the reserve leaves transactions, balances and history alone")
    func updateLeavesEconomicsUnchanged() throws {
        let spent = Transaction(
            id: "tx-food", date: Self.today, kind: .expense,
            legs: [AccountLeg(accountID: "current", amount: euro("-12.00"))],
            factivity: .observed
        )
        let harness = try harness(
            document(
                balance: "500.00", safetyFloor: "80.00",
                transactions: [spent]
            )
        )
        let before = try harness.store.exportDocument()
        try harness.store.setSafetyReserve(.eur(400))
        let after = try harness.store.exportDocument()

        #expect(after.transactions == before.transactions)
        #expect(after.balances == before.balances)
        #expect(after.expectedTransactions == before.expectedTransactions)
        #expect(after.planning.plannedPurchases == before.planning.plannedPurchases)
        #expect(after.planning.sinkingFunds == before.planning.sinkingFunds)
        #expect(after.planning.budgets == before.planning.budgets)
        #expect(after.planning.recurringObligations == before.planning.recurringObligations)
        #expect(after.planning.safetyFloor == euro("400.00"))
        #expect(after.planning.safetyFloor != before.planning.safetyFloor)
    }

    @Test("Setting the reserve does not bump the schema")
    func reserveChangeDoesNotMigrate() throws {
        let harness = try harness(document(balance: "500.00"))
        let before = try harness.store.exportDocument().schemaVersion
        try harness.store.setSafetyReserve(.eur(400))
        #expect(try harness.store.exportDocument().schemaVersion == before)
    }

    // MARK: - Recomputation

    @Test("Raising the reserve can create a reserve warning without a funding deficit")
    func raisingReserveCreatesAWarningNotADeficit() throws {
        let store = liveStore(
            balance: "500.00",
            obligations: [obligation("gym", "150.00", onDay: 6)]
        )
        let safeBefore = store.snapshot.safeToSpend
        #expect(store.snapshot.firstRisk == nil)

        try store.setSafetyReserve(.eur(400))

        let risk = try #require(store.snapshot.firstRisk)
        #expect(risk.kind == .reserveWarning)
        #expect(risk.kind != .hardDeficit)
        #expect(risk.date == CalendarDay(year: 2026, month: 9, day: 6))
        #expect(store.snapshot.lowestPoint.projectedBalance == Amount.eur(350))
        #expect(store.snapshot.safeToSpend == safeBefore)

        guard case let .act(card, _) = store.currentPresentation().attention.home else {
            Issue.record("expected the reserve warning to become Home attention")
            return
        }
        #expect(card.title.lowercased().contains("below your"))
        #expect(card.title.lowercased().contains("safety reserve"))
        #expect(!card.title.lowercased().contains("funding gap"))
        #expect(!card.title.lowercased().contains("needed"))
    }

    @Test("Lowering the reserve can clear a reserve warning")
    func loweringReserveClearsTheWarning() throws {
        let store = liveStore(
            balance: "500.00", safetyFloor: "400.00",
            obligations: [obligation("gym", "150.00", onDay: 6)]
        )
        #expect(store.snapshot.firstRisk?.kind == .reserveWarning)

        try store.setSafetyReserve(.eur(100))
        #expect(store.snapshot.firstRisk == nil)
        #expect(store.snapshot.firstBelowReserveDate == nil)

        if case .act(let card, _) = store.currentPresentation().attention.home {
            #expect(!card.title.lowercased().contains("safety reserve"))
        }
    }

    @Test("A genuine deficit stays a hard deficit regardless of the reserve")
    func deficitStaysADeficit() throws {
        // Opening 100, a 50 reserve, 300 leaving on day 6: both lines are
        // crossed by the same payment. Earliest-day-wins still prefers the
        // deficit on a tie, and presenting the reserve must not relabel it.
        let store = liveStore(
            balance: "100.00",
            obligations: [obligation("rent", "300.00", onDay: 6)]
        )
        #expect(store.snapshot.firstRisk?.kind == .hardDeficit)
        let safeBefore = store.snapshot.safeToSpend

        try store.setSafetyReserve(.eur(50))
        #expect(store.snapshot.firstRisk?.kind == .hardDeficit)
        #expect(store.snapshot.firstRisk?.kind != .reserveWarning)
        #expect(store.snapshot.safeToSpend == safeBefore)

        guard case let .act(card, _) = store.currentPresentation().attention.home else {
            Issue.record("expected the deficit card to remain")
            return
        }
        #expect(card.title.lowercased().contains("gap") || card.title.lowercased().contains("needs") || card.title.lowercased().contains("needed"))
        #expect(!card.title.lowercased().contains("safety reserve"))
    }

    @Test("Safe to Use does not subtract the reserve")
    func safeToUseIgnoresTheReserve() throws {
        let store = liveStore(
            balance: "500.00",
            obligations: [obligation("gym", "150.00", onDay: 6)]
        )
        let before = store.snapshot.safeToSpend
        let committed = store.snapshot.committedOutflows
        try store.setSafetyReserve(.eur(400))
        #expect(store.snapshot.safeToSpend == before)
        #expect(store.snapshot.committedOutflows == committed)

        let explanation = SafeToUseExplanation.make(
            from: store.snapshot, isAvailable: store.safeToUseIsAvailable
        )
        guard case let .explained(breakdown) = explanation else {
            Issue.record("the headline must still be explainable after a reserve change")
            return
        }
        #expect(breakdown.cash == store.snapshot.accountCash)
        #expect(breakdown.committed == committed)
        #expect(breakdown.safeToUse == before)
    }

    @Test("Affordability cash figures stay the same; a new floor is a warning, not a deficit")
    func affordabilityFormulasAreUnchanged() throws {
        let store = liveStore(balance: "500.00")
        var draft = store.makeAffordabilityDraft()
        draft.amountText = "150"
        draft.on = DomainMapper.civilDay(Day(year: 2026, month: 9, day: 6))
        draft.accountID = "current"

        let before = try store.evaluateAffordability(draft)
        try store.setSafetyReserve(.eur(400))
        let after = try store.evaluateAffordability(draft)

        #expect(after.ledgerCash == before.ledgerCash)
        #expect(after.unreservedCash == before.unreservedCash)
        #expect(after.purchaseEconomic == before.purchaseEconomic)
        #expect(after.firstRiskKind == .reserveWarning)
        #expect(after.firstRiskKind != .hardDeficit)
        #expect(after.overall != .notAffordable)
        #expect(after.why.contains(where: { $0.contains("safety reserve") }))
        #expect(!after.why.contains(where: { $0.lowercased().contains("short of cash") }))
    }

    // MARK: - Import / export

    @Test("A backup round-trip preserves the reserve")
    func backupRoundTripPreservesTheReserve() throws {
        let harness = try harness(document(balance: "500.00", safetyFloor: "400.00"))
        let backup = try harness.store.exportBackup()

        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let restored = try FinanceStore(context: container.mainContext, now: Self.todayDate)
        _ = try restored.prepareImport(from: backup.data)
        _ = try restored.confirmImport()
        #expect(restored.snapshot.safetyReserve == Amount.eur(400))
        #expect(try restored.exportDocument().planning.safetyFloor == euro("400.00"))
    }

    // MARK: - Week ahead freeze

    @Test("Week ahead still does not subtract the reserve from the week's low")
    func weekAheadDoesNotInventAComparison() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("FinanceApp/Surface/WeekAhead.swift"),
            encoding: .utf8
        )
        #expect(!source.contains("safetyReserve"))
        #expect(!source.contains("firstBelowReserveDate"))
        #expect(!source.contains("headroom"))
    }

    // MARK: - Identifiers and copy

    @Test("The reserve screen has stable identifiers and does not expose engine names")
    func identifiersAndCopy() {
        #expect(RouteID.planReserve == "plan.reserve")
        #expect(PlanningControlID.reserveAmount == "reserve.amount")
        #expect(PlanningControlID.reserveSave == "reserve.save")
        #expect(Set(SafetyReserveID.all).count == SafetyReserveID.all.count)
        #expect(SafetyReserveID.all.allSatisfy { $0.hasPrefix("reserve.") })
        #expect(SafetyReserveBreakdown.meaning.contains("buffer"))
        #expect(!SafetyReserveBreakdown.meaning.contains("safetyFloor"))
        #expect(!SafetyReserveBreakdown.distinction.contains("belowSafetyFloor"))
        #expect(SafetyReserveBreakdown.distinction.contains("not Safe to Use"))
    }
}
