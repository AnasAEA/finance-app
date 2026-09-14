import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// Phase 2.5 — budget control through the app facade.
///
/// The point of these tests is that the screens now state something they can
/// back up. Before this phase `spent` was a placeholder zero and every figure
/// derived from it said nothing; a bar at 0% was a claim, and the claim was
/// false. Spending is attributed now, so the tests below check what is
/// counted, what is deliberately *not* counted, and what happens to spending
/// no category claims — which must still reach the total rather than vanish.
///
/// Every figure here is synthetic.
@MainActor
@Suite("The budget counts what it says it counts")
struct BudgetProgressTests {

    // MARK: - Fixture

    private static let today = Day(year: 2026, month: 9, day: 15)
    private static var todayDate: Date { fixtureInstant(today) }

    private static func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    private static let account = Account(
        id: "bank", name: "Bank", currency: .eur, kind: .bank,
        supportedRails: [.cardDebit, .sepaCreditTransfer, .sepaDirectDebit], drawOrder: 0
    )

    private static func document(
        budgets: [BudgetAllocation],
        obligations: [RecurringObligation] = [],
        transactions: [Transaction] = [],
        settlements: [ObligationSettlement] = [],
        ceiling: Money? = Money(exactDecimal: "700.00", currency: .eur)!
    ) -> FinanceDocument {
        FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account],
            balances: [
                AccountBalance(
                    accountID: "bank", balance: euro("800.00"),
                    asOf: Day(year: 2026, month: 9, day: 1)
                )
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

    private static func budget(
        _ id: String, _ name: String, _ amount: String,
        categories: [String] = [],
        confirmation: BudgetConfirmation = .userConfirmed,
        spendingClass: SpendingClass = .flexible
    ) -> BudgetAllocation {
        BudgetAllocation(
            id: id, name: name, spendingClass: spendingClass,
            monthlyAmount: euro(amount),
            effectiveFrom: MonthKey(year: 2026, month: 1),
            confirmation: confirmation, categoryKeys: categories
        )
    }

    /// A container has to outlive the context it hands out, so both travel
    /// together. Every case here goes through real persistence: a budget
    /// figure that only survives in memory has not been proved to survive.
    @MainActor
    private struct Harness {
        let container: ModelContainer
        let store: FinanceStore

        func reopened() throws -> FinanceStore {
            try FinanceStore(context: container.mainContext, now: BudgetProgressTests.todayDate)
        }
    }

    private static func harness(_ document: FinanceDocument) throws -> Harness {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = try FinanceStore(context: container.mainContext, now: todayDate)
        try store.importDocument(document)
        return Harness(container: container, store: store)
    }

    // MARK: - The headline is measured against the gross ceiling

    @Test("The month is measured against the gross ceiling, housing included")
    func headlineUsesTheGrossCeiling() throws {
        let budget = try Self.harness(
            Self.document(budgets: [Self.budget("housing", "Housing", "480.00")])
        ).store.snapshot.everydayBudget

        #expect(budget.ceiling == .eur(700))
        #expect(budget.limit == .eur(700))
        #expect(budget.headlineCaption == "left of \(Amount.eur(700).formatted()) this month")
    }

    @Test("Without a ceiling the comparison falls back to what the lines allocate")
    func withoutACeilingTheLinesAreTheLimit() throws {
        let snapshot = try Self.harness(
            Self.document(
                budgets: [Self.budget("groceries", "Groceries", "70.00")],
                ceiling: nil
            )
        ).store.snapshot

        #expect(snapshot.everydayBudget.ceiling == nil)
        #expect(snapshot.everydayBudget.limit == .eur(70))
        #expect(snapshot.budget.unallocated == nil)
    }

    @Test("The unclaimed part of the ceiling is named rather than left implied")
    func unallocatedIsExplicit() throws {
        let overview = try Self.harness(
            Self.document(
                budgets: [
                    Self.budget("housing", "Housing", "480.00"),
                    Self.budget("bills", "Essential bills", "23.94"),
                    Self.budget("transit", "Transit reserve", "2.50"),
                    Self.budget("subs", "Subscriptions", "44.38"),
                ]
            )
        ).store.snapshot.budget

        #expect(overview.target == .eur(550.82))
        #expect(overview.unallocated == .eur(149.18))
    }

    // MARK: - Attribution

    @Test("A categorised expense reaches the line that claims its category")
    func expenseReachesItsLine() throws {
        let harness = try Self.harness(
            Self.document(budgets: [Self.budget("groceries", "Groceries", "70.00", categories: ["food"])])
        )
        let store = harness.store

        try store.add(
            try #require(TransactionDraft(
                date: Self.todayDate, kind: .expense, amount: .eur(24.50),
                accountID: "bank", categoryKey: "food", merchant: "Market"
            ))
        )

