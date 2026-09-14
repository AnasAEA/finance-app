import Testing
import Foundation
@testable import FinanceApp

/// What the month summary and the Home shortfall line are allowed to say.
///
/// **No `import FinanceCore`.** Everything here is read from the product
/// snapshot the screens actually render, because the defects these tests exist
/// to prevent were both presentation defects: figures that were individually
/// true and collectively a lie.
///
/// Two of them, specifically:
///
/// 1. The month summary added up event amounts for income and spending while
///    taking the closing balance from the projection. Everyday spending was in
///    the second and not the first, so `opening + income − spending` missed the
///    closing figure by the whole of the month's budget — a ledger with a phase
///    hidden behind it.
/// 2. Home printed the 30-day headroom deficit and then dated it with the
///    120-day forecast's first risk day, producing a sentence whose amount was
///    never the amount missing on the day named.
@MainActor
@Suite("The month summary adds up and the shortfall line means one thing")
struct PlanLedgerPresentationTests {

    /// The shipping fixture, through the real store and the real mapper.
    private var store: FinanceStore { FinanceStore.preview() }

    private func month(_ snapshot: FinanceAppSnapshot) throws -> MonthProjection {
        try #require(snapshot.monthProjections.first { $0.month.year == 2027 && $0.month.month == 3 })
    }

    // MARK: - One arithmetic model

