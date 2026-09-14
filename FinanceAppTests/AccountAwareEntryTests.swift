import Testing
import SwiftData
import FinanceCore
@testable import FinanceApp

@MainActor
@Suite("Phase 2.1 account-aware daily entry")
struct AccountAwareEntryTests {

    private func accountDraft(
        _ account: AccountSummary,
        name: String? = nil,
        isActive: Bool? = nil
    ) -> AccountDraft {
        AccountDraft(
            id: account.id,
            name: name ?? account.name,
            kind: account.kind,
            currencyCode: account.currencyCode,
            fractionDigits: account.fractionDigits,
            openingBalance: account.balance,
            openingBalanceDay: account.balanceAsOf,
            isActive: isActive ?? account.isActive
        )
    }

    private func sourceDraft(
        _ source: IncomeSourceSummary,
        name: String? = nil,
        isActive: Bool? = nil,
        preferredAccountID: String? = nil
    ) -> IncomeSourceDraft {
        IncomeSourceDraft(
            id: source.id,
            name: name ?? source.name,
            certainty: source.certainty,
            isActive: isActive ?? source.isActive,
            preferredAccountID: preferredAccountID ?? source.preferredAccountID,
            note: source.note
        )
    }

    @Test("Carrefour expense shows Groceries and Revolut and persists its account leg")
    func revolutExpense() throws {
        let harness = try EntryFixtures.Harness()
        try harness.store.add(
            EntryFixtures.draft(accountID: EntryFixtures.wallet.id, merchant: "Carrefour")
        )
        let row = try #require(harness.store.snapshot.activity.flatMap(\.rows).first)
        #expect(row.title == "Carrefour")
        #expect(row.subtitle == "Groceries · Revolut")
        #expect(row.primaryAccountID == EntryFixtures.wallet.id)
        let saved = try #require(try harness.store.exportDocument().transactions.first)
        #expect(saved.legs.map(\.accountID) == [EntryFixtures.wallet.id])
    }

