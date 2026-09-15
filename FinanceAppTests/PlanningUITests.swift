import Foundation
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

/// Phase 2.7 — Goals, sinking funds, and the affordability sheet.
///
/// Views do not calculate affordability. These tests pin the facade mapping
/// and the store boundary: drafts persist, evaluation is pure, and the sheet
/// presents the engine's axes rather than a Boolean.
///
/// Every figure is synthetic.
@MainActor
@Suite("Phase 2.7 planning UI mapping")
struct PlanningUITests {
    private let today = Day(year: 2026, month: 9, day: 1)
    private var todayDate: Date { fixtureInstant(today) }
    private let mapper = DomainMapper()

    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    private func mad(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .mad)!
    }

    private func bnp() -> Account {
        Account(
            id: "bnp", name: "Bank", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 0
        )
    }

    private func revolut() -> Account {
        Account(
            id: "revolut", name: "Wallet", currency: .eur, kind: .wallet,
            supportedRails: PaymentRail.euroWalletRails, drawOrder: 1
        )
    }

    private func savings() -> Account {
        Account(
            id: "savings", name: "Savings", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 5
        )
    }

    private func cashMAD() -> Account {
        Account(
            id: "cash-mad", name: "MAD cash", currency: .mad, kind: .cash,
            supportedRails: [.physicalCash], drawOrder: 9
        )
    }

    private func rent() -> RecurringObligation {
        RecurringObligation(
            id: "ob-rent", name: "Rent",
            amount: euro("460.00"),
            spec: .monthly(onDay: 11, from: MonthKey(year: 2026, month: 9), through: MonthKey(year: 2026, month: 9)),
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
        installments: [InstallmentPlan] = [],
        ceiling: Money? = Money(exactDecimal: "700.00", currency: .eur)!,
        floor: Money? = nil
    ) -> FinanceDocument {
        let accounts = accounts ?? [bnp()]
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
            installments: installments,
            planning: FinanceDocument.Planning(
                defaultScenario: .base,
                safetyFloor: floor,
                monthlyEconomicCeiling: ceiling,
                recurringObligations: obligations
            )
        )
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func store(_ document: FinanceDocument) throws -> FinanceStore {
        let container = try container()
        try StoredDocumentGraph.replace(with: document, in: container.mainContext, writtenOn: today)
        return try FinanceStore(context: container.mainContext, now: todayDate)
    }

    private func goalDraft(
        name: String = "Laptop",
        amount: String = "900",
        status: GoalStatus = .wishlist,
        funding: GoalFundingKind = .cash,
        sinkingFundID: String? = nil
    ) -> PlannedPurchaseDraft {
        var draft = PlannedPurchaseDraft()
        draft.name = name
        draft.amountText = amount
        draft.status = status
        draft.funding = funding
        draft.sinkingFundID = sinkingFundID
        return draft
    }

    private func fundDraft(
        name: String = "Tech",
        target: String = "900",
        reserved: String = "200",
        custody: FundCustodyKind = .virtual,
        accountID: String? = nil,
        goalID: String? = nil
    ) -> SinkingFundDraft {
        var draft = SinkingFundDraft()
        draft.name = name
        draft.targetText = target
        draft.reservedText = reserved
        draft.custody = custody
        draft.dedicatedAccountID = accountID
        draft.goalID = goalID
        return draft
    }

    // MARK: - Empty state and copy

    @Test("A store without planning rows has empty Plan goals and funds")
    func emptyPlanHasNoGoalsOrFunds() throws {
        let store = try store(document())
        #expect(store.snapshot.plannedPurchases.isEmpty)
        #expect(store.snapshot.sinkingFunds.isEmpty)
        #expect(PlanningCopy.emptyGoals == "Plan something you're saving for")
        #expect(PlanningCopy.emptyFunds == "Set money aside without counting it as spent")
    }

    @Test("Status copy does not treat wishlist as a commitment or bought as a transaction")
    func statusCopyDoesNotInventEconomics() {
        #expect(GoalStatus.wishlist.caption.contains("Not a commitment"))
        #expect(GoalStatus.saving.caption.contains("not spending"))
        #expect(GoalStatus.bought.caption.contains("not the transaction"))
        #expect(GoalStatus.cancelled.caption.contains("No effect on cash"))
    }

    @Test("Critical controls have stable accessibility identifiers")
    func criticalControlIdentifiers() {
        #expect(PlanningControlID.addGoal == "plan.goals.add")
        #expect(PlanningControlID.addFund == "plan.funds.add")
        #expect(PlanningControlID.openAffordability == "plan.afford.open")
        #expect(PlanningControlID.checkAffordability == "afford.check")
        #expect(PlanningControlID.goalName == "goal.name")
        #expect(PlanningControlID.goalSave == "goal.save")
        #expect(PlanningControlID.fundName == "fund.name")
        #expect(PlanningControlID.fundSave == "fund.save")
        #expect(PlanningControlID.affordabilityOverall == "afford.overall")
        #expect(PlanningControlID.affordabilityRisk == "afford.risk")
        #expect(PlanningControlID.reserveAmount == "reserve.amount")
        #expect(PlanningControlID.reserveSave == "reserve.save")
    }

    // MARK: - Goal CRUD

    @Test("Creating a goal persists through the snapshot")
    func createGoalPersists() throws {
        let store = try store(document())
        try store.savePlannedPurchase(goalDraft())
        #expect(store.snapshot.plannedPurchases.count == 1)
        let goal = try #require(store.snapshot.plannedPurchases.first)
        #expect(goal.name == "Laptop")
        #expect(goal.target == .eur(900))
        #expect(goal.status == .wishlist)
        #expect(goal.funding == .cash)
        let exported = try store.exportDocument()
        #expect(exported.planning.plannedPurchases.count == 1)
        #expect(exported.transactions.count == 0)
    }

    @Test("Editing a goal persists the new name and status")
    func editGoalPersists() throws {
        let store = try store(document())
        try store.savePlannedPurchase(goalDraft())
        let id = try #require(store.snapshot.plannedPurchases.first?.id)
        var draft = try #require(store.plannedPurchaseDraft(id: id))
        draft.name = "Camera"
        draft.status = .saving
        try store.savePlannedPurchase(draft)
        let goal = try #require(store.snapshot.plannedPurchases.first)
        #expect(goal.id == id)
        #expect(goal.name == "Camera")
        #expect(goal.status == .saving)
    }

    @Test("Deleting a goal still named by a fund fails closed")
    func deleteGoalFailsClosedWhenFundReferencesIt() throws {
        let store = try store(document())
        try store.savePlannedPurchase(goalDraft())
        let goalID = try #require(store.snapshot.plannedPurchases.first?.id)
        try store.saveSinkingFund(fundDraft(goalID: goalID))
        #expect(throws: AppManagementError.plannedPurchaseStillReferenced) {
            try store.deletePlannedPurchase(id: goalID)
        }
        #expect(store.snapshot.plannedPurchases.map(\.id) == [goalID])
        #expect(try store.exportDocument().transactions.isEmpty)
    }

    // MARK: - Funds

    @Test("Creating a virtual sinking fund persists set-aside, not spending")
    func createVirtualFund() throws {
        let store = try store(document())
        let before = store.snapshot.safeToSpend
        try store.saveSinkingFund(fundDraft())
        let fund = try #require(store.snapshot.sinkingFunds.first)
        #expect(fund.name == "Tech")
        #expect(fund.target == .eur(900))
        #expect(fund.reserved == .eur(200))
        #expect(fund.remaining == .eur(700))
        #expect(fund.custody == .virtual)
        #expect(store.snapshot.safeToSpend == before)
        #expect(store.snapshot.budget.summary.spent.isZero)
        #expect(try store.exportDocument().transactions.isEmpty)
    }

    @Test("A dedicated fund stores the account, not the account balance as the reservation")
    func createDedicatedFund() throws {
        let store = try store(document(
            accounts: [bnp(), savings()],
            balances: [
                AccountBalance(accountID: "bnp", balance: euro("800.00"), asOf: today),
                AccountBalance(accountID: "savings", balance: euro("1500.00"), asOf: today)
            ]
        ))
        try store.saveSinkingFund(fundDraft(custody: .dedicated, accountID: "savings"))
        let fund = try #require(store.snapshot.sinkingFunds.first)
        #expect(fund.custody == .dedicated)
        #expect(fund.dedicatedAccountID == "savings")
        #expect(fund.dedicatedAccountName == "Savings")
        #expect(fund.reserved == .eur(200))
        #expect(fund.reserved != .eur(1500))
    }

    @Test("A dedicated fund in the wrong currency is rejected with FinanceCore's rule")
    func dedicatedCurrencyMismatchIsRejected() throws {
        let store = try store(document(
            accounts: [bnp(), cashMAD()],
            balances: [
                AccountBalance(accountID: "bnp", balance: euro("800.00"), asOf: today),
                AccountBalance(accountID: "cash-mad", balance: mad("200.00"), asOf: today)
            ]
        ))
        do {
            try store.saveSinkingFund(fundDraft(custody: .dedicated, accountID: "cash-mad"))
            Issue.record("expected dedicated currency mismatch")
        } catch let error as AppManagementError {
            #expect(error.message.contains("same currency"))
            #expect(!error.message.contains("dedicatedFundAccountCurrencyMismatch"))
        }
        #expect(store.snapshot.sinkingFunds.isEmpty)
    }

    @Test("A dedicated fund pointing at a missing account is rejected")
    func dedicatedMissingAccountIsRejected() throws {
        let store = try store(document())
        do {
            try store.saveSinkingFund(fundDraft(custody: .dedicated, accountID: "ghost"))
            Issue.record("expected missing account")
        } catch let error as AppManagementError {
            #expect(
                error == .unknownAccount
                    || error.message.contains("existing account")
                    || error.message.contains("no longer available")
            )
        }
        #expect(store.snapshot.sinkingFunds.isEmpty)
    }

    @Test("A goal can be linked to a compatible sinking fund without copying the reservation")
    func goalLinkedToFund() throws {
        let store = try store(document())
        try store.saveSinkingFund(fundDraft())
        let fundID = try #require(store.snapshot.sinkingFunds.first?.id)
        try store.savePlannedPurchase(goalDraft(
            status: .saving, funding: .sinkingFund, sinkingFundID: fundID
        ))
        let goal = try #require(store.snapshot.plannedPurchases.first)
        #expect(goal.funding == .sinkingFund)
        #expect(goal.sinkingFundID == fundID)
        #expect(goal.sinkingFundName == "Tech")
        #expect(goal.reserved == .eur(200))
        let exported = try store.exportDocument()
        let persisted = try #require(exported.planning.plannedPurchases.first)
        #expect(persisted.reservedAmount.minorUnits == 0)
        #expect(exported.planning.sinkingFunds.first?.reservedAmount == euro("200.00"))
        #expect(throws: AppManagementError.sinkingFundStillReferenced) {
            try store.deleteSinkingFund(id: fundID)
        }
    }

    @Test("The mapper keeps wishlist, saving, bought and cancelled distinct")
    func mapperStatusVocabulary() {
        #expect(mapper.goalStatus(.planned) == .wishlist)
        #expect(mapper.goalStatus(.reserved) == .saving)
        #expect(mapper.goalStatus(.purchased) == .bought)
        #expect(mapper.goalStatus(.cancelled) == .cancelled)
        #expect(mapper.plannedPurchaseStatus(.wishlist) == .planned)
        #expect(mapper.fundCustody(.virtualReservation) == .virtual)
        #expect(mapper.fundCustody(.dedicatedAccount(accountID: "x")) == .dedicated)
    }

    // MARK: - Affordability purity and axes

    @Test("Evaluating affordability does not change persisted state or Home safe-to-spend")
    func evaluationIsPure() throws {
        let store = try store(document())
        try store.saveSinkingFund(fundDraft())
        try store.savePlannedPurchase(goalDraft())
        let beforeDoc = try store.exportDocument()
        let beforeSnap = store.snapshot
        var draft = store.makeAffordabilityDraft()
        draft.amountText = "10"
        draft.accountID = "bnp"
        let result = try store.evaluateAffordability(draft)
        #expect(result.overall == .affordable)
        let afterDoc = try store.exportDocument()
        let afterSnap = store.snapshot
        #expect(try Interchange.encode(afterDoc) == Interchange.encode(beforeDoc))
        #expect(afterSnap.safeToSpend == beforeSnap.safeToSpend)
        #expect(afterSnap.budget.summary.spent == beforeSnap.budget.summary.spent)
        #expect(afterSnap.budget.summary.committed == beforeSnap.budget.summary.committed)
        #expect(afterSnap.firstRisk == beforeSnap.firstRisk)
        #expect(afterSnap.plannedPurchases == beforeSnap.plannedPurchases)
        #expect(afterSnap.sinkingFunds == beforeSnap.sinkingFunds)
        #expect(afterDoc.transactions == beforeDoc.transactions)
        #expect(afterDoc.balances == beforeDoc.balances)
    }

    @Test("A cash-rich purchase that breaches the monthly ceiling is not affordable")
    func budgetOverrunIsPresented() throws {
        let store = try store(document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("2000.00"), asOf: today)],
            transactions: [
                Transaction(
                    id: "tx-spent", date: today, kind: .expense,
                    legs: [AccountLeg(accountID: "bnp", amount: euro("-200.00"))],
                    factivity: .observed
                )
            ],
            obligations: [rent()],
            ceiling: euro("700.00")
        ))
        var draft = store.makeAffordabilityDraft()
        draft.amountText = "50"
        draft.accountID = "bnp"
        let result = try store.evaluateAffordability(draft)
        #expect(result.overall == .notAffordable)
        #expect(result.cashCovers)
        #expect(result.withinBudget == false)
        #expect(result.countsAsSpending)
        #expect(result.why.contains(where: { $0.contains("spending budget") }))
        let remaining = try #require(result.budgetRemaining)
        let after = try #require(result.budgetAfter)
        #expect(after.minorUnits == remaining.minorUnits - result.purchaseEconomic.minorUnits)
        #expect(after.isNegative || after.minorUnits < remaining.minorUnits)
    }

    @Test("Pooled cash cannot settle a rail the chosen account cannot pay")
    func settlementFailureDespitePooledCash() throws {
        let store = try store(document(
            accounts: [bnp(), revolut()],
            balances: [
                AccountBalance(accountID: "bnp", balance: euro("20.00"), asOf: today),
                AccountBalance(accountID: "revolut", balance: euro("500.00"), asOf: today)
            ]
        ))
        var draft = store.makeAffordabilityDraft()
        draft.amountText = "100"
        draft.accountID = "bnp"
        draft.rail = .card
        let result = try store.evaluateAffordability(draft)
        #expect(result.overall == .notAffordable)
        #expect(!result.settlementCovers)
        #expect(result.poolUnreserved == .eur(520))
        #expect(result.settlementAvailable == .eur(20))
        #expect(result.why.contains(where: { $0.contains("this account does not have enough") }))
        #expect(result.settlementAccountName == "Bank")
    }

    @Test("A sinking-funded purchase consumes the reservation once")
    func sinkingFundedPurchaseDoesNotDoubleCount() throws {
        let store = try store(document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("800.00"), asOf: today)]
        ))
        try store.saveSinkingFund(fundDraft(reserved: "200"))
        let fundID = try #require(store.snapshot.sinkingFunds.first?.id)
        try store.savePlannedPurchase(goalDraft(
            amount: "50", status: .saving, funding: .sinkingFund, sinkingFundID: fundID
        ))
        var draft = store.affordabilityDraft(
            prefilledFromGoalID: try #require(store.snapshot.plannedPurchases.first?.id)
        )
        draft.accountID = "bnp"
        let result = try store.evaluateAffordability(draft)
        #expect(result.sinkingReservedBefore == .eur(200))
        #expect(result.sinkingConsumed == .eur(50))
        #expect(result.sinkingReservedAfter == .eur(150))
        #expect(result.reserved == .eur(200))
        #expect(result.ledgerCash == .eur(800))
        #expect(store.snapshot.sinkingFunds.first?.reserved == .eur(200))
        #expect(try store.exportDocument().planning.sinkingFunds.first?.reservedAmount == euro("200.00"))
    }

    @Test("First cash-risk names the rent day rather than a vague warning")
    func firstRiskDatePresentation() throws {
        let store = try store(document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("500.00"), asOf: today)],
            obligations: [rent()],
            floor: nil
        ))
        var draft = store.makeAffordabilityDraft()
        draft.amountText = "450"
        draft.on = DomainMapper.civilDay(Day(year: 2026, month: 9, day: 2))
        draft.accountID = "bnp"
        let result = try store.evaluateAffordability(draft)
        #expect(result.overall == .notAffordable)
        #expect(result.firstRiskKind == .hardDeficit)
        #expect(result.firstRiskDate == DomainMapper.civilDay(Day(year: 2026, month: 9, day: 11)))
        #expect(result.firstRiskLabel == "Rent")
        #expect(result.why.contains(where: { $0.contains("short of cash") }))
    }

    @Test("A floor warning is not presented as a hard deficit")
    func floorWarningIsConditional() throws {
        let store = try store(document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("500.00"), asOf: today)],
            floor: euro("400.00")
        ))
        var draft = store.makeAffordabilityDraft()
        draft.amountText = "150"
        draft.on = DomainMapper.civilDay(Day(year: 2026, month: 9, day: 2))
        draft.accountID = "bnp"
        let result = try store.evaluateAffordability(draft)
        #expect(result.overall == .affordableConditionally)
        #expect(result.firstRiskKind == .reserveWarning)
        #expect(result.firstRiskKind != .hardDeficit)
        #expect(result.why.contains(where: { $0.contains("safety reserve") }))
        #expect(!result.why.contains(where: { $0.lowercased().contains("below zero") }))
    }

    @Test("Possible income is required explicitly and is not treated as cash")
    func conditionalIncomePresentation() throws {
        let caf = IncomeSource(
            id: "caf", name: "CAF", amount: euro("190.00"), certainty: .possible,
            schedule: .oneShot(on: Day(year: 2026, month: 9, day: 12)),
            arrivesOnAccount: "bnp"
        )
        let store = try store(document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("500.00"), asOf: today)],
            income: [caf],
            obligations: [rent()],
            floor: nil
        ))
        var draft = store.makeAffordabilityDraft()
        draft.amountText = "80"
        draft.on = DomainMapper.civilDay(Day(year: 2026, month: 9, day: 13))
        draft.accountID = "bnp"
        let result = try store.evaluateAffordability(draft)
        #expect(result.overall == .affordableConditionally)
        let income = try #require(result.requiredIncome)
        #expect(income.contains("possible"))
        #expect(result.why.contains(where: { $0.contains("not in the normal plan") }))
    }

    @Test("Foreign cash is not converted to settle a euro rail")
    func noFXPath() throws {
        let store = try store(document(
            accounts: [bnp(), cashMAD()],
            balances: [
                AccountBalance(accountID: "bnp", balance: euro("800.00"), asOf: today),
                AccountBalance(accountID: "cash-mad", balance: mad("200.00"), asOf: today)
            ]
        ))
        var draft = store.makeAffordabilityDraft()
        draft.amountText = "100"
        draft.currencyCode = "MAD"
        draft.accountID = "bnp"
        draft.rail = .card
        let result = try store.evaluateAffordability(draft)
        #expect(result.overall == .notAffordable)
        #expect(result.why.contains(where: { $0.contains("Nothing is converted") }))
        #expect(result.why.contains(where: { $0.contains("Foreign cash") }))
    }

    @Test("Financing counts the purchase once in the budget, not purchase plus instalments")
    func financingDoesNotDoubleCount() throws {
        let plan = InstallmentPlan(
            id: "plan-4x",
            provider: "Test",
            purchaseDescription: "Phone",
            originalPurchaseAmount: euro("324.89"),
            installments: [
                Installment(sequence: 1, dueDate: Day(year: 2026, month: 9, day: 2), amount: euro("81.23")),
                Installment(sequence: 2, dueDate: Day(year: 2026, month: 9, day: 9), amount: euro("81.22")),
                Installment(sequence: 3, dueDate: Day(year: 2026, month: 9, day: 16), amount: euro("81.22")),
                Installment(sequence: 4, dueDate: Day(year: 2026, month: 9, day: 23), amount: euro("81.22"))
            ],
            paymentRequirement: .euroBankPayment()
        )
        let store = try store(document(
            balances: [AccountBalance(accountID: "bnp", balance: euro("800.00"), asOf: today)],
            installments: [plan],
            ceiling: euro("500.00")
        ))
        var draft = store.makeAffordabilityDraft()
        draft.amountText = "81.23"
        draft.accountID = "bnp"
        draft.funding = .financing
        draft.installmentPlanID = "plan-4x"
        let result = try store.evaluateAffordability(draft)
        #expect(result.purchaseEconomic == .eur(324.89))
        #expect(result.withinBudget == true)
        #expect(result.financingNote?.contains("counts once") == true)
        #expect(result.financingNote?.contains("not a second spend") == true)
    }

    @Test("An ordinary in-budget cash purchase is affordable with axes filled in")
    func ordinaryAffordable() throws {
        let store = try store(document())
        var draft = store.makeAffordabilityDraft()
        draft.amountText = "10"
        draft.accountID = "bnp"
        let result = try store.evaluateAffordability(draft)
        #expect(result.overall == .affordable)
        #expect(result.cashCovers)
        #expect(result.settlementCovers)
        #expect(result.withinBudget == true)
        #expect(result.ledgerCash == .eur(800))
        #expect(result.unreservedCash == .eur(800))
        #expect(result.firstRiskKind == .none)
        #expect(result.requiredIncome == nil)
        #expect(!result.why.contains(where: { $0.localizedCaseInsensitiveContains("buy") }))
        #expect(!result.why.contains(where: { $0.localizedCaseInsensitiveContains("go for it") }))
    }
}
