import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// Saving either persists the entry or says why it did not.
///
/// The failure this suite exists for is not a crash: it is the sheet closing on
/// a transaction that was never written, leaving someone believing a payment is
/// recorded. Every rejection below used to be a silent `return`.
@MainActor
@Suite("An entry is saved, or refused out loud")
struct EntryValidationTests {

        private func rejection(_ body: () throws -> Void) -> AppEntryError? {
        do { try body(); return nil }
        catch let error as AppEntryError { return error }
        catch { return nil }
    }

    // MARK: - The path that works

    @Test("A valid expense is persisted and readable back")
    func successfulSave() throws {
        let harness = try EntryFixtures.Harness()
        let store = harness.store
        try store.add(EntryFixtures.draft(merchant: "Carrefour"))

        let row = try #require(
            store.snapshot.activity.flatMap(\.rows).first { $0.title == "Carrefour" }
        )
        #expect(row.flow == .spending)
        #expect(row.amount == Amount.eur(12.34).negated)
        // And on disk, not only in the published snapshot.
        #expect(try store.exportDocument().transactions.contains { $0.id == row.id })
    }

    @Test("A valid transfer between same-currency accounts is persisted")
    func successfulTransfer() throws {
        let harness = try EntryFixtures.Harness()
        let store = harness.store
        try store.add(
            EntryFixtures.draft(kind: .transfer, amount: .eur(50), counterAccountID: EntryFixtures.wallet.id)
        )
        let moved = try #require(
            try store.exportDocument().transactions.first { $0.kind == .transfer }
        )
        #expect(moved.legs.count == 2)
    }

    // MARK: - The paths that used to close the sheet on nothing

    @Test("A transfer into another currency is refused, not silently dropped")
    func transferCurrencyMismatch() throws {
        let harness = try EntryFixtures.Harness()
        let store = harness.store
        let error = rejection {
            try store.add(
                EntryFixtures.draft(kind: .transfer, amount: .eur(50), counterAccountID: EntryFixtures.cashMAD.id)
            )
        }
        #expect(error == .transferCurrencyMismatch(from: "EUR", to: "MAD"))
        #expect(try store.exportDocument().transactions.isEmpty)
    }

    @Test("A transfer with no destination is refused")
    func missingCounterAccount() throws {
        let harness = try EntryFixtures.Harness()
        let store = harness.store
        #expect(rejection { try store.add(EntryFixtures.draft(kind: .transfer, amount: .eur(50))) }
                == .missingCounterAccount)
    }

    @Test("A transfer to the account it leaves is refused")
    func counterAccountIsSource() throws {
        let harness = try EntryFixtures.Harness()
        let store = harness.store
        let error = rejection {
            try store.add(
                EntryFixtures.draft(kind: .transfer, amount: .eur(50), counterAccountID: EntryFixtures.bank.id)
            )
        }
        #expect(error == .counterAccountIsSource)
    }

    @Test("A stale account id is refused")
    func staleAccount() throws {
        let harness = try EntryFixtures.Harness()
        let store = harness.store
        #expect(rejection { try store.add(EntryFixtures.draft(accountID: "closed-last-year")) }
                == .unknownAccount(id: "closed-last-year"))
    }

    @Test("A stale destination id is refused")
    func staleCounterAccount() throws {
        let harness = try EntryFixtures.Harness()
        let store = harness.store
        let error = rejection {
            try store.add(
                EntryFixtures.draft(kind: .transfer, amount: .eur(50), counterAccountID: "gone")
            )
        }
        #expect(error == .unknownCounterAccount(id: "gone"))
    }

    @Test("An amount in the wrong currency for the account is refused")
    func amountCurrencyMismatch() throws {
        let harness = try EntryFixtures.Harness()
        let store = harness.store
        let error = rejection {
            try store.add(
                EntryFixtures.draft(amount: Amount(minorUnits: 5_000, currencyCode: "MAD"), accountID: EntryFixtures.bank.id)
            )
        }
        #expect(error == .amountCurrencyMismatch(amountCurrency: "MAD", accountCurrency: "EUR"))
    }

    @Test("A zero amount is refused")
    func zeroAmount() throws {
        let harness = try EntryFixtures.Harness()
        let store = harness.store
        #expect(rejection { try store.add(EntryFixtures.draft(amount: .eur(0))) } == .invalidAmount)
    }

    @Test("A share that is zero, negative, or larger than the inflow is refused")
    func invalidShare() throws {
        let harness = try EntryFixtures.Harness()
        let store = harness.store
        for share in [Amount.eur(0), Amount.eur(50).negated, Amount.eur(150)] {
            let error = rejection {
                try store.add(EntryFixtures.draft(kind: .income, amount: .eur(100), ownShare: share))
            }
            #expect(error == .invalidOwnShare, "\(share)")
        }
        // A share denominated in something the inflow never was.
        let wrongCurrency = rejection {
            try store.add(
                EntryFixtures.draft(
                    kind: .income, amount: .eur(100),
                    ownShare: Amount(minorUnits: 5_000, currencyCode: "MAD")
                )
            )
        }
        #expect(wrongCurrency == .invalidOwnShare)
        #expect(try store.exportDocument().transactions.isEmpty)
    }

    @Test("A share equal to the whole inflow is ordinary income, not a pass-through")
    func wholeShareIsPlainIncome() throws {
        let harness = try EntryFixtures.Harness()
        let store = harness.store
        try store.add(EntryFixtures.draft(kind: .income, amount: .eur(100), ownShare: .eur(100)))
        let saved = try #require(try store.exportDocument().transactions.first)
        #expect(saved.kind == .income)
        #expect(saved.ownership == nil)
    }

    @Test("A preview store refuses to pretend it saved something")
    func readOnlyStore() {
        let store = FinanceStore(snapshot: .empty(asOf: CalendarDay(year: 2026, month: 9, day: 16)))
        #expect(rejection { try store.add(EntryFixtures.draft()) } == .storeIsReadOnly)
    }

    @Test("A store that could not be read refuses to write over it")
    func persistenceFailureIsSurfaced() throws {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        // Held for the whole test: the context alone would not keep it alive.
        let context = container.mainContext
        // A store written by a version this build does not support.
        var future = EntryFixtures.document()
        future.schemaVersion = "9.9.9"
        context.insert(try StoredDocumentMeta(document: future, writtenOn: EntryFixtures.today))
        try context.save()

        let store = try FinanceStore(context: context, now: fixtureInstant(EntryFixtures.today))
        #expect(store.loadFailure != nil)

        let error = rejection { try store.add(EntryFixtures.draft(accountID: EntryFixtures.bank.id)) }
        // The account list is empty because nothing loaded, so the entry is
        // refused before it reaches persistence — either way, never silently.
        #expect(error != nil)
        #expect(store.snapshot.activity.isEmpty)
    }

    @Test("A refused entry leaves the document exactly as it was")
    func refusalDoesNotHalfApply() throws {
        let harness = try EntryFixtures.Harness()
        let store = harness.store
        let before = try store.exportDocument()
        _ = rejection {
            try store.add(
                EntryFixtures.draft(kind: .transfer, amount: .eur(50), counterAccountID: EntryFixtures.cashMAD.id)
            )
        }
        #expect(try store.exportDocument() == before)
        #expect(store.snapshot.accountCash == before.balances
            .filter { account in
                EntryFixtures.accounts.first { $0.id == account.accountID }.map {
                    $0.currency == .eur && $0.kind != .cash
                } == true
            }
            .reduce(Amount.zeroEUR) { $0 + DomainMapper.amount($1.balance) })
    }

    // MARK: - Destinations that are never offered

    @Test("Only same-currency destinations are offered for a transfer")
    func transferDestinationsAreFiltered() throws {
        let harness = try EntryFixtures.Harness()
        let store = harness.store
        let options = store.snapshot.entryOptions

        let fromBank = options.transferDestinations(from: EntryFixtures.bank.id).map(\.id)
        #expect(fromBank.contains(EntryFixtures.wallet.id))
        #expect(!fromBank.contains(EntryFixtures.cashMAD.id))
        #expect(!fromBank.contains(EntryFixtures.walletKWD.id))
        #expect(!fromBank.contains(EntryFixtures.bank.id))

        #expect(options.transferDestinations(from: EntryFixtures.walletKWD.id).isEmpty)
        #expect(options.transferDestinations(from: nil).isEmpty)
    }
}

/// The advanced sheet used to say "Only your share counts as spending" for an
/// expense. Nothing implemented that.
@MainActor
@Suite("Entry promises only what is implemented")
struct SharedExpenseTests {

    @Test("Only an inflow may carry an owned share")
    func onlyIncomeOffersAShare() {
        #expect(TransactionDraft.Kind.income.supportsOwnShareEntry)
        #expect(!TransactionDraft.Kind.expense.supportsOwnShareEntry)
        #expect(!TransactionDraft.Kind.transfer.supportsOwnShareEntry)
    }

    @Test("A shared expense is refused rather than stored at full price")
    func sharedExpenseIsRefused() throws {
        let harness = try EntryFixtures.Harness()
        let store = harness.store
        var error: AppEntryError?
        do {
            try store.add(
                EntryFixtures.draft(kind: .expense, amount: .eur(40), ownShare: .eur(20))
            )
        } catch let thrown as AppEntryError {
            error = thrown
        }
        #expect(error == .sharedExpenseNotSupported)
        // Above all: it did not quietly become a €40 expense.
        #expect(try store.exportDocument().transactions.isEmpty)
    }
}