    @Test("The same expense can have identical economics and a different account")
    func sameExpenseDifferentAccount() throws {
        let harness = try EntryFixtures.Harness()
        try harness.store.add(EntryFixtures.draft(accountID: EntryFixtures.bank.id, merchant: "Carrefour"))
        try harness.store.add(EntryFixtures.draft(accountID: EntryFixtures.wallet.id, merchant: "Carrefour"))
        let saved = try harness.store.exportDocument().transactions
        #expect(saved.count == 2)
        #expect(Economics.effect(of: saved[0], currency: .eur).spending
            == Economics.effect(of: saved[1], currency: .eur).spending)
        #expect(saved[0].legs[0].accountID != saved[1].legs[0].accountID)
    }

    @Test("Parents income received in the bank shows two separate identities")
    func parentsIncomeInBank() throws {
        let harness = try EntryFixtures.Harness()
        try harness.store.add(
            EntryFixtures.draft(
                kind: .income,
                amount: .eur(800),
                accountID: EntryFixtures.bank.id,
                incomeSourceID: EntryFixtures.parents.id,
                merchant: "Parental support"
            )
        )
        let row = try #require(harness.store.snapshot.activity.flatMap(\.rows).first)
        #expect(row.title == "Parental support")
        #expect(row.subtitle == "Parents · BNP")
        #expect(row.incomeSourceID == EntryFixtures.parents.id)
        #expect(row.primaryAccountID == EntryFixtures.bank.id)
    }

    @Test("Parents remains the source when income is received in the wallet")
    func parentsIncomeInWallet() throws {
        let harness = try EntryFixtures.Harness()
        try harness.store.add(
            EntryFixtures.draft(
                kind: .income,
                amount: .eur(800),
                accountID: EntryFixtures.wallet.id,
                incomeSourceID: EntryFixtures.parents.id
            )
        )
        let row = try #require(harness.store.snapshot.activity.flatMap(\.rows).first)
        #expect(row.subtitle == "Parents · Revolut")
        #expect(row.incomeSourceID == EntryFixtures.parents.id)
        #expect(row.primaryAccountID == EntryFixtures.wallet.id)
    }

    @Test("A preferred receiving account is suggested but an override is saved")
    func preferredAccountCanBeOverridden() throws {
        let harness = try EntryFixtures.Harness()
        let source = try #require(
            harness.store.snapshot.entryOptions.incomeSource(EntryFixtures.parents.id)
        )
        #expect(source.preferredAccountID == EntryFixtures.bank.id)

        try harness.store.add(
            EntryFixtures.draft(
                kind: .income,
                amount: .eur(800),
                accountID: EntryFixtures.wallet.id,
                incomeSourceID: source.id
            )
        )
        let saved = try #require(try harness.store.exportDocument().transactions.first)
        #expect(saved.incomeSourceID == source.id)
        #expect(saved.legs.single?.accountID == EntryFixtures.wallet.id)
    }

    @Test("PayPal financing repayment identifies the account without becoming spending")
    func paypalFinancingRepayment() throws {
        var document = EntryFixtures.document()
        document.accounts[1].name = "PayPal"
        let repayment = Transaction(
            id: "phone-repayment",
            date: EntryFixtures.today,
            kind: .financingRepayment,
            legs: [
                AccountLeg(
                    accountID: EntryFixtures.wallet.id,
                    amount: Money(minorUnits: -8_122, currency: .eur)
                )
            ],
            factivity: .observed,
            lifecycle: .cleared,
            provenance: Provenance(source: "TEST", evidenceGrade: .userConfirmed)
        )
        document.transactions = [repayment]
        let harness = try EntryFixtures.Harness(document)
        let row = try #require(harness.store.snapshot.activity.flatMap(\.rows).first)
        #expect(row.subtitle == "Financing · PayPal")
        #expect(row.primaryAccountID == EntryFixtures.wallet.id)
        #expect(Economics.effect(of: repayment, currency: .eur).spending.isZero)
        #expect(Economics.effect(of: repayment, currency: .eur).financingRepayment.minorUnits == 8_122)
    }

    @Test("BNP to Revolut displays both accounts and has zero economics")
    func transferLabelsBothAccounts() throws {
        let harness = try EntryFixtures.Harness()
        try harness.store.add(
            EntryFixtures.draft(
                kind: .transfer,
                amount: .eur(50),
                accountID: EntryFixtures.bank.id,
                counterAccountID: EntryFixtures.wallet.id
            )
        )
        let row = try #require(harness.store.snapshot.activity.flatMap(\.rows).first)
        #expect(row.subtitle == "BNP → Revolut")
        let saved = try #require(try harness.store.exportDocument().transactions.first)
        let effect = Economics.effect(of: saved, currency: .eur)
        #expect(effect.spending.isZero)
        #expect(effect.income.isZero)
    }

    @Test("An inactive account is unavailable for entry but remains on history")
    func inactiveAccountHistory() throws {
        let harness = try EntryFixtures.Harness()
        try harness.store.add(EntryFixtures.draft(accountID: EntryFixtures.wallet.id, merchant: "Carrefour"))
        let wallet = try #require(harness.store.snapshot.accounts.first { $0.id == EntryFixtures.wallet.id })
        try harness.store.saveAccount(accountDraft(wallet, isActive: false))

        #expect(!harness.store.snapshot.entryOptions.accounts.contains { $0.id == wallet.id })
        let historical = try #require(harness.store.snapshot.activity.flatMap(\.rows).first)
        #expect(historical.primaryAccountID == wallet.id)
        #expect(historical.primaryAccountLabel == wallet.name)
        #expect(throws: AppEntryError.inactiveAccount(id: wallet.id)) {
            try harness.store.add(EntryFixtures.draft(accountID: wallet.id))
        }
    }

    @Test("A deactivated income source is unavailable but historical income resolves")
    func inactiveIncomeSourceHistory() throws {
        let harness = try EntryFixtures.Harness()
        try harness.store.add(EntryFixtures.draft(kind: .income, amount: .eur(800)))
        let parents = try #require(
            harness.store.snapshot.incomeSources.first { $0.id == EntryFixtures.parents.id }
        )
        try harness.store.saveIncomeSource(sourceDraft(parents, isActive: false))

        #expect(!harness.store.snapshot.entryOptions.incomeSources.contains { $0.id == parents.id })
        #expect(harness.store.snapshot.activity.flatMap(\.rows).first?.incomeSourceLabel == "Parents")
        #expect(throws: AppEntryError.inactiveIncomeSource(id: parents.id)) {
            try harness.store.add(EntryFixtures.draft(kind: .income, amount: .eur(10)))
        }
    }

    @Test("Renaming an income source updates historical rows through its stable ID")
    func renameIncomeSource() throws {
        let harness = try EntryFixtures.Harness()
        try harness.store.add(EntryFixtures.draft(kind: .income, amount: .eur(800)))
        let parents = try #require(harness.store.snapshot.incomeSources.first)
        try harness.store.saveIncomeSource(sourceDraft(parents, name: "Family support"))
        let row = try #require(harness.store.snapshot.activity.flatMap(\.rows).first)
        #expect(row.incomeSourceID == parents.id)
        #expect(row.incomeSourceLabel == "Family support")
        #expect(row.subtitle.hasPrefix("Family support ·"))
    }

    @Test("Renaming an account updates historical rows through account IDs")
    func renameAccount() throws {
        let harness = try EntryFixtures.Harness()
        try harness.store.add(EntryFixtures.draft(accountID: EntryFixtures.wallet.id))
        let wallet = try #require(harness.store.snapshot.accounts.first { $0.id == EntryFixtures.wallet.id })
        try harness.store.saveAccount(accountDraft(wallet, name: "Revolut Personal"))
        let row = try #require(harness.store.snapshot.activity.flatMap(\.rows).first)
        #expect(row.primaryAccountID == wallet.id)
        #expect(row.primaryAccountLabel == "Revolut Personal")
        #expect(row.subtitle == "Groceries · Revolut Personal")
    }

    @Test("Export and import preserve account legs, income source IDs and preferred account")
    func relationshipRoundTrip() throws {
        let original = try EntryFixtures.Harness()
        try original.store.add(
            EntryFixtures.draft(
                kind: .income,
                amount: .eur(800),
                accountID: EntryFixtures.wallet.id,
                incomeSourceID: EntryFixtures.parents.id
            )
        )
        try original.store.add(
            EntryFixtures.draft(
                kind: .transfer,
                amount: .eur(40),
                accountID: EntryFixtures.bank.id,
                counterAccountID: EntryFixtures.wallet.id
            )
        )
        let exported = try original.store.exportDocument()
        #expect(exported.incomeSources.single?.arrivesOnAccount == EntryFixtures.bank.id)

        let imported = try EntryFixtures.Harness(exported)
        let importedDocument = try imported.store.exportDocument()
        #expect(importedDocument == exported)
        let income = try #require(importedDocument.transactions.first { $0.kind == .income })
        #expect(income.incomeSourceID == EntryFixtures.parents.id)
        #expect(income.legs.single?.accountID == EntryFixtures.wallet.id)
        let transfer = try #require(importedDocument.transactions.first { $0.kind == .transfer })
        #expect(transfer.legs.map(\.accountID) == [EntryFixtures.bank.id, EntryFixtures.wallet.id])
    }

    @Test("Account creation records an observed opening balance, never income")
    func openingBalanceIsAccountTruth() throws {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = try FinanceStore(context: container.mainContext, now: fixtureInstant(EntryFixtures.today))
        try store.saveAccount(
            AccountDraft(
                id: nil,
                name: "BNP",
                kind: .bank,
                currencyCode: "EUR",
                fractionDigits: 2,
                openingBalance: .eur(123.45),
                openingBalanceDay: CalendarDay(year: 2026, month: 9, day: 1),
                isActive: true
            )
        )
        let document = try store.exportDocument()
        #expect(document.accounts.single?.name == "BNP")
        #expect(document.balances.single?.balance.minorUnits == 12_345)
        #expect(document.balances.single?.status == .observed)
        #expect(document.transactions.isEmpty)
    }

    @Test("Production-shaped first launch is empty and offers no transaction account")
    func firstLaunchIsEmpty() throws {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = try FinanceStore(context: container.mainContext, now: fixtureInstant(EntryFixtures.today))
        #expect(store.snapshot.accounts.isEmpty)
        #expect(store.snapshot.activity.isEmpty)
        #expect(store.snapshot.entryOptions.accounts.isEmpty)
        #expect(try store.exportDocument().documentKind == "LOCAL-USER-DATA")
    }

    @Test("JPY and KWD account exponents drive exact amount parsing")
    func exponentBehavior() throws {
        #expect(try Amount.parse("123", currencyCode: "JPY", fractionDigits: 0).minorUnits == 123)
        #expect(throws: Amount.ParseFailure.excessPrecision(allowed: 0)) {
            try Amount.parse("123.5", currencyCode: "JPY", fractionDigits: 0)
        }
        #expect(try Amount.parse("12.345", currencyCode: "KWD", fractionDigits: 3).minorUnits == 12_345)
        #expect(try Amount.parse("18.40", currencyCode: "EUR", fractionDigits: 2).minorUnits == 1_840)
    }

    @Test("A cross-currency plain transfer is refused without changing balances")
    func crossCurrencyTransferRefused() throws {
        let harness = try EntryFixtures.Harness()
        let before = try harness.store.exportDocument()
        #expect(throws: AppEntryError.transferCurrencyMismatch(from: "EUR", to: "MAD")) {
            try harness.store.add(
                EntryFixtures.draft(
                    kind: .transfer,
                    amount: .eur(30.00),
                    accountID: EntryFixtures.wallet.id,
                    counterAccountID: EntryFixtures.cashMAD.id
                )
            )
        }
        #expect(try harness.store.exportDocument() == before)
    }

    @Test("Income requires a stable economic source ID")
    func incomeSourceIsMandatory() throws {
        let harness = try EntryFixtures.Harness()
        var draft = EntryFixtures.draft(kind: .income, amount: .eur(20))
        draft.incomeSourceID = nil
        #expect(throws: AppEntryError.missingIncomeSource) {
            try harness.store.add(draft)
        }
    }

    @Test("Last-used expense and income accounts survive a store reload")
    func rememberedAccountDefaults() throws {
        let harness = try EntryFixtures.Harness()
        try harness.store.add(EntryFixtures.draft(accountID: EntryFixtures.bank.id))
        try harness.store.add(
            EntryFixtures.draft(
                kind: .income,
                amount: .eur(25),
                accountID: EntryFixtures.wallet.id
            )
        )

        let reloaded = try FinanceStore(
            context: harness.container.mainContext,
            now: fixtureInstant(EntryFixtures.today)
        )
        #expect(reloaded.snapshot.entryOptions.defaultExpenseAccountID == EntryFixtures.bank.id)
        #expect(reloaded.snapshot.entryOptions.defaultIncomeAccountID == EntryFixtures.wallet.id)
    }

    @Test("Income-source activation is app state that survives a store reload")
    func incomeSourceActivationPersists() throws {
        let harness = try EntryFixtures.Harness()
        let parents = try #require(harness.store.snapshot.incomeSources.first)
        try harness.store.saveIncomeSource(sourceDraft(parents, isActive: false))

        let reloaded = try FinanceStore(
            context: harness.container.mainContext,
            now: fixtureInstant(EntryFixtures.today)
        )
        #expect(reloaded.snapshot.incomeSources.first { $0.id == parents.id }?.isActive == false)
        #expect(!reloaded.snapshot.entryOptions.incomeSources.contains { $0.id == parents.id })
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
