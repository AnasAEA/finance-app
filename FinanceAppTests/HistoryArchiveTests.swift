import Foundation
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

@MainActor
@Suite("Private historical archive")
struct HistoryArchiveTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func record(
        id: String,
        day: Day,
        accountID: String = "bnp",
        provider: String = "bnp_statement",
        amount: Int64 = -1_000,
        currency: String = "EUR",
        merchant: String? = "Synthetic Merchant",
        description: String = "Synthetic transaction",
        categoryTop: String = "essential",
        categorySub: String? = "groceries",
        type: String = "expense",
        status: String = "booked",
        provenance: String = "canonical",
        confidence: String = "high",
        linkedID: String? = nil
    ) -> FinanceHistoricalRecord {
        FinanceHistoricalRecord(
            historicalID: id,
            date: day,
            accountID: accountID,
            provider: provider,
            rail: "card",
            merchant: merchant,
            description: description,
            rawDescription: "SAFE SYNTHETIC RAW",
            originalAmount: FinanceHistoryOriginalAmount(cents: amount, currency: currency),
            bookedAmountEURCents: currency == "EUR" ? amount : nil,
            economicAmountEURCents: currency == "EUR" ? amount : nil,
            personalAmountEURCents: currency == "EUR" ? amount : nil,
            category: FinanceHistoryCategory(top: categoryTop, sub: categorySub),
            economicType: type,
            status: status,
            provenance: provenance,
            confidence: confidence,
            economicViewRole: "personal",
            links: FinanceHistoryLinks(linkedTransactionID: linkedID, groupID: linkedID.map { "group-\($0)" }),
            evidence: FinanceHistoryEvidence(
                ruleID: "synthetic.rule",
                basis: "Synthetic test evidence"
            )
        )
    }

    private func document(
        id: String = "synthetic-archive",
        records: [FinanceHistoricalRecord],
        gaps: [FinanceHistorySourceGap] = [],
        cutoff: Day? = nil
    ) throws -> FinanceHistoryDocument {
        let first = try #require(records.map(\.date).min())
        let last = try #require(records.map(\.date).max())
        let accountsByID = Dictionary(
            records.map { ($0.accountID, ($0.provider, $0.accountID.uppercased())) },
            uniquingKeysWith: { first, _ in first }
        )
        let accounts = accountsByID.map {
            FinanceHistoryAccount(id: $0.key, name: $0.value.1, provider: $0.value.0)
        }
        let payload = FinanceHistoryPayload(
            archiveCutoff: cutoff ?? last,
            recordCount: records.count,
            dateRange: FinanceHistoryDateRange(start: first, end: last),
            accounts: accounts,
            sourceGaps: gaps,
            records: records
        )
        return try FinanceHistoryInterchange.make(
            archiveID: id,
            sourceRevision: "synthetic-revision",
            payload: payload
        )
    }

    @Test("A 2.0.0 archive carries an explicit exponent through to the surface")
    func explicitExponentReachesTheSurface() throws {
        let container = try container()
        let context = container.mainContext
        let service = HistoryArchiveService(context: context)

        // Identities 1.x could not state at all: an unknown code at five
        // digits, and EUR at zero.
        let exotic = FinanceHistoricalRecord(
            historicalID: "exotic",
            date: Day(year: 2025, month: 1, day: 2),
            accountID: "bnp",
            provider: "bnp_statement",
            rail: "card",
            merchant: "Synthetic Merchant",
            description: "Synthetic transaction",
            originalAmount: FinanceHistoryOriginalAmount(
                cents: 100, currency: "XAA", currencyExponent: 5
            ),
            economicAmountEURCents: -1,
            personalAmountEURCents: -1,
            category: FinanceHistoryCategory(top: "essential", sub: "groceries"),
            economicType: "expense",
            status: "booked",
            provenance: "canonical",
            confidence: "high",
            economicViewRole: "personal",
            evidence: FinanceHistoryEvidence(
                ruleID: "synthetic.rule", basis: "Synthetic test evidence"
            )
        )
        let wholeEuro = FinanceHistoricalRecord(
            historicalID: "whole-euro",
            date: Day(year: 2025, month: 1, day: 3),
            accountID: "bnp",
            provider: "bnp_statement",
            rail: "card",
            merchant: "Synthetic Merchant",
            description: "Synthetic transaction",
            originalAmount: FinanceHistoryOriginalAmount(
                cents: 100, currency: "EUR", currencyExponent: 0
            ),
            bookedAmountEURCents: 10_000,
            economicAmountEURCents: 10_000,
            personalAmountEURCents: 4_000,
            category: FinanceHistoryCategory(top: "essential", sub: "groceries"),
            economicType: "expense",
            status: "booked",
            provenance: "canonical",
            confidence: "high",
            economicViewRole: "personal",
            evidence: FinanceHistoryEvidence(
                ruleID: "synthetic.rule", basis: "Synthetic test evidence"
            )
        )
        let archive = try document(records: [exotic, wholeEuro])
        #expect(archive.schemaVersion == "2.0.0")

        _ = try service.prepareImport(data: FinanceHistoryInterchange.encode(archive))
        _ = try service.confirmImport()

        let rows = try context.fetch(FetchDescriptor<StoredHistoricalTransaction>())
        let storedExotic = try #require(rows.first { $0.identifier == "exotic" })
        #expect(storedExotic.currencyCode == "XAA")
        #expect(storedExotic.currencyExponent == 5)
        #expect(storedExotic.amountMinor == 100)

        let storedEuro = try #require(rows.first { $0.identifier == "whole-euro" })
        #expect(storedEuro.currencyExponent == 0)

        // The surface renders at the archive's own scale, not a fixed two.
        let page = try HistoryArchiveQueries(context: context).page(offset: 0, limit: 10)
        let surfaced = try #require(page.transactions.first { $0.id == "exotic" })
        #expect(surfaced.amount.currencyCode == "XAA")
        #expect(surfaced.amount.fractionDigits == 5)
        #expect(surfaced.amount.minorUnits == 100)

        let surfacedEuro = try #require(page.transactions.first { $0.id == "whole-euro" })
        #expect(surfacedEuro.amount.fractionDigits == 0)
        let currencies = try HistoryArchiveQueries(context: context).filterCatalog().currencies
        #expect(currencies.first { $0.id == "XAA" }?.fractionDigits == 5)
        #expect(currencies.first { $0.id == "EUR" }?.fractionDigits == 0)
        // The EUR-denominated companion fields stay fixed scale 2 even though
        // the original amount beside them is EUR/0.
        #expect(surfacedEuro.personalAmount?.fractionDigits == 2)
        #expect(surfacedEuro.personalAmount?.currencyCode == "EUR")
        #expect(surfacedEuro.personalAmount?.minorUnits == 4_000)
    }

    @Test("Imported currency exponent comes from the frozen historical table")
    func importExponentComesFromFrozenTable() throws {
        let container = try container()
        let context = container.mainContext
        let service = HistoryArchiveService(context: context)
        let codes = ["EUR", "JPY", "KWD", "XAA"]
        let archive = try document(records: codes.enumerated().map { index, code in
            record(
                id: "row-\(code)",
                day: Day(year: 2025, month: 1, day: index + 1),
                amount: 100,
                currency: code
            )
        })
        _ = try service.prepareImport(data: FinanceHistoryInterchange.encode(archive))
        _ = try service.confirmImport()

        let rows = try context.fetch(FetchDescriptor<StoredHistoricalTransaction>())
        for code in codes {
            let row = try #require(rows.first { $0.currencyCode == code })
            // Frozen table, never the evolving registry.
            #expect(row.currencyExponent == Currency.legacyDefaultDigits(code))
        }
    }

    @Test("Invalid archive is rejected before any rows are written")
    func invalidRejected() throws {
        let container = try container()
        let service = HistoryArchiveService(context: container.mainContext)
        #expect(throws: HistoryArchiveImportError.invalidArchive) {
            try service.prepareImport(data: Data("{\"not\":\"history\"}".utf8))
        }
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredHistoryArchive>()) == 0)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<StoredHistoricalTransaction>()) == 0)
    }

    @Test("Replacement is atomic and failure keeps the previous archive")
    func atomicReplacement() throws {
        enum Injected: Error { case failure }
        let container = try container()
        let context = container.mainContext
        let first = try document(records: [
            record(id: "old", day: Day(year: 2025, month: 1, day: 1))
        ])
        _ = try HistoryArchivePersistence.replace(
            with: first, in: context, importedAt: Date(timeIntervalSince1970: 1)
        )

        let replacement = try document(id: "replacement", records: [
            record(id: "new", day: Day(year: 2025, month: 2, day: 1))
        ])
        #expect(throws: Injected.failure) {
            _ = try HistoryArchivePersistence.replace(
                with: replacement,
                in: context,
                importedAt: Date(timeIntervalSince1970: 2),
                beforeSave: { throw Injected.failure }
            )
        }

        let archives = try context.fetch(FetchDescriptor<StoredHistoryArchive>())
        let rows = try context.fetch(FetchDescriptor<StoredHistoricalTransaction>())
        #expect(archives.map(\.identifier) == ["synthetic-archive"])
        #expect(rows.map(\.identifier) == ["old"])
    }

    @Test("Reimport of the same archive and digest is idempotent")
    func idempotentReimport() throws {
        let container = try container()
        let context = container.mainContext
        let archive = try document(records: [
            record(id: "one", day: Day(year: 2025, month: 1, day: 1))
        ])
        _ = try HistoryArchivePersistence.replace(
            with: archive, in: context, importedAt: Date(timeIntervalSince1970: 1)
        )
        let second = try HistoryArchivePersistence.replace(
            with: archive, in: context, importedAt: Date(timeIntervalSince1970: 9)
        )
        guard case let .unchanged(metadata) = second else {
            Issue.record("Expected idempotent import")
            return
        }
        #expect(metadata.importedAt == Date(timeIntervalSince1970: 1))
        #expect(try context.fetchCount(FetchDescriptor<StoredHistoricalTransaction>()) == 1)
        #expect(try context.fetch(FetchDescriptor<StoredHistoricalTransaction>()).first?.identifier == "one")
    }

    @Test("Several thousand records import as normalized rows and page")
    func thousandsOfRows() throws {
        let container = try container()
        let context = container.mainContext
        let records = (0..<5_000).map { index in
            record(
                id: String(format: "row-%05d", index),
                day: Day(year: 2012 + index / 365, month: index % 12 + 1, day: index % 28 + 1),
                amount: -Int64(index + 1)
            )
        }
        let archive = try document(records: records)
        _ = try HistoryArchivePersistence.replace(
            with: archive, in: context, importedAt: Date(timeIntervalSince1970: 1)
        )

        #expect(try context.fetchCount(FetchDescriptor<StoredHistoricalTransaction>()) == 5_000)
        let page = try HistoryArchiveQueries(context: context).page(offset: 0, limit: 125)
        #expect(page.transactions.count == 125)
        #expect(page.nextOffset == 125)
    }

    @Test("Text and every primary filter compose")
    func combinedFilters() throws {
        let container = try container()
        let context = container.mainContext
        let wanted = record(
            id: "wanted",
            day: Day(year: 2025, month: 7, day: 4),
            accountID: "paypal",
            provider: "paypal",
            amount: -5_000,
            merchant: "Épicerie Uber",
            description: "Ride for Yousra",
            categoryTop: "transport",
            categorySub: "ride_hailing"
        )
        let archive = try document(records: [
            wanted,
            record(id: "wrong-account", day: wanted.date, amount: -5_000, merchant: "Uber"),
            record(
                id: "wrong-year", day: Day(year: 2024, month: 7, day: 4),
                accountID: "paypal", provider: "paypal", amount: -5_000, merchant: "Uber",
                categoryTop: "transport", categorySub: "ride_hailing"
            )
        ], cutoff: Day(year: 2025, month: 12, day: 31))
        _ = try HistoryArchivePersistence.replace(
            with: archive, in: context, importedAt: Date(timeIntervalSince1970: 1)
        )

        var query = HistoryQuery()
        query.searchText = "epicerie uber"
        query.dateRange = CalendarDay(year: 2025, month: 1, day: 1)...CalendarDay(year: 2025, month: 12, day: 31)
        query.accountIDs = ["paypal"]
        query.categoryIDs = ["transport::ride_hailing"]
        query.economicTypes = ["expense"]
        query.minimumAmountMinor = 2_000
        query.maximumAmountMinor = 10_000
        query.currencies = ["EUR"]
        query.amountFractionDigits = 2
        query.sourceIDs = ["paypal"]
        query.statuses = ["booked"]
        query.provenanceValues = ["canonical"]

        let page = try HistoryArchiveQueries(context: context).page(matching: query)
        #expect(page.transactions.map(\.id) == ["wanted"])
    }

    @Test("Newest, oldest and amount sorting never mutate persisted rows")
    func sorting() throws {
        let container = try container()
        let context = container.mainContext
        let archive = try document(records: [
            record(id: "middle", day: Day(year: 2024, month: 2, day: 1), amount: -500),
            record(id: "newest", day: Day(year: 2025, month: 2, day: 1), amount: -100),
            record(id: "oldest", day: Day(year: 2023, month: 2, day: 1), amount: -900)
        ])
        _ = try HistoryArchivePersistence.replace(
            with: archive, in: context, importedAt: Date(timeIntervalSince1970: 1)
        )
        let queries = HistoryArchiveQueries(context: context)

        var query = HistoryQuery()
        #expect(try queries.page(matching: query).transactions.map(\.id) == ["newest", "middle", "oldest"])
        query.sort = .oldestFirst
        #expect(try queries.page(matching: query).transactions.map(\.id) == ["oldest", "middle", "newest"])
        query.sort = .amountHighToLow
        #expect(throws: HistoryArchiveQueryError.amountCurrencyRequired) {
            try queries.page(matching: query)
        }
        query.currencies = ["EUR"]
        query.amountFractionDigits = 2
        #expect(try queries.page(matching: query).transactions.map(\.id) == ["oldest", "middle", "newest"])
        #expect(try context.fetchCount(FetchDescriptor<StoredHistoricalTransaction>()) == 3)
    }

    @Test("Coverage warning and advanced provenance survive detail reads")
    func gapsAndProvenance() throws {
        let container = try container()
        let context = container.mainContext
        let gap = FinanceHistorySourceGap(
            startMonth: MonthKey(year: 2024, month: 1),
            endMonth: MonthKey(year: 2024, month: 2),
            completeness: "PARTIAL",
            affectedSources: ["bnp_statement"],
            message: "Bank records for part of this period are incomplete."
        )
        let archive = try document(records: [
            record(
                id: "linked", day: Day(year: 2024, month: 2, day: 2),
                provenance: "source_evidence", confidence: "medium", linkedID: "purchase-1"
            )
        ], gaps: [gap])
        _ = try HistoryArchivePersistence.replace(
            with: archive, in: context, importedAt: Date(timeIntervalSince1970: 1)
        )
        let queries = HistoryArchiveQueries(context: context)
        var query = HistoryQuery()
        query.dateRange = CalendarDay(year: 2024, month: 2, day: 1)...CalendarDay(year: 2024, month: 2, day: 29)
        let page = try queries.page(matching: query)
        let detail = try #require(try queries.detail(id: "linked"))

        #expect(page.coverageGaps.count == 1)
        #expect(page.coverageGaps.first?.message.contains("incomplete") == true)
        #expect(detail.evidence.provenance == "source_evidence")
        #expect(detail.evidence.confidence == "medium")
        #expect(detail.evidence.linkedTransactionID == "purchase-1")
        #expect(detail.evidence.ruleID == "synthetic.rule")
    }

    @Test("Explicit cutoff gives each day to exactly one display domain")
    func cutoffBoundary() {
        let cutoff = CalendarDay(year: 2026, month: 8, day: 19)
        let before = CalendarDay(year: 2026, month: 8, day: 18)
        let after = CalendarDay(year: 2026, month: 8, day: 20)

        #expect(HistoryArchiveBoundary.includesArchiveDate(before, cutoff: cutoff))
        #expect(HistoryArchiveBoundary.includesArchiveDate(cutoff, cutoff: cutoff))
        #expect(!HistoryArchiveBoundary.includesLiveDate(cutoff, cutoff: cutoff))
        #expect(HistoryArchiveBoundary.includesLiveDate(after, cutoff: cutoff))
    }

    @Test("Archive import leaves the operational document and projections unchanged")
    func operationalIsolation() throws {
        let container = try container()
        let context = container.mainContext
        let operational = try FinanceStore.developmentFixture()
        try StoredDocumentGraph.replace(
            with: operational,
            in: context,
            writtenOn: Day(year: 2026, month: 9, day: 1)
        )
        let before = try FinanceStore(
            context: context,
            now: fixtureInstant(Day(year: 2026, month: 9, day: 1))
        ).snapshot
        let balancesBefore = try context.fetchCount(FetchDescriptor<StoredAccountBalance>())

        let history = try document(records: [
            record(id: "history", day: Day(year: 2020, month: 1, day: 1), amount: -999_999)
        ])
        let service = HistoryArchiveService(context: context)
        _ = try service.prepareImport(data: FinanceHistoryInterchange.encode(history))
        _ = try service.confirmImport()

        let loaded = try StoredDocumentGraph.load(from: context)
        let after = try FinanceStore(
            context: context,
            now: fixtureInstant(Day(year: 2026, month: 9, day: 1))
        ).snapshot
        #expect(loaded == operational)
        #expect(try context.fetchCount(FetchDescriptor<StoredAccountBalance>()) == balancesBefore)
        #expect(after.accountCash == before.accountCash)
        #expect(after.safeToSpend == before.safeToSpend)
        #expect(after.currentMonth == before.currentMonth)
    }
}
