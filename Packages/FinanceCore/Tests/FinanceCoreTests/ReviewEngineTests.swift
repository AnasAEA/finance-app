import XCTest
@testable import FinanceCore

/// Phase 2.8 — pure period review.
///
/// Every fixture is synthetic. Amounts and names are invented for the test;
/// none of them is anybody's financial data.
final class ReviewEngineTests: XCTestCase {

    private func euro(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .eur)! }
    private func day(_ iso: String) -> Day { Day(isoString: iso)! }

    private let august = MonthKey(year: 2026, month: 8)
    private let september = MonthKey(year: 2026, month: 9)

    private var bank: Account {
        Account(
            id: "bank", name: "Bank", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 0
        )
    }
    private var wallet: Account {
        Account(
            id: "wallet", name: "Wallet", currency: .eur, kind: .wallet,
            supportedRails: PaymentRail.euroWalletRails, drawOrder: 1
        )
    }
    private var cash: Account {
        Account(
            id: "cash", name: "Cash", currency: .eur, kind: .cash,
            supportedRails: [.physicalCash], drawOrder: 2
        )
    }

    private func budget(
        _ id: String,
        _ amount: String,
        categoryKeys: [String] = [],
        spendingClass: SpendingClass = .flexible,
        from: MonthKey? = nil,
        through: MonthKey? = nil,
        overrides: [MonthKey: Money] = [:]
    ) -> BudgetAllocation {
        BudgetAllocation(
            id: id,
            name: id,
            spendingClass: spendingClass,
            monthlyAmount: euro(amount),
            effectiveFrom: from ?? MonthKey(year: 2026, month: 1),
            effectiveThrough: through,
            monthlyOverrides: overrides,
            confirmation: .userConfirmed,
            categoryKeys: categoryKeys
        )
    }

    private func expense(
        _ id: String,
        _ amount: String,
        on iso: String,
        account: String = "bank",
        lifecycle: TransactionLifecycle? = nil,
        provenance: Provenance = .devFixture
    ) -> Transaction {
        Transaction(
            id: id, date: day(iso), kind: .expense,
            legs: [AccountLeg(accountID: account, amount: euro("-\(amount)"))],
            factivity: .observed,
            lifecycle: lifecycle,
            provenance: provenance
        )
    }

    private func document(
        transactions: [Transaction] = [],
        expected: [Transaction] = [],
        income: [IncomeSource] = [],
        budgets: [BudgetAllocation] = [],
        obligations: [RecurringObligation] = [],
        settlements: [ObligationSettlement] = [],
        purchases: [PlannedPurchase] = [],
        funds: [SinkingFund] = [],
        ceiling: Money? = Money(exactDecimal: "700.00", currency: .eur),
        floor: Money? = nil,
        balance: String = "800.00",
        asOf iso: String = "2026-09-01"
    ) -> FinanceDocument {
        FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [bank, wallet, cash],
            balances: [
                AccountBalance(accountID: "bank", balance: euro(balance), asOf: day(iso)),
                AccountBalance(accountID: "wallet", balance: euro("0.00"), asOf: day(iso)),
                AccountBalance(accountID: "cash", balance: euro("0.00"), asOf: day(iso)),
            ],
            transactions: transactions,
            expectedTransactions: expected,
            incomeSources: income,
            planning: FinanceDocument.Planning(
                defaultScenario: .base,
                safetyFloor: floor,
                monthlyEconomicCeiling: ceiling,
                budgets: budgets,
                recurringObligations: obligations,
                settlements: settlements,
                plannedPurchases: purchases,
                sinkingFunds: funds
            )
        )
    }

    private func liveCovering(_ intervals: ReviewInterval..., cutoff: Day? = nil, history: FinanceHistoryDocument? = nil) -> ReviewCoverageInput {
        .liveCovered(intervals, cutoff: cutoff, history: history)
    }

    private func monthlyRequest(
        _ document: FinanceDocument,
        month: MonthKey? = nil,
        asOf iso: String = "2026-09-15",
        compare: Bool = false,
        coverage: ReviewCoverageInput? = nil,
        natures: [String: ReviewSpendingNature] = [:],
        incomeClasses: [String: ReviewIncomeClass] = [:],
        economicSources: [String: String] = [:],
        categoryKeys: [String: String] = [:],
        policy: ReviewFindingPolicy = .standard,
        horizon: String? = nil
    ) -> ReviewRequest {
        let month = month ?? september
        let interval = ReviewInterval.month(month)
        return ReviewRequest(
            document: document,
            kind: .monthly,
            interval: interval,
            asOf: day(iso),
            categoryKeys: categoryKeys,
            comparePreviousPeriod: compare,
            coverage: coverage ?? liveCovering(interval),
            spendingNatures: natures,
            incomeClasses: incomeClasses,
            economicSources: economicSources,
            findingPolicy: policy,
            forecastHorizonEnd: horizon.map(self.day)
        )
    }

    private func weeklyRequest(
        _ document: FinanceDocument,
        starting iso: String,
        asOf: String,
        coverage: ReviewCoverageInput? = nil,
        categoryKeys: [String: String] = [:],
        compare: Bool = false
    ) throws -> ReviewRequest {
        let interval = try XCTUnwrap(ReviewInterval.weekStarting(day(iso)))
        return ReviewRequest(
            document: document,
            kind: .weekly,
            interval: interval,
            asOf: day(asOf),
            categoryKeys: categoryKeys,
            comparePreviousPeriod: compare,
            coverage: coverage ?? liveCovering(interval)
        )
    }

    private func review(_ request: ReviewRequest) throws -> ReviewResult {
        try ReviewEngine.review(request)
    }

    private func obligation(
        _ id: String,
        amount: String,
        onDay: Int,
        month: MonthKey? = nil
    ) -> RecurringObligation {
        let month = month ?? september
        return RecurringObligation(
            id: id,
            name: id,
            amount: euro(amount),
            spec: .monthly(onDay: onDay, from: month, through: month),
            requirement: .euroBankPayment(),
            spendingClass: .essential,
            budgetID: nil
        )
    }

    /// The archive row fixture states its own currency identity.
    ///
    /// `currency`/`currencyExponent` default to EUR/2 so every existing case is
    /// unchanged, and `bookedEUR` is a double optional on purpose: omitted it
    /// mirrors `originalCents` as before, `.some(nil)` states a row with **no**
    /// booked euro figure, and `.some(x)` states one explicitly.
    private func historyRecord(
        id: String,
        date: String,
        originalCents: Int64,
        economicEUR: Int64?,
        personalEUR: Int64? = nil,
        economicType: String,
        currency: String = "EUR",
        currencyExponent: Int = 2,
        bookedEUR: Int64?? = nil,
        internalTransfer: Bool = false,
        financing: Bool = false,
        passThrough: FinanceHistoryPassThrough = .none,
        unresolved: String? = nil,
        economicSource: String? = nil
    ) -> FinanceHistoricalRecord {
        FinanceHistoricalRecord(
            historicalID: id,
            date: day(date),
            accountID: "bank",
            provider: "BNP",
            rail: "CARD",
            description: id,
            originalAmount: FinanceHistoryOriginalAmount(
                cents: originalCents, currency: currency, currencyExponent: currencyExponent
            ),
            bookedAmountEURCents: bookedEUR ?? originalCents,
            economicAmountEURCents: economicEUR,
            personalAmountEURCents: personalEUR,
            category: FinanceHistoryCategory(top: "TEST"),
            economicType: economicType,
            economicSource: economicSource,
            status: "BOOKED_EUR",
            provenance: "DIRECTLY_OBSERVED",
            confidence: "high",
            flags: FinanceHistoryFlags(
                internalTransfer: internalTransfer,
                passThrough: passThrough,
                financingLeg: financing
            ),
            economicViewRole: internalTransfer ? "PLUMBING" : "PRIMARY",
            evidence: FinanceHistoryEvidence(
                ruleID: "T",
                basis: "test",
                unresolvedReason: unresolved
            )
        )
    }

    private func historyDocument(
        cutoff: String,
        records: [FinanceHistoricalRecord],
        gaps: [FinanceHistorySourceGap] = [],
        rangeStart: String? = nil,
        rangeEnd: String? = nil
    ) -> FinanceHistoryDocument {
        let dates = records.map(\.date)
        let start = rangeStart.map(day) ?? dates.min() ?? day(cutoff)
        let end = rangeEnd.map(day) ?? dates.max() ?? day(cutoff)
        return FinanceHistoryDocument(
            schemaVersion: "1.1.0",
            documentKind: "TEST",
            archiveID: "test-archive",
            sourceRevision: "0",
            contentSHA256: "0",
            payload: FinanceHistoryPayload(
                archiveCutoff: day(cutoff),
                recordCount: records.count,
                dateRange: FinanceHistoryDateRange(start: start, end: end),
                accounts: [FinanceHistoryAccount(id: "bank", name: "Bank", provider: "BNP")],
                sourceGaps: gaps,
                records: records
            )
        )
    }

    private func septemberContext(_ result: ReviewResult) -> ReviewMonthlyBudgetContext {
        let match = result.budget.monthlyContexts.first { $0.month == september }
        XCTAssertNotNil(match)
        return match!
    }

    // MARK: - Periods

    func testWeeklyIntervalIsSevenInclusiveDaysAndPreviousIsThePriorWeek() throws {
        let week = try XCTUnwrap(ReviewInterval.weekStarting(day("2026-09-07")))
        XCTAssertEqual(week.start, day("2026-09-07"))
        XCTAssertEqual(week.end, day("2026-09-13"))
        XCTAssertEqual(week.dayCount, 7)
        let prior = try XCTUnwrap(week.previous(kind: .weekly))
        XCTAssertEqual(prior.start, day("2026-08-31"))
        XCTAssertEqual(prior.end, day("2026-09-06"))
        XCTAssertEqual(prior.dayCount, 7)
    }

    func testMonthlyIntervalIsTheCalendarMonthAndPreviousIsThePriorMonth() throws {
        let month = ReviewInterval.month(september)
        XCTAssertEqual(month.start, day("2026-09-01"))
        XCTAssertEqual(month.end, day("2026-09-30"))
        let prior = try XCTUnwrap(month.previous(kind: .monthly))
        XCTAssertEqual(prior.start, day("2026-08-01"))
        XCTAssertEqual(prior.end, day("2026-08-31"))
    }

    // MARK: - Clean / over budget

    func testCleanUnderBudgetMonth() throws {
        let result = try review(
            try monthlyRequest(
                document(
                    transactions: [expense("food", "40.00", on: "2026-09-04")],
                    budgets: [budget("groceries", "70.00", categoryKeys: ["food"])],
                    ceiling: euro("700.00")
                ),
                categoryKeys: ["food": "food"]
            )
        )
        XCTAssertEqual(result.coverage.status, .complete)
        XCTAssertEqual(result.totals.netEconomicSpending, euro("40.00"))
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("40.00"))
        XCTAssertEqual(result.budget.monthlyContexts.count, 1)
        let month = septemberContext(result)
        XCTAssertEqual(month.monthSpending, euro("40.00"))
        XCTAssertEqual(month.ceiling, euro("700.00"))
        XCTAssertEqual(month.remaining, euro("660.00"))
        XCTAssertEqual(month.overage, euro("0.00"))
        XCTAssertFalse(result.findings.contains { $0.kind == .budgetOverrun })
    }

    func testOverBudgetMonth() throws {
        let result = try review(
            try monthlyRequest(
                document(
                    transactions: [expense("big", "800.00", on: "2026-09-04")],
                    ceiling: euro("700.00")
                )
            )
        )
        let month = septemberContext(result)
        XCTAssertEqual(month.monthSpending, euro("800.00"))
        XCTAssertEqual(month.overage, euro("100.00"))
        XCTAssertEqual(month.remaining, euro("-100.00"))
        XCTAssertTrue(result.findings.contains { $0.kind == .budgetOverrun })
        XCTAssertEqual(result.findings.first { $0.kind == .budgetOverrun }?.severity, .important)
    }

    // MARK: - Cross-month weekly budgets

    func testWeekEntirelyInOneMonthHasOneBudgetContext() throws {
        let result = try review(
            try weeklyRequest(
                document(transactions: [expense("food", "30.00", on: "2026-09-08")]),
                starting: "2026-09-07",
                asOf: "2026-09-13"
            )
        )
        XCTAssertEqual(result.interval.monthKeys, [september])
        XCTAssertEqual(result.budget.monthlyContexts.map(\.month), [september])
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("30.00"))
        XCTAssertEqual(result.budget.monthlyContexts[0].periodSpendingInMonth, euro("30.00"))
    }

    func testWeekCrossingMonthBoundaryHasTwoMonthlyContexts() throws {
        let result = try review(
            try weeklyRequest(
                document(
                    transactions: [
                        expense("aug", "10.00", on: "2026-08-29"),
                        expense("sep", "20.00", on: "2026-09-04"),
                    ]
                ),
                starting: "2026-08-29",
                asOf: "2026-09-04"
            )
        )
        XCTAssertEqual(result.interval.start, day("2026-08-29"))
        XCTAssertEqual(result.interval.end, day("2026-09-04"))
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("30.00"))
        XCTAssertEqual(result.budget.monthlyContexts.map(\.month), [august, september])
        XCTAssertEqual(result.budget.monthlyContexts[0].periodSpendingInMonth, euro("10.00"))
        XCTAssertEqual(result.budget.monthlyContexts[1].periodSpendingInMonth, euro("20.00"))
        XCTAssertEqual(result.budget.monthlyContexts[0].intervalInMonth.end, day("2026-08-31"))
        XCTAssertEqual(result.budget.monthlyContexts[1].intervalInMonth.start, day("2026-09-01"))
        XCTAssertEqual(result.budget.monthlyContexts[1].monthSpending, euro("20.00"))
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("30.00"))
    }

    func testCrossMonthWeekUsesEachMonthBudgetDefinitionAndAssignsSpendingToTheCorrectMonth() throws {
        let groceries = budget(
            "groceries",
            "50.00",
            categoryKeys: ["food"],
            overrides: [september: euro("100.00")]
        )
        let result = try review(
            try weeklyRequest(
                document(
                    transactions: [
                        expense("aug-food", "12.00", on: "2026-08-30"),
                        expense("sep-food", "18.00", on: "2026-09-02"),
                    ],
                    budgets: [groceries],
                    ceiling: euro("700.00")
                ),
                starting: "2026-08-29",
                asOf: "2026-09-04",
                categoryKeys: ["aug-food": "food", "sep-food": "food"]
            )
        )
        XCTAssertEqual(result.budget.monthlyContexts.count, 2)
        let aug = result.budget.monthlyContexts[0]
        let sep = result.budget.monthlyContexts[1]
        XCTAssertEqual(aug.lines.first?.target, euro("50.00"))
        XCTAssertEqual(sep.lines.first?.target, euro("100.00"))
        XCTAssertEqual(aug.lines.first?.periodSpent, euro("12.00"))
        XCTAssertEqual(sep.lines.first?.periodSpent, euro("18.00"))
        XCTAssertEqual(aug.periodSpendingInMonth, euro("12.00"))
        XCTAssertEqual(sep.periodSpendingInMonth, euro("18.00"))
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("30.00"))
        XCTAssertEqual(aug.monthSpending, euro("12.00"))
        XCTAssertEqual(sep.monthSpending, euro("18.00"))
        XCTAssertEqual(aug.remaining, euro("688.00"))
        XCTAssertEqual(sep.remaining, euro("682.00"))
    }

    // MARK: - Economic exclusions

    func testTransferExcluded() throws {
        let transfer = Transaction(
            id: "mv", date: day("2026-09-05"), kind: .transfer,
            legs: [
                AccountLeg(accountID: "bank", amount: euro("-120.00")),
                AccountLeg(accountID: "wallet", amount: euro("120.00")),
            ],
            factivity: .observed
        )
        let result = try review(try monthlyRequest(document(transactions: [transfer, expense("x", "10.00", on: "2026-09-06")])))
        XCTAssertEqual(result.totals.netEconomicSpending, euro("10.00"))
        XCTAssertEqual(result.totals.internalTransfers, euro("120.00"))
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("10.00"))
    }

    func testWithdrawalExcluded() throws {
        let withdrawal = Transaction(
            id: "atm", date: day("2026-09-06"), kind: .cashWithdrawal,
            legs: [
                AccountLeg(accountID: "bank", amount: euro("-40.00")),
                AccountLeg(accountID: "cash", amount: euro("40.00")),
            ],
            factivity: .observed
        )
        let result = try review(try monthlyRequest(document(transactions: [withdrawal])))
        XCTAssertEqual(result.totals.netEconomicSpending, euro("0.00"))
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("0.00"))
        XCTAssertEqual(result.income.internalMovement, euro("40.00"))
    }

    func testRefundReversesSpendingAndIsNeverIncome() throws {
        let purchase = expense("p", "21.99", on: "2026-09-02")
        let refund = Transaction(
            id: "r", date: day("2026-09-08"), kind: .refund,
            legs: [AccountLeg(accountID: "bank", amount: euro("21.99"))],
            linkedTransactionID: "p",
            factivity: .observed
        )
        let result = try review(try monthlyRequest(document(transactions: [purchase, refund])))
        XCTAssertEqual(result.totals.economicSpending, euro("21.99"))
        XCTAssertEqual(result.totals.refunds, euro("21.99"))
        XCTAssertEqual(result.totals.netEconomicSpending, euro("0.00"))
        XCTAssertEqual(result.totals.personalIncome, euro("0.00"))
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("0.00"))
    }

    // MARK: - Contributions (the records behind a figure)

    // A screen that lists "the transactions behind this number" is only
    // honest if the list adds up to the number. These pin that the exposed
    // contributions are exactly the rows the totals summed: refunds included
    // as negatives, account movement never, zero rows never.

    private func sum(_ rows: [ReviewSpendingDriver]) -> Money {
        Money(minorUnits: rows.reduce(Int64(0)) { $0 + $1.amount.minorUnits }, currency: .eur)
    }

    private func assertLinesReconcile(_ result: ReviewResult, file: StaticString = #filePath, line: UInt = #line) {
        for context in result.budget.monthlyContexts {
            XCTAssertEqual(sum(context.contributions), context.monthSpending,
                           "month \(context.month.isoString)", file: file, line: line)
            for budgetLine in context.lines {
                let rows = result.budget.contributions.filter {
                    $0.budgetID == budgetLine.id && context.intervalInMonth.contains($0.date)
                }
                XCTAssertEqual(sum(rows), budgetLine.periodSpent,
                               "line \(budgetLine.id) in \(context.month.isoString)", file: file, line: line)
            }
        }
    }

    func testContributionsAreExactlyTheRowsBehindEveryFigure() throws {
        let partialRefund = Transaction(
            id: "g2-refund", date: day("2026-09-08"), kind: .refund,
            legs: [AccountLeg(accountID: "bank", amount: euro("5.00"))],
            linkedTransactionID: "g2",
            factivity: .observed
        )
        let transfer = Transaction(
            id: "move", date: day("2026-09-04"), kind: .transfer,
            legs: [
                AccountLeg(accountID: "bank", amount: euro("-120.00")),
                AccountLeg(accountID: "wallet", amount: euro("120.00")),
            ],
            factivity: .observed
        )
        let withdrawal = Transaction(
            id: "atm", date: day("2026-09-09"), kind: .cashWithdrawal,
            legs: [
                AccountLeg(accountID: "bank", amount: euro("-40.00")),
                AccountLeg(accountID: "cash", amount: euro("40.00")),
            ],
            factivity: .observed
        )
        let doc = document(
            transactions: [
                expense("g1", "30.00", on: "2026-09-02"),
                expense("g2", "20.00", on: "2026-09-05"),
                expense("t1", "15.00", on: "2026-09-06"),
                expense("u1", "7.00", on: "2026-09-07"),
                partialRefund, transfer, withdrawal,
            ],
            budgets: [
                budget("groceries", "200.00", categoryKeys: ["groceries"]),
                budget("transport", "80.00", categoryKeys: ["transport"]),
            ]
        )
        let result = try review(monthlyRequest(
            doc,
            categoryKeys: ["g1": "groceries", "g2": "groceries", "g2-refund": "groceries",
                           "t1": "transport"]
        ))

        let contributions = result.budget.contributions
        XCTAssertEqual(sum(contributions), result.budget.periodEconomicSpending)
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("67.00"))
        XCTAssertEqual(contributions.first { $0.id == "g2-refund" }?.amount, euro("-5.00"))
        XCTAssertFalse(contributions.contains { $0.id == "move" || $0.id == "atm" })
        XCTAssertFalse(contributions.contains { $0.amount.minorUnits == 0 })
        XCTAssertEqual(contributions.map(\.date), contributions.map(\.date).sorted())
        assertLinesReconcile(result)
    }

    func testMonthContributionsCoverTheWholeMonthWhileThePeriodCoversTheWeek() throws {
        let doc = document(
            transactions: [
                expense("aug-early", "11.00", on: "2026-08-10"),
                expense("aug-in-week", "13.00", on: "2026-08-31"),
                expense("sep-in-week", "17.00", on: "2026-09-02"),
                expense("sep-late", "19.00", on: "2026-09-20"),
            ],
            budgets: [budget("food", "300.00", categoryKeys: ["food"])],
            asOf: "2026-09-25"
        )
        let request = try weeklyRequest(
            doc, starting: "2026-08-31", asOf: "2026-09-25",
            coverage: liveCovering(ReviewInterval(start: day("2026-08-01"), end: day("2026-09-30"))),
            categoryKeys: ["aug-early": "food", "aug-in-week": "food",
                           "sep-in-week": "food", "sep-late": "food"]
        )
        let result = try review(request)

        XCTAssertEqual(Set(result.budget.contributions.map(\.id)), ["aug-in-week", "sep-in-week"])
        XCTAssertEqual(sum(result.budget.contributions), result.budget.periodEconomicSpending)
        let august = try XCTUnwrap(result.budget.monthlyContexts.first { $0.month == self.august })
        XCTAssertEqual(Set(august.contributions.map(\.id)), ["aug-early", "aug-in-week"])
        let september = try XCTUnwrap(result.budget.monthlyContexts.first { $0.month == self.september })
        XCTAssertEqual(Set(september.contributions.map(\.id)), ["sep-in-week", "sep-late"])
        assertLinesReconcile(result)
    }

    func testAFullyRefundedPurchaseListsNoZeroRow() throws {
        let purchase = expense("p", "21.99", on: "2026-09-02")
        let refund = Transaction(
            id: "r", date: day("2026-09-08"), kind: .refund,
            legs: [AccountLeg(accountID: "bank", amount: euro("21.99"))],
            linkedTransactionID: "p",
            factivity: .observed
        )
        let result = try review(monthlyRequest(document(transactions: [purchase, refund])))
        XCTAssertEqual(sum(result.budget.contributions), result.budget.periodEconomicSpending)
        XCTAssertFalse(result.budget.contributions.contains { $0.amount.minorUnits == 0 })
        assertLinesReconcile(result)
    }

    // MARK: - History EUR valuation (Debt B)

    // `classifyHistory` used to reach for `originalAmount.cents` whenever the
    // euro field it wanted was absent, which read a foreign row's minor units
    // as euro cents. One site guarded the code but not the exponent, so a
    // FinanceHistory 2.0.0 EUR/3 row walked straight through it. Euro minor
    // units are now only ever taken from a role's own authoritative field, or
    // from an original that is already EUR/2.

    private func historyRequest(
        _ records: [FinanceHistoricalRecord],
        cutoff: String = "2026-09-30",
        document doc: FinanceDocument? = nil
    ) -> ReviewRequest {
        let interval = ReviewInterval.month(september)
        return ReviewRequest(
            document: doc ?? document(),
            kind: .monthly,
            interval: interval,
            asOf: day("2026-09-15"),
            coverage: .liveCovered(
                [interval], cutoff: day(cutoff),
                history: historyDocument(cutoff: cutoff, records: records)
            )
        )
    }

    private func unresolvedIDs(_ result: ReviewResult) -> [String] {
        result.findings
            .filter { $0.kind == .unresolvedEvidenceAffectingAccuracy }
            .flatMap(\.ids)
    }

    private func assertUnresolved(
        _ result: ReviewResult, _ id: String, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(
            unresolvedIDs(result).contains(id),
            "\(label): \(id) must be declared through unresolvedEvidenceAffectingAccuracy, "
                + "got \(unresolvedIDs(result))",
            file: file, line: line
        )
    }

    func testH1EURSpendingRowIsUnchanged() throws {
        let result = try review(historyRequest([
            historyRecord(id: "h1", date: "2026-09-05", originalCents: -4000,
                          economicEUR: -4000, economicType: "SPENDING"),
        ]))
        XCTAssertEqual(result.totals.economicSpending, euro("40.00"))
        XCTAssertEqual(result.totals.netEconomicSpending, euro("40.00"))
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("40.00"))
        XCTAssertFalse(unresolvedIDs(result).contains("h1"))
        assertTotalsAlgebra(result, "H1")
    }

    /// H2 — a gross/booked role uses the booked euro figure. The USD minor
    /// units must never surface as euros.
    func testH2ForeignPassThroughUsesBookedEUR() throws {
        let result = try review(historyRequest([
            historyRecord(id: "h2", date: "2026-09-05", originalCents: 30000,
                          economicEUR: nil, personalEUR: 5000,
                          economicType: "INCOME", currency: "USD", bookedEUR: .some(27000),
                          passThrough: .partial),
        ]))
        XCTAssertEqual(result.income.passThroughGross, euro("270.00"))
        XCTAssertEqual(result.income.personalIncome, euro("50.00"))
        XCTAssertEqual(result.totals.passThroughNotMine, euro("220.00"))
        XCTAssertNotEqual(result.income.passThroughGross, euro("300.00"))
    }

    /// H3 — economic roles take the economic euro amount and nothing else.
    func testH3ForeignEconomicRolesUseEconomicEUR() throws {
        let spending = try review(historyRequest([
            historyRecord(id: "s", date: "2026-09-05", originalCents: -12345,
                          economicEUR: -1000, economicType: "SPENDING",
                          currency: "USD", bookedEUR: .some(-11000)),
        ]))
        XCTAssertEqual(spending.totals.economicSpending, euro("10.00"))

        let refund = try review(historyRequest([
            historyRecord(id: "r", date: "2026-09-05", originalCents: 12345,
                          economicEUR: 1000, economicType: "REFUND",
                          currency: "USD", bookedEUR: .some(11000)),
        ]))
        XCTAssertEqual(refund.totals.refunds, euro("10.00"))
        XCTAssertEqual(refund.totals.netEconomicSpending, euro("-10.00"))

        let financing = try review(historyRequest([
            historyRecord(id: "f", date: "2026-09-05", originalCents: -12345,
                          economicEUR: -1000, economicType: "FINANCING_REPAYMENT",
                          currency: "USD", bookedEUR: .some(-11000), financing: true),
        ]))
        XCTAssertEqual(financing.totals.financingRepayments, euro("10.00"))

        let transfer = try review(historyRequest([
            historyRecord(id: "t", date: "2026-09-05", originalCents: -12345,
                          economicEUR: -1000, economicType: "TRANSFER",
                          currency: "USD", bookedEUR: .some(-11000)),
        ]))
        XCTAssertEqual(transfer.totals.internalTransfers, euro("10.00"))
    }

    /// H3b — the owned role takes the personal euro amount.
    func testH3bForeignOwnedRoleUsesPersonalEUR() throws {
        let result = try review(historyRequest([
            historyRecord(id: "h3b", date: "2026-09-05", originalCents: 30000,
                          economicEUR: 27000, personalEUR: 5000,
                          economicType: "INCOME", currency: "USD", bookedEUR: .some(27000),
                          economicSource: "EARNED_EMPLOYMENT"),
        ]))
        XCTAssertEqual(result.income.personalIncome, euro("50.00"))
        XCTAssertNotEqual(result.income.personalIncome, euro("300.00"))
    }

    /// H4 — a foreign row with no euro amount at all contributes nothing *and*
    /// says so. The zero and the finding are one behaviour, not two.
    func testH4ForeignRowWithoutAnyEURIsZeroAndDeclared() throws {
        let result = try review(historyRequest([
            historyRecord(id: "h4", date: "2026-09-05", originalCents: 12345,
                          economicEUR: nil, economicType: "SPENDING",
                          currency: "USD", bookedEUR: .some(nil)),
        ]))
        XCTAssertEqual(result.totals.economicSpending, euro("0.00"))
        XCTAssertEqual(result.totals.netEconomicSpending, euro("0.00"))
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("0.00"))
        assertUnresolved(result, "h4", "H4")
        assertTotalsAlgebra(result, "H4")
    }

    /// H5 — JPY/0 minor units are whole yen. 100 of them is not €1.00.
    func testH5JPYZeroExponentIsNeverEuroCents() throws {
        let result = try review(historyRequest([
            historyRecord(id: "h5", date: "2026-09-05", originalCents: -100,
                          economicEUR: nil, economicType: "SPENDING",
                          currency: "JPY", currencyExponent: 0, bookedEUR: .some(nil)),
        ]))
        XCTAssertEqual(result.totals.economicSpending, euro("0.00"))
        XCTAssertNotEqual(result.totals.economicSpending, euro("1.00"))
        assertUnresolved(result, "h5", "H5")
    }

    /// H6 — KWD/3 minor units are thousandths. 100 of them is not €1.00.
    func testH6KWDThreeExponentIsNeverEuroCents() throws {
        let result = try review(historyRequest([
            historyRecord(id: "h6", date: "2026-09-05", originalCents: -100,
                          economicEUR: nil, economicType: "SPENDING",
                          currency: "KWD", currencyExponent: 3, bookedEUR: .some(nil)),
        ]))
        XCTAssertEqual(result.totals.economicSpending, euro("0.00"))
        XCTAssertNotEqual(result.totals.economicSpending, euro("1.00"))
        assertUnresolved(result, "h6", "H6")
    }

    /// H7 — a foreign refund with no economic euro amount refunds nothing.
    func testH7ForeignRefundWithoutEconomicEURRefundsNothing() throws {
        let result = try review(historyRequest([
            historyRecord(id: "h7", date: "2026-09-05", originalCents: 12345,
                          economicEUR: nil, economicType: "REFUND",
                          currency: "USD", bookedEUR: .some(nil)),
        ]))
        XCTAssertEqual(result.totals.refunds, euro("0.00"))
        XCTAssertEqual(result.totals.netEconomicSpending, euro("0.00"))
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("0.00"))
        assertUnresolved(result, "h7", "H7")
        assertTotalsAlgebra(result, "H7")
    }

    /// H8 — a EUR/2 internal transfer with no booked figure keeps reading its
    /// own original, exactly as before.
    func testH8EURInternalTransferStillReadsItsOriginal() throws {
        let result = try review(historyRequest([
            historyRecord(id: "h8", date: "2026-09-05", originalCents: -12000,
                          economicEUR: nil, economicType: "INTERNAL_TRANSFER",
                          bookedEUR: .some(nil), internalTransfer: true),
        ]))
        XCTAssertEqual(result.totals.internalTransfers, euro("120.00"))
        XCTAssertFalse(unresolvedIDs(result).contains("h8"))
    }

    /// H8b — the exponent hole FinanceHistory 2.0.0 opened. The old guard
    /// checked the code alone, so a EUR/3 original walked through it and 1000
    /// thousandths became €10.00. It is €1.00 and the archive never said so.
    func testH8bEURThreeExponentInternalTransferIsNotEuroCents() throws {
        let result = try review(historyRequest([
            historyRecord(id: "h8b", date: "2026-09-05", originalCents: 1000,
                          economicEUR: nil, economicType: "INTERNAL_TRANSFER",
                          currencyExponent: 3, bookedEUR: .some(nil), internalTransfer: true),
        ]))
        XCTAssertEqual(result.totals.internalTransfers, euro("0.00"))
        XCTAssertNotEqual(result.totals.internalTransfers, euro("10.00"))
        assertUnresolved(result, "h8b", "H8b")
    }

    /// H11 — every role that once fell back to the original refuses a foreign
    /// one, not just the refund branch. Each case below is the exact shape that
    /// a restored `?? originalAmount.cents` would silently value in euros.
    func testH11EachRoleRefusesAForeignOriginalWhenItsAuthorityIsAbsent() throws {
        // Pass-through gross: no booked euro figure to stand on.
        let passThrough = try review(historyRequest([
            historyRecord(id: "pt", date: "2026-09-05", originalCents: 30000,
                          economicEUR: nil, economicType: "INCOME",
                          currency: "USD", bookedEUR: .some(nil), passThrough: .partial),
        ]))
        XCTAssertEqual(passThrough.income.passThroughGross, euro("0.00"))
        XCTAssertEqual(passThrough.totals.passThroughNotMine, euro("0.00"))
        assertUnresolved(passThrough, "pt", "H11 pass-through gross")

        // Economic internal movement: no economic euro amount.
        let movement = try review(historyRequest([
            historyRecord(id: "mv", date: "2026-09-05", originalCents: -12345,
                          economicEUR: nil, economicType: "TOPUP",
                          currency: "USD", bookedEUR: .some(nil)),
        ]))
        XCTAssertEqual(movement.totals.internalTransfers, euro("0.00"))
        assertUnresolved(movement, "mv", "H11 economic movement")

        // Income gross-in: personal states what is mine, but nothing states the
        // gross, so the gross stays unvalued while the owned part survives.
        let income = try review(historyRequest([
            historyRecord(id: "in", date: "2026-09-05", originalCents: 30000,
                          economicEUR: nil, personalEUR: 5000, economicType: "INCOME",
                          currency: "USD", bookedEUR: .some(nil),
                          economicSource: "PARENTAL_SUPPORT_SELF"),
        ]))
        XCTAssertEqual(income.income.personalIncome, euro("50.00"))
        XCTAssertEqual(income.income.parentalSupportOwned, euro("50.00"))
        XCTAssertEqual(income.income.parentalSupportGross, euro("0.00"))
        assertUnresolved(income, "in", "H11 income gross-in")

        // Financing: economic only, no original anywhere.
        let financing = try review(historyRequest([
            historyRecord(id: "fin", date: "2026-09-05", originalCents: -12345,
                          economicEUR: nil, economicType: "FINANCING_REPAYMENT",
                          currency: "USD", bookedEUR: .some(nil), financing: true),
        ]))
        XCTAssertEqual(financing.totals.financingRepayments, euro("0.00"))
        assertUnresolved(financing, "fin", "H11 financing")

        // Flagged internal transfer: booked or an EUR/2 original, neither here.
        let transfer = try review(historyRequest([
            historyRecord(id: "it", date: "2026-09-05", originalCents: -12345,
                          economicEUR: nil, economicType: "INTERNAL_TRANSFER",
                          currency: "USD", bookedEUR: .some(nil), internalTransfer: true),
        ]))
        XCTAssertEqual(transfer.totals.internalTransfers, euro("0.00"))
        assertUnresolved(transfer, "it", "H11 flagged internal transfer")
    }

    /// H9 — end to end: unvaluable rows are excluded from every total and every
    /// one of their ids is named by the finding, with the algebra still intact.
    func testH9UnvaluedHistoryIsExcludedAndFullyDeclared() throws {
        let result = try review(historyRequest([
            historyRecord(id: "h4", date: "2026-09-05", originalCents: 12345,
                          economicEUR: nil, economicType: "SPENDING",
                          currency: "USD", bookedEUR: .some(nil)),
            historyRecord(id: "h5", date: "2026-09-06", originalCents: -100,
                          economicEUR: nil, economicType: "SPENDING",
                          currency: "JPY", currencyExponent: 0, bookedEUR: .some(nil)),
            historyRecord(id: "h6", date: "2026-09-07", originalCents: -100,
                          economicEUR: nil, economicType: "SPENDING",
                          currency: "KWD", currencyExponent: 3, bookedEUR: .some(nil)),
            historyRecord(id: "h7", date: "2026-09-08", originalCents: 12345,
                          economicEUR: nil, economicType: "REFUND",
                          currency: "USD", bookedEUR: .some(nil)),
            historyRecord(id: "ok", date: "2026-09-09", originalCents: -2500,
                          economicEUR: -2500, economicType: "SPENDING"),
        ]))
        XCTAssertEqual(result.totals.economicSpending, euro("25.00"))
        XCTAssertEqual(result.totals.refunds, euro("0.00"))
        XCTAssertEqual(result.totals.netEconomicSpending, euro("25.00"))
        for id in ["h4", "h5", "h6", "h7"] { assertUnresolved(result, id, "H9") }
        XCTAssertFalse(unresolvedIDs(result).contains("ok"))
        assertTotalsAlgebra(result, "H9")
    }

    /// H10 — booked euros are not economic meaning. A EUR/2 spending row whose
    /// economic amount is absent stays unvalued even though booked is right
    /// there, because promoting it would invent an economic judgement the
    /// archive never made.
    func testH10BookedIsNeverPromotedIntoEconomicMeaning() throws {
        let result = try review(historyRequest([
            historyRecord(id: "h10", date: "2026-09-05", originalCents: -4000,
                          economicEUR: nil, economicType: "SPENDING",
                          bookedEUR: .some(-4000)),
        ]))
        XCTAssertEqual(result.totals.economicSpending, euro("0.00"))
        XCTAssertEqual(result.totals.netEconomicSpending, euro("0.00"))
        assertUnresolved(result, "h10", "H10")
        assertTotalsAlgebra(result, "H10")
    }

    // MARK: - Independent history personal authority (H12–H14)

    /// These ownership boundaries must be reachable from a valid V2 archive,
    /// including foreign originals and explicit non-2 EUR exponents.
    private func validatedHistoryRequest(_ records: [FinanceHistoricalRecord]) throws -> ReviewRequest {
        let cutoff = "2026-09-30"
        let payload = historyDocument(cutoff: cutoff, records: records).payload
        let archive = try FinanceHistoryInterchange.make(
            archiveID: "personal-authority-test", sourceRevision: "synthetic", payload: payload
        )
        var request = historyRequest(records, cutoff: cutoff)
        // Isolate valuation findings from missing-day coverage: the review
        // covers exactly the date range this validated archive establishes.
        request.interval = ReviewInterval(start: payload.dateRange.start, end: payload.dateRange.end)
        request.coverage = .liveCovered([request.interval], cutoff: day(cutoff), history: archive)
        return request
    }

    private func assertPassThroughAuthority(
        _ id: String, booked: Int64?, personal: Int64?,
        gross: Int64, owned: Int64, notMine: Int64, unresolved: Bool,
        currency: String = "USD", exponent: Int = 2,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for flag: FinanceHistoryPassThrough in [.full, .partial] {
            let result = try review(validatedHistoryRequest([
                historyRecord(
                    id: id, date: "2026-09-05", originalCents: 30000,
                    economicEUR: nil, personalEUR: personal, economicType: "INCOME",
                    currency: currency, currencyExponent: exponent, bookedEUR: .some(booked),
                    passThrough: flag
                ),
            ]))
            XCTAssertEqual(result.income.passThroughGross.minorUnits, gross, file: file, line: line)
            XCTAssertEqual(result.income.passThroughOwned.minorUnits, owned, file: file, line: line)
            XCTAssertEqual(result.income.personalIncome.minorUnits, owned, file: file, line: line)
            XCTAssertEqual(result.totals.personalIncome.minorUnits, owned, file: file, line: line)
            XCTAssertEqual(result.totals.passThroughNotMine.minorUnits, notMine, file: file, line: line)
            XCTAssertEqual(unresolvedIDs(result), unresolved ? [id] : [], file: file, line: line)
            assertTotalsAlgebra(result, id, file: file, line: line)
        }
    }

    func testH12aPassThroughPreservesPersonalWithoutGross() throws {
        for (currency, exponent) in [("USD", 2), ("JPY", 0), ("KWD", 3), ("EUR", 0), ("EUR", 3), ("EUR", 4)] {
            try assertPassThroughAuthority(
                "h12a", booked: nil, personal: 5000,
                gross: 0, owned: 5000, notMine: 0, unresolved: true,
                currency: currency, exponent: exponent
            )
        }
    }

    func testH12bPassThroughPreservesGrossWithoutPersonal() throws {
        try assertPassThroughAuthority(
            "h12b", booked: 10000, personal: nil,
            gross: 10000, owned: 0, notMine: 10000, unresolved: true
        )
    }

    func testH12cPassThroughExplicitPersonalZeroIsKnown() throws {
        try assertPassThroughAuthority(
            "h12c", booked: 10000, personal: 0,
            gross: 10000, owned: 0, notMine: 10000, unresolved: false
        )
    }

    func testH12dPassThroughBothAuthoritiesAbsentIsUnresolved() throws {
        try assertPassThroughAuthority(
            "h12d", booked: nil, personal: nil,
            gross: 0, owned: 0, notMine: 0, unresolved: true
        )
    }

    func testH12ePassThroughPreservesBothAuthorities() throws {
        try assertPassThroughAuthority(
            "h12e", booked: 10000, personal: 3000,
            gross: 10000, owned: 3000, notMine: 7000, unresolved: false
        )
    }

    private func assertMappedIncomeAuthority(
        _ id: String, personal: Int64?, expectedPersonal: Int64, unresolved: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for source in ["PARENTAL_SUPPORT_SELF", "EARNED_EMPLOYMENT", "SHARED_EXPENSE_REIMBURSEMENT",
                       "UNRESOLVED_INCOMING", "PASS_THROUGH_OTHER"] {
            let result = try review(validatedHistoryRequest([
                historyRecord(
                    id: id, date: "2026-09-05", originalCents: 30000,
                    economicEUR: 27000, personalEUR: personal, economicType: "INCOME",
                    currency: "USD", bookedEUR: .some(27000), economicSource: source
                ),
            ]))
            XCTAssertEqual(result.income.personalIncome.minorUnits, expectedPersonal, file: file, line: line)
            XCTAssertEqual(result.totals.personalIncome.minorUnits, expectedPersonal, file: file, line: line)
            switch source {
            case "PARENTAL_SUPPORT_SELF":
                XCTAssertEqual(result.income.parentalSupportGross.minorUnits, 27000, file: file, line: line)
                XCTAssertEqual(result.income.parentalSupportOwned.minorUnits, expectedPersonal, file: file, line: line)
            case "EARNED_EMPLOYMENT":
                XCTAssertEqual(result.income.earnedOrOther.minorUnits, expectedPersonal, file: file, line: line)
            case "SHARED_EXPENSE_REIMBURSEMENT":
                XCTAssertEqual(result.income.reimbursements.minorUnits, expectedPersonal, file: file, line: line)
            case "PASS_THROUGH_OTHER":
                XCTAssertEqual(result.income.passThroughGross.minorUnits, 27000, file: file, line: line)
                XCTAssertEqual(result.income.passThroughOwned.minorUnits, expectedPersonal, file: file, line: line)
            default:
                XCTAssertEqual(result.income.unresolved.minorUnits, expectedPersonal, file: file, line: line)
            }
            // Income has no spending/refund role. Economic EUR must not become
            // personal income or be forced into an unrelated economic output.
            XCTAssertEqual(result.totals.economicSpending.minorUnits, 0, file: file, line: line)
            XCTAssertEqual(result.totals.refunds.minorUnits, 0, file: file, line: line)
            XCTAssertEqual(unresolvedIDs(result), unresolved ? [id] : [], file: file, line: line)
            assertTotalsAlgebra(result, id, file: file, line: line)
        }
    }

    func testH13aMappedIncomeNeverPromotesEconomicIntoPersonal() throws {
        try assertMappedIncomeAuthority("h13a", personal: nil, expectedPersonal: 0, unresolved: true)
    }

    func testH13bMappedIncomePreservesPersonalAndGross() throws {
        try assertMappedIncomeAuthority("h13b", personal: 5000, expectedPersonal: 5000, unresolved: false)
    }

    func testH13cMappedIncomeExplicitPersonalZeroIsKnown() throws {
        try assertMappedIncomeAuthority("h13c", personal: 0, expectedPersonal: 0, unresolved: false)
    }

    private func assertPlainIncomeAuthority(
        _ id: String, personal: Int64?, expectedPersonal: Int64, unresolved: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let result = try review(validatedHistoryRequest([
            historyRecord(
                id: id, date: "2026-09-05", originalCents: 30000,
                economicEUR: 27000, personalEUR: personal, economicType: "INCOME",
                currency: "USD", bookedEUR: .some(27000)
            ),
        ]))
        XCTAssertEqual(result.income.personalIncome.minorUnits, expectedPersonal, file: file, line: line)
        XCTAssertEqual(result.totals.personalIncome.minorUnits, expectedPersonal, file: file, line: line)
        XCTAssertEqual(unresolvedIDs(result), unresolved ? [id] : [], file: file, line: line)
        assertTotalsAlgebra(result, id, file: file, line: line)
    }

    func testH14aPlainIncomeMissingPersonalIsUnresolved() throws {
        try assertPlainIncomeAuthority("h14a", personal: nil, expectedPersonal: 0, unresolved: true)
    }

    func testH14bPlainIncomePreservesPersonal() throws {
        try assertPlainIncomeAuthority("h14b", personal: 5000, expectedPersonal: 5000, unresolved: false)
    }

    func testH14cPlainIncomeExplicitPersonalZeroIsKnown() throws {
        try assertPlainIncomeAuthority("h14c", personal: 0, expectedPersonal: 0, unresolved: false)
    }

    /// The classifier is made safe here; wiring history into the product is a
    /// separate, unauthorised decision. Production still reviews without it.
    func testFinanceStoreStillReviewsWithoutHistory() throws {
        let interval = ReviewInterval.month(september)
        let request = ReviewRequest(
            document: document(transactions: [expense("p", "50.00", on: "2026-09-04")]),
            kind: .monthly,
            interval: interval,
            asOf: day("2026-09-15"),
            coverage: .liveCovered([interval])
        )
        XCTAssertNil(request.coverage.history)
        let result = try review(request)
        XCTAssertEqual(result.totals.netEconomicSpending, euro("50.00"))
    }

    // MARK: - Fail-closed history semantics

    /// Synthetic movement, valuation and ownership are deliberately independent
    /// of type. USD originals also prevent an implicit EUR-original authority.
    private func semanticRecord(
        _ id: String, type: String = "NEW_TYPE_2030", original: Int64 = 1200,
        booked: Int64? = 1000, economic: Int64? = 900, personal: Int64? = 700,
        source: String? = nil, internalTransfer: Bool = false,
        financing: Bool = false, passThrough: FinanceHistoryPassThrough = .none,
        reason: String? = nil
    ) -> FinanceHistoricalRecord {
        historyRecord(
            id: id, date: "2026-09-05", originalCents: original,
            economicEUR: economic, personalEUR: personal, economicType: type,
            currency: "USD", bookedEUR: .some(booked), internalTransfer: internalTransfer,
            financing: financing, passThrough: passThrough, unresolved: reason,
            economicSource: source
        )
    }

    /// Exercises both the validated V2 wire and the public review path. Every
    /// EUR total and income bucket is asserted, including unexpected spillover.
    private func assertHistorySemantics(
        _ record: FinanceHistoricalRecord,
        totals expectedTotals: [String: Int64] = [:],
        income expectedIncome: [String: Int64] = [:],
        unresolved: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        var request = try validatedHistoryRequest([record])
        let archive = try XCTUnwrap(request.coverage.history, file: file, line: line)
        XCTAssertEqual(archive.schemaVersion, "2.0.0", file: file, line: line)
        let decoded = try FinanceHistoryInterchange.decodeValidated(
            FinanceHistoryInterchange.encode(archive)
        )
        request.coverage = .liveCovered(
            [request.interval], cutoff: day("2026-09-30"), history: decoded
        )
        let result = try review(request)
        let totals = result.totals
        let income = result.income
        let totalValues = [
            "spending": totals.economicSpending, "refunds": totals.refunds,
            "net": totals.netEconomicSpending, "personal": totals.personalIncome,
            "notMine": totals.passThroughNotMine, "financing": totals.financingRepayments,
            "transfers": totals.internalTransfers,
        ]
        let incomeValues = [
            "personal": income.personalIncome, "supportGross": income.parentalSupportGross,
            "supportOwned": income.parentalSupportOwned, "earned": income.earnedOrOther,
            "reimbursements": income.reimbursements, "passGross": income.passThroughGross,
            "passOwned": income.passThroughOwned, "notMine": income.passThroughNotMine,
            "movement": income.internalMovement, "unresolved": income.unresolved,
        ]
        XCTAssertTrue(Set(expectedTotals.keys).isSubset(of: Set(totalValues.keys)), file: file, line: line)
        XCTAssertTrue(Set(expectedIncome.keys).isSubset(of: Set(incomeValues.keys)), file: file, line: line)
        for (name, amount) in totalValues {
            XCTAssertEqual(amount.currency, .eur, file: file, line: line)
            XCTAssertEqual(amount.minorUnits, expectedTotals[name] ?? 0,
                           "\(record.historicalID): totals.\(name)", file: file, line: line)
        }
        for (name, amount) in incomeValues {
            XCTAssertEqual(amount.currency, .eur, file: file, line: line)
            XCTAssertEqual(amount.minorUnits, expectedIncome[name] ?? 0,
                           "\(record.historicalID): income.\(name)", file: file, line: line)
        }
        XCTAssertEqual(unresolvedIDs(result), unresolved ? [record.historicalID] : [], file: file, line: line)
        XCTAssertEqual(
            result.findings.filter { $0.kind == .unresolvedEvidenceAffectingAccuracy }.count,
            unresolved ? 1 : 0, file: file, line: line
        )
        assertTotalsAlgebra(result, record.historicalID, file: file, line: line)
    }

    func testU1OtherOutflowIsNotInferredSpending() throws {
        try assertHistorySemantics(semanticRecord("u1", type: "OTHER", original: -1200,
            booked: -1000, economic: -900, personal: -700), unresolved: true)
    }

    func testU2LoanProceedsAreNotInferredIncome() throws {
        try assertHistorySemantics(semanticRecord("u2", type: "LOAN"), unresolved: true)
    }

    func testU3NegativeLoanIsNotInferredSpending() throws {
        try assertHistorySemantics(semanticRecord("u3", type: "LOAN", original: -1200,
            booked: -1000, economic: 900), unresolved: true)
    }

    func testU4UnmappedSharedContributionIsNotIncome() throws {
        try assertHistorySemantics(semanticRecord("u4", type: "SHARED_EXPENSE_CONTRIBUTION"), unresolved: true)
    }

    func testU5PassThroughTypeDoesNotInventAFlag() throws {
        try assertHistorySemantics(semanticRecord("u5", type: "PASS_THROUGH"), unresolved: true)
    }

    func testU6UnresolvedNegativeEvidenceIsNotSpending() throws {
        try assertHistorySemantics(semanticRecord("u6", type: "UNRESOLVED", original: -1200,
            economic: -900, reason: "purpose not established"), unresolved: true)
    }

    func testU7UnresolvedPositiveEvidenceIsNotIncome() throws {
        try assertHistorySemantics(semanticRecord("u7", type: "UNRESOLVED",
            reason: "purpose not established"), unresolved: true)
    }

    func testU8FutureNegativeVocabularyFailsClosed() throws {
        for source: String? in [nil, "NEW_SOURCE_2030"] {
            try assertHistorySemantics(semanticRecord("u8", original: -1200,
                economic: -900, source: source), unresolved: true)
        }
    }

    func testU9FuturePositiveVocabularyFailsClosed() throws {
        for source: String? in [nil, "NEW_SOURCE_2030"] {
            try assertHistorySemantics(semanticRecord("u9", source: source), unresolved: true)
        }
    }

    func testU10UnknownSemanticsWithoutEURStillUnresolved() throws {
        try assertHistorySemantics(semanticRecord("u10", booked: nil,
            economic: nil, personal: nil), unresolved: true)
    }

    func testU11ExplicitZeroDoesNotEstablishUnknownSemantics() throws {
        try assertHistorySemantics(semanticRecord("u11", original: 0,
            booked: 0, economic: 0, personal: 0), unresolved: true)
    }

    func testA1UnknownTypeRetainsRecognizedParentalSource() throws {
        try assertHistorySemantics(semanticRecord("a1", source: "PARENTAL_SUPPORT_SELF"),
            totals: ["personal": 700],
            income: ["personal": 700, "supportGross": 1000, "supportOwned": 700], unresolved: false)
    }

    func testA2SharedContributionRetainsRecognizedReimbursementSource() throws {
        for type in ["SHARED_EXPENSE_CONTRIBUTION", "NEW_TYPE_2030"] {
            try assertHistorySemantics(semanticRecord("a2", type: type, source: "SHARED_EXPENSE_REIMBURSEMENT"),
                totals: ["personal": 700], income: ["personal": 700, "reimbursements": 700], unresolved: false)
        }
    }

    func testA3UnknownTypeRetainsFinancingFlagAuthority() throws {
        try assertHistorySemantics(semanticRecord("a3", financing: true),
            totals: ["financing": 900], unresolved: false)
    }

    func testA4UnknownTypeRetainsInternalTransferFlagAuthority() throws {
        try assertHistorySemantics(semanticRecord("a4", internalTransfer: true),
            totals: ["transfers": 1000], income: ["movement": 1000], unresolved: false)
    }

    func testA5UnknownTypeRetainsFullPassThroughFlagAuthority() throws {
        try assertHistorySemantics(semanticRecord("a5", passThrough: .full),
            totals: ["personal": 700, "notMine": 300],
            income: ["personal": 700, "passGross": 1000, "passOwned": 700, "notMine": 300], unresolved: false)
    }

    func testA6UnknownTypeRetainsPartialPassThroughFlagAuthority() throws {
        try assertHistorySemantics(semanticRecord("a6", passThrough: .partial),
            totals: ["personal": 700, "notMine": 300],
            income: ["personal": 700, "passGross": 1000, "passOwned": 700, "notMine": 300], unresolved: false)
    }

    func testK1ExplicitSpendingZeroIsKnown() throws {
        try assertHistorySemantics(semanticRecord("k1", type: "SPENDING", original: 0,
            booked: 0, economic: 0, personal: 0), unresolved: false)
    }

    func testK2ExplicitIncomeZeroIsKnown() throws {
        try assertHistorySemantics(semanticRecord("k2", type: "INCOME", original: 0,
            booked: 0, economic: 0, personal: 0), unresolved: false)
    }

    func testK3ExplicitFinancingZeroIsKnown() throws {
        try assertHistorySemantics(semanticRecord("k3", type: "FINANCING_REPAYMENT", original: 0,
            booked: 0, economic: 0, personal: 0), unresolved: false)
    }

    func testK4ExplicitTransferZeroIsKnown() throws {
        try assertHistorySemantics(semanticRecord("k4", type: "INTERNAL_TRANSFER", original: 0,
            booked: 0, economic: 0, personal: 0), unresolved: false)
    }

    func testK5FlaggedPassThroughZeroIsKnown() throws {
        for flag: FinanceHistoryPassThrough in [.full, .partial] {
            try assertHistorySemantics(semanticRecord("k5", original: 0,
                booked: 0, economic: 0, personal: 0, passThrough: flag), unresolved: false)
        }
    }

    func testK6MappedIncomeZeroIsKnown() throws {
        try assertHistorySemantics(semanticRecord("k6", original: 0,
            booked: 0, economic: 0, personal: 0, source: "PARENTAL_SUPPORT_SELF"), unresolved: false)
    }

    /// These producer types have meaning, but this consumer has no mapping for
    /// them yet. Explicit vocabulary support requires a separately reviewed extension.
    func testG1UnmappedGiftIsDeliberatelyUnresolved() throws {
        for source: String? in [nil, "GIFT_OTHER"] {
            try assertHistorySemantics(semanticRecord("g1", type: "GIFT", source: source), unresolved: true)
        }
    }

    func testG2UnmappedInstitutionalBenefitIsDeliberatelyUnresolved() throws {
        for source: String? in [nil, "OTHER_ECONOMIC_RESOURCE"] {
            try assertHistorySemantics(semanticRecord("g2", type: "INSTITUTIONAL_BENEFIT", source: source), unresolved: true)
        }
    }

    func testS1ExplicitSpendingKeepsEconomicAuthority() throws {
        for type in ["SPENDING", "EXPENSE"] {
            try assertHistorySemantics(semanticRecord("s1", type: type, original: -1200, economic: -900),
                totals: ["spending": 900, "net": 900], unresolved: false)
        }
    }

    func testS2ExplicitSpendingOutranksPositiveDirection() throws {
        try assertHistorySemantics(semanticRecord("s2", type: "SPENDING"),
            totals: ["spending": 900, "net": 900], unresolved: false)
    }

    func testS3ExplicitIncomeKeepsPersonalAuthority() throws {
        try assertHistorySemantics(semanticRecord("s3", type: "INCOME"),
            totals: ["personal": 700], income: ["personal": 700, "unresolved": 700], unresolved: false)
    }

    func testS4ExplicitIncomeOutranksNonPositiveDirection() throws {
        for original: Int64 in [-1200, 0] {
            try assertHistorySemantics(semanticRecord("s4", type: "INCOME", original: original, booked: 0),
                totals: ["personal": 700], income: ["personal": 700, "unresolved": 700], unresolved: false)
        }
    }

    func testD1SemanticAndEvidenceUncertaintyNamesTheRowOnce() throws {
        try assertHistorySemantics(semanticRecord("d1", reason: "purpose not established"), unresolved: true)
    }

    func testD2RecognizedValuedRoleStillPreservesEvidenceReason() throws {
        try assertHistorySemantics(semanticRecord("d2", type: "SPENDING", original: -1200,
            reason: "independent source uncertainty"), totals: ["spending": 900, "net": 900], unresolved: true)
    }

    // MARK: - ReviewTotals resolution parity (Debt A)

    // `ReviewTotals` used to fold refunds a second time from the raw effects
    // while `ReviewBudget` answered from the resolved per-id net. The two
    // disagreed wherever refund suppression applied. These pin the resolved
    // formula and the parity laws it exists to satisfy.

    private func refundTransaction(
        _ id: String,
        _ amount: String,
        on iso: String,
        linkedTo linked: String?,
        account: String = "bank"
    ) -> Transaction {
        Transaction(
            id: id, date: day(iso), kind: .refund,
            legs: [AccountLeg(accountID: account, amount: euro(amount))],
            linkedTransactionID: linked,
            factivity: .observed
        )
    }

    /// R2 and R3 hold for every review, whatever it contains.
    private func assertTotalsAlgebra(
        _ result: ReviewResult,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            result.totals.economicSpending.minorUnits - result.totals.refunds.minorUnits,
            result.totals.netEconomicSpending.minorUnits,
            "R2 gross - refunds == net: \(label)", file: file, line: line
        )
        XCTAssertGreaterThanOrEqual(
            result.totals.refunds.minorUnits, 0,
            "R3 refunds are never negative: \(label)", file: file, line: line
        )
        XCTAssertEqual(
            result.totals.netEconomicSpending, result.budget.periodEconomicSpending,
            "R1 totals net == budget period spending: \(label)", file: file, line: line
        )
        let monthSum = result.budget.monthlyContexts.reduce(Int64(0)) {
            $0 + $1.periodSpendingInMonth.minorUnits
        }
        XCTAssertEqual(
            monthSum, result.budget.periodEconomicSpending.minorUnits,
            "R4 monthly period-spending sums to the period: \(label)", file: file, line: line
        )
    }

    func testP1PlainPurchaseHasNoRefunds() throws {
        let result = try review(
            try monthlyRequest(document(transactions: [expense("p", "50.00", on: "2026-09-04")]))
        )
        XCTAssertEqual(result.totals.economicSpending, euro("50.00"))
        XCTAssertEqual(result.totals.refunds, euro("0.00"))
        XCTAssertEqual(result.totals.netEconomicSpending, euro("50.00"))
        assertTotalsAlgebra(result, "P1")
    }

    func testP3PartialRefundNetsTheDifference() throws {
        let result = try review(
            try monthlyRequest(document(transactions: [
                expense("p", "50.00", on: "2026-09-04"),
                refundTransaction("r", "20.00", on: "2026-09-09", linkedTo: "p"),
            ]))
        )
        XCTAssertEqual(result.totals.economicSpending, euro("50.00"))
        XCTAssertEqual(result.totals.refunds, euro("20.00"))
        XCTAssertEqual(result.totals.netEconomicSpending, euro("30.00"))
        assertTotalsAlgebra(result, "P3")
    }

    func testP4ReversedExpenseAloneCountsNothing() throws {
        let result = try review(
            try monthlyRequest(document(transactions: [
                expense("p", "40.00", on: "2026-09-04", lifecycle: .reversed),
            ]))
        )
        XCTAssertEqual(result.totals.economicSpending, euro("0.00"))
        XCTAssertEqual(result.totals.refunds, euro("0.00"))
        XCTAssertEqual(result.totals.netEconomicSpending, euro("0.00"))
        assertTotalsAlgebra(result, "P4")
    }

    /// The primary repro. A reversed original already contributes no spending,
    /// so its linked refund credit must not be subtracted a second time: the
    /// period is a no-op, not a €40 windfall. Before the repair the totals said
    /// -4000 while the budget said 0.
    func testP5ReversedOriginalWithLinkedRefundIsANoOp() throws {
        let result = try review(
            try monthlyRequest(document(transactions: [
                expense("p", "40.00", on: "2026-09-04", lifecycle: .reversed),
                refundTransaction("r", "40.00", on: "2026-09-09", linkedTo: "p"),
            ]))
        )
        XCTAssertEqual(result.totals.economicSpending, euro("0.00"))
        XCTAssertEqual(result.totals.refunds, euro("0.00"))
        XCTAssertEqual(result.totals.netEconomicSpending, euro("0.00"))
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("0.00"))
        assertTotalsAlgebra(result, "P5")
    }

    func testP6TwoRefundsAgainstOnePurchase() throws {
        let result = try review(
            try monthlyRequest(document(transactions: [
                expense("p", "50.00", on: "2026-09-04"),
                refundTransaction("r1", "20.00", on: "2026-09-09", linkedTo: "p"),
                refundTransaction("r2", "10.00", on: "2026-09-11", linkedTo: "p"),
            ]))
        )
        XCTAssertEqual(result.totals.economicSpending, euro("50.00"))
        XCTAssertEqual(result.totals.refunds, euro("30.00"))
        XCTAssertEqual(result.totals.netEconomicSpending, euro("20.00"))
        assertTotalsAlgebra(result, "P6")
    }

    /// P7 — gross is the one number the repair does not touch.
    func testP7GrossSpendingIsUnchangedByTheResolution() throws {
        let cases: [(String, [Transaction], String)] = [
            ("P1", [expense("p", "50.00", on: "2026-09-04")], "50.00"),
            ("P2", [expense("p", "21.99", on: "2026-09-02"),
                    refundTransaction("r", "21.99", on: "2026-09-08", linkedTo: "p")], "21.99"),
            ("P3", [expense("p", "50.00", on: "2026-09-04"),
                    refundTransaction("r", "20.00", on: "2026-09-09", linkedTo: "p")], "50.00"),
            ("P4", [expense("p", "40.00", on: "2026-09-04", lifecycle: .reversed)], "0.00"),
            ("P5", [expense("p", "40.00", on: "2026-09-04", lifecycle: .reversed),
                    refundTransaction("r", "40.00", on: "2026-09-09", linkedTo: "p")], "0.00"),
            ("P6", [expense("p", "50.00", on: "2026-09-04"),
                    refundTransaction("r1", "20.00", on: "2026-09-09", linkedTo: "p"),
                    refundTransaction("r2", "10.00", on: "2026-09-11", linkedTo: "p")], "50.00"),
        ]
        for (label, transactions, gross) in cases {
            let result = try review(try monthlyRequest(document(transactions: transactions)))
            XCTAssertEqual(result.totals.economicSpending, euro(gross), "gross unchanged: \(label)")
            assertTotalsAlgebra(result, label)
        }
    }

    /// P10 — with one exact calendar month and no history, the review, its
    /// monthly context and the independent monthly budget engine agree.
    func testP10ReviewAgreesWithMonthlyBudgetEngineOverAFullMonth() throws {
        let cases: [(String, [Transaction])] = [
            ("P1", [expense("p", "50.00", on: "2026-09-04")]),
            ("P2", [expense("p", "21.99", on: "2026-09-02"),
                    refundTransaction("r", "21.99", on: "2026-09-08", linkedTo: "p")]),
            ("P3", [expense("p", "50.00", on: "2026-09-04"),
                    refundTransaction("r", "20.00", on: "2026-09-09", linkedTo: "p")]),
            ("P5", [expense("p", "40.00", on: "2026-09-04", lifecycle: .reversed),
                    refundTransaction("r", "40.00", on: "2026-09-09", linkedTo: "p")]),
            ("P6", [expense("p", "50.00", on: "2026-09-04"),
                    refundTransaction("r1", "20.00", on: "2026-09-09", linkedTo: "p"),
                    refundTransaction("r2", "10.00", on: "2026-09-11", linkedTo: "p")]),
        ]
        for (label, transactions) in cases {
            let doc = document(transactions: transactions)
            let result = try review(try monthlyRequest(doc))
            let report = MonthlyBudgetEngine.report(
                month: september, today: day("2026-09-15"), document: doc
            )
            XCTAssertEqual(
                result.totals.netEconomicSpending, report.spent,
                "R5 review net == monthly report spent: \(label)"
            )
            XCTAssertEqual(
                septemberContext(result).monthSpending, report.spent,
                "R6 monthly context == monthly report spent: \(label)"
            )
            assertTotalsAlgebra(result, label)
        }
    }

    /// P11 — resolution is order-independent, and a refund whose original sits
    /// in an earlier period legitimately drives the period negative.
    func testP11RefundOrderAndCrossPeriodRefunds() throws {
        let earlyRefund = try review(
            try monthlyRequest(document(transactions: [
                refundTransaction("r", "20.00", on: "2026-09-02", linkedTo: "p"),
                expense("p", "50.00", on: "2026-09-09"),
            ]))
        )
        XCTAssertEqual(earlyRefund.totals.netEconomicSpending, euro("30.00"))
        XCTAssertEqual(earlyRefund.totals.refunds, euro("20.00"))
        assertTotalsAlgebra(earlyRefund, "P11 refund before original")

        // The original is in August; only the refund falls inside September.
        let crossPeriod = try review(
            try monthlyRequest(document(transactions: [
                expense("p", "50.00", on: "2026-08-20"),
                refundTransaction("r", "20.00", on: "2026-09-09", linkedTo: "p"),
            ]))
        )
        XCTAssertEqual(crossPeriod.totals.economicSpending, euro("0.00"))
        XCTAssertEqual(crossPeriod.totals.refunds, euro("20.00"))
        XCTAssertEqual(crossPeriod.totals.netEconomicSpending, euro("-20.00"))
        assertTotalsAlgebra(crossPeriod, "P11 cross-period refund")
    }

    /// P12 — an unlinked refund keeps the established convention: it counts as
    /// a refund and drives net negative rather than becoming income.
    func testP12UnlinkedRefundStaysARefund() throws {
        let result = try review(
            try monthlyRequest(document(transactions: [
                refundTransaction("r", "35.00", on: "2026-09-09", linkedTo: nil),
            ]))
        )
        XCTAssertEqual(result.totals.refunds, euro("35.00"))
        XCTAssertEqual(result.totals.netEconomicSpending, euro("-35.00"))
        XCTAssertEqual(result.totals.personalIncome, euro("0.00"))
        assertTotalsAlgebra(result, "P12")
    }

    func testFinancingIsNotDoubled() throws {
        let purchase = expense("phone", "324.89", on: "2026-09-03")
        let repayment = Transaction(
            id: "rep", date: day("2026-09-10"), kind: .financingRepayment,
            legs: [AccountLeg(accountID: "wallet", amount: euro("-81.22"))],
            installmentPlanID: "plan",
            factivity: .observed
        )
        let result = try review(try monthlyRequest(document(transactions: [purchase, repayment])))
        XCTAssertEqual(result.totals.netEconomicSpending, euro("324.89"))
        XCTAssertEqual(result.totals.financingRepayments, euro("81.22"))
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("324.89"))
    }

    // MARK: - Income / support

    func testPassThroughExcludedFromOwnedIncomeAndIsNeverEarned() throws {
        let arrival = Transaction(
            id: "in", date: day("2026-09-07"), kind: .passThrough,
            legs: [AccountLeg(accountID: "bank", amount: euro("300.00"))],
            ownership: [OwnershipSplit(ownerID: "other", isSelf: false, amount: euro("300.00"))],
            factivity: .observed
        )
        let result = try review(try monthlyRequest(document(transactions: [arrival])))
        XCTAssertEqual(result.income.personalIncome, euro("0.00"))
        XCTAssertEqual(result.income.passThroughNotMine, euro("300.00"))
        XCTAssertEqual(result.income.passThroughGross, euro("300.00"))
        XCTAssertEqual(result.income.earnedOrOther, euro("0.00"))
        XCTAssertEqual(result.income.parentalSupportOwned, euro("0.00"))
        XCTAssertEqual(result.totals.personalIncome, euro("0.00"))
    }

    func testUnidentifiedLiveIncomeIsUnresolvedNotEarned() throws {
        let pay = Transaction(
            id: "mystery-in",
            date: day("2026-09-05"),
            kind: .income,
            legs: [AccountLeg(accountID: "bank", amount: euro("250.00"))],
            factivity: .observed
        )
        let result = try review(try monthlyRequest(document(transactions: [pay])))
        XCTAssertEqual(result.income.personalIncome, euro("250.00"))
        XCTAssertEqual(result.income.unresolved, euro("250.00"))
        XCTAssertEqual(result.income.earnedOrOther, euro("0.00"))
        XCTAssertEqual(result.income.parentalSupportOwned, euro("0.00"))
    }

    func testLiveParentalSupportRemainsSupportViaIncomeSource() throws {
        let source = IncomeSource(
            id: "inc-parents-september-support",
            name: "Parental support — September (received)",
            amount: euro("0.00"),
            certainty: .received,
            schedule: .oneShot(on: day("2026-08-18"))
        )
        let received = Transaction(
            id: "tx-parent-support",
            date: day("2026-09-03"),
            kind: .income,
            legs: [AccountLeg(accountID: "bank", amount: euro("900.00"))],
            incomeSourceID: "inc-parents-september-support",
            factivity: .observed
        )
        let result = try review(
            try monthlyRequest(
                document(transactions: [received], income: [source]),
                economicSources: ["inc-parents-september-support": "PARENTAL_SUPPORT_SELF"]
            )
        )
        XCTAssertEqual(result.income.parentalSupportOwned, euro("900.00"))
        XCTAssertEqual(result.income.parentalSupportGross, euro("900.00"))
        XCTAssertEqual(result.income.earnedOrOther, euro("0.00"))
        XCTAssertEqual(result.income.unresolved, euro("0.00"))
    }

    func testSupportRoutedThroughOwnershipSplitShowsGrossAndOwned() throws {
        let source = IncomeSource(
            id: "inc-parents",
            name: "Parental support",
            amount: euro("800.00"),
            certainty: .guaranteed,
            schedule: .oneShot(on: day("2026-09-16"))
        )
        let arrival = Transaction(
            id: "support",
            date: day("2026-09-16"),
            kind: .passThrough,
            legs: [AccountLeg(accountID: "bank", amount: euro("1600.00"))],
            ownership: [
                OwnershipSplit(ownerID: "self", isSelf: true, amount: euro("800.00")),
                OwnershipSplit(ownerID: "co-resident", isSelf: false, amount: euro("800.00")),
            ],
            incomeSourceID: "inc-parents",
            factivity: .observed
        )
        let result = try review(
            try monthlyRequest(
                document(transactions: [arrival], income: [source]),
                incomeClasses: ["inc-parents": .parentalSupport]
            )
        )
        XCTAssertEqual(result.income.parentalSupportGross, euro("1600.00"))
        XCTAssertEqual(result.income.parentalSupportOwned, euro("800.00"))
        XCTAssertEqual(result.income.passThroughGross, euro("1600.00"))
        XCTAssertEqual(result.income.passThroughOwned, euro("800.00"))
        XCTAssertEqual(result.income.passThroughNotMine, euro("800.00"))
        XCTAssertEqual(result.income.personalIncome, euro("800.00"))
        XCTAssertEqual(result.income.earnedOrOther, euro("0.00"))
    }

    func testReimbursementRequiresExplicitEvidence() throws {
        let unnamed = Transaction(
            id: "maybe-reimburse",
            date: day("2026-09-08"),
            kind: .income,
            legs: [AccountLeg(accountID: "bank", amount: euro("40.00"))],
            factivity: .observed
        )
        let unnamedResult = try review(try monthlyRequest(document(transactions: [unnamed])))
        XCTAssertEqual(unnamedResult.income.reimbursements, euro("0.00"))
        XCTAssertEqual(unnamedResult.income.unresolved, euro("40.00"))

        let named = Transaction(
            id: "reimburse",
            date: day("2026-09-08"),
            kind: .income,
            legs: [AccountLeg(accountID: "bank", amount: euro("40.00"))],
            incomeSourceID: "inc-shared",
            factivity: .observed
        )
        let namedResult = try review(
            try monthlyRequest(
                document(transactions: [named]),
                economicSources: ["inc-shared": "SHARED_EXPENSE_REIMBURSEMENT"]
            )
        )
        XCTAssertEqual(namedResult.income.reimbursements, euro("40.00"))
        XCTAssertEqual(namedResult.income.unresolved, euro("0.00"))
        XCTAssertEqual(namedResult.income.earnedOrOther, euro("0.00"))
    }

    func testKnownEarnedSourceIsEarnedOrOther() throws {
        let job = Transaction(
            id: "job",
            date: day("2026-09-05"),
            kind: .income,
            legs: [AccountLeg(accountID: "bank", amount: euro("253.00"))],
            incomeSourceID: "inc-job",
            factivity: .observed
        )
        let result = try review(
            try monthlyRequest(
                document(transactions: [job]),
                economicSources: ["inc-job": "EARNED_EMPLOYMENT"]
            )
        )
        XCTAssertEqual(result.income.earnedOrOther, euro("253.00"))
        XCTAssertEqual(result.income.unresolved, euro("0.00"))
    }

    // MARK: - Expected vs actual / ordinary vs exceptional

    func testExpectedVersusActualMatching() throws {
        let rent = obligation("ob-rent", amount: "480.00", onDay: 11)
        let actual = expense("rent-paid", "480.00", on: "2026-09-11")
        let settlement = ObligationSettlement.paid(
            id: "s-rent",
            obligationID: "ob-rent",
            expectedDay: day("2026-09-11"),
            actualTransactionID: "rent-paid"
        )
        let missed = obligation("ob-phone", amount: "7.99", onDay: 5)
        let skipped = obligation("ob-gym", amount: "20.00", onDay: 8)
        let skippedSettlement = ObligationSettlement.skipped(
            id: "s-gym",
            obligationID: "ob-gym",
            expectedDay: day("2026-09-08")
        )
        let result = try review(
            try monthlyRequest(
                document(
                    transactions: [actual],
                    obligations: [rent, missed, skipped],
                    settlements: [settlement, skippedSettlement]
                )
            )
        )
        let byName = Dictionary(uniqueKeysWithValues: result.expectations.items.map { ($0.name, $0) })
        XCTAssertEqual(byName["ob-rent"]?.status, .matched)
        XCTAssertEqual(byName["ob-rent"]?.actualTransactionID, "rent-paid")
        XCTAssertEqual(byName["ob-phone"]?.status, .missed)
        XCTAssertEqual(byName["ob-gym"]?.status, .skipped)
    }

    func testExceptionalVersusOrdinaryWhenExplicitlyClassified() throws {
        let rent = obligation("ob-rent", amount: "480.00", onDay: 11)
        let actualRent = expense("rent-paid", "480.00", on: "2026-09-11")
        let settlement = ObligationSettlement.paid(
            id: "s-rent",
            obligationID: "ob-rent",
            expectedDay: day("2026-09-11"),
            actualTransactionID: "rent-paid"
        )
        let groceries = expense("food", "24.50", on: "2026-09-04")
        let laptop = expense("laptop", "200.00", on: "2026-09-12")
        let mystery = expense("mystery", "12.00", on: "2026-09-13")
        let result = try review(
            try monthlyRequest(
                document(
                    transactions: [actualRent, groceries, laptop, mystery],
                    budgets: [budget("groceries", "70.00", categoryKeys: ["food"])],
                    obligations: [rent],
                    settlements: [settlement]
                ),
                natures: ["laptop": .exceptional],
                categoryKeys: ["food": "food"]
            )
        )
        XCTAssertEqual(result.budget.ordinaryRecurring, euro("480.00"))
        XCTAssertEqual(result.budget.ordinaryVariable, euro("24.50"))
        XCTAssertEqual(result.budget.exceptional, euro("200.00"))
        XCTAssertEqual(result.budget.unresolvedNature, euro("12.00"))
        XCTAssertTrue(result.findings.contains { $0.kind == .majorExceptionalPurchase && $0.ids == ["laptop"] })
        XCTAssertFalse(
            result.findings.contains { $0.kind == .majorExceptionalPurchase && $0.ids == ["mystery"] },
            "amount alone must not invent exceptional"
        )
    }

    func testReservationIsNotSpending() throws {
        let fund = SinkingFund(
            id: "sf",
            name: "Laptop",
            targetAmount: euro("500.00"),
            reservedAmount: euro("200.00")
        )
        let purchase = PlannedPurchase(
            id: "goal",
            name: "Laptop",
            targetAmount: euro("500.00"),
            targetDate: day("2026-09-20"),
            status: .reserved,
            funding: .sinkingFund(id: "sf"),
            reservedAmount: euro("0.00"),
            requirement: .euroBankPayment()
        )
        let result = try review(
            try monthlyRequest(
                document(
                    transactions: [expense("food", "10.00", on: "2026-09-04")],
                    purchases: [purchase],
                    funds: [fund]
                )
            )
        )
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("10.00"))
        XCTAssertEqual(result.goals.currentlySetAside, euro("200.00"))
        XCTAssertFalse(result.goals.reservationHistoryKnown)
        XCTAssertNil(result.goals.reservationChange)
        XCTAssertEqual(result.goals.activePurchases.map(\.id), ["goal"])
        XCTAssertTrue(result.findings.contains { $0.kind == .goalDeadlineApproaching && $0.ids == ["goal"] })
    }

    // MARK: - Coverage fail-closed

    func testMissingCoverageMetadataIsInsufficient() throws {
        let result = try review(
            try monthlyRequest(
                document(transactions: [expense("x", "10.00", on: "2026-09-04")]),
                coverage: .absent
            )
        )
        XCTAssertEqual(result.coverage.status, .insufficient)
        XCTAssertTrue(result.coverage.reasons.contains { $0.kind == .coverageMetadataAbsent })
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("10.00"))
        XCTAssertFalse(result.coverage.isComplete)
    }

    func testMissingArchiveCoverageIsInsufficientAndNotZeroActivity() throws {
        let result = try review(
            try monthlyRequest(
                document(transactions: []),
                month: MonthKey(year: 2026, month: 7),
                asOf: "2026-07-31",
                coverage: liveCovering(ReviewInterval.month(MonthKey(year: 2026, month: 7)), cutoff: day("2026-08-19"))
            )
        )
        XCTAssertEqual(result.coverage.status, .insufficient)
        XCTAssertTrue(result.coverage.reasons.contains { $0.kind == .archiveHistoryAbsent })
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("0.00"))
        XCTAssertTrue(result.findings.contains { $0.kind == .unresolvedEvidenceAffectingAccuracy })
        XCTAssertFalse(result.coverage.isComplete)
    }

    func testLiveEraIntervalWithoutAffirmativeLiveCoverageIsInsufficient() throws {
        let result = try review(
            try monthlyRequest(
                document(transactions: [expense("sep", "10.00", on: "2026-09-10")]),
                coverage: ReviewCoverageInput(archiveCutoff: day("2026-08-19"))
            )
        )
        XCTAssertEqual(result.coverage.status, .insufficient)
        XCTAssertTrue(result.coverage.reasons.contains { $0.kind == .missingLiveInterval })
    }

    func testArchiveLiveBoundaryDoesNotDuplicate() throws {
        let history = historyDocument(
            cutoff: "2026-08-19",
            records: [
                historyRecord(
                    id: "h-cutoff",
                    date: "2026-08-19",
                    originalCents: -1_000,
                    economicEUR: 1_000,
                    economicType: "SPENDING"
                )
            ],
            rangeStart: "2026-08-01",
            rangeEnd: "2026-08-19"
        )
        let liveDuplicate = expense("live-cutoff", "10.00", on: "2026-08-19")
        let liveAfter = expense("live-after", "5.00", on: "2026-08-20")
        let result = try review(
            try monthlyRequest(
                document(transactions: [liveDuplicate, liveAfter]),
                month: august,
                asOf: "2026-08-31",
                coverage: liveCovering(
                    ReviewInterval.month(august),
                    cutoff: day("2026-08-19"),
                    history: history
                )
            )
        )
        XCTAssertEqual(result.coverage.status, .complete)
        XCTAssertTrue(result.coverage.usedArchive)
        XCTAssertTrue(result.coverage.usedLive)
        XCTAssertEqual(result.totals.netEconomicSpending, euro("15.00"))
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("15.00"))
        XCTAssertFalse(result.budget.drivers.contains { $0.id == "live-cutoff" })
        XCTAssertTrue(result.budget.drivers.contains { $0.id == "h-cutoff" })
    }

    func testMixedIntervalWithLiveGapIsPartial() throws {
        let history = historyDocument(
            cutoff: "2026-08-19",
            records: [
                historyRecord(
                    id: "h1",
                    date: "2026-08-10",
                    originalCents: -500,
                    economicEUR: 500,
                    economicType: "SPENDING"
                )
            ],
            rangeStart: "2026-08-01",
            rangeEnd: "2026-08-19"
        )
        let liveCovered = ReviewInterval(start: day("2026-08-20"), end: day("2026-08-25"))
        let result = try review(
            try monthlyRequest(
                document(transactions: [expense("late", "5.00", on: "2026-08-28")]),
                month: august,
                asOf: "2026-08-31",
                coverage: ReviewCoverageInput(
                    archiveCutoff: day("2026-08-19"),
                    history: history,
                    liveCoveredIntervals: [liveCovered]
                )
            )
        )
        XCTAssertEqual(result.coverage.status, .partial)
        XCTAssertTrue(result.coverage.reasons.contains { $0.kind == .missingLiveInterval })
        XCTAssertTrue(result.coverage.usedArchive)
        XCTAssertTrue(result.coverage.usedLive)
    }

    // MARK: - Comparison

    func testPriorPeriodComparableDelta() throws {
        let augustSpend = expense("aug", "50.00", on: "2026-08-10")
        let septSpend = expense("sep", "80.00", on: "2026-09-10")
        let groceries = budget("groceries", "100.00", categoryKeys: ["food"])
        let result = try review(
            try monthlyRequest(
                document(
                    transactions: [augustSpend, septSpend],
                    budgets: [groceries]
                ),
                compare: true,
                coverage: liveCovering(ReviewInterval.month(august), ReviewInterval.month(september)),
                categoryKeys: ["aug": "food", "sep": "food"]
            )
        )
        guard case let .available(comparison) = result.comparison else {
            return XCTFail("expected a comparable prior period")
        }
        XCTAssertEqual(comparison.priorInterval, ReviewInterval.month(august))
        XCTAssertEqual(comparison.spending.current, euro("80.00"))
        XCTAssertEqual(comparison.spending.prior, euro("50.00"))
        XCTAssertEqual(comparison.spending.absolute, euro("30.00"))
        XCTAssertEqual(comparison.spending.basisPoints, 6_000)
        XCTAssertTrue(result.findings.contains { $0.kind == .spendingMateriallyHigherThanPrior })
    }

    func testPriorPeriodComparisonRefusedWhenIncomplete() throws {
        let result = try review(
            try monthlyRequest(
                document(transactions: [expense("sep", "80.00", on: "2026-09-10")]),
                compare: true,
                coverage: liveCovering(ReviewInterval.month(september))
            )
        )
        XCTAssertEqual(result.coverage.status, .complete)
        guard case let .unavailable(reason) = result.comparison else {
            return XCTFail("comparison must be refused")
        }
        XCTAssertEqual(reason, .priorCoverageIncomplete)
        XCTAssertFalse(result.findings.contains { $0.kind == .spendingMateriallyHigherThanPrior })
    }

    func testZeroDenominatorComparisonOmitsPercentage() throws {
        let result = try review(
            try monthlyRequest(
                document(transactions: [expense("sep", "40.00", on: "2026-09-10")]),
                compare: true,
                coverage: liveCovering(ReviewInterval.month(august), ReviewInterval.month(september))
            )
        )
        guard case let .available(comparison) = result.comparison else {
            return XCTFail("prior month of zero activity is still complete live coverage")
        }
        XCTAssertEqual(comparison.spending.prior, euro("0.00"))
        XCTAssertEqual(comparison.spending.current, euro("40.00"))
        XCTAssertNil(comparison.spending.basisPoints)
        XCTAssertFalse(result.findings.contains { $0.kind == .unusuallyHighCategory })
    }

    // MARK: - Finding policy boundaries

    func testSpendingDeltaOfOneEuroIsNotMaterial() throws {
        let result = try compareSpending(prior: "400.00", current: "401.00")
        XCTAssertEqual(result.comparisonSpending.absolute, euro("1.00"))
        XCTAssertFalse(result.findings.contains { $0.kind == .spendingMateriallyHigherThanPrior })
    }

    func testSpendingDeltaExactlyAtAbsoluteButBelowRelativeIsNotMaterial() throws {
        let result = try compareSpending(prior: "400.00", current: "425.00")
        XCTAssertEqual(result.comparisonSpending.absolute, euro("25.00"))
        XCTAssertEqual(result.comparisonSpending.basisPoints, 625)
        XCTAssertFalse(result.findings.contains { $0.kind == .spendingMateriallyHigherThanPrior })
    }

    func testSpendingDeltaExactlyAtBothThresholdsIsMaterial() throws {
        let result = try compareSpending(prior: "400.00", current: "480.00")
        XCTAssertEqual(result.comparisonSpending.absolute, euro("80.00"))
        XCTAssertEqual(result.comparisonSpending.basisPoints, 2_000)
        XCTAssertTrue(result.findings.contains { $0.kind == .spendingMateriallyHigherThanPrior })
    }

    func testSpendingJustBelowBothRelativeThresholdIsNotMaterial() throws {
        let result = try compareSpending(prior: "400.00", current: "479.99")
        XCTAssertEqual(result.comparisonSpending.basisPoints, 1_999)
        XCTAssertFalse(result.findings.contains { $0.kind == .spendingMateriallyHigherThanPrior })
    }

    func testZeroPriorRequiresAbsoluteThresholdOnly() throws {
        XCTAssertFalse(try compareSpending(prior: "0.00", current: "24.99").findings.contains { $0.kind == .spendingMateriallyHigherThanPrior })
        XCTAssertTrue(try compareSpending(prior: "0.00", current: "25.00").findings.contains { $0.kind == .spendingMateriallyHigherThanPrior })
    }

    func testUnusuallyHighCategoryDoublingOneEuroIsNotAFinding() throws {
        let result = try compareCategory(prior: "1.00", current: "2.00")
        XCTAssertFalse(result.findings.contains { $0.kind == .unusuallyHighCategory })
    }

    func testUnusuallyHighCategoryBelowPriorFloorIsNotAFinding() throws {
        let result = try compareCategory(prior: "19.99", current: "50.00")
        XCTAssertFalse(result.findings.contains { $0.kind == .unusuallyHighCategory })
    }

    func testUnusuallyHighCategoryExactlyAtThresholdsIsAFinding() throws {
        let result = try compareCategory(prior: "25.00", current: "50.00")
        XCTAssertTrue(result.findings.contains { $0.kind == .unusuallyHighCategory })
    }

    func testUnusuallyHighCategoryJustBelowAbsoluteIncreaseIsNotAFinding() throws {
        let result = try compareCategory(prior: "25.00", current: "49.99")
        XCTAssertFalse(result.findings.contains { $0.kind == .unusuallyHighCategory })
    }

    func testMajorExceptionalPurchaseThreshold() throws {
        let below = try review(
            try monthlyRequest(
                document(transactions: [expense("small", "99.99", on: "2026-09-12")]),
                natures: ["small": .exceptional]
            )
        )
        XCTAssertEqual(below.budget.exceptional, euro("99.99"))
        XCTAssertFalse(below.findings.contains { $0.kind == .majorExceptionalPurchase })

        let at = try review(
            try monthlyRequest(
                document(transactions: [expense("big", "100.00", on: "2026-09-12")]),
                natures: ["big": .exceptional]
            )
        )
        XCTAssertTrue(at.findings.contains { $0.kind == .majorExceptionalPurchase && $0.ids == ["big"] })
    }

    // MARK: - Risk

    func testFirstCashRiskIsHardDeficit() throws {
        let rent = RecurringObligation(
            id: "ob-rent",
            name: "Rent",
            amount: euro("400.00"),
            spec: .monthly(onDay: 11, from: september, through: september),
            requirement: PaymentRequirement(currency: .eur, acceptableRails: [.sepaDirectDebit]),
            spendingClass: .essential
        )
        let result = try review(
            try monthlyRequest(
                document(obligations: [rent], balance: "100.00"),
                asOf: "2026-09-01",
                horizon: "2026-09-30"
            )
        )
        XCTAssertEqual(result.risk.firstHardCashRiskDate, day("2026-09-11"))
        XCTAssertNotEqual(result.risk.firstHardCashRiskDate, result.risk.firstFloorWarningDate)
        XCTAssertEqual(result.risk.firstRisk?.kind, .poolDeficit)
        XCTAssertTrue(result.findings.contains { $0.kind == .upcomingLiquidityRisk })
        XCTAssertGreaterThan(result.risk.asOfLedgerLiquidity.minorUnits, 0)
        XCTAssertEqual(result.risk.asOf, day("2026-09-01"))
    }

    func testFloorWarningIsDistinctFromHardDeficit() throws {
        let rent = RecurringObligation(
            id: "ob-rent",
            name: "Rent",
            amount: euro("150.00"),
            spec: .monthly(onDay: 11, from: september, through: september),
            requirement: PaymentRequirement(currency: .eur, acceptableRails: [.sepaDirectDebit]),
            spendingClass: .essential
        )
        let result = try review(
            try monthlyRequest(
                document(
                    obligations: [rent],
                    floor: euro("400.00"),
                    balance: "500.00"
                ),
                asOf: "2026-09-01",
                horizon: "2026-09-30"
            )
        )
        XCTAssertNil(result.risk.firstHardCashRiskDate)
        XCTAssertEqual(result.risk.firstFloorWarningDate, day("2026-09-11"))
        XCTAssertEqual(result.risk.firstRisk?.kind, .belowSafetyFloor)
        XCTAssertTrue(result.findings.contains { $0.kind == .floorWarning })
        XCTAssertFalse(result.findings.contains { $0.kind == .upcomingLiquidityRisk })
    }

    func testHistoricalReviewDistinguishesPeriodFromAsOfOutlook() throws {
        let june = MonthKey(year: 2026, month: 6)
        let result = try review(
            try monthlyRequest(
                document(
                    transactions: [expense("june", "40.00", on: "2026-06-10")],
                    balance: "800.00",
                    asOf: "2026-08-15"
                ),
                month: june,
                asOf: "2026-08-15",
                coverage: liveCovering(ReviewInterval.month(june))
            )
        )
        XCTAssertEqual(result.interval, ReviewInterval.month(june))
        XCTAssertEqual(result.asOf, day("2026-08-15"))
        XCTAssertTrue(result.interval.end < result.asOf)
        XCTAssertEqual(result.risk.asOf, day("2026-08-15"))
        XCTAssertEqual(result.risk.asOfLedgerLiquidity, euro("800.00"))
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("40.00"))
        let labels = Mirror(reflecting: result.risk).children.compactMap(\.label)
        XCTAssertFalse(labels.contains("endingLedgerLiquidity"))
        XCTAssertTrue(labels.contains("asOfLedgerLiquidity"))
    }

    // MARK: - Determinism / unresolved evidence

    func testDeterministicShuffledInput() throws {
        let transactions = [
            expense("c", "12.00", on: "2026-09-13"),
            expense("a", "40.00", on: "2026-09-04"),
            expense("b", "8.00", on: "2026-09-09"),
        ]
        let original = document(
            transactions: transactions,
            budgets: [budget("g", "100.00", categoryKeys: ["food"])],
            purchases: [
                PlannedPurchase(
                    id: "z-goal", name: "Z", targetAmount: euro("10.00"),
                    status: .planned, requirement: .euroBankPayment()
                ),
                PlannedPurchase(
                    id: "a-goal", name: "A", targetAmount: euro("20.00"),
                    status: .planned, requirement: .euroBankPayment()
                ),
            ]
        )
        var shuffled = original
        shuffled.transactions = transactions.reversed()
        shuffled.planning.plannedPurchases = original.planning.plannedPurchases.reversed()
        shuffled.planning.budgets = original.planning.budgets
        let left = try review(try monthlyRequest(original, categoryKeys: ["a": "food", "b": "food", "c": "food"]))
        let right = try review(try monthlyRequest(shuffled, categoryKeys: ["c": "food", "a": "food", "b": "food"]))
        XCTAssertEqual(left, right)
        XCTAssertEqual(left.budget.drivers.map(\.id), ["a", "c", "b"])
    }

    func testUnresolvedEvidenceIsSurfaced() throws {
        let unresolved = expense(
            "mystery",
            "18.00",
            on: "2026-09-09",
            provenance: Provenance(source: "TEST", evidenceGrade: .unresolved)
        )
        let result = try review(try monthlyRequest(document(transactions: [unresolved])))
        XCTAssertTrue(
            result.findings.contains {
                $0.kind == .unresolvedEvidenceAffectingAccuracy && $0.ids.contains("mystery")
            }
        )
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("18.00"))
        XCTAssertEqual(result.budget.unresolvedNature, euro("18.00"))
    }

    func testExpectedIncomeSourceMatchingAndSupportBelowExpected() throws {
        let source = IncomeSource(
            id: "inc-parents",
            name: "Parents",
            amount: euro("800.00"),
            certainty: .guaranteed,
            schedule: .oneShot(on: day("2026-09-16"))
        )
        let expected = Transaction(
            id: "exp-support",
            date: day("2026-09-16"),
            kind: .passThrough,
            legs: [AccountLeg(accountID: "bank", amount: euro("1600.00"))],
            ownership: [
                OwnershipSplit(ownerID: "self", isSelf: true, amount: euro("800.00")),
                OwnershipSplit(ownerID: "co-resident", isSelf: false, amount: euro("800.00")),
            ],
            incomeSourceID: "inc-parents",
            factivity: .expected,
            certainty: .guaranteed
        )
        let actual = Transaction(
            id: "act-support",
            date: day("2026-09-16"),
            kind: .passThrough,
            legs: [AccountLeg(accountID: "bank", amount: euro("800.00"))],
            ownership: [
                OwnershipSplit(ownerID: "self", isSelf: true, amount: euro("400.00")),
                OwnershipSplit(ownerID: "co-resident", isSelf: false, amount: euro("400.00")),
            ],
            linkedTransactionID: "exp-support",
            incomeSourceID: "inc-parents",
            factivity: .observed
        )
        let result = try review(
            try monthlyRequest(
                document(
                    transactions: [actual],
                    expected: [expected],
                    income: [source]
                ),
                incomeClasses: ["inc-parents": .parentalSupport]
            )
        )
        XCTAssertEqual(result.income.parentalSupportOwned, euro("400.00"))
        XCTAssertEqual(result.income.parentalSupportGross, euro("800.00"))
        let matched = result.expectations.items.first { $0.id == "exp-support" }
        XCTAssertEqual(matched?.status, .matched)
        XCTAssertTrue(result.findings.contains { $0.kind == .supportBelowExpected })
    }

    func testRejectedAndPendingProviderEvidenceIsNotSpending() throws {
        let pending = Transaction(
            id: "hold",
            date: day("2026-09-04"),
            kind: .expense,
            legs: [AccountLeg(accountID: "bank", amount: euro("-9.00"))],
            factivity: .expected,
            lifecycle: .pending
        )
        let reversed = expense("rev", "50.00", on: "2026-09-05", lifecycle: .reversed)
        let result = try review(try monthlyRequest(document(transactions: [pending, reversed])))
        XCTAssertEqual(result.budget.periodEconomicSpending, euro("0.00"))
        XCTAssertEqual(result.totals.netEconomicSpending, euro("0.00"))
    }

    func testResultDoesNotExposeSafeToSpend() throws {
        let result = try review(try monthlyRequest(document()))
        let labels = Mirror(reflecting: result).children.compactMap(\.label)
        XCTAssertFalse(labels.contains("safeToSpend"))
        let riskLabels = Mirror(reflecting: result.risk).children.compactMap(\.label)
        XCTAssertFalse(riskLabels.contains("safeToSpend"))
        XCTAssertFalse(riskLabels.contains("endingLedgerLiquidity"))
        XCTAssertEqual(result.risk.asOfLedgerLiquidity, euro("800.00"))
    }

    // MARK: - Comparison fixtures

    private struct ComparisonProbe {
        let findings: [ReviewFinding]
        let comparisonSpending: ReviewDelta
        let comparisonCategories: [ReviewCategoryDelta]
    }

    private func compareSpending(prior: String, current: String) throws -> ComparisonProbe {
        let result = try review(
            try monthlyRequest(
                document(transactions: [
                    expense("aug", prior, on: "2026-08-10"),
                    expense("sep", current, on: "2026-09-10"),
                ]),
                compare: true,
                coverage: liveCovering(ReviewInterval.month(august), ReviewInterval.month(september))
            )
        )
        guard case let .available(comparison) = result.comparison else {
            XCTFail("comparison should be available")
            return ComparisonProbe(
                findings: result.findings,
                comparisonSpending: ReviewDelta(current: euro(current), prior: euro(prior)),
                comparisonCategories: []
            )
        }
        return ComparisonProbe(
            findings: result.findings,
            comparisonSpending: comparison.spending,
            comparisonCategories: comparison.categoryDeltas
        )
    }

    private func compareCategory(prior: String, current: String) throws -> ReviewResult {
        try review(
            try monthlyRequest(
                document(
                    transactions: [
                        expense("aug", prior, on: "2026-08-10"),
                        expense("sep", current, on: "2026-09-10"),
                    ],
                    budgets: [budget("groceries", "200.00", categoryKeys: ["food"])]
                ),
                compare: true,
                coverage: liveCovering(ReviewInterval.month(august), ReviewInterval.month(september)),
                categoryKeys: ["aug": "food", "sep": "food"]
            )
        )
    }

    // MARK: - Current liquidity comes from CurrentHoldings, not stored anchors

    /// A stored balance is an anchor: authoritative *through* its own day. If
    /// review sums anchors it reports cash as of the anchor day and calls it
    /// today, which is how one result came to hold two liquidity models.
    func testAsOfLiquidityUsesEffectiveHoldingsNotStoredAnchors() throws {
        let anchorDay = day("2026-09-01")
        let document = document(
            transactions: [expense("spend", "10.00", on: "2026-09-02")],
            balance: "100.00",
            asOf: "2026-09-01"
        )
        XCTAssertEqual(
            document.balances.first { $0.accountID == "bank" }?.balance, euro("100.00"),
            "anchor is unchanged by review"
        )

        let asOf = day("2026-09-03")
        let holdings = CurrentHoldings.effective(
            accountID: "bank", asOf: asOf, in: document
        )
        XCTAssertEqual(holdings.amount, euro("90.00"))

        let result = try review(
            try monthlyRequest(document, asOf: "2026-09-03", coverage: liveCovering(.month(september)))
        )
        XCTAssertEqual(result.risk.asOfLedgerLiquidity, euro("90.00"))
        XCTAssertEqual(result.risk.asOf, asOf)
        _ = anchorDay
    }

    /// The physical shape that failed the canary: an anchor plus post-anchor
    /// economics on one account, and a second account with none.
    func testAsOfLiquidityMatchesCanonicalHoldingsAcrossAccounts() throws {
        var document = document(
            transactions: [expense("bnp-legs", "15.47", on: "2026-08-23")],
            balance: "384.09",
            asOf: "2026-08-22"
        )
        document.balances = [
            AccountBalance(accountID: "bank", balance: euro("384.09"), asOf: day("2026-08-22")),
            AccountBalance(accountID: "wallet", balance: euro("78.85"), asOf: day("2026-08-23")),
            AccountBalance(accountID: "cash", balance: euro("0.00"), asOf: day("2026-08-23")),
        ]
        let asOf = day("2026-09-02")
        XCTAssertEqual(
            CurrentHoldings.euroFinancialAccountLiquidity(in: document, asOf: asOf),
            euro("447.47")
        )
        let result = try review(try monthlyRequest(document, asOf: "2026-09-02"))
        XCTAssertEqual(result.risk.asOfLedgerLiquidity, euro("447.47"))
    }

    /// The review's own forecast already opens on `CurrentHoldings`. Its
    /// as-of liquidity must not disagree with the projection it ships beside.
    func testAsOfLiquidityAgreesWithForecastOpeningPool() throws {
        let document = document(
            transactions: [expense("spend", "25.00", on: "2026-09-02")],
            balance: "500.00",
            asOf: "2026-09-01"
        )
        let request = try monthlyRequest(document, asOf: "2026-09-03")
        let result = try review(request)
        let forecast = try ForecastEngine.run(
            ForecastComposer.makeRequest(
                from: document, startDate: request.asOf,
                endDate: try XCTUnwrap(request.resolvedForecastEnd)
            )
        )
        XCTAssertEqual(result.risk.asOfLedgerLiquidity, euro("475.00"))
        // The projection opens on the same pool the review reports.
        let opening = try XCTUnwrap(forecast.dailyBalances.first)
        XCTAssertEqual(opening.day, request.asOf)
        XCTAssertEqual(result.risk.asOfLedgerLiquidity, opening.spendablePool)
    }

    // MARK: - The liquidity finding pairs one amount with one date

    /// `minimumBridgeRequired` answers a different question over a different
    /// window. Pairing it with the first-risk day states a number that was
    /// never true on that day.
    func testUpcomingLiquidityFindingCarriesFirstRiskShortfallNotBridge() throws {
        let rent = obligation("ob-rent", amount: "480.00", onDay: 11)
        let document = document(
            obligations: [rent], balance: "120.00", asOf: "2026-09-01"
        )
        let result = try review(try monthlyRequest(document, asOf: "2026-09-01"))
        let risk = try XCTUnwrap(result.risk.firstRisk)
        let finding = try XCTUnwrap(
            result.findings.first { $0.kind == .upcomingLiquidityRisk }
        )
        XCTAssertEqual(finding.dates, [risk.day])
        XCTAssertEqual(finding.amounts, [risk.shortfall])
        // The regression this test exists for: never the bridge figure.
        if result.risk.minimumBridgeRequired != risk.shortfall {
            XCTAssertFalse(finding.amounts.contains(result.risk.minimumBridgeRequired))
        }
        // The bridge stays available for anything that genuinely wants it.
        XCTAssertGreaterThanOrEqual(result.risk.minimumBridgeRequired.minorUnits, 0)
    }

    /// The floor and the deficit remain separate engine facts; only the
    /// presentation decides which to show. Pinned so a later change cannot
    /// quietly drop one.
    func testFloorAndDeficitRemainDistinctEngineFacts() throws {
        let rent = obligation("ob-rent", amount: "480.00", onDay: 11)
        let document = document(
            obligations: [rent], floor: euro("50.00"), balance: "120.00", asOf: "2026-09-01"
        )
        let result = try review(try monthlyRequest(document, asOf: "2026-09-01"))
        XCTAssertNotNil(result.risk.firstHardCashRiskDate)
        XCTAssertNotNil(result.risk.firstFloorWarningDate)
        XCTAssertEqual(result.risk.firstRisk?.kind, .poolDeficit)
    }


    // MARK: - Provider-status warnings are period-scoped

    /// A provider-status warning belongs to the period holding the euro it
    /// disputes, and to no other. It used to be appended to every review's
    /// unresolved-evidence finding regardless of interval, so one month's
    /// disputed row was reported as unresolved evidence in every month.
    func testProviderStatusWarningIsScopedToItsOwnReviewPeriod() throws {
        func day(_ iso: String) -> Day { Day(isoString: iso)! }
        func euro(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .eur)! }

        let account = Account(
            id: "bank", name: "Bank", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 0
        )
        let binding = ExternalAccountBinding(
            id: "binding-1", provider: .bnp, remoteOpaqueAccountID: "remote-1",
            localAccountID: "bank", syncStartBoundary: day("2026-01-01"),
            createdAt: Date(timeIntervalSince1970: 0)
        )
        // Resolved by a person, then downgraded by the provider: exactly the
        // shape `providerStatusWarnings` reports.
        let observation = ExternalObservation(
            id: "mar-1", bindingID: "binding-1", provider: .bnp, status: .pending,
            creditDebitIndicator: .debit, amount: euro("-30.00"),
            bookingDate: day("2026-03-10"),
            eligibleForEconomicActual: true, observedAt: Date(timeIntervalSince1970: 1_000)
        )
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account],
            balances: [AccountBalance(accountID: "bank", balance: euro("800.00"),
                                      asOf: day("2026-01-01"))],
            transactions: [
                Transaction(id: "t1", date: day("2026-03-10"), kind: .expense,
                            legs: [AccountLeg(accountID: "bank", amount: euro("-30.00"))],
                            factivity: .observed)
            ],
            planning: FinanceDocument.Planning(defaultScenario: .base),
            externalAccountBindings: [binding],
            externalObservations: [observation],
            externalEvidenceLinks: [
                ExternalEvidenceLink(id: "l1", observationID: "mar-1",
                                     transactionID: "t1", role: .accountMovement)
            ],
            observationResolutions: [
                ExternalObservationResolution(observationID: "mar-1", state: .linkedToTransaction)
            ]
        )
        XCTAssertEqual(ExternalEvidenceReview.providerStatusWarnings(in: document), ["mar-1"])

        func unresolvedIDs(inMonth month: Int) throws -> [String] {
            let interval = ReviewInterval.month(MonthKey(year: 2026, month: month))
            return try ReviewEngine.review(
                ReviewRequest(
                    document: document, kind: .monthly, interval: interval,
                    asOf: day("2026-08-31"),
                    coverage: ReviewCoverageInput(liveCoveredIntervals: [interval])
                )
            )
            .findings
            .filter { $0.kind == .unresolvedEvidenceAffectingAccuracy }
            .flatMap(\.ids)
        }

        XCTAssertTrue(try unresolvedIDs(inMonth: 3).contains("mar-1"), "March owns it")
        XCTAssertFalse(try unresolvedIDs(inMonth: 8).contains("mar-1"), "August does not")
        XCTAssertFalse(try unresolvedIDs(inMonth: 4).contains("mar-1"), "nor any other month")
    }


    /// Proves the fallback this change deleted was unreachable rather than
    /// merely unused. `economicPeriodDay` and `cutoverComparisonDate` order
    /// the same four provider dates differently, so they can disagree about
    /// *which* day — but they are nil under exactly one condition, all four
    /// absent, and `x ?? y` can therefore never reach `y`.
    func testEconomicPeriodDayAndCutoverDateAreNilTogetherForEveryDateShape() throws {
        func day(_ iso: String) -> Day { Day(isoString: iso)! }
        func euro(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .eur)! }
        let candidates: [String?] = [nil, "2026-08-15", "2026-09-01"]
        var disagreedOnTheDay = 0

        for booking in candidates {
            for transaction in candidates {
                for value in candidates {
                    for derived in candidates {
                        let observation = ExternalObservation(
                            id: "o", bindingID: "b", provider: .bnp, status: .booked,
                            creditDebitIndicator: .debit, amount: euro("-1.00"),
                            bookingDate: booking.map(day),
                            transactionDate: transaction.map(day),
                            valueDate: value.map(day),
                            derivedTransactionDate: derived.map(day),
                            derivedDateProvenance: derived == nil ? nil : .parsedFromProviderRemittance,
                            eligibleForEconomicActual: true,
                            observedAt: Date(timeIntervalSince1970: 0)
                        )
                        XCTAssertEqual(
                            observation.economicPeriodDay == nil,
                            observation.cutoverComparisonDate == nil,
                            "b=\(booking ?? "-") t=\(transaction ?? "-") v=\(value ?? "-") d=\(derived ?? "-")"
                        )
                        if observation.economicPeriodDay != observation.cutoverComparisonDate {
                            disagreedOnTheDay += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(
            disagreedOnTheDay, 0,
            "the two rules genuinely differ on the day; only their nil-ness coincides"
        )
    }

}