        let line = try #require(store.snapshot.budget.lines.first)
        #expect(line.spent == .eur(24.50))
        #expect(line.remaining == .eur(45.50))
        #expect(store.snapshot.budget.uncategorized.isZero)
        #expect(store.snapshot.everydayBudget.spent == .eur(24.50))
    }

    @Test("Spending in a category no line claims still reaches the total, and is named")
    func uncategorisedSpendingIsNeverHidden() throws {
        let harness = try Self.harness(
            Self.document(budgets: [Self.budget("groceries", "Groceries", "70.00", categories: ["food"])])
        )
        let store = harness.store

        try store.add(
            try #require(TransactionDraft(
                date: Self.todayDate, kind: .expense, amount: .eur(31.25),
                accountID: "bank", categoryKey: "health", merchant: "Pharmacy"
            ))
        )

        #expect(store.snapshot.budget.lines.first?.spent.isZero == true)
        #expect(store.snapshot.budget.uncategorized == .eur(31.25))
        #expect(store.snapshot.everydayBudget.spent == .eur(31.25))
    }

    @Test("A transfer between own accounts is movement, not spending")
    func transfersAreNotSpending() throws {
        var document = Self.document(
            budgets: [Self.budget("everyday", "Everyday", "100.00", categories: ["other"])]
        )
        document.accounts.append(
            Account(
                id: "wallet", name: "Wallet", currency: .eur, kind: .wallet,
                supportedRails: [.electronicPayment], drawOrder: 1
            )
        )
        document.balances.append(
            AccountBalance(
                accountID: "wallet", balance: Self.euro("0.00"),
                asOf: Day(year: 2026, month: 9, day: 1)
            )
        )
        let harness = try Self.harness(document)
        let store = harness.store

        try store.add(
            try #require(TransactionDraft(
                date: Self.todayDate, kind: .transfer, amount: .eur(120),
                accountID: "bank", counterAccountID: "wallet"
            ))
        )

        #expect(store.snapshot.everydayBudget.spent.isZero)
        #expect(store.snapshot.budget.uncategorized.isZero)
    }

    // MARK: - Commitments

    @Test("A commitment still owed is committed, not spent")
    func unsettledCommitmentIsCommitted() throws {
        let rent = RecurringObligation(
            id: "ob-rent", name: "Landlord", amount: Self.euro("-480.00"),
            spec: .monthly(onDay: 25, from: MonthKey(year: 2026, month: 1), through: nil),
            requirement: PaymentRequirement(currency: .eur, acceptableRails: [.sepaDirectDebit]),
            spendingClass: .essential, budgetID: "housing"
        )
        let overview = try Self.harness(
            Self.document(
                budgets: [Self.budget("housing", "Housing", "480.00")],
                obligations: [rent]
            )
        ).store.snapshot.budget

        #expect(overview.summary.committed == .eur(480.00))
        #expect(overview.summary.spent.isZero)
        #expect(overview.lines.first?.committed == .eur(480.00))
        // 700 gross, nothing spent, 480.00 promised.
        #expect(overview.summary.safeToSpend == .eur(220.00))
    }

    // MARK: - Suggestions are not agreement

    @Test("A suggested target is marked as a proposal, not as a decision")
    func suggestionsAreMarked() throws {
        let overview = try Self.harness(
            Self.document(
                budgets: [
                    Self.budget("groceries", "Groceries", "70.00", confirmation: .suggested),
                    Self.budget("transport", "Transport", "10.00", confirmation: .suggested),
                ]
            )
        ).store.snapshot.budget

        #expect(overview.hasSuggestedLines)
        #expect(overview.isEntirelySuggested)
        #expect(overview.lines.allSatisfy { $0.isSuggested })
    }

    @Test("Accepting the suggestions is what makes them the person's own")
    func acceptingSuggestionsConfirmsThem() throws {
        let harness = try Self.harness(
            Self.document(
                budgets: [Self.budget("groceries", "Groceries", "70.00", confirmation: .suggested)]
            )
        )
        let store = harness.store

        #expect(store.snapshot.budget.isEntirelySuggested)
        try store.confirmSuggestedBudgetLines()
        #expect(!store.snapshot.budget.hasSuggestedLines)
        let exported = try store.exportDocument()
        #expect(exported.planning.budgets.first?.confirmation == .userConfirmed)
    }

    @Test("Editing a line records the agreement along with the number")
    func editingALineConfirmsIt() throws {
        let harness = try Self.harness(
            Self.document(
                budgets: [Self.budget("groceries", "Groceries", "70.00", confirmation: .suggested)]
            )
        )
        let store = harness.store

        try store.saveBudgetLine(
            BudgetLineDraft(
                id: "groceries", name: "Groceries", monthlyTarget: .eur(60),
                spendingClass: .flexible, categoryKeys: ["food"]
            )
        )

        let line = try #require(store.snapshot.budget.lines.first)
        #expect(line.limit == .eur(60))
        #expect(!line.isSuggested)
    }

    // MARK: - Editing

    @Test("A category may only feed one line, so spending is never counted twice")
    func categoriesAreExclusive() throws {
        let harness = try Self.harness(
            Self.document(budgets: [Self.budget("groceries", "Groceries", "70.00", categories: ["food"])])
        )
        let store = harness.store

        #expect(throws: AppManagementError.duplicateBudgetCategory("Groceries")) {
            try store.saveBudgetLine(
                BudgetLineDraft(
                    name: "Eating out", monthlyTarget: .eur(20),
                    spendingClass: .optional, categoryKeys: ["food"]
                )
            )
        }
    }

    @Test("The ceiling can be set, cleared, and survives a reopen")
    func ceilingIsEditableAndPersisted() throws {
        let harness = try Self.harness(
            Self.document(budgets: [Self.budget("groceries", "Groceries", "70.00")], ceiling: nil)
        )
        let store = harness.store

        try store.setMonthlyEconomicCeiling(.eur(700))
        #expect(store.snapshot.everydayBudget.ceiling == .eur(700))
        #expect(try harness.reopened().snapshot.everydayBudget.ceiling == .eur(700))

        try store.setMonthlyEconomicCeiling(nil)
        #expect(store.snapshot.everydayBudget.ceiling == nil)
        #expect(try harness.reopened().snapshot.everydayBudget.ceiling == nil)
    }

    @Test("Deleting a line unlinks the commitments that pointed at it")
    func deletingALineUnlinksItsCommitments() throws {
        let rent = RecurringObligation(
            id: "ob-rent", name: "Landlord", amount: Self.euro("-480.00"),
            spec: .monthly(onDay: 25, from: MonthKey(year: 2026, month: 1), through: nil),
            requirement: PaymentRequirement(currency: .eur, acceptableRails: [.sepaDirectDebit]),
            spendingClass: .essential, budgetID: "housing"
        )
        let harness = try Self.harness(
            Self.document(budgets: [Self.budget("housing", "Housing", "480.00")], obligations: [rent])
        )
        let store = harness.store

        try store.deleteBudgetLine(id: "housing")
        #expect(store.snapshot.budget.lines.isEmpty)
        #expect(store.budgetID(forObligation: "ob-rent") == nil)
        let exported = try store.exportDocument()
        #expect(exported.planning.recurringObligations.first?.budgetID == nil)
    }

    @Test("Budget targets and their categories survive a reopen")
    func budgetsSurviveAReopen() throws {
        let harness = try Self.harness(
            Self.document(budgets: [Self.budget("groceries", "Groceries", "70.00", confirmation: .suggested)])
        )
        try harness.store.saveBudgetLine(
            BudgetLineDraft(
                id: "groceries", name: "Groceries", monthlyTarget: .eur(60),
                spendingClass: .essential, categoryKeys: ["food", "household"]
            )
        )

        let reopened = try harness.reopened()
        let line = try #require(reopened.snapshot.budget.lines.first)
        #expect(line.limit == .eur(60))
        #expect(!line.isSuggested)
        #expect(line.spendingClass == .essential)
        #expect(Set(reopened.categoryKeys(forBudget: "groceries")) == ["food", "household"])
    }

    // MARK: - Pace

    @Test("Pace divides what is left by the days that are left")
    func paceIsOverTheDaysThatRemain() throws {
        let overview = try Self.harness(
            Self.document(budgets: [Self.budget("groceries", "Groceries", "160.00")])
        ).store.snapshot.budget

        #expect(overview.daysInMonth == 30)
        #expect(overview.daysRemaining == 16)
        #expect(overview.isCurrentMonth)
        #expect(overview.lines.first?.dailyPace == .eur(10))
    }

    // MARK: - Budget is not liquidity

    @Test("Budget headroom is not the money in the accounts")
    func budgetIsNotLiquidity() throws {
        let snapshot = try Self.harness(
            Self.document(budgets: [Self.budget("groceries", "Groceries", "70.00")])
        ).store.snapshot

        // 800 in the account, 700 of gross ceiling: the two answer different
        // questions and must not be conflated.
        #expect(snapshot.accountCash == .eur(800))
        #expect(snapshot.everydayBudget.safeToSpend == .eur(700))
    }
}
