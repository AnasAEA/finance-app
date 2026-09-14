import Testing
import SwiftData
import FinanceCore
@testable import FinanceApp

@MainActor
@Suite("FinanceDocument persistence integration")
struct FinanceDocumentPersistenceTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func roundTrip(_ document: FinanceDocument) throws -> FinanceDocument {
        let container = try container()
        let context = container.mainContext
        try StoredDocumentGraph.replace(
            with: document,
            in: context,
            writtenOn: Day(year: 2027, month: 3, day: 1)
        )
        return try #require(try StoredDocumentGraph.load(from: context))
    }

    private var accounts: [Account] {
        [
            Account(
                id: "bank-a", name: "Bank A", currency: .eur, kind: .bank,
                supportedRails: PaymentRail.euroBankRails, drawOrder: 0
            ),
            Account(
                id: "bank-b", name: "Bank B", currency: .eur, kind: .wallet,
                supportedRails: PaymentRail.euroWalletRails, drawOrder: 1
            ),
            Account(
                id: "cash-eur", name: "Euro cash", currency: .eur, kind: .cash,
                supportedRails: PaymentRail.cashOnlyRails, drawOrder: 2
            )
        ]
    }

    private func document(_ transactions: [Transaction]) -> FinanceDocument {
        let day = Day(year: 2026, month: 9, day: 2)
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: accounts,
            balances: accounts.map {
                AccountBalance(
                    accountID: $0.id,
                    balance: Money(minorUnits: 10_000, currency: .eur),
                    asOf: day
                )
            },
            transactions: transactions
        )
    }

    private func transaction(
        id: String,
        kind: TransactionKind,
        legs: [AccountLeg],
        ownership: [OwnershipSplit]? = nil,
        linked: String? = nil,
        installment: String? = nil,
        lifecycle: TransactionLifecycle = .cleared
    ) -> Transaction {
        Transaction(
            id: id,
            date: Day(year: 2026, month: 9, day: 2),
            kind: kind,
            legs: legs,
            ownership: ownership,
            linkedTransactionID: linked,
            installmentPlanID: installment,
            factivity: .observed,
            lifecycle: lifecycle,
            provenance: Provenance(source: "TEST", evidenceGrade: .userConfirmed)
        )
    }

    @Test("The authoritative DEV fixture survives domain → persistence → document exactly")
    func fixtureRoundTrip() throws {
        let source = try FinanceStore.developmentFixture()
        let output = try roundTrip(source)
        #expect(output == source)
        #expect(try Interchange.encode(output) == Interchange.encode(source))
    }

    @Test("The document is normalized into queryable rows, not stored as a blob")
    func normalizedRows() throws {
        let container = try container()
        let context = container.mainContext
        let source = try FinanceStore.developmentFixture()
        try StoredDocumentGraph.replace(
            with: source,
            in: context,
            writtenOn: Day(year: 2027, month: 3, day: 1)
        )

        #expect(try context.fetchCount(FetchDescriptor<StoredTransaction>()) == 9)
        #expect(try context.fetchCount(FetchDescriptor<StoredAccountLeg>()) == 11)
        #expect(try context.fetchCount(FetchDescriptor<StoredOwnershipSplit>()) == 2)
        #expect(try context.fetchCount(FetchDescriptor<StoredInstallment>()) == 12)
        #expect(try context.fetchCount(FetchDescriptor<StoredScheduledPayment>()) == 0)

        let housing = try #require(
            context.fetch(FetchDescriptor<StoredRecurringObligation>())
                .first { $0.identifier == "ob-housing" }
        )
        #expect(housing.requiredRailTokens == [PaymentRail.sepaDirectDebit.id])
    }

    @Test("Ordinary expense round-trips")
    func ordinaryExpense() throws {
        let value = transaction(
            id: "expense", kind: .expense,
            legs: [AccountLeg(accountID: "bank-a", amount: Money(minorUnits: -1_234, currency: .eur))]
        )
        #expect(try roundTrip(document([value])).transactions == [value])
    }

    @Test("Ordinary income round-trips")
    func ordinaryIncome() throws {
        let value = transaction(
            id: "income", kind: .income,
            legs: [AccountLeg(accountID: "bank-a", amount: Money(minorUnits: 25_000, currency: .eur))]
        )
        #expect(try roundTrip(document([value])).transactions == [value])
    }

    @Test("Owned-account transfer round-trips with both legs")
    func ownedTransfer() throws {
        let value = transaction(
            id: "transfer", kind: .transfer,
            legs: [
                AccountLeg(accountID: "bank-a", amount: Money(minorUnits: -5_000, currency: .eur)),
                AccountLeg(accountID: "bank-b", amount: Money(minorUnits: 5_000, currency: .eur))
            ]
        )
        #expect(try roundTrip(document([value])).transactions == [value])
    }

    @Test("ATM withdrawal round-trips as an asset-form change")
    func atmWithdrawal() throws {
        let value = transaction(
            id: "atm", kind: .cashWithdrawal,
            legs: [
                AccountLeg(accountID: "bank-a", amount: Money(minorUnits: -2_000, currency: .eur)),
                AccountLeg(accountID: "cash-eur", amount: Money(minorUnits: 2_000, currency: .eur))
            ]
        )
        #expect(try roundTrip(document([value])).transactions == [value])
        #expect(Economics.effect(of: value, currency: .eur).spending.isZero)
    }

    @Test("Financing repayment round-trips without becoming spending")
    func financingRepayment() throws {
        let value = transaction(
            id: "repayment", kind: .financingRepayment,
            legs: [AccountLeg(accountID: "bank-a", amount: Money(minorUnits: -8_123, currency: .eur))],
            installment: "plan"
        )
        #expect(try roundTrip(document([value])).transactions == [value])
        #expect(Economics.effect(of: value, currency: .eur).spending.isZero)
    }

    @Test("Refund/reversal link round-trips and remains a refund")
    func refund() throws {
        let value = transaction(
            id: "refund", kind: .refund,
            legs: [AccountLeg(accountID: "bank-a", amount: Money(minorUnits: 999, currency: .eur))],
            linked: "expense"
        )
        #expect(try roundTrip(document([value])).transactions == [value])
        #expect(Economics.effect(of: value, currency: .eur).income.isZero)
    }

    @Test("Arbitrary multi-leg transaction preserves sequence and signs")
    func multiLeg() throws {
        let value = transaction(
            id: "multi", kind: .transfer,
            legs: [
                AccountLeg(accountID: "bank-a", amount: Money(minorUnits: -10_000, currency: .eur)),
                AccountLeg(accountID: "bank-b", amount: Money(minorUnits: 6_000, currency: .eur)),
                AccountLeg(accountID: "cash-eur", amount: Money(minorUnits: 4_000, currency: .eur))
            ]
        )
        #expect(try roundTrip(document([value])).transactions.first?.legs == value.legs)
    }

    @Test("€1,000 custody with exact €400/€600 ownership survives persistence")
    func ownershipSplit() throws {
        let value = transaction(
            id: "custody", kind: .passThrough,
            legs: [AccountLeg(accountID: "bank-a", amount: Money(minorUnits: 100_000, currency: .eur))],
            ownership: [
                OwnershipSplit(ownerID: "self", isSelf: true, amount: Money(minorUnits: 40_000, currency: .eur)),
                OwnershipSplit(ownerID: "other", isSelf: false, amount: Money(minorUnits: 60_000, currency: .eur))
            ]
        )
        let output = try #require(try roundTrip(document([value])).transactions.first)
        #expect(output.ownership == value.ownership)
        let effect = Economics.effect(of: output, currency: .eur)
        #expect(effect.income.minorUnits == 40_000)
        #expect(effect.passThroughNotMine.minorUnits == 60_000)
    }

    @Test("Pass-through disposal remains non-spending")
    func passThroughDisposal() throws {
        let value = transaction(
            id: "disposal", kind: .passThrough,
            legs: [AccountLeg(accountID: "bank-a", amount: Money(minorUnits: -60_000, currency: .eur))],
            linked: "custody"
        )
        #expect(try roundTrip(document([value])).transactions == [value])
        #expect(Economics.effect(of: value, currency: .eur).spending.isZero)
    }

    @Test("Every lifecycle state round-trips without semantic promotion")
    func lifecycle() throws {
        for state in TransactionLifecycle.allCases {
            let value = transaction(
                id: "lifecycle-\(state.rawValue)", kind: .expense,
                legs: [AccountLeg(accountID: "bank-a", amount: Money(minorUnits: -100, currency: .eur))],
                lifecycle: state
            )
            #expect(try roundTrip(document([value])).transactions.first?.lifecycle == state)
        }
    }

    @Test("A supported three-decimal currency preserves its exponent")
    func nonTwoExponent() throws {
        let account = Account(
            id: "kwd", name: "KWD account", currency: .kwd, kind: .wallet,
            supportedRails: [.electronicPayment]
        )
        let value = Transaction(
            id: "kwd-income",
            date: Day(year: 2026, month: 9, day: 2),
            kind: .income,
            legs: [AccountLeg(accountID: account.id, amount: Money(minorUnits: 1_234, currency: .kwd))],
            factivity: .observed,
            provenance: .devFixture
        )
        let input = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account],
            balances: [
                AccountBalance(
                    accountID: account.id,
                    balance: Money(minorUnits: 1_234, currency: .kwd),
                    asOf: Day(year: 2026, month: 9, day: 2)
                )
            ],
            transactions: [value]
        )
        let output = try roundTrip(input)
        #expect(output.accounts[0].currency.minorUnitDigits == 3)
        #expect(output.balances[0].balance.description == "1.234 KWD")
        #expect(output.transactions[0].legs[0].amount.currency.minorUnitDigits == 3)
    }
}

