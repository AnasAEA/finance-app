import Foundation
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

/// Opt-in rehearsal against a COPY of the live store. Skips when the repaired
/// copy is absent. Never opens the physical device container.
@Suite("Copy-only current-holdings repair rehearsal")
@MainActor
struct CurrentHoldingsRepairRehearsalTests {
    private var repairedStore: URL {
        URL(
            filePath: ProcessInfo.processInfo.environment["FINANCE_HOLDINGS_STORE_COPY"]
                ?? "/tmp/finance-account-repair-20260901/rehearsal/FinanceCore-1.1.store"
        )
    }
    private var currentPhysicalCopy: URL {
        URL(
            filePath: ProcessInfo.processInfo.environment["FINANCE_PHYSICAL_STORE_COPY"]
                ?? "/tmp/finance-account-repair-20260901/inspect-now/FinanceCore-1.1.store"
        )
    }
    private let today = Day(year: 2026, month: 9, day: 1)

    @Test("Repaired copy matches provider and fallback to the cent")
    func repairedCopyReconciles() throws {
        guard FileManager.default.fileExists(atPath: repairedStore.path) else { return }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("current-holdings-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(filePath: repairedStore.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(
                    at: source,
                    to: directory.appendingPathComponent("FinanceCore-1.1.store\(suffix)")
                )
            }
        }

        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(
                url: directory.appendingPathComponent("FinanceCore-1.1.store")
            )
        )
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(today)
        )
        #expect(store.loadFailure == nil)
        let document = try store.exportDocument()
        try ExternalEvidenceReview.validate(document)
        #expect(document.transactions.count == 11)
        #expect(document.expectedTransactions.count == 3)

        let bnpAnchor = try #require(document.balances.first { $0.accountID == "bank-main" })
        #expect(bnpAnchor.balance.minorUnits == 38_409)
        #expect(bnpAnchor.asOf == Day(year: 2026, month: 8, day: 22))
        #expect(bnpAnchor.status == .carriedForward)

        let fallback = try #require(
            CurrentHoldings.derivedLedgerBalance(
                accountID: "bank-main", asOf: today, in: document
            )
        )
        #expect(fallback.minorUnits == 36_862)

        let provider = try #require(
            CurrentHoldings.canonicalProviderSnapshot(for: "bank-main", in: document)
        )
        #expect(provider.balanceType == "CLBD")
        #expect(provider.amount.minorUnits == 36_862)

        #expect(store.snapshot.accounts.first { $0.id == "bank-main" }?.balance.minorUnits == 36_862)
        #expect(store.snapshot.accounts.first { $0.id == "revolut-eur" }?.balance.minorUnits == 7_885)
        #expect(store.snapshot.accounts.first { $0.id == "paypal-eur" }?.balance.minorUnits == 0)
        #expect(store.snapshot.accountCash.minorUnits == 44_747)
        #expect(store.snapshot.currentPendingProviderSnapshots.count == 3)
        #expect(store.bankFreshness != .neverSynced)
        #expect(store.bankFreshness.caption(
            relativeTo: store.snapshot.freshnessReference()
        ) != "Not synced yet")

        let rowSum = store.snapshot.accounts
            .filter { $0.kind != .cash && $0.currencyCode == "EUR" }
            .reduce(Int64(0)) { $0 + $1.balance.minorUnits }
        #expect(rowSum == store.snapshot.accountCash.minorUnits)

        let phoneRepayments = document.transactions.filter { transaction in
            transaction.kind == .financingRepayment
                && transaction.date == Day(year: 2026, month: 8, day: 22)
                && transaction.legs.contains { $0.amount.minorUnits == -8_122 }
        }
        #expect(phoneRepayments.count == 2)
        #expect(!document.transactions.contains { $0.id.hasPrefix("transaction-a0454403") })
        #expect(!document.transactions.contains { transaction in
            transaction.legs.contains { $0.amount.minorUnits == -16_244 }
        })
        #expect(document.transactions.filter { $0.provenance.source == "EXTERNAL-EVIDENCE-REVIEW" }.count == 3)
        #expect(document.externalEvidenceLinks.count == 3)
        #expect(
            document.observationResolutions.filter { $0.state == .unreviewed }.count == 2
        )
        #expect(document.planning.settlements.count == 2)
        #expect(document.externalObservations.count == 447)
        #expect(store.trustedAutomationEnabled == false)

        #expect(
            CurrentHoldings.effective(accountID: "paypal-eur", asOf: today, in: document).source
                == .ledgerFallback
        )

        let aggregateObservation = try #require(document.externalObservations.first {
            $0.provider == .bnp
                && $0.amount == Money(minorUnits: -16_244, currency: .eur)
        })
        #expect(document.observationResolutions.first {
            $0.observationID == aggregateObservation.id
        }?.state == .unreviewed)
        let aggregateCandidates = document.crossProviderCandidates.filter {
            $0.bankObservationID == aggregateObservation.id
                || $0.walletObservationID == aggregateObservation.id
        }
        #expect(aggregateCandidates.map(\.state) == [.unique])
        #expect(document.externalEvidenceLinks.allSatisfy {
            $0.observationID != aggregateObservation.id
        })
        let aggregateSurface = try #require(store.snapshot.syncedObservations.first {
            $0.id == aggregateObservation.id
        })
        #expect(aggregateSurface.duplicateConflict?.kind == .aggregateExisting)
        #expect(aggregateSurface.duplicateConflict?.transactionIDs.count == 2)
        #expect(!aggregateSurface.suggestions.contains { $0.kind == .existingTransaction })
    }

    @Test("Sanitized unresolved PayPal debit audit uses evidence, not merchant text")
    func unresolvedPayPalDebitAudit() throws {
        guard FileManager.default.fileExists(atPath: currentPhysicalCopy.path) else { return }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paypal-review-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(filePath: currentPhysicalCopy.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(
                    at: source,
                    to: directory.appendingPathComponent("FinanceCore-1.1.store\(suffix)")
                )
            }
        }

        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(
                url: directory.appendingPathComponent("FinanceCore-1.1.store")
            )
        )
        let store = try FinanceStore(context: container.mainContext, now: fixtureInstant(today))
        let document = try store.exportDocument()
        let resolutions = Dictionary(
            uniqueKeysWithValues: document.observationResolutions.map {
                ($0.observationID, $0.state)
            }
        )
        let targets = document.externalObservations.filter {
            $0.provider == .paypal
                && $0.amount == Money(minorUnits: -799, currency: .eur)
                && resolutions[$0.id] == .unreviewed
        }
        let target = try #require(targets.only)
        let binding = try #require(
            document.externalAccountBindings.first { $0.id == target.bindingID }
        )
        let date = try #require(target.suggestedEconomicDate)

        let exactTransactions = document.transactions.filter { transaction in
            transaction.lifecycle != .reversed
                && date.isWithin(days: 5, of: transaction.date)
                && transaction.legs.contains {
                    $0.accountID == binding.localAccountID && $0.amount == target.amount
                }
        }
        let sameAmountTransactions = document.transactions.filter { transaction in
            transaction.lifecycle != .reversed
                && date.isWithin(days: 5, of: transaction.date)
                && transaction.legs.contains { $0.amount == target.amount }
        }
        let targetLinks = document.externalEvidenceLinks.filter {
            $0.observationID == target.id
        }
        let crossProvider = document.crossProviderCandidates.filter {
            $0.bankObservationID == target.id || $0.walletObservationID == target.id
        }
        let linkedRelatedTransactionIDs = Set(crossProvider.flatMap { candidate -> [String] in
            let relatedID = candidate.bankObservationID == target.id
                ? candidate.walletObservationID : candidate.bankObservationID
            guard candidate.state == .unique, let relatedID else { return [] }
            return document.externalEvidenceLinks.compactMap { link in
                link.observationID == relatedID && link.role == .accountMovement
                    ? link.transactionID : nil
            }
        })
        let linkedRelatedTransactions = document.transactions.filter {
            linkedRelatedTransactionIDs.contains($0.id) && $0.lifecycle != .reversed
        }
        let linkedSettlements = document.planning.settlements.filter { settlement in
            settlement.actualTransactionID.map(linkedRelatedTransactionIDs.contains) == true
        }
        let sameAmountSettlements = document.planning.settlements.filter { settlement in
            settlement.actualTransactionID.map { transactionID in
                sameAmountTransactions.contains { $0.id == transactionID }
            } == true
        }
        let nearbyOccurrences = OccurrenceExpander.occurrences(
            in: document,
            from: try #require(date.advanced(by: -5)),
            to: try #require(date.advanced(by: 5)),
            asOf: today,
            ledger: ReconciliationLedger(document.planning.settlements)
        ).filter {
            $0.amount == target.amount.magnitude
        }

        #expect(exactTransactions.isEmpty)
        #expect(sameAmountTransactions.count == 1)
        #expect(targetLinks.isEmpty)
        #expect(crossProvider.isEmpty)
        #expect(linkedRelatedTransactions.isEmpty)
        #expect(nearbyOccurrences.count == 1)
        #expect(nearbyOccurrences.allSatisfy { $0.status.isResolved })
        #expect(linkedSettlements.isEmpty)
        #expect(sameAmountSettlements.count == 1)
        let surface = try #require(store.snapshot.syncedObservations.first {
            $0.id == target.id
        })
        #expect(surface.duplicateConflict?.kind == .settledRecurring)
        #expect(surface.duplicateConflict?.transactionIDs.count == 1)
        #expect(!surface.suggestions.contains { $0.kind == .existingTransaction })
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
