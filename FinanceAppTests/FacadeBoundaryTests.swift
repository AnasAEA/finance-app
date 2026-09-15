import Testing
import SwiftUI
@testable import FinanceApp

/// The boundary, asserted rather than asserted-to.
///
/// **This file deliberately does not `import FinanceCore`.** Every value it
/// builds, reads and compares is a product type. If a screen or a store ever
/// needs an engine type to be driven or inspected, this file stops compiling —
/// which is the whole point of it.
@MainActor
@Suite("The UI is driven by the facade")
struct FacadeBoundaryTests {

    // MARK: - A snapshot built without an engine

    /// Two accounts and one obligation, assembled by hand. No forecast runs.
    static func handBuiltSnapshot() -> FinanceAppSnapshot {
        let day = CalendarDay(year: 2027, month: 2, day: 28)
        let month = CalendarMonth(year: 2027, month: 3, firstDay: day)

        var snapshot = FinanceAppSnapshot.empty(asOf: day)
        snapshot.horizonDays = 30
        snapshot.accountCash = .eur(396.00)
        snapshot.trackedHoldings = [
            HoldingLine(
                id: "bank", title: "Everyday bank", subtitle: "Current account",
                kind: .bank, balance: .eur(300.00), isSpendableHere: true,
                carriedAt: nil, railLabels: ["Direct debit", "Transfer"]
            ),
            HoldingLine(
                id: "cash", title: "Cash", subtitle: "Cash",
                kind: .cash,
                balance: Amount(minorUnits: 15_000, currencyCode: "CHF"),
                isSpendableHere: false, carriedAt: .eur(30.00),
                railLabels: ["Cash in hand"]
            )
        ]
        snapshot.physicalCash = [snapshot.trackedHoldings[1]]
        snapshot.safeToSpend = .zeroEUR
        snapshot.safeToSpendReason = .shortfall(.eur(120.00))
        snapshot.rawShortfall = Amount.eur(120.00).negated
        snapshot.cashRunway = .endsIn(days: 15)
        snapshot.firstRisk = RiskPoint(
            date: day, projectedBalance: Amount.eur(85.00).negated,
            triggerLabel: "Housing", triggerAmount: .eur(350.00),
            kind: .hardDeficit, shortfall: .eur(85.00)
        )
        snapshot.minimumBridgeRequired = .eur(85.00)
        snapshot.runwayPoints = [RunwayPoint(date: day, balance: .eur(396.00))]
        snapshot.upcomingEvents = [
            PlannedEvent(
                id: "housing", date: day, label: "Housing",
                amount: Amount.eur(350.00).negated, isInflow: false,
                isGuaranteedButNotReceived: false, certaintyLabel: nil,
                isRecovery: false, hasApproximateDate: false, note: nil
            )
        ]
        snapshot.monthProjections = [
            MonthProjection(
                month: month, opening: .eur(396.00), plannedIncome: .zeroEUR,
                committedSpending: .eur(350.00), everydaySpending: .zeroEUR,
                closing: .eur(46.00),
                unfundedEUR: nil, events: snapshot.upcomingEvents
            )
        ]
        snapshot.budget = BudgetOverview(
            monthLabel: "March 2027",
            summary: BudgetSummary(
                limit: .eur(750), spent: .eur(45.00), remaining: .eur(705.00),
                committed: .eur(480.00), safeToSpend: .eur(200.36),
                fraction: 0.06, isOverspent: false, isNearLimit: false,
                ceiling: .eur(700)
            ),
            target: .eur(120),
            unallocated: .eur(580),
            uncategorized: .zeroEUR,
            financingRepayments: .zeroEUR,
            daysInMonth: 30,
            daysElapsed: 12,
            daysRemaining: 18,
            isCurrentMonth: true,
            lines: [
                BudgetLine(
                    key: "food", name: "Food", symbolName: "fork.knife",
                    limit: .eur(120), spent: .eur(39.95), committed: .zeroEUR,
                    remaining: .eur(80.05), remainingAfterCommitted: .eur(80.05),
                    fraction: 0.33, rawFraction: 0.33, isOverspent: false,
                    isHousing: false, isSuggested: false,
                    dailyPace: .eur(4.44), weeklyPace: .eur(31.13),
                    spendingClass: .flexible
                )
            ],
            otherCurrencyLines: []
        )
        snapshot.activity = [
            ActivityDay(
                date: day, net: Amount.eur(39.95).negated,
                rows: [
                    ActivityRow(
                        id: "row", title: "Carrefour City", subtitle: "Food · Revolut",
                        symbolName: "fork.knife", amount: Amount.eur(39.95).negated,
                        trailingNote: nil, ownedPortion: nil, isReversed: false,
                        isPending: false, flow: .spending, searchText: "Carrefour City Food"
                    )
                ]
            )
        ]
        snapshot.entryOptions = EntryOptions(
            accounts: [AccountOption(id: "bank", name: "BNP Paribas", currencyCode: "EUR")],
            categories: [
                CategoryOption(key: "food", name: "Food", symbolName: "fork.knife",
                               isIncome: false, isTransfer: false)
            ],
            defaultAccountID: "bank"
        )
        return snapshot
    }

