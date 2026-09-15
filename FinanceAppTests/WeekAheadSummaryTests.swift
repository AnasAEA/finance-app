import FinanceCore
import Foundation
import Testing
@testable import FinanceApp

/// What the week does to projected cash, and what the projection is not
/// allowed to claim while saying it.
///
/// The store tests run a real document through the real engine and the real
/// mapper, so the minimum they pin is a minimum over values the forecast
/// actually produced. The snapshot tests then drive the selection rule and
/// every refusal directly, which is the only way to reach a mixed-currency or
/// out-of-order series that the engine cannot itself emit.
///
/// All values and identities are synthetic.
@MainActor
@Suite("Week ahead summary")
struct WeekAheadSummaryTests {

    private static let today = Day(year: 2026, month: 9, day: 3)
    private static let civilToday = CalendarDay(year: 2026, month: 9, day: 3)

    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    // MARK: - Fixtures

    private func account(
        _ id: String = "current",
        kind: AccountKind = .bank,
        currency: Currency = .eur,
        order: Int = 0
    ) -> Account {
        Account(
            id: id, name: id.capitalized, currency: currency, kind: kind,
            supportedRails: currency == .eur && kind != .cash
                ? PaymentRail.euroBankRails
                : [PaymentRail.physicalCash],
            drawOrder: order
        )
    }

    /// A one-off obligation on an exact day, so the window's shape is chosen
    /// by the test rather than by a recurrence rule.
    private func obligation(_ id: String, _ amount: String, onDay: Int) -> RecurringObligation {
        RecurringObligation(
            id: id, name: id, amount: euro(amount),
            spec: .monthly(
                onDay: onDay,
                from: MonthKey(year: 2026, month: 9),
                through: MonthKey(year: 2026, month: 9)
            ),
            requirement: .euroBankPayment(),
            spendingClass: .essential
        )
    }

