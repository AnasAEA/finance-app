import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

func fixtureInstant(_ day: Day, in timeZone: TimeZone = .current) -> Date {
    guard let date = DomainMapper.date(day, in: timeZone) else {
        preconditionFailure("test fixture days are Foundation-representable")
    }
    return date
}

/// Accounts and drafts the entry suites share.
///
/// Deliberately not nested inside a `@MainActor` suite: a default argument is
/// evaluated in a nonisolated context, so `accountID: String = bank.id` there
/// is an actor-isolation violation — a warning today, an error in Swift 6, and
/// enough to stop the testing macro registering that type's tests at all.
enum EntryFixtures {

    static let bank = Account(
        id: "bank-eur", name: "BNP", currency: .eur, kind: .bank,
        supportedRails: PaymentRail.euroBankRails, drawOrder: 0
    )
    static let wallet = Account(
        id: "wallet-eur", name: "Revolut", currency: .eur, kind: .wallet,
        supportedRails: PaymentRail.euroWalletRails, drawOrder: 1
    )
    static let cashMAD = Account(
        id: "cash-mad", name: "Cash MAD", currency: .mad, kind: .cash,
        supportedRails: PaymentRail.cashOnlyRails, drawOrder: 2
    )
    static let walletKWD = Account(
        id: "wallet-kwd", name: "KWD Wallet", currency: .kwd, kind: .wallet,
        supportedRails: [.electronicPayment], drawOrder: 3
    )

    static var accounts: [Account] { [bank, wallet, cashMAD, walletKWD] }

    static let today = Day(year: 2026, month: 9, day: 16)
    static let parents = IncomeSource(
        id: "income-parents",
        name: "Parents",
        amount: Money(minorUnits: 0, currency: .eur),
        certainty: .received,
        schedule: .oneShot(on: today),
        arrivesOnAccount: bank.id
    )

    static func document() -> FinanceDocument {
        FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: accounts,
            balances: accounts.map {
                AccountBalance(
                    accountID: $0.id,
                    balance: Money(minorUnits: 50_000, currency: $0.currency),
                    asOf: today
                )
            },
            incomeSources: [parents]
        )
    }

    /// A store and the container underneath it.
    ///
    /// Both are handed back together on purpose: a `ModelContext` does not keep
    /// its `ModelContainer` alive, so a helper that returns only the store
    /// leaves the test working against a container that has been deallocated.
    @MainActor
    final class Harness {
        let container: ModelContainer
        let store: FinanceStore

        init(_ document: FinanceDocument = EntryFixtures.document()) throws {
            container = try ModelContainer(
                for: Schema(FinanceSchema.models),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            store = try FinanceStore(
                context: container.mainContext,
                now: fixtureInstant(EntryFixtures.today)
            )
            try store.importDocument(document)
        }
    }

    static func draft(
        kind: TransactionDraft.Kind = .expense,
        amount: Amount = .eur(12.34),
        accountID: String = EntryFixtures.bank.id,
        counterAccountID: String? = nil,
        incomeSourceID: String? = nil,
        ownShare: Amount? = nil,
        merchant: String? = nil
    ) -> TransactionDraft {
        TransactionDraft(
            day: CalendarDay(year: 2026, month: 9, day: 16),
            kind: kind,
            amount: amount,
            accountID: accountID,
            counterAccountID: counterAccountID,
            incomeSourceID: kind == .income ? (incomeSourceID ?? EntryFixtures.parents.id) : nil,
            categoryKey: kind == .transfer ? nil : "food",
            merchant: merchant,
            ownShare: ownShare
        )
    }
}
