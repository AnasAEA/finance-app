import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// Phase 2.5 — the archive is evidence, not ledger.
///
/// Several thousand reconstructed historical rows are, arithmetically, a very
/// large pile of money. If any of it reached the operational side it would
/// move balances, drown the forecast, invent a runway, or blow through a
/// monthly budget with spending from 2023. The separation is therefore not a
/// layering preference: it is the thing that keeps the current picture true.
///
/// Each test below names one operational fact and holds it still across an
/// archive import.
@MainActor
@Suite("The historical archive changes nothing operational")
struct ArchiveBoundaryTests {

    private static let today = Day(year: 2026, month: 9, day: 15)

    @MainActor
    private struct Harness {
        let container: ModelContainer
        let context: ModelContext
        var store: FinanceStore {
            get throws { try FinanceStore(context: context, now: fixtureInstant(ArchiveBoundaryTests.today)) }
        }
    }

    private static func harness() throws -> Harness {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        try StoredDocumentGraph.replace(
            with: operationalDocument(),
            in: context,
            writtenOn: today
        )
        return Harness(container: container, context: context)
    }

    /// A live plan with a balance, a budget under a ceiling, and a commitment
    /// still owed — the things an archive must not touch.
    private static func operationalDocument() -> FinanceDocument {
        let bank = Account(
            id: "bank", name: "Bank", currency: .eur, kind: .bank,
            supportedRails: [.cardDebit, .sepaCreditTransfer, .sepaDirectDebit], drawOrder: 0
        )
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [bank],
            balances: [
                AccountBalance(
                    accountID: "bank",
                    balance: Money(exactDecimal: "384.09", currency: .eur)!,
                    asOf: Day(year: 2026, month: 9, day: 1)
                )
            ],
            transactions: [
                Transaction(
                    id: "live-1", date: Day(year: 2026, month: 9, day: 3), kind: .expense,
                    legs: [AccountLeg(
                        accountID: "bank",
                        amount: Money(exactDecimal: "-24.50", currency: .eur)!
                    )],
                    factivity: .observed
                )
            ],
            planning: FinanceDocument.Planning(
                safetyFloor: Money(exactDecimal: "50.00", currency: .eur)!,
                monthlyEconomicCeiling: Money(exactDecimal: "700.00", currency: .eur)!,
                budgets: [
                    BudgetAllocation(
                        id: "housing", name: "Housing", spendingClass: .essential,
                        monthlyAmount: Money(exactDecimal: "480.00", currency: .eur)!,
                        effectiveFrom: MonthKey(year: 2026, month: 1),
                        confirmation: .userConfirmed
                    )
                ],
                recurringObligations: [
                    RecurringObligation(
                        id: "ob-rent", name: "Landlord",
                        amount: Money(exactDecimal: "-480.00", currency: .eur)!,
                        spec: .monthly(onDay: 25, from: MonthKey(year: 2026, month: 1), through: nil),
                        requirement: PaymentRequirement(
                            currency: .eur, acceptableRails: [.sepaDirectDebit]
                        ),
                        spendingClass: .essential, budgetID: "housing"
                    )
                ]
            )
        )
    }

    /// An archive whose rows are large, old, and numerous enough that any leak
    /// into the operational side would be unmissable.
    private static func loudArchive() throws -> Data {
        let records = (0..<200).map { index in
            HistoryArchiveFixture.record(
                id: "loud-\(index)",
                day: Day(year: 2023, month: 1 + index % 12, day: 1 + index % 28),
                amount: -999_99
            )
        }
        let days = records.map(\.date)
        let payload = FinanceHistoryPayload(
            archiveCutoff: HistoryArchiveFixture.cutoff,
            recordCount: records.count,
            dateRange: FinanceHistoryDateRange(start: days.min()!, end: days.max()!),
            accounts: [
                FinanceHistoryAccount(id: "acct-a", name: "Synthetic A", provider: "provider_a")
            ],
            records: records
        )
        return try FinanceHistoryInterchange.encode(
            FinanceHistoryInterchange.make(
                archiveID: "loud-archive", sourceRevision: "synthetic", payload: payload
            )
        )
    }

    @discardableResult
    private static func importArchive(_ harness: Harness, data: Data? = nil) throws -> HistoryImportOutcome {
        let service = HistoryArchiveService(context: harness.context)
        _ = try service.prepareImport(data: data ?? loudArchive())
        return try service.confirmImport()
    }

    // MARK: - Nothing operational moves

    @Test("Balances, liquidity, forecast and safe-to-spend are untouched")
    func operationalFiguresAreUnchanged() throws {
        let harness = try Self.harness()
        let before = try harness.store.snapshot

        try Self.importArchive(harness)
        let after = try harness.store.snapshot

        #expect(after.accountCash == before.accountCash)
        #expect(after.trackedHoldings == before.trackedHoldings)
        #expect(after.safeToSpend == before.safeToSpend)
        #expect(after.safeDailySpend == before.safeDailySpend)
        #expect(after.cashRunway == before.cashRunway)
        #expect(after.lowestPoint == before.lowestPoint)
        #expect(after.runwayPoints == before.runwayPoints)
        #expect(after.monthProjections == before.monthProjections)
        #expect(after.firstRisk == before.firstRisk)
        #expect(after.minimumBridgeRequired == before.minimumBridgeRequired)
    }

    @Test("The month's budget counts no historical spending")
    func budgetIsUnchanged() throws {
        let harness = try Self.harness()
        let before = try harness.store.snapshot.budget
        #expect(before.summary.spent == .eur(24.50))

        try Self.importArchive(harness)
        let after = try harness.store.snapshot.budget

        // 200 archive rows at 999.99 each would be impossible to miss.
        #expect(after.summary.spent == .eur(24.50))
        #expect(after == before)
    }

    @Test("The live activity list gains no archive rows")
    func activityIsUnchanged() throws {
        let harness = try Self.harness()
        let before = try harness.store.snapshot.activity

        try Self.importArchive(harness)

        #expect(try harness.store.snapshot.activity == before)
        #expect(try harness.store.snapshot.activity.flatMap(\.rows).count == 1)
    }

    @Test("Expected payments and settlement state are unchanged")
    func reconciliationIsUnchanged() throws {
        let harness = try Self.harness()
        let before = try harness.store.snapshot.expectedPayments

        try Self.importArchive(harness)

        #expect(try harness.store.snapshot.expectedPayments == before)
        #expect(try harness.store.snapshot.reconciliations.isEmpty)
    }

    @Test("The bank inbox and provider evidence are unchanged")
    func bankingIsUnchanged() throws {
        let harness = try Self.harness()
        let before = try harness.store.snapshot

        try Self.importArchive(harness)
        let after = try harness.store.snapshot

        #expect(after.syncedObservations == before.syncedObservations)
        #expect(after.providerAccountBindings == before.providerAccountBindings)
        #expect(after.providerBalanceStatuses == before.providerBalanceStatuses)
        #expect(after.providerConnections == before.providerConnections)
        #expect(after.mappableRemoteAccounts == before.mappableRemoteAccounts)
        #expect(after.unreviewedSyncedObservations.isEmpty)
    }

    @Test("The exported document is byte-for-byte the document that went in")
    func theDocumentItselfIsUnchanged() throws {
        let harness = try Self.harness()
        let before = try #require(try StoredDocumentGraph.load(from: harness.context))

        try Self.importArchive(harness)

        #expect(try StoredDocumentGraph.load(from: harness.context) == before)
        #expect(try harness.store.exportDocument() == before)
    }

    @Test("Exporting the plan carries no archive row with it")
    func exportCarriesNoArchive() throws {
        let harness = try Self.harness()
        try Self.importArchive(harness)

        let exported = try harness.store.exportDocument()
        #expect(exported.transactions.count == 1)
        #expect(exported.transactions.allSatisfy { !$0.id.hasPrefix("loud-") })
        #expect(exported.expectedTransactions.isEmpty)
    }

    // MARK: - And nothing operational leaks the other way

    @Test("Archive queries return archive rows only")
    func archiveQueriesSeeNoLiveRows() throws {
        let harness = try Self.harness()
        try Self.importArchive(harness, data: HistoryArchiveFixture.data())

        let page = try harness.store.history.page(limit: 100)
        #expect(page.transactions.count == HistoryArchiveFixture.recordCount)
        #expect(page.transactions.allSatisfy { $0.id != "live-1" })
        #expect(page.transactions.allSatisfy { $0.date <= HistoryArchiveFixture.cutoff.calendarDay })
    }

    @Test("The archive stops at its cutoff, and the live ledger starts after it")
    func theCutoffIsTheJoin() throws {
        let harness = try Self.harness()
        try Self.importArchive(harness, data: HistoryArchiveFixture.data())

        let cutoff = HistoryArchiveFixture.cutoff.calendarDay
        let page = try harness.store.history.page(limit: 100)
        #expect(page.transactions.allSatisfy {
            HistoryArchiveBoundary.includesArchiveDate($0.date, cutoff: cutoff)
        })
        // The live row is 2026-09-03, strictly after 2026-08-19.
        let liveDays = try harness.store.snapshot.activity.map(\.date)
        #expect(liveDays.allSatisfy { HistoryArchiveBoundary.includesLiveDate($0, cutoff: cutoff) })
    }

    // MARK: - Removing the plan does not remove the evidence

    @Test("An archive survives a re-import of current state")
    func archiveSurvivesACurrentStateImport() throws {
        let harness = try Self.harness()
        try Self.importArchive(harness, data: HistoryArchiveFixture.data())

        // Writing the operational graph again must not take the archive with
        // it: the two live in the same store but answer to different owners.
        try StoredDocumentGraph.replace(
            with: Self.operationalDocument(), in: harness.context, writtenOn: Self.today
        )

        let metadata = try #require(try harness.store.history.metadata())
        #expect(metadata.transactionCount == HistoryArchiveFixture.recordCount)
    }
}

private extension Day {
    var calendarDay: CalendarDay { DomainMapper.civilDay(self) }
}