    private func store(
        balance: String,
        obligations: [RecurringObligation]
    ) -> FinanceStore {
        let current = account()
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [current],
            balances: [
                AccountBalance(accountID: current.id, balance: euro(balance), asOf: Self.today)
            ],
            planning: FinanceDocument.Planning(
                defaultScenario: .base,
                recurringObligations: obligations
            )
        )
        return FinanceStore(document: document, today: Self.today, scenario: .base)
    }

    private func summary(
        _ store: FinanceStore,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> WeekAheadSummary {
        guard let summary = WeekAheadSummary.make(
            from: store.snapshot, isAvailable: store.safeToUseIsAvailable
        ) else {
            Issue.record("expected a weekly summary", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        return summary
    }

    // MARK: - W: the real engine, the real mapper

    @Test("The week's low is the lowest projected close inside the window")
    func normalTrajectory() throws {
        // 1 000 on the 3rd, 400 leaving on the 6th. Nothing else moves, so the
        // pool closes at 600 from the 6th to the end of the window.
        let summary = try summary(
            store(balance: "1000.00", obligations: [obligation("rent", "400.00", onDay: 6)])
        )
        #expect(summary.low == Amount.eur(600))
        #expect(summary.day == CalendarDay(year: 2026, month: 9, day: 6))
        // Today through today + 7, inclusive at both ends — the same window
        // the event list beside the row is built over.
        #expect(summary.windowStart == Self.civilToday)
        #expect(summary.windowEnd == CalendarDay(year: 2026, month: 9, day: 10))
        #expect(summary.dayCount == 8)
        #expect(summary.notes.isEmpty)
    }

    @Test("The low is the minimum of the week, not the last day of it")
    func minimumIsNotTheEndpoint() throws {
        // Down to 300 on the 5th, back up on the 8th: the week's answer is the
        // dip, not where it finishes.
        let current = account()
        var document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [current],
            balances: [
                AccountBalance(accountID: current.id, balance: euro("1000.00"), asOf: Self.today)
            ],
            planning: FinanceDocument.Planning(
                defaultScenario: .base,
                recurringObligations: [obligation("rent", "700.00", onDay: 5)]
            )
        )
        document.incomeSources = [
            IncomeSource(
                id: "salary", name: "Salary", amount: euro("900.00"),
                certainty: .guaranteed,
                schedule: .monthly(
                    onDay: 8,
                    from: MonthKey(year: 2026, month: 9),
                    through: MonthKey(year: 2026, month: 9)
                ),
                arrivesOnAccount: current.id
            )
        ]
        let store = FinanceStore(document: document, today: Self.today, scenario: .base)
        let summary = try summary(store)

        #expect(summary.low == Amount.eur(300))
        #expect(summary.day == CalendarDay(year: 2026, month: 9, day: 5))
        // Proof it really is a minimum and not a closing balance.
        #expect(summary.low < Amount.eur(1000))
        #expect(store.snapshot.runwayPoints.last?.balance != summary.low)
    }

    @Test("An obligation past the window does not set this week's low")
    func obligationBeyondTheWindowIsNotThisWeek() throws {
        let summary = try summary(
            store(balance: "1000.00", obligations: [obligation("rent", "400.00", onDay: 20)])
        )
        // Flat across the week: the low is the level it sits at, and the 20th
        // is somebody else's week.
        #expect(summary.low == Amount.eur(1000))
        #expect(summary.day == Self.civilToday)
        #expect(summary.notes.isEmpty)
    }

    @Test("A risk the plan already reports inside the window is restated, not re-derived")
    func riskInsideTheWindowIsRestated() throws {
        let store = store(
            balance: "50.00", obligations: [obligation("rent", "300.00", onDay: 5)]
        )
        let summary = try summary(store)

        #expect(summary.low == Amount.eur(-250))
        #expect(summary.day == CalendarDay(year: 2026, month: 9, day: 5))
        // The day is the engine's own first-risk day, and the note says only
        // that — no threshold of this feature's own, and no second amount.
        #expect(store.snapshot.firstRisk?.date == summary.day)
        #expect(summary.notes == [.planAlreadyFlagsThisDay])
        let sentence = WeekAheadNote.planAlreadyFlagsThisDay.sentence
        #expect(!sentence.contains("€"))
        #expect(!sentence.contains("rent"))
    }

    @Test("A risk beyond the window is not pulled into this week")
    func riskBeyondTheWindowIsNotClaimed() throws {
        let store = store(
            balance: "50.00", obligations: [obligation("rent", "300.00", onDay: 20)]
        )
        let summary = try summary(store)

        #expect(store.snapshot.firstRisk != nil)
        #expect(store.snapshot.firstRisk?.date == CalendarDay(year: 2026, month: 9, day: 20))
        #expect(summary.day == Self.civilToday)
        #expect(summary.notes.isEmpty)
    }

    @Test("Several payments on the low day are never attributed to one of them")
    func sameDayEventsGetNoSingleCause() throws {
        let store = store(
            balance: "1000.00",
            obligations: [
                obligation("rent", "300.00", onDay: 6),
                obligation("insurance", "120.00", onDay: 6),
                obligation("gym", "40.00", onDay: 6),
            ]
        )
        let summary = try summary(store)

        // One point, three payments folded into it. The point knows the total
        // and not the order, so nothing may name a cause.
        #expect(summary.low == Amount.eur(540))
        #expect(summary.day == CalendarDay(year: 2026, month: 9, day: 6))
        let said = summary.notes.map(\.sentence).joined(separator: " ")
        for name in ["rent", "insurance", "gym", "After", "because", "caused"] {
            #expect(!said.contains(name), "the week's low named \(name)")
        }
    }

    @Test("Reading the week changes no money and no stored state")
    func summaryIsAReadOnlyQuestion() throws {
        let store = store(
            balance: "1000.00", obligations: [obligation("rent", "400.00", onDay: 6)]
        )
        let before = store.snapshot
        _ = try summary(store)
        _ = WeekAheadSummary.make(from: store.snapshot, isAvailable: true)

        #expect(store.snapshot == before)
        #expect(store.snapshot.safeToSpend == before.safeToSpend)
        #expect(store.snapshot.committedOutflows == before.committedOutflows)
        #expect(store.snapshot.runwayPoints == before.runwayPoints)
    }

    @Test("The week's low is not Safe to Use and is not expected to reconcile with it")
    func projectedCashIsADifferentQuestionFromSafeToUse() throws {
        let store = store(
            balance: "1000.00", obligations: [obligation("rent", "400.00", onDay: 6)]
        )
        let summary = try summary(store)
        let snapshot = store.snapshot

        // Safe to Use answers what can be used now, over its own 30-day
        // window, clamped at zero. The week's low answers where the balance
        // goes. Both are true here and they are different numbers.
        #expect(snapshot.safeToSpend == Amount.eur(600))
        #expect(summary.low == Amount.eur(600))
        // Same figure only because this fixture is that simple — nothing in
        // the summary is derived from Safe to Use, and the row carries no
        // component of it.
        #expect(WeekAheadSummary.title == "Lowest projected cash")
        #expect(!WeekAheadSummary.title.lowercased().contains("safe"))
    }

    // MARK: - P: the selection rule and every refusal

    private func point(_ day: Int, _ major: Decimal) -> RunwayPoint {
        RunwayPoint(
            date: CalendarDay(year: 2026, month: 9, day: day),
            balance: .eur(major)
        )
    }

    private func snapshot(_ points: [RunwayPoint]) -> FinanceAppSnapshot {
        var snapshot = FinanceAppSnapshot.empty(asOf: Self.civilToday)
        snapshot.runwayPoints = points
        return snapshot
    }

    @Test("Equal minima resolve to the earliest day")
    func tiesGoToTheEarliestDay() {
        let summary = WeekAheadSummary.make(
            from: snapshot([point(3, 900), point(5, 400), point(7, 400), point(9, 700)]),
            isAvailable: true
        )
        #expect(summary?.low == Amount.eur(400))
        #expect(summary?.day == CalendarDay(year: 2026, month: 9, day: 5))
    }

    @Test("Earliest still wins when the series does not arrive in order")
    func tiesAreResolvedAfterSorting() {
        let summary = WeekAheadSummary.make(
            from: snapshot([point(7, 400), point(9, 700), point(5, 400), point(3, 900)]),
            isAvailable: true
        )
        #expect(summary?.day == CalendarDay(year: 2026, month: 9, day: 5))
    }

    @Test("No projected points in the window produces no minimum")
    func noPointsMeansNoClaim() {
        #expect(WeekAheadSummary.make(from: snapshot([]), isAvailable: true) == nil)
        // Points exist, but all of them are past the window.
        #expect(
            WeekAheadSummary.make(
                from: snapshot([point(11, 500), point(12, 480)]), isAvailable: true
            ) == nil
        )
    }

    @Test("The window is inclusive of today and of day seven, and excludes day eight")
    func windowBoundsAreExact() {
        let onLastDay = WeekAheadSummary.make(
            from: snapshot([point(3, 900), point(10, 100)]), isAvailable: true
        )
        #expect(onLastDay?.day == CalendarDay(year: 2026, month: 9, day: 10))
        #expect(onLastDay?.low == Amount.eur(100))

        // The 11th is one day past the window and cannot lower the week.
        let justOutside = WeekAheadSummary.make(
            from: snapshot([point(3, 900), point(11, 100)]), isAvailable: true
        )
        #expect(justOutside?.day == Self.civilToday)
        #expect(justOutside?.low == Amount.eur(900))
    }

    @Test("Without a completed projection there is no weekly minimum")
    func noProjectionMeansNoMinimum() {
        #expect(
            WeekAheadSummary.make(
                from: snapshot([point(3, 900), point(5, 400)]), isAvailable: false
            ) == nil
        )
    }

    @Test("A series that does not share one currency is refused, never converted")
    func mixedCurrencyIsRefused() {
        var mixed = snapshot([point(3, 900)])
        mixed.runwayPoints.append(
            RunwayPoint(
                date: CalendarDay(year: 2026, month: 9, day: 5),
                balance: Amount(minorUnits: 10_000, currencyCode: "MAD")
            )
        )
        // 100,00 MAD is numerically the smallest figure present. It is not the
        // week's low, and no rate exists here to make it one.
        #expect(WeekAheadSummary.make(from: mixed, isAvailable: true) == nil)
    }

    @Test("A projected deficit is reported as a deficit, never clamped at zero")
    func negativeLowSurvives() {
        let summary = WeekAheadSummary.make(
            from: snapshot([point(3, 200), point(6, -180)]), isAvailable: true
        )
        #expect(summary?.low == Amount.eur(-180))
        #expect(summary?.low.isNegative == true)
    }

    @Test("Income the plan does not treat as certain is named, and only inside the window")
    func uncertainIncomeIsNamedWhenItIsInTheWeek() {
        var base = snapshot([point(3, 900), point(5, 400)])
        #expect(WeekAheadSummary.make(from: base, isAvailable: true)?.notes.isEmpty == true)

        // Certain money says nothing.
        base.upcomingEvents = [
            planned(day: 4, amount: .eur(500), isInflow: true, certainty: nil)
        ]
        #expect(WeekAheadSummary.make(from: base, isAvailable: true)?.notes.isEmpty == true)

        // Less-than-certain money inside the week does.
        base.upcomingEvents = [
            planned(day: 4, amount: .eur(500), isInflow: true, certainty: "Expected")
        ]
        #expect(
            WeekAheadSummary.make(from: base, isAvailable: true)?.notes
                == [.includesUncertainIncome]
        )

        // The same money a fortnight out does not qualify this week.
        base.upcomingEvents = [
            planned(day: 17, amount: .eur(500), isInflow: true, certainty: "Expected")
        ]
        #expect(WeekAheadSummary.make(from: base, isAvailable: true)?.notes.isEmpty == true)

        // An outflow carries no certainty label and must never raise the note.
        base.upcomingEvents = [
            planned(day: 4, amount: .eur(-500), isInflow: false, certainty: "Expected")
        ]
        #expect(WeekAheadSummary.make(from: base, isAvailable: true)?.notes.isEmpty == true)
    }

    private func planned(
        day: Int,
        amount: Amount,
        isInflow: Bool,
        certainty: String?
    ) -> PlannedEvent {
        PlannedEvent(
            id: "event-\(day)",
            date: CalendarDay(year: 2026, month: 9, day: day),
            label: "Event",
            amount: amount,
            isInflow: isInflow,
            isGuaranteedButNotReceived: isInflow && certainty == nil,
            certaintyLabel: isInflow ? certainty : nil,
            isRecovery: false,
            hasApproximateDate: false,
            note: nil
        )
    }

    @Test("The summary carries no event identity to attribute a cause with")
    func thereIsNothingToAttributeWith() {
        let summary = WeekAheadSummary.make(
            from: snapshot([point(3, 900), point(5, 400)]), isAvailable: true
        )
        // Every sentence the row can say, walked whole: none names an event,
        // and none asserts causation.
        for note in [WeekAheadNote.planAlreadyFlagsThisDay, .includesUncertainIncome] {
            for forbidden in ["After ", "because", "caused by", "due to"] {
                #expect(!note.sentence.contains(forbidden), "\(note) claimed causality")
            }
        }
        #expect(summary?.dayText.isEmpty == false)
    }

    // MARK: - N: boundary and navigation

    @Test("Home's week row renders a summary and computes nothing")
    func homeOnlyRenders() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FinanceApp")
        let home = try String(
            contentsOf: app.appendingPathComponent("Features/Home/HomeView.swift"),
            encoding: .utf8
        )
        #expect(home.contains("WeekAheadSummary.make"))
        // The row may not reach the series, reduce it, or reach for a risk
        // threshold of its own.
        for forbidden in ["runwayPoints", "lowestPoint", "firstRisk", "min(", "reduce("] {
            #expect(!home.contains(forbidden), "Home reached \(forbidden)")
        }

        // The week's answer is projected cash; Safe to Use is untouched beside
        // it and still leads with its own figure.
        #expect(home.contains("MoneyText(amount: snapshot.safeToSpend"))
        #expect(home.contains("navigation.openHome(.safeToUse)"))

        // Upcoming is reached through the destination Plan already owns.
        #expect(home.contains("navigation.openPlan(.upcoming)"))
        let surface = try String(
            contentsOf: app.appendingPathComponent("Surface/WeekAhead.swift"),
            encoding: .utf8
        )
        #expect(!surface.contains("triggerLabel"), "the summary reached for an event label")
    }

    @Test("The week row is addressable and cannot collide with an event row")
    func identifierIsDistinct() {
        #expect(RouteID.homeWeekLow == "home.week-low")
        #expect(!RouteID.homeWeekLow.hasPrefix("home.week."))
        #expect(RouteID.homeWeekLow != RouteID.homeWeekEvent("low"))
        #expect(RouteID.homeWeekLow != RouteID.homeUpcomingAll)
    }

    @Test("Seeing the week does not move the person or the plan")
    func navigationIsUnchanged() {
        let store = FinanceStore.preview()
        let before = store.snapshot
        let navigation = AppNavigation()

        _ = WeekAheadSummary.make(from: store.snapshot, isAvailable: store.safeToUseIsAvailable)
        #expect(navigation.selectedTab == .home)
        #expect(navigation.planPath.isEmpty)

        // The canonical next step is the Upcoming that Plan already owns.
        navigation.openPlan(.upcoming)
        #expect(navigation.selectedTab == .plan)
        #expect(navigation.planPath.count == 1)
        #expect(store.snapshot == before)
    }
}
