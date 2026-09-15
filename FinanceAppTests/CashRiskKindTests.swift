import FinanceCore
import Foundation
import Testing
@testable import FinanceApp

/// The engine distinguishes running out of money from spending into the
/// reserve. The app used to collapse the two, and called a funded plan a
/// funding gap.
///
/// Every test here drives a real document through the real engine and the real
/// mapper, because the point of the slice is that a classification survives
/// that journey. Nothing reconstructs a kind from an amount.
///
/// All values and identities are synthetic.
@MainActor
@Suite("Cash risk kind")
struct CashRiskKindTests {

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

    /// One euro account, optional reserve, whatever obligations the case needs.
    private func store(
        balance: String,
        safetyFloor: String? = nil,
        obligations: [RecurringObligation]
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
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [current],
            balances: [
                AccountBalance(accountID: "current", balance: euro(balance), asOf: Self.today)
            ],
            planning: planning
        )
        return FinanceStore(document: document, today: Self.today, scenario: .base)
    }

    private func card(in store: FinanceStore) throws -> HomeAttentionCard {
        guard case let .act(card, _) = store.currentPresentation().attention.home else {
            Issue.record("expected an attention card, got \(store.currentPresentation().attention.home)")
            throw CancellationError()
        }
        return card
    }

    // MARK: - The classification survives the boundary

    @Test("Cash going below zero arrives as a shortfall")
    func deficitKeepsItsKind() throws {
        let store = store(
            balance: "100.00", obligations: [obligation("rent", "300.00", onDay: 6)]
        )
        let risk = try #require(store.snapshot.firstRisk)

        #expect(risk.kind == .hardDeficit)
        #expect(risk.date == CalendarDay(year: 2026, month: 9, day: 6))
        #expect(risk.projectedBalance == Amount.eur(-200))
    }

    @Test("Cash crossing the reserve while still funded arrives as a reserve warning")
    func reserveBreachKeepsItsKind() throws {
        // 500 on the account, a 400 reserve, 150 leaving: 350 remains. The
        // person is funded and 50 under their own reserve.
        let store = store(
            balance: "500.00", safetyFloor: "400.00",
            obligations: [obligation("gym", "150.00", onDay: 6)]
        )
        let risk = try #require(store.snapshot.firstRisk)

        #expect(risk.kind == .reserveWarning)
        #expect(risk.projectedBalance == Amount.eur(350))
        // The balance is positive. Any rule that read the kind off the sign
        // would have called this solvent and said nothing.
        #expect(risk.projectedBalance.isPositive)
        #expect(risk.riskAmount == Amount.eur(50))
        #expect(risk.reserveGap == Amount.eur(50))
        // Not money that is missing: nothing is.
        #expect(risk.fundingDeficit == nil)
    }

    @Test("No risk carries no kind")
    func noRiskNoKind() {
        let store = store(
            balance: "5000.00", safetyFloor: "400.00",
            obligations: [obligation("gym", "150.00", onDay: 6)]
        )
        #expect(store.snapshot.firstRisk == nil)
    }

    @Test("A lowest point that is not the risk day borrows no kind")
    func theLowestPointDoesNotInheritAClassification() throws {
        let store = store(
            balance: "500.00", safetyFloor: "400.00",
            obligations: [
                obligation("gym", "150.00", onDay: 6),
                obligation("rent", "600.00", onDay: 20),
            ]
        )
        let snapshot = store.snapshot
        let risk = try #require(snapshot.firstRisk)

        // First risk is the reserve breach on the 6th; the deepest point is
        // the deficit on the 20th. They are different days and different
        // facts, so the lowest point is given neither kind nor shortfall.
        #expect(risk.kind == .reserveWarning)
        #expect(risk.date == CalendarDay(year: 2026, month: 9, day: 6))
        #expect(snapshot.lowestPoint.date == CalendarDay(year: 2026, month: 9, day: 20))
        #expect(snapshot.lowestPoint.kind == nil)
        #expect(snapshot.lowestPoint.riskAmount == nil)
    }

    @Test("First risk stays the engine's earliest, never the worst")
    func earliestWinsNotWorst() throws {
        // A reserve breach on the 6th, a real deficit on the 10th. The app
        // reports what the engine reports: the earliest. It does not promote
        // the more severe state, and it builds no precedence of its own.
        let store = store(
            balance: "500.00", safetyFloor: "400.00",
            obligations: [
                obligation("gym", "150.00", onDay: 6),
                obligation("rent", "600.00", onDay: 10),
            ]
        )
        let risk = try #require(store.snapshot.firstRisk)

        #expect(risk.date == CalendarDay(year: 2026, month: 9, day: 6))
        #expect(risk.kind == .reserveWarning)
        #expect(store.snapshot.lowestPoint.projectedBalance == Amount.eur(-250))
        #expect(store.snapshot.cashRunway.daysRemaining == 7)
    }

    @Test("Both engine kinds are answered, and neither maps to the other")
    func theMappingIsTotalAndDistinct() {
        #expect(DomainMapper.riskKind(.poolDeficit) == .hardDeficit)
        #expect(DomainMapper.riskKind(.belowSafetyFloor) == .reserveWarning)
        #expect(DomainMapper.riskKind(.poolDeficit) != DomainMapper.riskKind(.belowSafetyFloor))
    }

    @Test("A failed projection classifies nothing")
    func noProjectionNoClassification() {
        struct ForecastUnavailable: Error {}
        let current = Account(
            id: "current", name: "Current", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 0
        )
        var planning = FinanceDocument.Planning(defaultScenario: .base)
        planning.safetyFloor = euro("400.00")
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [current],
            balances: [
                AccountBalance(accountID: "current", balance: euro("100.00"), asOf: Self.today)
            ],
            planning: planning
        )
        let store = FinanceStore(
            document: document, today: Self.today, scenario: .base,
            forecastRunner: { _ in throw ForecastUnavailable() }
        )

        #expect(!store.safeToUseIsAvailable)
        // Unknown does not become "no risk with a kind", and it does not
        // become a reserve breach because a floor happens to be set.
        #expect(store.snapshot.firstRisk == nil)
        #expect(store.snapshot.lowestPoint.kind == nil)
        #expect(WeekAheadSummary.make(from: store.snapshot, isAvailable: false) == nil)
    }

    // MARK: - Home says which problem it is

    @Test("A shortfall reads as money that has to be found")
    func deficitCardNamesTheGap() throws {
        let card = try card(
            in: store(balance: "100.00", obligations: [obligation("rent", "300.00", onDay: 6)])
        )
        #expect(card.title.contains("200,00") || card.title.contains("200.00"))
        #expect(card.title.lowercased().contains("needs") || card.title.lowercased().contains("gap"))
        #expect(!card.title.lowercased().contains("reserve"))
    }

    @Test("A reserve breach is never called a funding gap")
    func reserveCardNamesTheReserve() throws {
        let store = store(
            balance: "500.00", safetyFloor: "400.00",
            obligations: [obligation("gym", "150.00", onDay: 6)]
        )
        let card = try card(in: store)

        // The old copy read "50,00 € funding gap by Sep 6" while the person
        // held 350,00 € and needed nothing. Nothing is needed, and the card
        // may not say it is.
        #expect(card.title.lowercased().contains("below your safety reserve"))
        #expect(!card.title.lowercased().contains("funding gap"))
        #expect(!card.title.lowercased().contains("needs"))
        #expect(!card.title.lowercased().contains("needed"))
    }

    @Test("A risk with no settlement failure offers what is coming, not a dead end")
    func unexplainableRiskRoutesToUpcoming() throws {
        let store = store(
            balance: "500.00", safetyFloor: "400.00",
            obligations: [obligation("gym", "150.00", onDay: 6)]
        )
        // Funding Needed explains one payment that could not be settled. This
        // risk has none, so that screen would have shown "Funding detail
        // unavailable" to a person who tapped a card promising an explanation.
        #expect(store.currentPresentation().attention.fundingNeeded == nil)

        let card = try card(in: store)
        #expect(card.destination == .planUpcoming)
        #expect(card.actionTitle == "See what's coming")
    }

    @Test("A risk that can be explained still opens the canonical explanation")
    func settleableRiskKeepsFundingNeeded() throws {
        let store = store(
            balance: "100.00", obligations: [obligation("rent", "300.00", onDay: 6)]
        )
        #expect(store.currentPresentation().attention.fundingNeeded != nil)

        let card = try card(in: store)
        #expect(card.destination == .planFundingNeeded)
        #expect(card.actionTitle == "See what's needed")
    }

    @Test("Attention priority and the one-card rule are unchanged")
    func onlyTheCopyAndTheRouteMoved() throws {
        let store = store(
            balance: "500.00", safetyFloor: "400.00",
            obligations: [obligation("gym", "150.00", onDay: 6)]
        )
        let attention = store.currentPresentation().attention

        // Still exactly one primary card, still the funding candidate, still
        // tinted as the one thing Home highlights.
        guard case let .act(card, reviewCount) = attention.home else {
            Issue.record("expected the funding candidate to stay primary")
            return
        }
        #expect(card.isTinted)
        #expect(reviewCount == 0)
        #expect(attention.activity.isEmpty)
    }

    // MARK: - The week's row says which problem it is

    @Test("A shortfall on the week's low day reads as a shortfall")
    func weeklyLowNamesAShortfall() throws {
        let store = store(
            balance: "100.00", obligations: [obligation("rent", "300.00", onDay: 6)]
        )
        let summary = try #require(
            WeekAheadSummary.make(from: store.snapshot, isAvailable: store.safeToUseIsAvailable)
        )
        #expect(summary.day == store.snapshot.firstRisk?.date)
        #expect(summary.notes == [.shortfallOnThisDay])
        #expect(summary.notes.map(\.sentence) == ["The plan projects a cash shortfall on this day."])
    }

    @Test("A reserve breach on the week's low day reads as the reserve")
    func weeklyLowNamesTheReserve() throws {
        let store = store(
            balance: "500.00", safetyFloor: "400.00",
            obligations: [obligation("gym", "150.00", onDay: 6)]
        )
        let summary = try #require(
            WeekAheadSummary.make(from: store.snapshot, isAvailable: store.safeToUseIsAvailable)
        )
        #expect(summary.day == store.snapshot.firstRisk?.date)
        #expect(summary.notes == [.belowReserveOnThisDay])
        #expect(
            summary.notes.map(\.sentence)
                == ["The plan projects cash below your safety reserve on this day."]
        )
        // The week's own figure is untouched by the classification.
        #expect(summary.low == Amount.eur(350))
    }

    @Test("A risk on another day attaches no risk copy to the week's row")
    func lowDayThatIsNotTheRiskDayStaysSilent() throws {
        let store = store(
            balance: "500.00", safetyFloor: "400.00",
            obligations: [obligation("rent", "600.00", onDay: 20)]
        )
        let summary = try #require(
            WeekAheadSummary.make(from: store.snapshot, isAvailable: store.safeToUseIsAvailable)
        )
        #expect(store.snapshot.firstRisk?.date == CalendarDay(year: 2026, month: 9, day: 20))
        #expect(summary.day != store.snapshot.firstRisk?.date)
        #expect(summary.notes.isEmpty)
    }

    @Test("An unclassified risk says nothing rather than something vague")
    func unclassifiedRiskRaisesNoNote() {
        var snapshot = FinanceAppSnapshot.empty(
            asOf: CalendarDay(year: 2026, month: 9, day: 3)
        )
        snapshot.runwayPoints = [
            RunwayPoint(date: CalendarDay(year: 2026, month: 9, day: 3), balance: .eur(500)),
            RunwayPoint(date: CalendarDay(year: 2026, month: 9, day: 6), balance: .eur(350)),
        ]
        snapshot.firstRisk = RiskPoint(
            date: CalendarDay(year: 2026, month: 9, day: 6),
            projectedBalance: .eur(350),
            triggerLabel: "Gym", triggerAmount: .eur(150),
            kind: nil, riskAmount: .eur(50)
        )
        let summary = WeekAheadSummary.make(from: snapshot, isAvailable: true)

        #expect(summary?.day == CalendarDay(year: 2026, month: 9, day: 6))
        // The day matches, but "below zero" and "below your reserve" are not
        // interchangeable and neither may stand in for an unknown.
        #expect(summary?.notes.isEmpty == true)
    }

    // MARK: - Nothing else moved

    @Test("Safe to Use and the week's figure are untouched by the classification")
    func neighbouringAnswersAreUnchanged() throws {
        let store = store(
            balance: "500.00", safetyFloor: "400.00",
            obligations: [obligation("gym", "150.00", onDay: 6)]
        )
        let snapshot = store.snapshot

        // 500 on the accounts, 150 committed inside the 30-day window.
        #expect(snapshot.accountCash == Amount.eur(500))
        #expect(snapshot.committedOutflows == Amount.eur(150))
        #expect(snapshot.safeToSpend == Amount.eur(350))
        guard case let .explained(breakdown) = SafeToUseExplanation.make(
            from: snapshot, isAvailable: store.safeToUseIsAvailable
        ) else {
            Issue.record("expected Safe to Use to still explain itself")
            return
        }
        #expect(breakdown.safeToUse == Amount.eur(350))
        #expect(breakdown.outcome == .headroom)

        // The reserve is not a Safe to Use component and does not reduce it.
        #expect(breakdown.notes.isEmpty)
    }

    @Test("Nothing derives the kind from a balance or a reserve amount")
    func noSurfaceReinventsTheClassification() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FinanceApp")
        for file in [
            "Surface/WeekAhead.swift",
            "Features/Home/HomeView.swift",
            "Persistence/AttentionPresentationMapper.swift",
        ] {
            let source = try String(
                contentsOf: app.appendingPathComponent(file), encoding: .utf8
            )
            for forbidden in [
                "safetyFloor",
                "isNegative ? .hardDeficit",
                "projectedBalance.isNegative",
                "< safetyFloor",
            ] {
                #expect(!source.contains(forbidden), "\(file) re-derived the risk kind")
            }
        }
        // The one place the engine's kinds are read is the mapper.
        let mapper = try String(
            contentsOf: app.appendingPathComponent("Persistence/DomainMapper.swift"),
            encoding: .utf8
        )
        #expect(mapper.contains("case .poolDeficit: .hardDeficit"))
        #expect(mapper.contains("case .belowSafetyFloor: .reserveWarning"))
    }
}
