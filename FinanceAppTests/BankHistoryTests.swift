import Foundation
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

@MainActor
@Suite("Synced bank history")
struct BankHistoryTests {
    private let today = Day(year: 2026, month: 9, day: 26)

    private func row(id: String = "bank", date: CalendarDay? = CalendarDay(year: 2026, month: 9, day: 23),
                     linked: String? = nil) -> BankHistoryItem {
        BankHistoryItem(id: id, title: "Synthetic shop", accountID: "bank-account", accountName: "Current",
                        providerID: "bnp", providerName: "BNP", amount: Amount(minorUnits: -1234, currencyCode: "EUR"),
                        dates: ObservationDates(booking: date, transaction: date, value: nil,
                                                derivedTransaction: nil, derivedProvenanceLabel: nil,
                                                economicPeriod: date),
                        observedAt: Date(timeIntervalSince1970: 1), status: .booked,
                        resolution: .unreviewed, linkedTransactionID: linked)
    }

    @Test("Only the archive boundary and a displayed persisted link suppress a bank row")
    func explicitOverlapOnly() {
        let cutoff = CalendarDay(year: 2026, month: 8, day: 19)
        #expect(row().isVisible(cutoff: cutoff, visibleTransactionIDs: ["same-looking-transaction"]))
        #expect(!row(linked: "recorded").isVisible(cutoff: cutoff, visibleTransactionIDs: ["recorded"]))
        #expect(row(linked: "recorded").isVisible(cutoff: cutoff, visibleTransactionIDs: []))
        #expect(!row(date: cutoff).isVisible(cutoff: cutoff, visibleTransactionIDs: []))
        #expect(row(date: nil).isVisible(cutoff: cutoff, visibleTransactionIDs: []))
    }

    @Test("Bank rows support search, account, source, currency, status and amount filters")
    func bankFilters() {
        var query = HistoryQuery()
        query.searchText = "synthetic SHOP"
        query.accountIDs = ["bank-account"]
        query.sourceIDs = ["bnp"]
        query.currencies = ["EUR"]
        query.statuses = ["booked"]
        query.minimumAmountMinor = 1200
        query.maximumAmountMinor = 1300
        query.amountFractionDigits = 2
        #expect(row().matches(query, catalog: .empty))
        query.economicTypes = ["expense"]
        #expect(!row().matches(query, catalog: .empty))
        query.economicTypes = []
        query.dateRange = CalendarDay(year: 2026, month: 9, day: 1)...CalendarDay(year: 2026, month: 9, day: 26)
        #expect(!row(date: nil).matches(query, catalog: .empty))
    }

    @Test("Archive and live filter catalogs retain both sources and refuse mixed scales")
    func mergedCatalog() {
        func catalog(account: String, digits: Int) -> HistoryFilterCatalog {
            HistoryFilterCatalog(accounts: [.init(id: account, name: account)], categories: [],
                                 economicTypes: [], economicSources: [],
                                 currencies: [.init(id: "EUR", name: "EUR", fractionDigits: digits)],
                                 sources: [], statuses: [], provenanceValues: [])
        }
        let merged = catalog(account: "archive", digits: 2).merging(catalog(account: "live", digits: 0))
        #expect(Set(merged.accounts.map(\.id)) == ["archive", "live"])
        #expect(merged.currencies.count == 1)
        #expect(merged.currencies.first?.fractionDigits == nil)
    }

    @Test("Import and reopen expose recent bank history without creating economics")
    func bankImportUpdatesHistory() throws {
        let container = try ModelContainer(for: Schema(FinanceSchema.models),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let account = Account(id: "bank-account", name: "Current", currency: .eur, kind: .bank,
                              supportedRails: [.cardDebit])
        let binding = ExternalAccountBinding(id: "binding", provider: .bnp, remoteOpaqueAccountID: "remote",
                                             localAccountID: account.id,
                                             syncStartBoundary: Day(year: 2026, month: 9, day: 1),
                                             createdAt: Date(timeIntervalSince1970: 1))
        let document = FinanceDocument(schemaVersion: Interchange.currentSchemaVersion, documentKind: "TEST",
                                       accounts: [account],
                                       balances: [AccountBalance(accountID: account.id,
                                                                 balance: Money(minorUnits: 10000, currency: .eur), asOf: today)],
                                       externalAccountBindings: [binding])
        try StoredDocumentGraph.replace(with: document, in: container.mainContext, writtenOn: today)
        let store = try FinanceStore(context: container.mainContext, now: fixtureInstant(today))
        func observation(_ id: String, day: Day?, identity: ExternalObservationIdentity = .durable,
                         status: ExternalObservationStatus = .booked) -> ExternalObservation {
            ExternalObservation(id: id, bindingID: binding.id, provider: .bnp, identity: identity,
                                status: status, creditDebitIndicator: .debit,
                                amount: Money(minorUnits: -1234, currency: .eur), transactionDate: day,
                                rawMerchantText: "Synthetic shop", eligibleForEconomicActual: identity == .durable,
                                observedAt: Date(timeIntervalSince1970: 1))
        }
        let economicBefore = store.snapshot
        try store.importBankEvidence(.init(observations: [
            observation("recent", day: Day(year: 2026, month: 9, day: 23)),
            observation("outside-review-period", day: Day(year: 2026, month: 8, day: 25)),
            observation("undated", day: nil),
            observation("current", day: today, identity: .provisionalSnapshot, status: .pending)
        ]), authoritativePendingSnapshots: [.bnp: .init(authoritativeAt: Date(timeIntervalSince1970: 1), observationIDs: ["current"])])
        #expect(Set(store.snapshot.bankHistory.map(\.id)) == ["recent", "outside-review-period", "undated", "current"])
        #expect(store.snapshot.activity.isEmpty)
        #expect(store.snapshot.safeToSpend == economicBefore.safeToSpend)
        #expect((try store.exportDocument()).transactions.isEmpty)
        let reopened = try FinanceStore(context: container.mainContext, now: fixtureInstant(today))
        #expect(reopened.snapshot.bankHistory == store.snapshot.bankHistory)
        try store.importBankEvidence(.init(), authoritativePendingSnapshots: [.bnp: .init(authoritativeAt: Date(timeIntervalSince1970: 2), observationIDs: [])])
        #expect(!store.snapshot.bankHistory.contains { $0.id == "current" })
    }
}