    @Test("Every month's rows reach its own closing figure, to the cent")
    func everyMonthReconciles() throws {
        let snapshot = store.snapshot
        #expect(!snapshot.monthProjections.isEmpty)
        for month in snapshot.monthProjections {
            #expect(month.reconciledClosing == month.closing,
                    "\(month.month) does not add up: \(month.opening.editingText) + \(month.plannedIncome.editingText) − \(month.committedSpending.editingText) − \(month.everydaySpending.editingText) ≠ \(month.closing.editingText)")
            // The split is a split, not two independent figures.
            #expect(month.plannedSpending == month.committedSpending + month.everydaySpending)
            // Both halves are magnitudes; the sign belongs to the row, not the
            // number, and a negative here would silently add.
            #expect(!month.committedSpending.isNegative)
            #expect(!month.everydaySpending.isNegative)
        }
    }

    @Test("It still adds up under every scenario, including the tightest")
    func everyScenarioReconciles() throws {
        for scenario in PlanScenario.allCases {
            let snapshot = FinanceStore.preview(scenario: scenario).snapshot
            #expect(!snapshot.monthProjections.isEmpty)
            for month in snapshot.monthProjections {
                #expect(month.reconciledClosing == month.closing,
                        "\(scenario) \(month.month) does not add up")
            }
        }
    }

    @Test("Each month opens where the one before it closed")
    func monthsChain() throws {
        let months = store.snapshot.monthProjections
        for (earlier, later) in zip(months, months.dropFirst()) {
            #expect(later.opening == earlier.closing)
        }
    }

    @Test("September's rows are the figures the fixture actually implies")
    func monthRowsAreDerivable() throws {
        let projection = try month(store.snapshot)

        // Opening: the spendable euro accounts. The €200 MAD pocket and the
        // empty euro pocket are not on bank rails and are not in it.
        #expect(projection.opening == .eur(396.00))

        // Income: 1,000.00 arrives in hand, 400.00 of it is deposited to the
        // bank and 600.00 goes on to its owner. Net 400.00 — the part that
        // was ever the holder's.
        #expect(projection.plannedIncome == .eur(400.00))

        // Committed: 552.00 of recurring charges (29.00 + 480.00 + 8.00 +
        // 24.00 + 11.00) and 100.00 of financing legs — the two that fall in
        // March, 40.00 on the 6th and 60.00 on the 15th. The other two plans'
        // legs fall outside the month and are not in here.
        #expect(projection.committedSpending == .eur(652.00))

        // Everyday: September's own budget override, €85.00, spread over the
        // month. Nothing in this fixture is linked to a budget line, so the
        // whole envelope is still variable.
        #expect(projection.everydaySpending == .eur(90.00))

        // 396.00 + 400.00 − 652.00 − 90.00.
        #expect(projection.closing == .eur(54.00))
        #expect(projection.reconciledClosing == projection.closing)
    }

    @Test("The gross that passes through is in neither the income row nor the balance")
    func passThroughIsNetEverywhere() throws {
        let projection = try month(store.snapshot)

        // €1,000 lands; the row says €400, and so does the arithmetic behind
        // the closing figure. Presenting the net share is only honest while
        // the two agree.
        #expect(projection.plannedIncome == .eur(400.00))
        #expect(projection.plannedIncome != .eur(1000.00))

        let inflows = projection.events.filter(\.isInflow)
        let visible = inflows.reduce(Amount.zeroEUR) { $0 + $1.amount }
        #expect(visible == projection.plannedIncome)
        #expect(!inflows.contains(where: { $0.amount.magnitude == .eur(1000.00) }))
    }

    @Test("A month can owe a failed payment and still close in the black")
    func unfundedIsNotTheClosingBalance() throws {
        let snapshot = store.snapshot
        let projection = try month(snapshot)

        // Three payments cannot be met from the account they must come out of,
        // on the day they are due:
        //
        //   113.74  the rent, €480.00 by direct debit against the only account
        //           on that rail, which holds 345.95 by the 11th;
        //    35.58  the instalment leg on the 16th, once the card accounts are
        //           down to 15.67 and the deposit has not landed yet;
        //     2.83  that same day's everyday slice, with nothing left to draw.
        //
        // And the month still ends with 54.00, because the money arrives
        // afterwards. A screen that reads either of these off the other is
        // wrong: month-end cash and settlement failures are separate facts.
        let unfunded = try #require(projection.unfundedEUR)
        #expect(unfunded == .eur(267.50))
        #expect(projection.closing == .eur(54.00))
        #expect(projection.closing.isPositive)

        // Three different true numbers, three different questions. None of them
        // may stand in for another on screen.
        #expect(unfunded != projection.closing.magnitude)
        #expect(unfunded != snapshot.firstRisk?.shortfall)
        #expect(unfunded != snapshot.safeToSpendReason.shortfallAmount)
    }

    // MARK: - One shortfall, one horizon

    @Test("The shortfall sentence takes its amount and its day from one risk")
    func shortfallComesFromOneRisk() throws {
        let snapshot = store.snapshot
        let statement = try #require(PlanningTotals.shortfall(from: snapshot))
        let risk = try #require(snapshot.firstRisk)
        let missing = try #require(risk.shortfall)
        let day = try #require(statement.date)

        #expect(statement == .dated(amount: missing, date: risk.date))
        #expect(day == CalendarDay(year: 2027, month: 3, day: 10))

        // The rent's own unfunded remainder on the 11th: what its account could
        // not find. Not the pool's gap, and not the 30-day headroom deficit.
        #expect(statement.amount == .eur(209.00))

        // The regression, stated as the thing that must not come back: the
        // 30-day figure paired with the 120-day date. Both numbers are true
        // and the sentence they make is false.
        // The 30-day headroom: the whole pool, 396.00, against the whole
        // month's committed charges, 652.00. A different question about a
        // different horizon, and 47.00 away from the answer to this one.
        let headroom = try #require(snapshot.safeToSpendReason.shortfallAmount)
        #expect(headroom == .eur(256.00))
        #expect(statement.amount != headroom)
    }

    @Test("With no risk day inside the horizon, the sentence names a window instead")
    func noRiskMeansNoDate() throws {
        var snapshot = FinanceAppSnapshot.empty(
            asOf: store.initialDay
        )
        snapshot.safeToSpendWindowDays = 30
        snapshot.safeToSpendReason = .shortfall(.eur(166.62))
        snapshot.firstRisk = nil

        let statement = try #require(PlanningTotals.shortfall(from: snapshot))
        #expect(statement == .undated(amount: .eur(166.62), withinDays: 30))
        // No day is invented from a horizon that found none.
        #expect(statement.date == nil)
    }

    @Test("Nothing short, nothing said")
    func noShortfallNoSentence() {
        var snapshot = FinanceAppSnapshot.empty(
            asOf: store.initialDay
        )
        snapshot.safeToSpendReason = .liquidity
        #expect(PlanningTotals.shortfall(from: snapshot) == nil)
    }

    @Test("The two horizons on the snapshot stay told apart")
    func horizonsAreDistinct() {
        let snapshot = store.snapshot
        #expect(snapshot.horizonDays == 120)
        #expect(snapshot.safeToSpendWindowDays == 30)
    }

    // MARK: - Scenario context

    @Test("The scenario note appears only when guaranteed money is all there is")
    func scenarioNoteIsEarned() throws {
        let projection = try month(store.snapshot)
        // The month's only arrival is the guaranteed owned share, so every
        // scenario is reading the same inflow.
        #expect(PlanningTotals.incomeIsScenarioIndependent(in: projection))

        // A month with no arrivals at all makes no such claim.
        let empty = MonthProjection(
            month: projection.month, opening: .eur(10), plannedIncome: .zeroEUR,
            committedSpending: .zeroEUR, everydaySpending: .zeroEUR,
            closing: .eur(10), unfundedEUR: nil, events: []
        )
        #expect(!PlanningTotals.incomeIsScenarioIndependent(in: empty))
    }
}
