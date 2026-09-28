import Foundation
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

/// Opt-in synthetic diagnostic. Run one size at a time with
/// TEST_RUNNER_FINANCE_HISTORY_COUNT=1000|10000|50000. Add
/// TEST_RUNNER_FINANCE_HISTORY_MATCHED_TRANSACTION=1 to include an exact
/// same-amount recorded payment and exercise suggestion lookups.
@Suite("History scale diagnostics")
@MainActor
struct HistoryScaleDiagnostics {
    @Test("Persist, reopen and present a synthetic provider history",
          .enabled(if: ProcessInfo.processInfo.environment["FINANCE_HISTORY_COUNT"] != nil))
    func measuredHistory() throws {
        let count = try #require(Int(ProcessInfo.processInfo.environment["FINANCE_HISTORY_COUNT"] ?? ""))
        guard [1_000, 10_000, 50_000].contains(count) else {
            Issue.record("History scale must be 1000, 10000 or 50000")
            return
        }

        let day = Day(year: 2026, month: 8, day: 23)
        let instant = fixtureInstant(day)
        let matchedTransaction = ProcessInfo.processInfo.environment["FINANCE_HISTORY_MATCHED_TRANSACTION"] == "1"
        let account = Account(id: "synthetic-bank", name: "Synthetic Bank", currency: .eur,
                              kind: .bank, supportedRails: [.cardDebit])
        let binding = ExternalAccountBinding(id: "synthetic-binding", provider: .bnp,
            remoteOpaqueAccountID: "acct_00000000000000000000000000000001",
            localAccountID: account.id, syncStartBoundary: day, createdAt: instant)
        let observations = (0..<count).map { index in
            ExternalObservation(
                id: String(format: "obs_%032x", index), bindingID: binding.id, provider: .bnp,
                status: .booked, creditDebitIndicator: .debit,
                amount: Money(minorUnits: -100, currency: .eur), bookingDate: day,
                rawMerchantText: "SYNTHETIC MERCHANT", eligibleForEconomicActual: true,
                observedAt: instant
            )
        }
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion, documentKind: "TEST",
            accounts: [account],
            balances: [AccountBalance(accountID: account.id,
                                      balance: Money(minorUnits: 100_000, currency: .eur), asOf: day)],
            transactions: matchedTransaction ? [
                Transaction(id: "synthetic-recorded", date: day, kind: .expense,
                    legs: [AccountLeg(accountID: account.id,
                                      amount: Money(minorUnits: -100, currency: .eur))],
                    factivity: .observed)
            ] : [],
            externalAccountBindings: [binding], externalObservations: observations,
            observationResolutions: observations.map {
                ExternalObservationResolution(observationID: $0.id, state: .unreviewed)
            }
        )
        let encodedAt = Date()
        let encoded = try Interchange.encode(document)
        let encodeSeconds = Date().timeIntervalSince(encodedAt)
        let decodedAt = Date()
        #expect(try Interchange.decode(encoded).externalObservations.count == count)
        let decodeSeconds = Date().timeIntervalSince(decodedAt)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-scale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic.store")
        let schema = Schema(FinanceSchema.models)

        let savedAt = Date()
        do {
            let container = try ModelContainer(for: schema,
                configurations: ModelConfiguration(schema: schema, url: url))
            try StoredDocumentGraph.replace(
                with: document, in: container.mainContext, writtenOn: day,
                presentation: matchedTransaction ? [
                    "synthetic-recorded": DomainMapper.TransactionPresentation(
                        categoryKey: nil, merchant: "SYNTHETIC MERCHANT"
                    )
                ] : [:]
            )
        }
        let saveSeconds = Date().timeIntervalSince(savedAt)

        let openedAt = Date()
        let reopened = try ModelContainer(for: schema,
            configurations: ModelConfiguration(schema: schema, url: url))
        let loaded = try #require(try StoredDocumentGraph.load(from: reopened.mainContext))
        #expect(loaded.externalObservations.count == count)
        let loadSeconds = Date().timeIntervalSince(openedAt)

        let storeOpenedAt = Date()
        let store = try FinanceStore(context: reopened.mainContext, now: instant)
        #expect(!store.storeIsUnreadable)
        #expect(store.snapshot.syncedObservations.count == count)
        if matchedTransaction {
            #expect(store.snapshot.syncedObservations.first?.suggestions.contains {
                $0.kind == .existingTransaction
            } == true)
        }
        let storeOpenSeconds = Date().timeIntervalSince(storeOpenedAt)

        let recalculatedAt = Date()
        #expect(store.snapshot(under: .base).syncedObservations.count == count)
        let recalculationSeconds = Date().timeIntervalSince(recalculatedAt)
        print("[history-scale] count=\(count) matchedTransaction=\(matchedTransaction) encode=\(encodeSeconds) decode=\(decodeSeconds) save=\(saveSeconds) load=\(loadSeconds) storeOpen=\(storeOpenSeconds) recalculate=\(recalculationSeconds)")
    }
}
