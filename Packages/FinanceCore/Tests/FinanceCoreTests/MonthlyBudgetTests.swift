import XCTest
@testable import FinanceCore

/// Phase 2.5 — monthly budget control.
///
/// Every fixture here is synthetic. The shapes are real (a gross ceiling that
/// includes housing, a recurring charge that settles, a refund that corrects a
/// purchase); the amounts, names and accounts are invented for the test and
/// none of them belongs to anybody.
final class MonthlyBudgetTests: XCTestCase {

    // MARK: - Fixture vocabulary

    private func euro(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .eur)! }
    private func day(_ iso: String) -> Day { Day(isoString: iso)! }
    private let september = MonthKey(year: 2026, month: 9)

    private let bank = Account(
        id: "bank", name: "Bank", currency: .eur, kind: .bank,
        supportedRails: [.cardDebit, .sepaCreditTransfer, .sepaDirectDebit], drawOrder: 0
    )
    private let wallet = Account(
        id: "wallet", name: "Wallet", currency: .eur, kind: .wallet,
        supportedRails: [.electronicPayment], drawOrder: 1
    )
    private let cash = Account(
        id: "cash", name: "Cash", currency: .eur, kind: .cash,
        supportedRails: [.physicalCash], drawOrder: 2
    )

    private func budget(
        _ id: String,
        _ amount: String,
        categoryKeys: [String] = [],
        confirmation: BudgetConfirmation = .userConfirmed,
        spendingClass: SpendingClass = .flexible
    ) -> BudgetAllocation {
        BudgetAllocation(
            id: id,
            name: id,
            spendingClass: spendingClass,
            monthlyAmount: euro(amount),
            effectiveFrom: MonthKey(year: 2026, month: 1),
            confirmation: confirmation,
            categoryKeys: categoryKeys
        )
    }

    private func expense(
        _ id: String, _ amount: String, on iso: String,
        account: String = "bank", lifecycle: TransactionLifecycle? = nil
    ) -> Transaction {
        Transaction(
            id: id, date: day(iso), kind: .expense,
            legs: [AccountLeg(accountID: account, amount: euro("-\(amount)"))],
            factivity: .observed, lifecycle: lifecycle
        )
    }

    private func document(
        transactions: [Transaction] = [],
        budgets: [BudgetAllocation] = [],
        obligations: [RecurringObligation] = [],
        settlements: [ObligationSettlement] = [],
        ceiling: Money? = nil
    ) -> FinanceDocument {
        FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [bank, wallet, cash],
            balances: [
                AccountBalance(accountID: "bank", balance: euro("500.00"), asOf: day("2026-09-01"))
            ],
            transactions: transactions,
            planning: FinanceDocument.Planning(
                monthlyEconomicCeiling: ceiling,
                budgets: budgets,
                recurringObligations: obligations,
                settlements: settlements
            )
        )
    }

    private func report(
        _ document: FinanceDocument,
        today: String = "2026-09-15",
        categoryKeys: [String: String] = [:]
    ) -> MonthlyBudgetReport {
        MonthlyBudgetEngine.report(
            month: september,
            today: day(today),
            document: document,
            categoryKeys: categoryKeys
        )
    }

    // MARK: - Only economic spending counts

    func testAnExpenseCountsAgainstTheLineThatClaimsItsCategory() {
        let result = report(
            document(
                transactions: [expense("t1", "24.50", on: "2026-09-04")],
                budgets: [budget("groceries", "70.00", categoryKeys: ["food"])]
            ),
            categoryKeys: ["t1": "food"]
        )
        XCTAssertEqual(result.lines.first?.spent, euro("24.50"))
        XCTAssertEqual(result.lines.first?.remaining, euro("45.50"))
        XCTAssertEqual(result.spent, euro("24.50"))
        XCTAssertEqual(result.uncategorized, euro("0.00"))
    }

    func testATransferBetweenOwnAccountsIsNotSpending() {
        let transfer = Transaction(
            id: "mv", date: day("2026-09-05"), kind: .transfer,
            legs: [
                AccountLeg(accountID: "bank", amount: euro("-120.00")),
                AccountLeg(accountID: "wallet", amount: euro("120.00")),
            ],
            factivity: .observed
        )
        let result = report(
            document(
                transactions: [transfer],
                budgets: [budget("everyday", "100.00", categoryKeys: ["other"])]
            ),
            categoryKeys: ["mv": "other"]
        )
        XCTAssertEqual(result.spent, euro("0.00"))
        XCTAssertEqual(result.lines.first?.spent, euro("0.00"))
    }

    func testACashWithdrawalIsNotSpending() {
        let withdrawal = Transaction(
            id: "atm", date: day("2026-09-06"), kind: .cashWithdrawal,
            legs: [
                AccountLeg(accountID: "bank", amount: euro("-40.00")),
                AccountLeg(accountID: "cash", amount: euro("40.00")),
            ],
            factivity: .observed
        )
        let result = report(
            document(
                transactions: [withdrawal],
                budgets: [budget("everyday", "100.00", categoryKeys: ["other"])]
            ),
            categoryKeys: ["atm": "other"]
        )
        XCTAssertEqual(result.spent, euro("0.00"))
    }

    func testAPassThroughCarriesNoPersonalSpending() {
        let arrival = Transaction(
            id: "in", date: day("2026-09-07"), kind: .passThrough,
            legs: [AccountLeg(accountID: "bank", amount: euro("300.00"))],
            ownership: [OwnershipSplit(ownerID: "other", isSelf: false, amount: euro("300.00"))],
            factivity: .observed
        )
        let disposal = Transaction(
            id: "out", date: day("2026-09-08"), kind: .passThrough,
            legs: [AccountLeg(accountID: "bank", amount: euro("-300.00"))],
            linkedTransactionID: "in",
            factivity: .observed
        )
        let result = report(
            document(
                transactions: [arrival, disposal],
                budgets: [budget("everyday", "100.00", categoryKeys: ["other"])]
            ),
            categoryKeys: ["in": "other", "out": "other"]
        )
        XCTAssertEqual(result.spent, euro("0.00"))
    }

    func testAFinancingRepaymentIsCashOutButNotNewSpending() {
        let repayment = Transaction(
            id: "rep", date: day("2026-09-09"), kind: .financingRepayment,
            legs: [AccountLeg(accountID: "wallet", amount: euro("-24.00"))],
            installmentPlanID: "plan", factivity: .observed
        )
        let result = report(
            document(
                transactions: [repayment],
                budgets: [budget("everyday", "100.00", categoryKeys: ["shopping"])]
            ),
            categoryKeys: ["rep": "shopping"]
        )
        XCTAssertEqual(result.spent, euro("0.00"), "a repayment consumes nothing new")
        XCTAssertEqual(result.financingRepayments, euro("24.00"), "but the cash still left")
    }

    func testAReversedExpenseCountsForNothing() {
        let result = report(
            document(
                transactions: [expense("rev", "480.00", on: "2026-09-11", lifecycle: .reversed)],
                budgets: [budget("housing", "480.00", categoryKeys: ["housing"])]
            ),
            categoryKeys: ["rev": "housing"]
        )
        XCTAssertEqual(result.spent, euro("0.00"))
        XCTAssertEqual(result.lines.first?.remaining, euro("480.00"))
    }

    func testARefundCorrectsTheLineOfTheExpenseItReverses() {
        let purchase = expense("buy", "40.00", on: "2026-09-02")
        let refund = Transaction(
            id: "back", date: day("2026-09-12"), kind: .refund,
            legs: [AccountLeg(accountID: "bank", amount: euro("15.00"))],
            linkedTransactionID: "buy", factivity: .observed
        )
        let result = report(
            document(
                transactions: [purchase, refund],
                budgets: [budget("shopping", "50.00", categoryKeys: ["shopping"])]
            ),
            // The credit itself carries no category; only the purchase does.
            categoryKeys: ["buy": "shopping"]
        )
        XCTAssertEqual(result.lines.first?.spent, euro("25.00"))
        XCTAssertEqual(result.spent, euro("25.00"))
        XCTAssertEqual(result.uncategorized, euro("0.00"))
    }

    func testARefundOfAReversedChargeGivesBackNothing() {
        // A contested direct debit arrives as two facts: the debit, marked
        // reversed, and the credit that undid it. Counting both would score
        // the month at minus the rent.
        let debit = expense("rent", "480.00", on: "2026-09-12", lifecycle: .reversed)
        let reversal = Transaction(
            id: "rent-back", date: day("2026-09-17"), kind: .refund,
            legs: [AccountLeg(accountID: "bank", amount: euro("480.00"))],
            linkedTransactionID: "rent", factivity: .observed
        )
        let result = report(
            document(
                transactions: [debit, reversal],
                budgets: [budget("housing", "480.00", categoryKeys: ["housing"])],
                ceiling: euro("700.00")
            ),
            categoryKeys: ["rent": "housing", "rent-back": "housing"]
        )
        XCTAssertEqual(result.spent, euro("0.00"), "nothing was consumed and nothing was given back")
        XCTAssertEqual(result.uncategorized, euro("0.00"))
        XCTAssertEqual(result.lines.first?.spent, euro("0.00"))
        XCTAssertEqual(result.lines.first?.remaining, euro("480.00"))
    }

    func testHeadroomNeverExceedsTheCeiling() {
        // The visible symptom of the bug above: a month with nothing spent
        // reported more headroom than the ceiling allows.
        let debit = expense("rent", "480.00", on: "2026-09-12", lifecycle: .reversed)
        let reversal = Transaction(
            id: "rent-back", date: day("2026-09-17"), kind: .refund,
            legs: [AccountLeg(accountID: "bank", amount: euro("480.00"))],
            linkedTransactionID: "rent", factivity: .observed
        )
        let result = report(
            document(transactions: [debit, reversal], budgets: [], ceiling: euro("700.00"))
        )
        XCTAssertFalse(result.spent.isNegative, "spending is consumption, and consumption is not negative")
        XCTAssertEqual(result.safeToSpendBudget, euro("700.00"))
    }

    func testARefundOfAChargeThatActuallyHappenedStillGivesItBack() {
        // The rule is narrow: only a refund of a *reversed* charge is void.
        let purchase = expense("buy", "40.00", on: "2026-09-02")
        let refund = Transaction(
            id: "back", date: day("2026-09-12"), kind: .refund,
            legs: [AccountLeg(accountID: "bank", amount: euro("15.00"))],
            linkedTransactionID: "buy", factivity: .observed
        )
        let result = report(
            document(
                transactions: [purchase, refund],
                budgets: [budget("shopping", "50.00", categoryKeys: ["shopping"])]
            ),
            categoryKeys: ["buy": "shopping"]
        )
        XCTAssertEqual(result.spent, euro("25.00"))
    }

    func testAnUnlinkedRefundStillOffsetsSpending() {
        // With no link there is nothing to check, and money genuinely came
        // back, so it counts.
        let refund = Transaction(
            id: "loose", date: day("2026-09-12"), kind: .refund,
            legs: [AccountLeg(accountID: "bank", amount: euro("15.00"))],
            factivity: .observed
        )
        let result = report(
            document(
                transactions: [expense("buy", "40.00", on: "2026-09-02"), refund],
                budgets: [budget("shopping", "50.00", categoryKeys: ["shopping"])]
            ),
            categoryKeys: ["buy": "shopping", "loose": "shopping"]
        )
        XCTAssertEqual(result.spent, euro("25.00"))
    }

    // MARK: - Uncategorised spending is still spending

    func testSpendingNoLineClaimsIsCountedAndNamed() {
        let result = report(
            document(
                transactions: [
                    expense("known", "20.00", on: "2026-09-03"),
                    expense("stray", "31.25", on: "2026-09-10"),
                ],
                budgets: [budget("groceries", "70.00", categoryKeys: ["food"])]
            ),
            categoryKeys: ["known": "food", "stray": "health"]
        )
        XCTAssertEqual(result.lines.first?.spent, euro("20.00"))
        XCTAssertEqual(result.uncategorized, euro("31.25"))
        XCTAssertEqual(result.spent, euro("51.25"), "the total hides nothing")
    }

    // MARK: - Expected and actual are counted exactly once

    private func rent(budgetID: String?) -> RecurringObligation {
        RecurringObligation(
            id: "ob-housing", name: "Landlord", amount: euro("-480.00"),
            spec: .monthly(onDay: 12, from: MonthKey(year: 2026, month: 1), through: nil),
            requirement: PaymentRequirement(currency: .eur, acceptableRails: [.sepaDirectDebit]),
            spendingClass: .essential, budgetID: budgetID
        )
    }

    func testAnUnsettledObligationIsCommittedAndNotSpent() {
        let result = report(
            document(
                budgets: [budget("housing", "480.00")],
                obligations: [rent(budgetID: "housing")]
            ),
            today: "2026-09-01"
        )
        XCTAssertEqual(result.committed, euro("480.00"))
        XCTAssertEqual(result.spent, euro("0.00"))
        XCTAssertEqual(result.lines.first?.committed, euro("480.00"))
        XCTAssertEqual(result.lines.first?.remainingAfterCommitted, euro("0.00"))
    }

    func testASettledObligationIsSpentOnceAndNoLongerCommitted() {
        let actual = expense("rent-actual", "480.00", on: "2026-09-12")
        let result = report(
            document(
                transactions: [actual],
                budgets: [budget("housing", "480.00")],
                obligations: [rent(budgetID: "housing")],
                settlements: [
                    ObligationSettlement(
                        id: "s1", obligationID: "ob-housing", expectedDay: day("2026-09-12"),
                        resolution: .paid, actualTransactionID: "rent-actual"
                    )
                ]
            )
        )
        XCTAssertEqual(result.spent, euro("480.00"))
        XCTAssertEqual(result.committed, euro("0.00"), "settling it must not leave it owed as well")
        XCTAssertEqual(result.lines.first?.spent, euro("480.00"))
        XCTAssertEqual(result.lines.first?.remaining, euro("0.00"))
    }

    func testASettledActualReachesItsLineWithoutAnyCategory() {
        let actual = expense("rent-actual", "480.00", on: "2026-09-12")
        let result = report(
            document(
                transactions: [actual],
                budgets: [budget("housing", "480.00")],
                obligations: [rent(budgetID: "housing")],
                settlements: [
                    ObligationSettlement(
                        id: "s1", obligationID: "ob-housing", expectedDay: day("2026-09-12"),
                        resolution: .paid, actualTransactionID: "rent-actual"
                    )
                ]
            )
        )
        XCTAssertEqual(result.uncategorized, euro("0.00"))
        XCTAssertEqual(result.lines.first?.spent, euro("480.00"))
    }

    func testAnUnlinkedObligationCountsInTheMonthTotalButInNoLine() {
        let result = report(
            document(
                budgets: [budget("housing", "480.00")],
                obligations: [rent(budgetID: nil)]
            ),
            today: "2026-09-01"
        )
        XCTAssertEqual(result.committed, euro("480.00"))
        XCTAssertEqual(result.lines.first?.committed, euro("0.00"), "no mapping is invented")
    }

    // MARK: - The gross ceiling

    func testTheCeilingIsGrossAndTheUnclaimedPartIsNamed() {
        let result = report(
            document(
                budgets: [
                    budget("housing", "480.00"),
                    budget("bills", "23.94"),
                    budget("transit", "2.50"),
                    budget("subscriptions", "44.38"),
                ],
                ceiling: euro("700.00")
            ),
            today: "2026-09-01"
        )
        XCTAssertEqual(result.ceiling, euro("700.00"))
        XCTAssertEqual(result.target, euro("550.82"))
        XCTAssertEqual(result.unallocated, euro("149.18"))
    }

    func testSafeToSpendIsMeasuredAgainstTheCeilingNotTheAllocatedTotal() {
        let result = report(
            document(
                transactions: [expense("t", "30.00", on: "2026-09-02")],
                budgets: [budget("groceries", "70.00", categoryKeys: ["food"])],
                obligations: [rent(budgetID: nil)],
                ceiling: euro("700.00")
            ),
            today: "2026-09-01",
            categoryKeys: ["t": "food"]
        )
        // 700 gross − 30 spent − 480.00 still owed.
        XCTAssertEqual(result.safeToSpendBudget, euro("190.00"))
    }

    func testWithoutACeilingHeadroomFallsBackToTheAllocatedTotal() {
        let result = report(
            document(
                transactions: [expense("t", "30.00", on: "2026-09-02")],
                budgets: [budget("groceries", "70.00", categoryKeys: ["food"])]
            ),
            categoryKeys: ["t": "food"]
        )
        XCTAssertNil(result.ceiling)
        XCTAssertNil(result.unallocated)
        XCTAssertEqual(result.safeToSpendBudget, euro("40.00"))
    }

    func testGrossHousingIsNeverReducedByAssistanceInTheBudget() {
        // Assistance is income, and income is not part of this report at all.
        let assistance = Transaction(
            id: "aid", date: day("2026-09-05"), kind: .income,
            legs: [AccountLeg(accountID: "bank", amount: euro("190.00"))],
            factivity: .observed
        )
        let result = report(
            document(
                transactions: [assistance, expense("rent", "480.00", on: "2026-09-12")],
                budgets: [budget("housing", "480.00", categoryKeys: ["housing"])],
                ceiling: euro("700.00")
            ),
            categoryKeys: ["rent": "housing", "aid": "housing"]
        )
        XCTAssertEqual(result.lines.first?.spent, euro("480.00"), "assistance does not discount rent")
        XCTAssertEqual(result.spent, euro("480.00"))
    }

    // MARK: - Overspend

    func testAnOverspentLineSaysSoAndKeepsTheBarFull() {
        let result = report(
            document(
                transactions: [expense("t", "126.00", on: "2026-09-04")],
                budgets: [budget("groceries", "70.00", categoryKeys: ["food"])]
            ),
            categoryKeys: ["t": "food"]
        )
        let line = try! XCTUnwrap(result.lines.first)
        XCTAssertTrue(line.isOverspent)
        XCTAssertEqual(line.remaining, euro("-56.00"))
        XCTAssertEqual(line.fraction, 1.0)
        XCTAssertEqual(line.rawFraction, 1.8, accuracy: 0.0001)
    }

    // MARK: - Pace

    func testPaceSpreadsWhatIsLeftOverTheDaysThatAreLeft() {
        // 15 September: today plus 15 more days remain in a 30-day month.
        let result = report(
            document(budgets: [budget("groceries", "160.00", categoryKeys: ["food"])]),
            today: "2026-09-15"
        )
        let line = try! XCTUnwrap(result.lines.first)
        XCTAssertEqual(result.daysInMonth, 30)
        XCTAssertEqual(result.daysRemaining, 16)
        XCTAssertEqual(result.daysElapsed, 14)
        XCTAssertEqual(line.dailyPace, euro("10.00"))
        XCTAssertEqual(line.weeklyPace, euro("70.00"))
    }

    func testAnOverspentLinePacesAtZeroRatherThanBelowIt() {
        let result = report(
            document(
                transactions: [expense("t", "200.00", on: "2026-09-04")],
                budgets: [budget("groceries", "160.00", categoryKeys: ["food"])]
            ),
            categoryKeys: ["t": "food"]
        )
        XCTAssertEqual(result.lines.first?.dailyPace, euro("0.00"))
    }

    func testAPastMonthHasNoPace() {
        let result = report(
            document(budgets: [budget("groceries", "160.00", categoryKeys: ["food"])]),
            today: "2026-11-02"
        )
        XCTAssertEqual(result.daysRemaining, 0)
        XCTAssertFalse(result.isCurrentMonth)
        XCTAssertNil(result.lines.first?.dailyPace)
    }

    // MARK: - Suggestion is not consent

    func testASuggestedSplitIsNeverReportedAsAgreed() {
        let result = report(
            document(
                budgets: [
                    budget("groceries", "70.00", categoryKeys: ["food"], confirmation: .suggested),
                    budget("transport", "10.00", categoryKeys: ["transport"], confirmation: .suggested),
                ]
            )
        )
        XCTAssertTrue(result.isEntirelySuggested)
        XCTAssertTrue(result.lines.allSatisfy { $0.confirmation == .suggested })
    }

    func testAConfirmedLineIsDistinguishableFromAProposedOne() {
        let result = report(
            document(
                budgets: [
                    budget("housing", "480.00", confirmation: .userConfirmed),
                    budget("groceries", "70.00", categoryKeys: ["food"], confirmation: .suggested),
                ]
            )
        )
        XCTAssertFalse(result.isEntirelySuggested)
        XCTAssertEqual(result.lines.first { $0.id == "housing" }?.confirmation, .userConfirmed)
    }

    // MARK: - Scope

    func testOnlyThisMonthAndOnlyObservedFactsAreCounted() {
        let planned = Transaction(
            id: "future", date: day("2026-09-20"), kind: .expense,
            legs: [AccountLeg(accountID: "bank", amount: euro("-99.00"))],
            factivity: .expected
        )
        let result = report(
            document(
                transactions: [
                    expense("august", "50.00", on: "2026-08-30"),
                    expense("september", "12.00", on: "2026-09-02"),
                    expense("october", "77.00", on: "2026-10-01"),
                    planned,
                ],
                budgets: [budget("everyday", "100.00", categoryKeys: ["other"])]
            ),
            categoryKeys: [
                "august": "other", "september": "other",
                "october": "other", "future": "other",
            ]
        )
        XCTAssertEqual(result.spent, euro("12.00"))
    }

    func testALineNotInEffectThisMonthDoesNotAppear() {
        let later = BudgetAllocation(
            id: "electricity", name: "Electricity", spendingClass: .essential,
            monthlyAmount: euro("45.00"), effectiveFrom: MonthKey(year: 2026, month: 11),
            confirmation: .userConfirmed
        )
        let result = report(document(budgets: [later, budget("groceries", "70.00")]))
        XCTAssertEqual(result.lines.map(\.id), ["groceries"])
        XCTAssertEqual(result.target, euro("70.00"))
    }

    func testAMonthOverrideBeatsTheBaseAmount() {
        let variable = BudgetAllocation(
            id: "variable", name: "Variable", spendingClass: .flexible,
            monthlyAmount: euro("170.00"), effectiveFrom: MonthKey(year: 2026, month: 1),
            monthlyOverrides: [september: euro("85.00")], confirmation: .userConfirmed
        )
        XCTAssertEqual(report(document(budgets: [variable])).target, euro("85.00"))
    }

    // MARK: - Currency

    func testAForeignLineStaysVisibleWithoutBeingSummedIntoEuros() {
        let market = BudgetAllocation(
            id: "market", name: "Market", spendingClass: .flexible,
            monthlyAmount: Money(minorUnits: 30_000, currency: .mad),
            effectiveFrom: MonthKey(year: 2026, month: 1), confirmation: .userConfirmed
        )
        let result = report(
            document(budgets: [market, budget("groceries", "70.00", categoryKeys: ["food"])])
        )
        XCTAssertEqual(result.lines.map(\.id), ["groceries"])
        XCTAssertEqual(result.otherCurrencyLines.map(\.id), ["market"])
        XCTAssertEqual(result.target, euro("70.00"), "no rate is invented to sum dirhams into euros")
        XCTAssertEqual(
            result.otherCurrencyLines.first?.target,
            Money(minorUnits: 30_000, currency: .mad)
        )
    }

    func testAForeignLineCountsSpendingInItsOwnCurrency() {
        let market = BudgetAllocation(
            id: "market", name: "Market", spendingClass: .flexible,
            monthlyAmount: Money(minorUnits: 30_000, currency: .mad),
            effectiveFrom: MonthKey(year: 2026, month: 1),
            confirmation: .userConfirmed, categoryKeys: ["food"]
        )
        let dirhamSpend = Transaction(
            id: "souk", date: day("2026-09-06"), kind: .expense,
            legs: [AccountLeg(
                accountID: "cash-mad",
                amount: Money(minorUnits: -12_000, currency: .mad)
            )],
            factivity: .observed
        )
        let result = report(
            document(transactions: [dirhamSpend], budgets: [market]),
            categoryKeys: ["souk": "food"]
        )
        XCTAssertEqual(
            result.otherCurrencyLines.first?.spent,
            Money(minorUnits: 12_000, currency: .mad)
        )
        XCTAssertEqual(result.spent, euro("0.00"), "a dirham purchase is not euro spending")
    }

    // MARK: - Attribution is auditable

    func testAttributionSaysWhyEachTransactionLanded() {
        let actual = expense("rent-actual", "480.00", on: "2026-09-12")
        let groceries = expense("g", "20.00", on: "2026-09-03")
        let stray = expense("s", "5.00", on: "2026-09-04")
        let doc = document(
            transactions: [actual, groceries, stray],
            budgets: [
                budget("housing", "480.00"),
                budget("groceries", "70.00", categoryKeys: ["food"]),
            ],
            obligations: [rent(budgetID: "housing")],
            settlements: [
                ObligationSettlement(
                    id: "s1", obligationID: "ob-housing", expectedDay: day("2026-09-12"),
                    resolution: .paid, actualTransactionID: "rent-actual"
                )
            ]
        )
        let attributions = MonthlyBudgetEngine.attributions(
            month: september,
            document: doc,
            lines: doc.planning.budgets,
            ledger: ReconciliationLedger(doc.planning.settlements),
            categoryKeys: ["g": "food"]
        )
        let byID = Dictionary(uniqueKeysWithValues: attributions.map { ($0.transactionID, $0) })
        XCTAssertEqual(byID["rent-actual"]?.basis, .settledObligation(obligationID: "ob-housing"))
        XCTAssertEqual(byID["g"]?.basis, .category("food"))
        XCTAssertEqual(byID["s"]?.basis, .unattributed)
        XCTAssertNil(byID["s"]?.budgetID)
    }

    // MARK: - Schema

    func testBudgetConfirmationAndCeilingSurviveARoundTrip() throws {
        let original = document(
            budgets: [budget("groceries", "70.00", categoryKeys: ["food"], confirmation: .userConfirmed)],
            obligations: [rent(budgetID: "housing")],
            ceiling: euro("700.00")
        )
        let data = try Interchange.encode(original)
        let decoded = try Interchange.decode(data)
        XCTAssertEqual(decoded.planning.monthlyEconomicCeiling, euro("700.00"))
        XCTAssertEqual(decoded.planning.budgets.first?.confirmation, .userConfirmed)
        XCTAssertEqual(decoded.planning.budgets.first?.categoryKeys, ["food"])
        XCTAssertEqual(decoded.planning.recurringObligations.first?.budgetID, "housing")
    }

    func testADocumentWrittenBeforeConfirmationExistedIsNotTreatedAsAgreed() throws {
        let json = """
        {
          "schemaVersion": "1.1.0",
          "documentKind": "TEST",
          "accounts": [],
          "balances": [],
          "transactions": [],
          "expectedTransactions": [],
          "incomeSources": [],
          "installments": [],
          "debts": [],
          "planning": {
            "budgets": [{
              "id": "variable", "name": "Variable", "spendingClass": "flexible",
              "monthlyAmount": "170.00 EUR", "effectiveFrom": "2026-09",
              "monthlyOverrides": []
            }],
            "recurringObligations": [],
            "carriedEURValues": []
          }
        }
        """
        let decoded = try Interchange.decode(Data(json.utf8))
        XCTAssertEqual(decoded.planning.budgets.first?.confirmation, .suggested)
        XCTAssertEqual(decoded.planning.budgets.first?.categoryKeys, [String]())
        XCTAssertNil(decoded.planning.monthlyEconomicCeiling)
    }
}
