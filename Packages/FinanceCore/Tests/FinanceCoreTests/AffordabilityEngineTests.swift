import XCTest
@testable import FinanceCore

/// Phase 2.7 — affordability engine.
///
/// Every fixture is synthetic. Amounts and account names are invented for the
/// test; none of them is anybody's financial data.
final class AffordabilityEngineTests: XCTestCase {

    private func euro(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .eur)! }
    private func mad(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .mad)! }
    private func day(_ iso: String) -> Day { Day(isoString: iso)! }

    private let today = Day(isoString: "2026-09-01")!
    private let horizon = Day(isoString: "2026-09-30")!
    private let september = MonthKey(year: 2026, month: 9)

    private var bnp: Account {
        Account(
            id: "bnp", name: "BNP", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 0
        )
    }
    private var revolut: Account {
        Account(
            id: "revolut", name: "Revolut", currency: .eur, kind: .wallet,
            supportedRails: PaymentRail.euroWalletRails, drawOrder: 1
        )
    }
    private var savings: Account {
        Account(
            id: "savings", name: "Savings", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 5
        )
    }
    private var cashMAD: Account {
        Account(
            id: "cash-mad", name: "MAD cash", currency: .mad, kind: .cash,
            supportedRails: [.physicalCash], drawOrder: 9
        )
    }

    private func rent(centsAmount: String = "460.00") -> RecurringObligation {
        RecurringObligation(
            id: "ob-rent",
            name: "Rent",
            amount: euro(centsAmount),
            spec: .monthly(onDay: 11, from: september, through: september),
            requirement: PaymentRequirement(currency: .eur, acceptableRails: [.sepaDirectDebit]),
            spendingClass: .essential
        )
    }

    private func document(
        accounts: [Account]? = nil,
        balances: [AccountBalance]? = nil,
        transactions: [Transaction] = [],
        income: [IncomeSource] = [],
        obligations: [RecurringObligation] = [],
        budgets: [BudgetAllocation] = [],
        ceiling: Money? = Money(exactDecimal: "700.00", currency: .eur),
        floor: Money? = nil,
        scenario: Scenario = .base
    ) -> FinanceDocument {
        let accounts = accounts ?? [bnp]
        let balances = balances ?? [
            AccountBalance(accountID: "bnp", balance: euro("800.00"), asOf: today)
        ]
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: accounts,
            balances: balances,
            transactions: transactions,
            incomeSources: income,
            planning: FinanceDocument.Planning(
                defaultScenario: scenario,
                safetyFloor: floor,
                monthlyEconomicCeiling: ceiling,
                budgets: budgets,
                recurringObligations: obligations
            )
        )
    }

    private func candidate(
        amount: String,
        on: String = "2026-09-02",
        kind: AffordabilityCandidateKind = .consumption,
        requirement: PaymentRequirement = .euroBankPayment(),
        settlementAccountID: String? = nil,
        sinkingFundID: String? = nil,
        financing: FinancingProposal? = nil,
        currency: Currency = .eur
    ) -> AffordabilityCandidate {
        AffordabilityCandidate(
            id: "want",
            name: "candidate",
            amount: Money(exactDecimal: amount, currency: currency)!,
            on: day(on),
            requirement: requirement,
            kind: kind,
            settlementAccountID: settlementAccountID,
            sinkingFundID: sinkingFundID,
            financing: financing
        )
    }

    private func evaluate(
        _ document: FinanceDocument,
        _ candidate: AffordabilityCandidate,
        purchases: [PlannedPurchase] = [],
        funds: [SinkingFund] = []
    ) throws -> AffordabilityVerdict {
        try AffordabilityEngine.evaluate(
            AffordabilityRequest(
                document: document,
                today: today,
                horizonEnd: horizon,
                candidate: candidate,
                plannedPurchases: purchases,
                sinkingFunds: funds
            )
        )
    }

    private func virtualFund(reserved: String, id: String = "sf-tech") -> SinkingFund {
        SinkingFund(
            id: id,
            name: id,
            targetAmount: euro("500.00"),
            reservedAmount: euro(reserved)
        )
    }

    // MARK: - Reserved ≠ spent

    func testReservedCashLowersUnreservedNotSpent() throws {
        let doc = document(balances: [AccountBalance(accountID: "bnp", balance: euro("800.00"), asOf: today)])
        let fund = virtualFund(reserved: "200.00")
        let verdict = try evaluate(doc, candidate(amount: "10.00", kind: .reservation), funds: [fund])
        XCTAssertEqual(verdict.cash.ledgerPool, euro("800.00"))
        XCTAssertEqual(verdict.cash.reserved, euro("200.00"))
        XCTAssertEqual(verdict.cash.unreservedPool, euro("600.00"))
        XCTAssertEqual(verdict.budget.spent, euro("0.00"))
        XCTAssertEqual(verdict.economicAmount, euro("0.00"))
        XCTAssertTrue(verdict.reasons.contains(.reservedMoneyIsNotSpent))
        XCTAssertTrue(verdict.reasons.contains(.notEconomicSpending))
        XCTAssertFalse(verdict.reasons.contains(where: { $0 == .overBudget }))
    }

    func testSinkingContributionDoesNotConsumeTheCeiling() throws {
        let doc = document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("800.00"), asOf: today)],
            transactions: [
                Transaction(
                    id: "tx-spent", date: day("2026-09-01"), kind: .expense,
                    legs: [AccountLeg(accountID: "bnp", amount: euro("-100.00"))],
                    factivity: .observed
                )
            ]
        )
        let verdict = try evaluate(
            doc,
            candidate(amount: "50.00", kind: .reservation),
            funds: [virtualFund(reserved: "50.00")]
        )
        XCTAssertEqual(verdict.budget.spent, euro("100.00"))
        XCTAssertEqual(verdict.economicAmount, euro("0.00"))
        XCTAssertEqual(verdict.budget.withinCeiling, true)
        XCTAssertEqual(verdict.overall, .affordable)
    }

    // MARK: - Balance ≠ safe-to-spend

    func testLedgerCoveringAPurchaseIsNotEnoughWhenRentAndReservationsBite() throws {
        let doc = document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("800.00"), asOf: today)],
            obligations: [rent()]
        )
        let verdict = try evaluate(
            doc,
            candidate(amount: "300.00"),
            funds: [virtualFund(reserved: "200.00")]
        )
        XCTAssertGreaterThanOrEqual(verdict.cash.ledgerPool.minorUnits, 30_000)
        XCTAssertEqual(verdict.overall, .notAffordable)
        XCTAssertTrue(verdict.reasons.contains(.accountBalanceIsNotSafeToSpend))
        XCTAssertFalse(verdict.cash.sufficient)
    }

    // MARK: - Planned purchase ≠ transaction

    func testWishlistIsNotAForecastEventAndDoesNotMoveThePool() throws {
        let goal = PlannedPurchase(
            id: "goal-laptop",
            name: "laptop",
            targetAmount: euro("900.00"),
            status: .planned,
            requirement: .euroBankPayment()
        )
        let doc = document()
        let withGoal = try evaluate(doc, candidate(amount: "1.00"), purchases: [goal])
        let without = try evaluate(doc, candidate(amount: "1.00"))
        XCTAssertEqual(withGoal.baseline.projectedEndBalance, without.baseline.projectedEndBalance)
        XCTAssertEqual(withGoal.cash.reserved, euro("0.00"))
        XCTAssertFalse(withGoal.baseline.appliedEvents.contains { $0.sourceRef == "goal-laptop" })
    }

    func testPurchasedAndCancelledGoalsWithholdNothing() throws {
        let purchases = [
            PlannedPurchase(
                id: "old", name: "old", targetAmount: euro("100.00"),
                status: .purchased, reservedAmount: euro("100.00"),
                requirement: .euroBankPayment()
            ),
            PlannedPurchase(
                id: "nope", name: "nope", targetAmount: euro("100.00"),
                status: .cancelled, reservedAmount: euro("100.00"),
                requirement: .euroBankPayment()
            ),
        ]
        let overlay = ReservationOverlay.apply(
            positions: ReservationOverlay.positions(purchases: purchases, funds: []),
            to: ["bnp": euro("800.00")],
            accounts: [bnp],
            poolRequirement: PaymentRequirement(currency: .eur, acceptableRails: PaymentRail.euroBankRails)
        )
        XCTAssertTrue(overlay.reserved.isEmpty)
        XCTAssertEqual(overlay.availableBalances["bnp"], euro("800.00"))
    }

    func testStatusAloneDoesNotCreateACommitment() throws {
        let reservedGoal = PlannedPurchase(
            id: "goal", name: "goal", targetAmount: euro("100.00"),
            status: .reserved, reservedAmount: euro("0.00"),
            requirement: .euroBankPayment()
        )
        let overlay = ReservationOverlay.apply(
            positions: ReservationOverlay.positions(purchases: [reservedGoal], funds: []),
            to: ["bnp": euro("800.00")],
            accounts: [bnp],
            poolRequirement: PaymentRequirement(currency: .eur, acceptableRails: PaymentRail.euroBankRails)
        )
        XCTAssertTrue(overlay.reserved.isEmpty)
    }

    // MARK: - Sinking-funded purchase consumes reservation

    func testPartialSinkingFundConsumptionDoesNotDoubleCount() throws {
        let doc = document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("1000.00"), asOf: today)]
        )
        let fund = virtualFund(reserved: "500.00")
        let before = fund
        let verdict = try evaluate(
            doc,
            candidate(amount: "400.00", sinkingFundID: "sf-tech"),
            funds: [fund]
        )
        XCTAssertEqual(verdict.sinkingFundConsumption?.reservedBefore, euro("500.00"))
        XCTAssertEqual(verdict.sinkingFundConsumption?.consumed, euro("400.00"))
        XCTAssertEqual(verdict.sinkingFundConsumption?.reservedAfter, euro("100.00"))
        XCTAssertEqual(verdict.after.projectedEndBalance, verdict.baseline.projectedEndBalance)
        XCTAssertTrue(verdict.reasons.contains(.sinkingFundConsumed))
        XCTAssertEqual(fund, before)
        XCTAssertEqual(verdict.budget.economicAmount, euro("400.00"))
        XCTAssertEqual(verdict.budget.withinCeiling, true)
    }

    func testExactSinkingFundConsumption() throws {
        let doc = document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("1000.00"), asOf: today)]
        )
        let verdict = try evaluate(
            doc,
            candidate(amount: "500.00", sinkingFundID: "sf-tech"),
            funds: [virtualFund(reserved: "500.00")]
        )
        XCTAssertEqual(verdict.sinkingFundConsumption?.consumed, euro("500.00"))
        XCTAssertEqual(verdict.sinkingFundConsumption?.reservedAfter, euro("0.00"))
        XCTAssertEqual(verdict.after.projectedEndBalance, verdict.baseline.projectedEndBalance)
    }

    func testInsufficientFundRemainderFromUnreserved() throws {
        let doc = document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("1000.00"), asOf: today)],
            ceiling: euro("2000.00")
        )
        let payable = try evaluate(
            doc,
            candidate(amount: "800.00", sinkingFundID: "sf-tech"),
            funds: [virtualFund(reserved: "500.00")]
        )
        XCTAssertEqual(payable.sinkingFundConsumption?.consumed, euro("500.00"))
        XCTAssertEqual(payable.sinkingFundConsumption?.reservedAfter, euro("0.00"))
        XCTAssertTrue(payable.reasons.contains(.sinkingFundDoesNotFullyCover))
        XCTAssertEqual(payable.overall, .affordable)

        let tooMuch = try evaluate(
            doc,
            candidate(amount: "1300.00", sinkingFundID: "sf-tech"),
            funds: [virtualFund(reserved: "500.00")]
        )
        XCTAssertEqual(tooMuch.overall, .notAffordable)
        XCTAssertFalse(tooMuch.settlement.wouldSettle)
    }

    func testSinkingFundedPurchaseStillCountsAgainstTheCeiling() throws {
        let doc = document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("1000.00"), asOf: today)],
            ceiling: euro("700.00")
        )
        let verdict = try evaluate(
            doc,
            candidate(amount: "800.00", sinkingFundID: "sf-tech"),
            funds: [virtualFund(reserved: "800.00")]
        )
        XCTAssertEqual(verdict.budget.economicAmount, euro("800.00"))
        XCTAssertEqual(verdict.budget.withinCeiling, false)
        XCTAssertEqual(verdict.overall, .notAffordable)
        XCTAssertTrue(verdict.reasons.contains(.overBudget))
        XCTAssertTrue(verdict.cash.sufficient)
    }

    func testCandidateEvaluationDoesNotMutateTheFund() throws {
        let doc = document()
        var funds = [virtualFund(reserved: "200.00")]
        let snapshot = funds
        _ = try evaluate(doc, candidate(amount: "50.00", sinkingFundID: "sf-tech"), funds: funds)
        funds[0].reservedAmount = euro("200.00")
        XCTAssertEqual(funds, snapshot)
    }

    func testGoalAndFundDoNotDoubleReserve() throws {
        let fund = SinkingFund(
            id: "sf-laptop", name: "laptop", goalID: "goal-laptop",
            targetAmount: euro("900.00"), reservedAmount: euro("200.00")
        )
        let goal = PlannedPurchase(
            id: "goal-laptop", name: "laptop", targetAmount: euro("900.00"),
            status: .reserved, funding: .sinkingFund(id: "sf-laptop"),
            reservedAmount: euro("200.00"), requirement: .euroBankPayment()
        )
        let overlay = ReservationOverlay.apply(
            positions: ReservationOverlay.positions(purchases: [goal], funds: [fund]),
            to: ["bnp": euro("800.00")],
            accounts: [bnp],
            poolRequirement: PaymentRequirement(currency: .eur, acceptableRails: PaymentRail.euroBankRails)
        )
        XCTAssertEqual(overlay.reserved.amount(in: .eur), euro("200.00"))
        XCTAssertEqual(overlay.availableBalances["bnp"], euro("600.00"))
    }

    // MARK: - Dedicated custody

    func testDedicatedCustodyWithholdsTheSavingsAccountOnly() throws {
        let fund = SinkingFund(
            id: "sf-dedicated", name: "dedicated",
            targetAmount: euro("300.00"), reservedAmount: euro("200.00"),
            custody: .dedicatedAccount(accountID: "savings")
        )
        let overlay = ReservationOverlay.apply(
            positions: ReservationOverlay.positions(purchases: [], funds: [fund]),
            to: ["bnp": euro("800.00"), "savings": euro("200.00")],
            accounts: [bnp, savings],
            poolRequirement: PaymentRequirement(currency: .eur, acceptableRails: PaymentRail.euroBankRails)
        )
        XCTAssertEqual(overlay.availableBalances["bnp"], euro("800.00"))
        XCTAssertEqual(overlay.availableBalances["savings"], euro("0.00"))
        XCTAssertEqual(overlay.reserved.amount(in: .eur), euro("200.00"))
    }

    func testDedicatedFundCannotPayAnUnrelatedRail() throws {
        let doc = document(
            accounts: [bnp, savings],
            balances: [
                AccountBalance(accountID: "bnp", balance: euro("20.00"), asOf: today),
                AccountBalance(accountID: "savings", balance: euro("500.00"), asOf: today),
            ]
        )
        let fund = SinkingFund(
            id: "sf-dedicated", name: "dedicated",
            targetAmount: euro("500.00"), reservedAmount: euro("500.00"),
            custody: .dedicatedAccount(accountID: "savings")
        )
        let unrelated = try evaluate(
            doc,
            candidate(
                amount: "100.00",
                requirement: PaymentRequirement(currency: .eur, acceptableRails: [.cardDebit]),
                settlementAccountID: "bnp"
            ),
            funds: [fund]
        )
        XCTAssertEqual(unrelated.overall, .notAffordable)
        XCTAssertTrue(unrelated.reasons.contains(.settlementAccountInsufficient))
        XCTAssertEqual(unrelated.cash.ledgerPool, euro("520.00"))
        XCTAssertEqual(unrelated.cash.unreservedPool, euro("20.00"))
        XCTAssertEqual(unrelated.settlement.settlementAvailable, euro("20.00"))
        XCTAssertLessThan(unrelated.settlement.settlementAvailable.minorUnits, 10000)

        let funded = try evaluate(
            doc,
            candidate(amount: "100.00", sinkingFundID: "sf-dedicated"),
            funds: [fund]
        )
        XCTAssertEqual(funded.sinkingFundConsumption?.consumed, euro("100.00"))
        XCTAssertEqual(funded.overall, .affordable)
    }

    func testDedicatedExtraIsSpendableButReservedSliceIsNot() throws {
        let doc = document(
            accounts: [bnp, savings],
            balances: [
                AccountBalance(accountID: "bnp", balance: euro("10.00"), asOf: today),
                AccountBalance(accountID: "savings", balance: euro("150.00"), asOf: today),
            ]
        )
        let fund = SinkingFund(
            id: "sf-dedicated", name: "dedicated",
            targetAmount: euro("100.00"), reservedAmount: euro("100.00"),
            custody: .dedicatedAccount(accountID: "savings")
        )
        let extra = try evaluate(
            doc,
            candidate(amount: "40.00", settlementAccountID: "savings"),
            funds: [fund]
        )
        XCTAssertEqual(extra.overall, .affordable)

        let intoReserved = try evaluate(
            doc,
            candidate(amount: "80.00", settlementAccountID: "savings"),
            funds: [fund]
        )
        XCTAssertEqual(intoReserved.overall, .notAffordable)
        XCTAssertTrue(intoReserved.reasons.contains(.settlementAccountInsufficient))
    }

    // MARK: - Settlement liquidity ≠ pooled cash

    func testPooledCashCannotRescueAnUnfundedAccountRail() throws {
        let doc = document(
            accounts: [bnp, revolut],
            balances: [
                AccountBalance(accountID: "bnp", balance: euro("20.00"), asOf: today),
                AccountBalance(accountID: "revolut", balance: euro("500.00"), asOf: today),
            ]
        )
        let verdict = try evaluate(
            doc,
            candidate(
                amount: "100.00",
                requirement: PaymentRequirement(currency: .eur, acceptableRails: [.cardDebit]),
                settlementAccountID: "bnp"
            )
        )
        XCTAssertEqual(verdict.cash.ledgerPool, euro("520.00"))
        XCTAssertEqual(verdict.settlement.poolUnreserved, euro("520.00"))
        XCTAssertEqual(verdict.settlement.settlementAvailable, euro("20.00"))
        XCTAssertFalse(verdict.settlement.wouldSettle)
        XCTAssertEqual(verdict.overall, .notAffordable)
        XCTAssertTrue(verdict.reasons.contains(.poolWouldCoverButSettlementWouldNot))
        XCTAssertTrue(verdict.reasons.contains(.settlementAccountInsufficient))
    }

    // MARK: - Financing counted once

    func testFinancingPurchaseCountsEconomicallyOnce() throws {
        let doc = document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("800.00"), asOf: today)],
            ceiling: euro("500.00")
        )
        let proposal = FinancingProposal(
            originalPurchaseAmount: euro("324.89"),
            installments: [
                Installment(sequence: 1, dueDate: day("2026-09-02"), amount: euro("81.23")),
                Installment(sequence: 2, dueDate: day("2026-09-09"), amount: euro("81.22")),
                Installment(sequence: 3, dueDate: day("2026-09-16"), amount: euro("81.22")),
                Installment(sequence: 4, dueDate: day("2026-09-23"), amount: euro("81.22")),
            ]
        )
        let verdict = try evaluate(
            doc,
            candidate(amount: "81.23", kind: .financingPurchase, financing: proposal)
        )
        XCTAssertEqual(verdict.economicAmount, euro("324.89"))
        XCTAssertEqual(verdict.cashAmount, euro("324.89"))
        XCTAssertEqual(verdict.budget.withinCeiling, true)
        XCTAssertTrue(verdict.reasons.contains(.financingDoesNotDoubleCount))
        XCTAssertFalse(verdict.reasons.contains(.overBudget))
        let installmentEvents = verdict.after.appliedEvents.filter { $0.id.hasPrefix("afford-want-inst-") }
        XCTAssertEqual(installmentEvents.count, 4)
        XCTAssertFalse(verdict.after.appliedEvents.contains { $0.id == "afford-want" })
    }

    // MARK: - Timing / first-risk

    func testSmallPreRentPurchaseLeavesRentCovered() throws {
        let doc = document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("500.00"), asOf: today)],
            obligations: [rent()],
            floor: nil
        )
        let verdict = try evaluate(doc, candidate(amount: "30.00"))
        XCTAssertEqual(verdict.overall, .affordable)
        XCTAssertNil(verdict.timing.firstNegativeAfter)
        XCTAssertTrue(verdict.reasons.contains(.firstRiskUnchanged))
    }

    func testPreRentPurchaseThatBouncesRentReportsTheRentDay() throws {
        let doc = document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("500.00"), asOf: today)],
            obligations: [rent()],
            floor: nil
        )
        let verdict = try evaluate(doc, candidate(amount: "450.00"))
        XCTAssertEqual(verdict.overall, .notAffordable)
        XCTAssertEqual(verdict.timing.firstNegativeAfter, day("2026-09-11"))
        XCTAssertTrue(verdict.timing.deficitWorsened)
        XCTAssertTrue(verdict.reasons.contains(.newPoolDeficit))
        XCTAssertEqual(verdict.timing.firstRiskAfter?.triggerLabel, "ob-rent")
    }

    func testFloorOnlyBreachIsConditionalNotAHardDeficit() throws {
        let doc = document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("500.00"), asOf: today)],
            floor: euro("400.00")
        )
        let verdict = try evaluate(doc, candidate(amount: "150.00", on: "2026-09-02"))
        XCTAssertNil(verdict.timing.firstNegativeAfter)
        XCTAssertEqual(verdict.timing.firstBelowFloorAfter, day("2026-09-02"))
        XCTAssertTrue(verdict.timing.newFloorBreach)
        XCTAssertEqual(verdict.overall, .affordableConditionally)
        XCTAssertTrue(verdict.reasons.contains(.newFloorBreach))
    }

    // MARK: - Strict ceiling

    func testCashRichOverCeilingConsumptionIsNotAffordable() throws {
        let doc = document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("2000.00"), asOf: today)],
            transactions: [
                Transaction(
                    id: "tx-spent", date: day("2026-09-01"), kind: .expense,
                    legs: [AccountLeg(accountID: "bnp", amount: euro("-200.00"))],
                    factivity: .observed
                )
            ],
            obligations: [rent()],
            ceiling: euro("700.00")
        )
        let over = try evaluate(doc, candidate(amount: "50.00"))
        XCTAssertEqual(over.overall, .notAffordable)
        XCTAssertTrue(over.reasons.contains(.overBudget))
        XCTAssertTrue(over.cash.sufficient)

        let within = try evaluate(doc, candidate(amount: "30.00"))
        XCTAssertEqual(within.overall, .affordable)
        XCTAssertTrue(within.reasons.contains(.withinBudget))
    }

    func testDiscretionaryPurchaseReducesOptionalEnvelopeNotFood() throws {
        let budgets = [
            BudgetAllocation(
                id: "food", name: "food", spendingClass: .essential,
                monthlyAmount: euro("85.00"), effectiveFrom: MonthKey(year: 2026, month: 1),
                confirmation: .userConfirmed
            ),
            BudgetAllocation(
                id: "wants", name: "wants", spendingClass: .optional,
                monthlyAmount: euro("40.00"), effectiveFrom: MonthKey(year: 2026, month: 1),
                confirmation: .userConfirmed
            ),
        ]
        let doc = document(budgets: budgets)
        let verdict = try evaluate(doc, candidate(amount: "40.00", on: "2026-09-15"))
        let foodAfter = verdict.after.appliedEvents.filter { $0.id.hasPrefix("var-food-") }
        let foodBefore = verdict.baseline.appliedEvents.filter { $0.id.hasPrefix("var-food-") }
        let wantsAfter = verdict.after.appliedEvents.filter { $0.id.hasPrefix("var-wants-") }
        let wantsBefore = verdict.baseline.appliedEvents.filter { $0.id.hasPrefix("var-wants-") }
        XCTAssertEqual(foodAfter.count, foodBefore.count)
        XCTAssertFalse(wantsBefore.isEmpty)
        XCTAssertTrue(wantsAfter.isEmpty)
    }

    // MARK: - FX

    func testMADNeverSettlesAEuroRail() throws {
        let doc = document(
            accounts: [bnp, cashMAD],
            balances: [
                AccountBalance(accountID: "bnp", balance: euro("800.00"), asOf: today),
                AccountBalance(accountID: "cash-mad", balance: mad("200.00"), asOf: today),
            ]
        )
        let euroRail = try evaluate(
            doc,
            candidate(
                amount: "100.00",
                requirement: .euroBankPayment(),
                currency: .mad
            )
        )
        XCTAssertEqual(euroRail.overall, .notAffordable)
        XCTAssertTrue(euroRail.reasons.contains(.ineligibleCurrencyOrRail))
        XCTAssertTrue(euroRail.reasons.contains(.foreignCurrencyNotConverted))
        XCTAssertTrue(euroRail.cash.ineligible)

        let cashPurchase = try evaluate(
            doc,
            candidate(
                amount: "100.00",
                requirement: PaymentRequirement(currency: .mad, acceptableRails: [.physicalCash]),
                currency: .mad
            )
        )
        XCTAssertFalse(cashPurchase.cash.ineligible)
        XCTAssertEqual(cashPurchase.economicAmount.currency, .mad)
    }

    // MARK: - Future income

    func testPossibleCAFDoesNotMakeAPurchaseAffordable() throws {
        let caf = IncomeSource(
            id: "caf", name: "CAF", amount: euro("190.00"), certainty: .possible,
            schedule: .oneShot(on: day("2026-09-12")), arrivesOnAccount: "bnp"
        )
        let job = IncomeSource(
            id: "job", name: "job", amount: euro("253.00"), certainty: .target,
            schedule: .oneShot(on: day("2026-09-25")), arrivesOnAccount: "bnp"
        )
        let doc = document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("500.00"), asOf: today)],
            income: [caf, job],
            obligations: [rent()],
            floor: nil
        )
        let verdict = try evaluate(doc, candidate(amount: "80.00", on: "2026-09-13"))
        XCTAssertTrue(verdict.funding.excludedIncomeIDs.contains("caf"))
        XCTAssertTrue(verdict.funding.excludedIncomeIDs.contains("job"))
        XCTAssertNotEqual(verdict.overall, .affordable)
        if verdict.overall == .affordableConditionally, let required = verdict.funding.requiredCertainty {
            XCTAssertTrue([IncomeCertainty.target, .possible].contains(required))
        }
    }

    func testDependsOnDoesNotPromoteCAF() throws {
        let job = IncomeSource(
            id: "job", name: "job", amount: euro("253.00"), certainty: .target,
            schedule: .oneShot(on: day("2026-09-25")), arrivesOnAccount: "bnp"
        )
        let caf = IncomeSource(
            id: "caf", name: "CAF", amount: euro("190.00"), certainty: .expected,
            schedule: .oneShot(on: day("2026-09-20")), dependsOn: ["job"], arrivesOnAccount: "bnp"
        )
        let parents = IncomeSource(
            id: "parents", name: "parents", amount: euro("800.00"), certainty: .guaranteed,
            schedule: .oneShot(on: day("2026-09-16")), arrivesOnAccount: "bnp"
        )
        let doc = document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("100.00"), asOf: today)],
            income: [caf, job, parents],
            obligations: [rent()],
            floor: nil
        )
        let verdict = try evaluate(doc, candidate(amount: "10.00", on: "2026-09-12"))
        XCTAssertTrue(verdict.baseline.includedIncomeEventIDs.contains("parents"))
        XCTAssertTrue(verdict.funding.excludedIncomeIDs.contains("caf"))
        XCTAssertTrue(verdict.funding.excludedIncomeIDs.contains("job"))
    }

    func testBaseFailureWithPossibleSuccessIsConditional() throws {
        let caf = IncomeSource(
            id: "caf", name: "CAF", amount: euro("190.00"), certainty: .possible,
            schedule: .oneShot(on: day("2026-09-12")), arrivesOnAccount: "bnp"
        )
        let doc = document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("500.00"), asOf: today)],
            income: [caf],
            obligations: [rent()],
            floor: nil
        )
        let verdict = try evaluate(doc, candidate(amount: "80.00", on: "2026-09-13"))
        XCTAssertEqual(verdict.overall, .affordableConditionally)
        XCTAssertEqual(verdict.funding.requiredCertainty, .possible)
        XCTAssertTrue(verdict.reasons.contains(.dependsOnExcludedIncome))
    }

    // MARK: - Determinism / purity

    func testShuffledIncomeOrderDoesNotChangeTheVerdict() throws {
        let a = IncomeSource(
            id: "a", name: "a", amount: euro("50.00"), certainty: .guaranteed,
            schedule: .oneShot(on: day("2026-09-18")), arrivesOnAccount: "bnp"
        )
        let b = IncomeSource(
            id: "b", name: "b", amount: euro("100.00"), certainty: .expected,
            schedule: .oneShot(on: day("2026-09-20")), arrivesOnAccount: "bnp"
        )
        let first = try evaluate(
            document(
                balances: [AccountBalance(accountID: "bnp", balance: euro("500.00"), asOf: today)],
                income: [a, b],
                obligations: [rent(centsAmount: "200.00")],
                floor: nil
            ),
            candidate(amount: "50.00", on: "2026-09-05")
        )
        let second = try evaluate(
            document(
                balances: [AccountBalance(accountID: "bnp", balance: euro("500.00"), asOf: today)],
                income: [b, a],
                obligations: [rent(centsAmount: "200.00")],
                floor: nil
            ),
            candidate(amount: "50.00", on: "2026-09-05")
        )
        XCTAssertEqual(first.overall, second.overall)
        XCTAssertEqual(first.reasons, second.reasons)
        XCTAssertEqual(first.after.lowestBalance, second.after.lowestBalance)
        XCTAssertEqual(first.after.appliedEvents.map(\.id), second.after.appliedEvents.map(\.id))
    }
}