    @Test("Every screen renders from a snapshot alone, with no engine behind it")
    func screensRenderFromASnapshot() {
        let store = FinanceStore(snapshot: Self.handBuiltSnapshot())

        // If any of these needed a forecast, a Money, a Transaction or a
        // ModelContext, none of them would produce an image here.
        #expect(rendered(HomeView(), store: store) != nil)
        #expect(rendered(ActivityView(), store: store) != nil)
        #expect(rendered(NavigationStack { PlanView() }, store: store) != nil)
        #expect(rendered(NavigationStack { SettingsView() }, store: store) != nil)
        #expect(rendered(AddTransactionSheet(), store: store) != nil)
    }

    @Test("A fixed store serves exactly what it was given")
    func fixedStoreDoesNotRecompute() {
        let snapshot = Self.handBuiltSnapshot()
        let store = FinanceStore(snapshot: snapshot)

        #expect(store.snapshot == snapshot)
        store.scenario = .upside
        #expect(store.snapshot == snapshot)
        #expect(store.snapshot(under: .guaranteed) == snapshot)
    }

    private func rendered(_ view: some View, store: FinanceStore) -> UIImage? {
        let renderer = ImageRenderer(
            content: view
                .environment(store)
                .environment(AppNavigation())
                .frame(width: 393, height: 852)
        )
        renderer.scale = 1
        return renderer.uiImage
    }
}

// MARK: - What the numbers are allowed to claim

@MainActor
@Suite("What the screens are allowed to claim")
struct PresentationClaimTests {

    /// The shipping fixture, through the real store and the real mapper.
    private var store: FinanceStore { FinanceStore.preview() }

    // MARK: Physical cash

    @Test("Physical cash is listed, and is not part of the account figure")
    func physicalCashIsSeparate() throws {
        let snapshot = store.snapshot

        // The foreign-currency pocket: held in its own currency, unspendable
        // on a euro rail, and shown with what it cost rather than converted.
        let cash = try #require(snapshot.physicalCash.first { $0.balance.currencyCode != "EUR" })
        #expect(cash.balance.currencyCode == "CHF")
        #expect(cash.isSpendableHere == false)
        // Shown with what it cost, which is context, not a euro balance.
        #expect(cash.carriedAt?.currencyCode == "EUR")

        // The headline figure is euros only, and reconciles to the euro
        // accounts on their own.
        #expect(snapshot.accountCash.currencyCode == "EUR")
        let euroHoldings = snapshot.trackedHoldings
            .filter(\.isSpendableHere)
            .reduce(Amount.zeroEUR) { $0 + $1.balance }
        #expect(snapshot.accountCash == euroHoldings)

        // Both appear in the list; only one is counted.
        #expect(snapshot.trackedHoldings.contains { !$0.isSpendableHere })
        #expect(snapshot.trackedHoldings.count > snapshot.physicalCash.count)
    }

    @Test("The row for cash in hand says it cannot be spent here")
    func physicalCashRowSaysSo() throws {
        let cash = try #require(store.snapshot.physicalCash.first)
        #expect(HoldingRow(holding: cash).accessibilityLabel.contains("not spendable here"))
    }

    // MARK: Safe to spend

    @Test("Nothing safe to spend and a real shortfall are two separate facts")
    func shortfallCoexistsWithZeroSafeToSpend() throws {
        let snapshot = store.snapshot

        // Safe to spend is defined to be non-negative.
        #expect(snapshot.safeToSpend.isZero)
        #expect(snapshot.safeDailySpend.isZero)

        // The depth of the shortfall survives the clamp, negative and intact.
        #expect(snapshot.rawShortfall.isNegative)
        #expect(snapshot.safeToSpendReason.isShortfall)

        let named = try #require(snapshot.safeToSpendReason.shortfallAmount)
        #expect(named.isPositive)
        #expect(named == snapshot.rawShortfall.negated)
    }

    @Test("A snapshot with no shortfall carries no phantom one")
    func noShortfallMeansZeroRawShortfall() {
        var snapshot = FinanceAppSnapshot.empty(
            asOf: store.initialDay
        )
        snapshot.safeToSpendReason = .budget
        #expect(snapshot.rawShortfall.isZero)
        #expect(snapshot.safeToSpendReason.shortfallAmount == nil)
    }

    // MARK: Guaranteed but not received

    @Test("Guaranteed future support is shown as a promise, not as a balance")
    func guaranteedIncomeIsNotPresentedAsReceived() throws {
        let snapshot = store.snapshot
        let september = try #require(snapshot.monthProjections.first { $0.month.month == 3 })
        let support = try #require(
            september.events.first { $0.id == "etx-pot-arrival" }
        )

        #expect(support.isInflow)
        #expect(support.isGuaranteedButNotReceived)
        // Guaranteed is the top of the planned scale, so it carries no
        // "expected" or "target" qualifier — the promise marker is what
        // distinguishes it.
        #expect(support.certaintyLabel == nil)