@MainActor
@Suite("Shared fixture app-boundary acceptance")
struct SharedFixtureAppBoundaryTests {

    /// The engine vector itself is hand-derived once, in FinanceCore's
    /// `FixtureVectorTests`. What has to be proven *here* is the App boundary:
    /// that the shared fixture survives the persistence spine unchanged and
    /// that the numbers the app reads back are the engine's own.
    private func store() throws -> (FinanceDocument, FinanceStore) {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let document = try FinanceStore.developmentFixture()
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2027, month: 3, day: 1))
        )
        try store.importDocument(document)
        return (document, store)
    }

    @Test("Persistence import/export remains on the FinanceDocument spine")
    func storeRoundTrip() throws {
        let (document, store) = try store()
        #expect(try store.exportDocument() == document)
    }

    @Test("The snapshot the app reads back carries the engine's own month figures")
    func snapshotMatchesTheEngine() throws {
        let (_, store) = try store()
        #expect(store.snapshot.accountCash == .eur(396.00))
        #expect(store.snapshot.currentMonth?.closing == .eur(54.00))
        #expect(store.snapshot.currentMonth?.unfundedEUR == .eur(267.50))
        #expect(store.snapshot.currentMonth?.unfundedInOtherCurrencies.isEmpty == true)
    }

    @Test("Gross custody never becomes personal capacity across the app boundary")
    func ownershipCustodyAcceptance() throws {
        let (document, store) = try store()
        let arrival = try #require(document.expectedTransactions.first { $0.id == "pot-arrival" })
        let handover = try #require(document.expectedTransactions.first { $0.id == "pot-handover" })
        let totals = Economics.totals(for: [arrival, handover], currency: .eur)

        // 1,000.00 physically arrives; 400.00 of it is income.
        #expect(arrival.legs.first?.amount.minorUnits == 100_000)
        #expect(totals.personalIncome.minorUnits == 40_000)
        #expect(totals.passThroughNotMine.minorUnits == 60_000)
        #expect(totals.personalNetFlow.minorUnits == 40_000)

        // And the app's own read-out never shows the gross as spendable.
        #expect(store.snapshot.accountCash == .eur(396.00))
    }
}
