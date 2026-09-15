import FinanceCore
import Foundation
import Testing
@testable import FinanceApp

/// A reserve gap is not money that is missing, and the app may not say it is.
///
/// `PlanningTotals.shortfall` read the first risk's magnitude and date whatever
/// kind that risk was. A reserve breach carries `reserve − projected pool` and
/// a day on which nothing goes wrong, so a person who was funded throughout was
/// told their balance was about to fall short. Every case here drives a real
/// document through the real engine and the real mapper.
///
/// All values and identities are synthetic.
@MainActor
@Suite("Shortfall semantics")
struct ShortfallSemanticsTests {

    private static let today = Day(year: 2026, month: 9, day: 3)

    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
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

    private func income(_ amount: String, onDay: Int) -> IncomeSource {
        IncomeSource(
            id: "salary", name: "Salary", amount: euro(amount),
            certainty: .guaranteed,
            schedule: .monthly(
                onDay: onDay,
                from: MonthKey(year: 2026, month: 9),
                through: MonthKey(year: 2026, month: 9)
            ),
            arrivesOnAccount: "current"
        )
    }

    private func store(
        balance: String,
        safetyFloor: String? = nil,
        obligations: [RecurringObligation],
        incomes: [IncomeSource] = []
    ) -> FinanceStore {
        let current = Account(
            id: "current", name: "Current", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 0
        )
        var planning = FinanceDocument.Planning(
            defaultScenario: .base,
            recurringObligations: obligations
        )
        planning.safetyFloor = safetyFloor.map(euro)
        var document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [current],
            balances: [
                AccountBalance(accountID: "current", balance: euro(balance), asOf: Self.today)
            ],
            planning: planning
        )
        document.incomeSources = incomes
        return FinanceStore(document: document, today: Self.today, scenario: .base)
    }

    /// The state that produced the false sentence.
    ///
    /// 300,00 € on the account against a 450,00 € reserve, so the run is under
    /// the reserve from its first day. 400,00 € of rent falls inside the
    /// 30-day committed window, which is more than the 300,00 € available, so
    /// Safe to Use is legitimately constrained. 500,00 € of guaranteed salary
    /// lands first, so the pool never goes near zero.
    ///
    /// Headroom deficit 100,00 €; reserve gap 150,00 €. Two different numbers,
    /// which is what makes the confusion visible.
    private func fundedButUnderReserve() -> FinanceStore {
        store(
            balance: "300.00", safetyFloor: "450.00",
            obligations: [obligation("rent", "400.00", onDay: 10)],
            incomes: [income("500.00", onDay: 5)]
        )
    }

    // MARK: - The bug, reproduced and fixed

    @Test("The reproduction state is what it claims: funded throughout, under the reserve")
    func theReproductionStateIsFundedThroughout() throws {
        let snapshot = fundedButUnderReserve().snapshot
        let risk = try #require(snapshot.firstRisk)

        // Safe to Use is genuinely constrained, which is what opens the
        // shortfall sentence at all.
        #expect(snapshot.accountCash == Amount.eur(300))
        #expect(snapshot.committedOutflows == Amount.eur(400))
        #expect(snapshot.safeToSpendReason == .shortfall(.eur(100)))
        #expect(snapshot.safeToSpendReason.isShortfall)

        // And the projection never goes short anywhere in the horizon.
        #expect(risk.kind == .reserveWarning)
        #expect(risk.date == CalendarDay(year: 2026, month: 9, day: 3))
        #expect(risk.projectedBalance == Amount.eur(300))
        #expect(snapshot.lowestPoint.projectedBalance.isPositive)
        #expect(snapshot.cashRunway.isClear)
        #expect(snapshot.minimumBridgeRequired == Amount.eur(0))

        // The two magnitudes differ, so neither can be mistaken for the other
        // by coincidence.
        #expect(risk.riskAmount == Amount.eur(150))
        #expect(risk.reserveGap == Amount.eur(150))
        #expect(risk.fundingDeficit == nil)
    }

    @Test("A funded plan under its reserve is never given a day it falls short")
    func noBorrowedDeficitDay() throws {
        let snapshot = fundedButUnderReserve().snapshot
        let statement = try #require(PlanningTotals.shortfall(from: snapshot))

        // Was: .dated(amount: 150,00 €, date: 3 September) — the reserve gap,
        // on a day the balance was 300,00 € and falling short of nothing.
        #expect(statement.date == nil)
        #expect(statement == .undated(amount: .eur(100), withinDays: 30))
        // The amount is the committed-outflow headroom deficit, which is money
        // genuinely not there. It is not the reserve gap.
        #expect(statement.amount == Amount.eur(100))
        #expect(statement.amount != snapshot.firstRisk?.riskAmount)
    }

    @Test("The Safe to Use screen states no day and claims no dated shortfall")
    func theScreenNoLongerSaysItFallsShort() throws {
        let store = fundedButUnderReserve()
        guard case let .explained(breakdown) = SafeToUseExplanation.make(
            from: store.snapshot, isAvailable: store.safeToUseIsAvailable
        ) else {
            Issue.record("expected Safe to Use to explain itself")
            return
        }

        // The true half survives: committed payments really do outrun the
        // money on the accounts inside the window.
        #expect(breakdown.summary.contains("Committed payments come to more than the money on your accounts"))
        // The false half is gone. No day, and no claim about falling short on
        // one — the projection never falls short at all.
        #expect(!breakdown.summary.contains("first projected to fall short"))
        #expect(!breakdown.summary.contains("September"))
        // And no reserve figure leaked into a screen that is not about it.
        #expect(!breakdown.summary.contains("150"))
    }

    // MARK: - A genuine deficit still says everything it used to

    @Test("A real deficit still names its amount and its day")
    func genuineDeficitIsUnchanged() throws {
        // No reserve at all, so the only risk that can arise is a deficit.
        let store = store(
            balance: "50.00", obligations: [obligation("rent", "300.00", onDay: 6)]
        )
        let snapshot = store.snapshot
        let risk = try #require(snapshot.firstRisk)
        let statement = try #require(PlanningTotals.shortfall(from: snapshot))

        #expect(risk.kind == .hardDeficit)
        #expect(risk.fundingDeficit == risk.riskAmount)
        #expect(risk.reserveGap == nil)
        #expect(statement == .dated(amount: try #require(risk.fundingDeficit), date: risk.date))
        #expect(statement.date == CalendarDay(year: 2026, month: 9, day: 6))

        guard case let .explained(breakdown) = SafeToUseExplanation.make(
            from: snapshot, isAvailable: store.safeToUseIsAvailable
        ) else {
            Issue.record("expected Safe to Use to explain itself")
            return
        }
        #expect(breakdown.summary.contains("first projected to fall short"))
    }

    @Test("A reserve breach before a later deficit does not promote the deficit")
    func theLaterDeficitIsNotPromoted() throws {
        // Under the reserve from day one; genuinely short on the 20th. The
        // engine's first risk is the earliest, and the app does not reach past
        // it for the more severe state to fill a sentence.
        let store = store(
            balance: "300.00", safetyFloor: "450.00",
            obligations: [obligation("rent", "400.00", onDay: 20)]
        )
        let snapshot = store.snapshot
        let risk = try #require(snapshot.firstRisk)

        #expect(risk.kind == .reserveWarning)
        #expect(risk.date == CalendarDay(year: 2026, month: 9, day: 3))
        #expect(snapshot.lowestPoint.projectedBalance == Amount.eur(-100))

        let statement = try #require(PlanningTotals.shortfall(from: snapshot))
        #expect(statement.date == nil)
        #expect(statement == .undated(amount: .eur(100), withinDays: 30))
    }

    @Test("A deficit and a reserve breach on one day keep the engine's precedence")
    func sameDayDeficitWins() throws {
        // 100,00 € against a 450,00 € reserve and a 300,00 € payment: the same
        // day crosses both lines, and the engine prefers the deficit.
        let store = store(
            balance: "100.00", safetyFloor: "450.00",
            obligations: [obligation("rent", "300.00", onDay: 6)]
        )
        let snapshot = store.snapshot
        let risk = try #require(snapshot.firstRisk)

        // The run is already under the reserve on day one, so that is the
        // earliest risk and it stays the reported one.
        #expect(risk.date == CalendarDay(year: 2026, month: 9, day: 3))
        #expect(risk.kind == .reserveWarning)
        #expect(PlanningTotals.shortfall(from: snapshot)?.date == nil)

        // With the reserve set below the opening balance, the two lines are
        // crossed together on the 6th and the deficit is what is reported.
        let tighter = self.store(
            balance: "100.00", safetyFloor: "50.00",
            obligations: [obligation("rent", "300.00", onDay: 6)]
        )
        let sameDay = try #require(tighter.snapshot.firstRisk)
        #expect(sameDay.date == CalendarDay(year: 2026, month: 9, day: 6))
        #expect(sameDay.kind == .hardDeficit)
        #expect(sameDay.fundingDeficit == Amount.eur(200))
        #expect(PlanningTotals.shortfall(from: tighter.snapshot)?.date == sameDay.date)
    }

    // MARK: - The two amounts cannot be swapped

    @Test("Funding deficit and reserve gap are mutually exclusive, always")
    func theTwoReadersNeverBothAnswer() throws {
        for store in [
            fundedButUnderReserve(),
            store(balance: "50.00", obligations: [obligation("rent", "300.00", onDay: 6)]),
            store(
                balance: "500.00", safetyFloor: "400.00",
                obligations: [obligation("gym", "150.00", onDay: 6)]
            ),
        ] {
            guard let risk = store.snapshot.firstRisk else { continue }
            let deficit = risk.fundingDeficit
            let gap = risk.reserveGap
            #expect(!(deficit != nil && gap != nil), "one risk answered as both")
            #expect(deficit != nil || gap != nil, "a classified risk answered as neither")
            #expect(deficit ?? gap == risk.riskAmount)
        }
    }

    @Test("An unclassified risk supplies neither amount and no day")
    func unclassifiedRiskSuppliesNothing() {
        var snapshot = FinanceAppSnapshot.empty(
            asOf: CalendarDay(year: 2026, month: 9, day: 3)
        )
        snapshot.safeToSpendReason = .shortfall(.eur(100))
        snapshot.safeToSpendWindowDays = 30
        snapshot.firstRisk = RiskPoint(
            date: CalendarDay(year: 2026, month: 9, day: 6),
            projectedBalance: .eur(300),
            triggerLabel: "Rent", triggerAmount: .eur(400),
            kind: nil, riskAmount: .eur(150)
        )

        let risk = snapshot.firstRisk
        #expect(risk?.fundingDeficit == nil)
        #expect(risk?.reserveGap == nil)
        // Unknown does not become a deficit to fill a sentence with.
        #expect(PlanningTotals.shortfall(from: snapshot) == .undated(amount: .eur(100), withinDays: 30))
    }

    @Test("No risk at all still says nothing")
    func noRiskNoStatement() {
        var snapshot = FinanceAppSnapshot.empty(
            asOf: CalendarDay(year: 2026, month: 9, day: 3)
        )
        #expect(PlanningTotals.shortfall(from: snapshot) == nil)
        // Constrained, with no risk day anywhere: the window's own sentence.
        snapshot.safeToSpendReason = .shortfall(.eur(80))
        snapshot.safeToSpendWindowDays = 30
        #expect(PlanningTotals.shortfall(from: snapshot) == .undated(amount: .eur(80), withinDays: 30))
    }

    // MARK: - Nothing else moved

    @Test("Safe to Use keeps its figure and its arithmetic")
    func safeToUseIsUntouched() throws {
        let store = fundedButUnderReserve()
        let snapshot = store.snapshot

        #expect(snapshot.safeToSpend == Amount.eur(0))
        guard case let .explained(breakdown) = SafeToUseExplanation.make(
            from: snapshot, isAvailable: store.safeToUseIsAvailable
        ) else {
            Issue.record("expected a breakdown")
            return
        }
        // 300 − 400 = −100, clamped to 0. Unchanged by this slice.
        #expect(breakdown.cash == Amount.eur(300))
        #expect(breakdown.committed == Amount.eur(400))
        #expect(breakdown.headroom == Amount.eur(-100))
        #expect(breakdown.safeToUse == Amount.eur(0))
        #expect(breakdown.resultLabel == "Short by")
        #expect(breakdown.resultValue == Amount.eur(100))
        #expect(breakdown.isShort)
    }

    @Test("Home attention and the week's row keep the behaviour they shipped with")
    func neighbouringSurfacesAreUnchanged() throws {
        let store = fundedButUnderReserve()

        // The reserve breach is still named as a reserve breach, by the card
        // that owns that figure.
        guard case let .act(card, _) = store.currentPresentation().attention.home else {
            Issue.record("expected the funding candidate to stay primary")
            return
        }
        #expect(card.title.lowercased().contains("below your"))
        #expect(card.title.lowercased().contains("safety reserve"))
        #expect(!card.title.lowercased().contains("funding gap"))

        // The week's row reads the kind, not an amount, and today is the low.
        let summary = try #require(
            WeekAheadSummary.make(from: store.snapshot, isAvailable: store.safeToUseIsAvailable)
        )
        #expect(summary.day == CalendarDay(year: 2026, month: 9, day: 3))
        #expect(summary.notes.contains(.belowReserveOnThisDay))
        #expect(!summary.notes.contains(.shortfallOnThisDay))
    }

    @Test("The shortfall sentence is built from a classified deficit, not a raw magnitude")
    func theConsumerAsksForWhatItMeans() throws {
        let surface = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FinanceApp/Surface")
        let totals = try String(
            contentsOf: surface.appendingPathComponent("PlanningTotals.swift"),
            encoding: .utf8
        )
        #expect(totals.contains("risk.fundingDeficit"))
        // The generic magnitude may not be read where a funding claim is made,
        // and no sign test may stand in for the engine's classification.
        #expect(!totals.contains("riskAmount"))
        #expect(!totals.contains("projectedBalance.isNegative"))
    }
}