        let spoken = UpcomingRow(event: support).accessibilityLabel
        #expect(spoken.contains("not received yet"))

        // Support that did arrive is a different row, on a different list,
        // for a different amount — and carries no promise marker. The two
        // must not be readable as the same money.
        let received = try #require(
            snapshot.activity.flatMap(\.rows).first { $0.id == "tx-salary-2027-02-26" }
        )
        #expect(received.flow == .income)
        #expect(received.isPending == false)
        #expect(received.amount.magnitude != support.amount.magnitude)
        #expect(!snapshot.activity.flatMap(\.rows).contains {
            $0.amount.magnitude == support.amount.magnitude && $0.flow == .income
        })
    }

    @Test("Money already in the account carries no promise marker")
    func receivedIncomeIsNotMarkedAsPending() {
        let received = store.snapshot.activity
            .flatMap(\.rows)
            .filter { $0.flow == .income }
        #expect(!received.isEmpty)
        for row in received {
            #expect(row.isPending == false)
            #expect(row.trailingNote != "Pending")
        }
    }

    // MARK: Pass-through

    @Test("A share that belongs to someone else is not counted as income")
    func passThroughIsNotPersonalIncome() throws {
        let store = FinanceStore.preview()
        let account = try #require(store.snapshot.entryOptions.defaultAccountID)
        let incomeSource = try #require(store.snapshot.entryOptions.incomeSources.first?.id)

        // €1,000 arrives; €600 of it is a co-resident's and only passes through.
        try store.add(
            try #require(TransactionDraft(
                day: store.initialDay,
                kind: .income,
                amount: .eur(1000),
                accountID: account,
                incomeSourceID: incomeSource,
                categoryKey: "income",
                merchant: "Family transfer",
                ownShare: .eur(800)
            ))
        )

        let row = try #require(
            store.snapshot.activity.flatMap(\.rows).first { $0.title == "Family transfer" }
        )

        // The row names the owner's share, so the gross figure beside it is
        // never read as €1,000 of income.
        let owned = try #require(row.ownedPortion)
        #expect(owned == .eur(800))
        #expect(owned < row.amount.magnitude)
    }

    @Test("An ordinary inflow names no share at all")
    func wholeInflowsCarryNoShareCaveat() throws {
        let store = FinanceStore.preview()
        let account = try #require(store.snapshot.entryOptions.defaultAccountID)
        let incomeSource = try #require(store.snapshot.entryOptions.incomeSources.first?.id)

        try store.add(
            try #require(TransactionDraft(
                day: store.initialDay, kind: .income, amount: .eur(250),
                accountID: account, incomeSourceID: incomeSource,
                categoryKey: "income", merchant: "Whole inflow"
            ))
        )

        let row = try #require(
            store.snapshot.activity.flatMap(\.rows).first { $0.title == "Whole inflow" }
        )
        #expect(row.ownedPortion == nil)
        #expect(row.flow == .income)
    }

    // MARK: Scenario

    @Test("Switching scenario goes through the facade and changes the plan")
    func scenarioSwitchIsVisible() {
        let store = FinanceStore.preview()
        let base = store.snapshot

        store.scenario = .guaranteed
        #expect(store.snapshot.scenario == .guaranteed)

        // A tighter scenario never produces a rosier picture.
        #expect(store.snapshot.lowestPoint.projectedBalance <= base.lowestPoint.projectedBalance)
    }
}

// MARK: - Fixture content

@MainActor
@Suite("Authoritative fixture content says only true things")
struct FixtureCopyTests {

    private var store: FinanceStore { FinanceStore.preview() }

    /// Nothing the document does not contain may appear as a planned charge or
    /// a live commitment. An obligation that was never written down — or one
    /// that was removed — must not be invented by the projection.
    @Test("No commitment exists that the document does not state")
    func noCommitmentIsInvented() {
        let documented: Set<String> = [
            "Broadband", "Housing", "Contents insurance", "Transit pass", "Music streaming",
        ]
        let committed = Set(store.snapshot.commitments.flatMap(\.lines).map(\.name))
        #expect(committed.subtracting(documented).isEmpty,
                "invented commitments: \(committed.subtracting(documented))")
    }

    @Test("The income line carries the owned share, never the gross arrival")
    func supportLineIsTheOwnedShare() throws {
        let line = try #require(
            store.snapshot.income.flatMap(\.lines).first { $0.id == "inc-trip-pot" }
        )
        // The owner's share, never the gross transfer that briefly passes
        // through the pocket. The "not received yet" copy is product copy and
        // is asserted where the screen produces it, not from fixture text.
        #expect(line.amount == .eur(400.00))
        if let note = line.note {
            #expect(!note.contains("1000") && !note.contains("1,000"),
                    "an income note must not restate the gross arrival")
        }
    }

    @Test("No income source claims the whole pass-through arrival")
    func noSourceClaimsTheGross() {
        let amounts = store.snapshot.income.flatMap(\.lines).map(\.amount)
        #expect(!amounts.contains(.eur(1000.00)))
    }
}
