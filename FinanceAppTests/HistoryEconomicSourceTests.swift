import Foundation
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

/// Economic source is the dimension that answers "where did this money come
/// from", and it is not the counterparty, the category, or the description.
///
/// The shapes exercised here are the real ones the reconstruction found and
/// the amounts are invented: support paid directly by a parent, the same
/// support handed on by a sibling, one arrival split between two people with
/// the sibling's share leaving again, and a sibling reimbursement that only
/// looks like the others on the bank statement.
@MainActor
@Suite("History economic source")
struct HistoryEconomicSourceTests {
    private static let parentalSupport = HistoryEconomicSource.parentalSupport
    private static let reimbursement = "SHARED_EXPENSE_REIMBURSEMENT"
    private static let unresolved = "UNRESOLVED_INCOMING"

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
        amount: Int64,
        personal: Int64? = nil,
        merchant: String,
        description: String,
        categoryTop: String = "INCOME",
        categorySub: String? = "Family_Support",
        type: String,
        economicSource: String?,
        passThrough: FinanceHistoryPassThrough = .none,
        provenance: String = "USER_CONFIRMED"
    ) -> FinanceHistoricalRecord {
        FinanceHistoricalRecord(
            historicalID: id,
            date: day,
            accountID: accountID,
            provider: provider,
            rail: "SEPA_VIR",
            merchant: merchant,
            description: description,
            rawDescription: merchant,
            originalAmount: FinanceHistoryOriginalAmount(cents: amount, currency: "EUR"),
            bookedAmountEURCents: amount,
            economicAmountEURCents: amount,
            personalAmountEURCents: personal ?? amount,
            category: FinanceHistoryCategory(top: categoryTop, sub: categorySub),
            economicType: type,
            economicSource: economicSource,
            status: "BOOKED_EUR",
            provenance: provenance,
            confidence: "high",
            flags: FinanceHistoryFlags(passThrough: passThrough),
            economicViewRole: "PRIMARY",
            evidence: FinanceHistoryEvidence(
                ruleID: "synthetic.rule", basis: "Synthetic test evidence"
            )
        )
    }

    /// One arrival straight from a parent; one economically identical arrival
    /// the sibling handed on; one arrival split with the sibling and the
    /// onward leg that hands that share over; one sibling reimbursement; one
    /// sibling transfer the reconstruction never resolved.
    private func chains() -> [FinanceHistoricalRecord] {
        [
            record(
                id: "direct-parent", day: Day(year: 2025, month: 5, day: 23),
                amount: 70_000, merchant: "PARENT NAME", description: "parent",
                type: "FAMILY_SUPPORT", economicSource: Self.parentalSupport
            ),
            record(
                id: "routed-via-sibling", day: Day(year: 2026, month: 8, day: 18),
                amount: 120_000, merchant: "SHARED HOUSEHOLD",
                description: "Parental support via sibling",
                type: "FAMILY_SUPPORT", economicSource: Self.parentalSupport
            ),
            record(
                id: "split-arrival", day: Day(year: 2026, month: 3, day: 30),
                amount: 280_000, personal: 140_000, merchant: "PARENT NAME",
                description: "parent", type: "FAMILY_SUPPORT",
                economicSource: Self.parentalSupport, passThrough: .partial
            ),
            record(
                id: "onward-leg", day: Day(year: 2026, month: 3, day: 30),
                amount: -140_000, personal: 0, merchant: "SIBLING NAME",
                description: "sibling share handed over",
                categoryTop: "TRANSFERS", categorySub: "Pass_Through",
                type: "PASS_THROUGH", economicSource: nil, passThrough: .full
            ),
            record(
                id: "sibling-reimbursement", day: Day(year: 2025, month: 8, day: 25),
                amount: 11_875, personal: 0, merchant: "SHARED HOUSEHOLD",
                description: "sibling laptop share",
                categoryTop: "REFUNDS", categorySub: "Shared_Expense_Reimbursement",
                type: "SHARED_EXPENSE_CONTRIBUTION", economicSource: Self.reimbursement
            ),
            record(
                id: "sibling-unresolved", day: Day(year: 2026, month: 2, day: 4),
                amount: 70_000, personal: 0, merchant: "SHARED HOUSEHOLD",
                description: "sibling transfer",
                categoryTop: "UNKNOWN", categorySub: "Unresolved_Incoming",
                type: "UNRESOLVED", economicSource: Self.unresolved,
                provenance: "UNRESOLVED"
            ),
        ]
    }

    private func document(
        _ records: [FinanceHistoricalRecord],
        id: String = "synthetic-source-archive",
        revision: String = "synthetic-revision"
    ) throws -> FinanceHistoryDocument {
        let first = try #require(records.map(\.date).min())
        let last = try #require(records.map(\.date).max())
        let payload = FinanceHistoryPayload(
            archiveCutoff: Day(year: 2026, month: 8, day: 19),
            recordCount: records.count,
            dateRange: FinanceHistoryDateRange(start: first, end: last),
            accounts: [
                FinanceHistoryAccount(id: "bnp", name: "BNP", provider: "bnp_statement")
            ],
            records: records
        )
        return try FinanceHistoryInterchange.make(
            archiveID: id, sourceRevision: revision, payload: payload
        )
    }

    /// A context does not keep its container alive, so the two travel together
    /// and a test holds this value for as long as it queries.
    private struct Installation {
        let container: ModelContainer
        let queries: HistoryArchiveQueries
    }

    private func installed() throws -> Installation {
        let container = try container()
        let context = container.mainContext
        _ = try HistoryArchivePersistence.replace(
            with: try document(chains()),
            in: context,
            importedAt: Date(timeIntervalSince1970: 1)
        )
        return Installation(
            container: container, queries: HistoryArchiveQueries(context: context)
        )
    }

    private func parentalQuery() -> HistoryQuery {
        var query = HistoryQuery()
        query.economicSourceIDs = [Self.parentalSupport]
        return query
    }

    @Test("Support paid directly by a parent is found under parental support")
    func directParentSupport() throws {
        let installation = try installed()
        let queries = installation.queries
        let matched = try queries.page(matching: parentalQuery()).transactions
        #expect(matched.contains { $0.id == "direct-parent" })
    }

    @Test("Support routed through a sibling is found under parental support")
    func supportRoutedThroughSibling() throws {
        let installation = try installed()
        let queries = installation.queries
        let matched = try queries.page(matching: parentalQuery()).transactions
        let routed = try #require(matched.first { $0.id == "routed-via-sibling" })
        // The bank counterparty is the sibling and the parents are nowhere in
        // the rail text; the economic source is what carries the row in.
        #expect(routed.merchantOrCounterparty == "SHARED HOUSEHOLD")
        #expect(routed.economicSource == Self.parentalSupport)
    }

    @Test("A sibling reimbursement is not parental support")
    func siblingReimbursementExcluded() throws {
        let installation = try installed()
        let queries = installation.queries
        let matched = try queries.page(matching: parentalQuery()).transactions
        #expect(!matched.contains { $0.id == "sibling-reimbursement" })

        var reimbursements = HistoryQuery()
        reimbursements.economicSourceIDs = [Self.reimbursement]
        #expect(
            try queries.page(matching: reimbursements).transactions.map(\.id)
                == ["sibling-reimbursement"]
        )
    }

    @Test("An arrival the reconstruction left unresolved stays unresolved")
    func unresolvedStaysUnresolved() throws {
        let installation = try installed()
        let queries = installation.queries
        let matched = try queries.page(matching: parentalQuery()).transactions
        #expect(!matched.contains { $0.id == "sibling-unresolved" })
    }

    @Test("A split arrival contributes only the self-owned share")
    func splitArrivalCountsOwnShareOnly() throws {
        let installation = try installed()
        let queries = installation.queries
        let matched = try queries.page(matching: parentalQuery()).transactions
        let split = try #require(matched.first { $0.id == "split-arrival" })
        #expect(split.amount.minorUnits == 280_000)
        #expect(split.personalAmount?.minorUnits == 140_000)

        let support = matched.reduce(into: Int64(0)) { total, row in
            total += row.personalAmount?.minorUnits ?? row.amount.minorUnits
        }
        // 700.00 direct + 1,200.00 routed + 1,400.00 own half of 2,800.00.
        #expect(support == 330_000)
    }

    @Test("The onward pass-through leg is never counted as support")
    func onwardLegNotSupport() throws {
        let installation = try installed()
        let queries = installation.queries
        let matched = try queries.page(matching: parentalQuery()).transactions
        #expect(!matched.contains { $0.id == "onward-leg" })

        let detail = try #require(try queries.detail(id: "onward-leg"))
        #expect(detail.economicSource == nil)
        #expect(detail.personalAmount?.minorUnits == 0)
        #expect(detail.passThrough == "full")
    }

    @Test("The raw counterparty does not control the economic-source filter")
    func counterpartyDoesNotControlFilter() throws {
        let installation = try installed()
        let queries = installation.queries
        let matched = try queries.page(matching: parentalQuery()).transactions
        let siblingFronted = matched.filter { $0.merchantOrCounterparty == "SHARED HOUSEHOLD" }
        // The same printed counterparty appears on rows that are support, on a
        // reimbursement, and on an unresolved transfer. Only the classified
        // one is here.
        #expect(siblingFronted.map(\.id) == ["routed-via-sibling"])
        #expect(matched.allSatisfy { $0.economicSource == Self.parentalSupport })
    }

    @Test("Economic source composes with date, account, amount and text")
    func composesWithEveryOtherFilter() throws {
        let installation = try installed()
        let queries = installation.queries
        var query = parentalQuery()
        let window2026 = CalendarDay(year: 2026, month: 1, day: 1)
        query.dateRange = window2026...CalendarDay(year: 2026, month: 8, day: 19)
        query.accountIDs = ["bnp"]
        query.minimumAmountMinor = 100_000
        query.maximumAmountMinor = 200_000
        query.currencies = ["EUR"]
        query.amountFractionDigits = 2
        query.searchText = "sibling"
        #expect(try queries.page(matching: query).transactions.map(\.id) == ["routed-via-sibling"])

        // Every other constraint held constant, dropping the source dimension
        // drags the sibling's onward pass-through leg back in. That is the
        // whole point: date, account, amount and text cannot separate money
        // that was support from money that was only passing through.
        var withoutSource = query
        withoutSource.economicSourceIDs = []
        #expect(
            try queries.page(matching: withoutSource).transactions.map(\.id)
                == ["routed-via-sibling", "onward-leg"]
        )

        var wrongWindow = query
        let window2025 = CalendarDay(year: 2025, month: 1, day: 1)
        wrongWindow.dateRange = window2025...CalendarDay(year: 2025, month: 12, day: 31)
        #expect(try queries.page(matching: wrongWindow).transactions.isEmpty)
    }

    @Test("Export and import preserve the economic source verbatim")
    func roundTripPreservesSource() throws {
        let encoded = try FinanceHistoryInterchange.encode(document(chains()))
        let decoded = try FinanceHistoryInterchange.decode(encoded)
        let sources = Dictionary(
            decoded.payload.records.map { ($0.historicalID, $0.economicSource) },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(sources["routed-via-sibling"] == Self.parentalSupport)
        #expect(sources["sibling-reimbursement"] == Self.reimbursement)
        // Present in the archive, and stating no economic source at all.
        #expect(sources["onward-leg"] == .some(nil))

        let container = try container()
        _ = try HistoryArchivePersistence.replace(
            with: decoded, in: container.mainContext, importedAt: Date(timeIntervalSince1970: 1)
        )
        let queries = HistoryArchiveQueries(context: container.mainContext)
        #expect(
            try queries.page(matching: parentalQuery()).transactions.count == 3
        )
        let catalog = try queries.filterCatalog()
        #expect(catalog.economicSources.map(\.id).sorted()
                == [Self.parentalSupport, Self.reimbursement, Self.unresolved].sorted())
        #expect(
            catalog.economicSources.first { $0.id == Self.parentalSupport }?.name
                == "Parental support"
        )
    }

    @Test("Re-importing the same archive stays idempotent")
    func reimportIsIdempotent() throws {
        let container = try container()
        let context = container.mainContext
        let archive = try document(chains())
        let first = try HistoryArchivePersistence.replace(
            with: archive, in: context, importedAt: Date(timeIntervalSince1970: 1)
        )
        guard case .imported = first else {
            Issue.record("first install should import")
            return
        }
        let second = try HistoryArchivePersistence.replace(
            with: archive, in: context, importedAt: Date(timeIntervalSince1970: 2)
        )
        guard case .unchanged = second else {
            Issue.record("identical archive should be unchanged")
            return
        }
        let queries = HistoryArchiveQueries(context: context)
        #expect(try context.fetchCount(FetchDescriptor<StoredHistoricalTransaction>()) == 6)
        #expect(try queries.page(matching: parentalQuery()).transactions.count == 3)
    }

    @Test("An archive written before economic source existed still imports")
    func olderSchemaRemainsReadable() throws {
        var legacy = try document(chains())
        legacy.schemaVersion = "1.0.0"
        for index in legacy.payload.records.indices {
            legacy.payload.records[index].economicSource = nil
        }
        // Version and body are atomic, so a 1.0.0 archive must be hashed and
        // encoded as 1.0.0 — not relabelled after the fact.
        legacy.contentSHA256 = try FinanceHistoryInterchange.contentSHA256(
            for: legacy.payload, schemaVersion: legacy.schemaVersion
        )
        let encoded = try FinanceHistoryInterchange.encoder(for: legacy.schemaVersion)
            .encode(legacy)

        let decoded = try FinanceHistoryInterchange.decode(encoded)
        #expect(decoded.schemaVersion == "1.0.0")
        #expect(decoded.payload.records.allSatisfy { $0.economicSource == nil })

        let container = try container()
        _ = try HistoryArchivePersistence.replace(
            with: decoded, in: container.mainContext, importedAt: Date(timeIntervalSince1970: 1)
        )
        let queries = HistoryArchiveQueries(context: container.mainContext)
        #expect(try queries.filterCatalog().economicSources.isEmpty)
        // Nothing claims to be support when the archive states no source.
        #expect(try queries.page(matching: parentalQuery()).transactions.isEmpty)
        #expect(try queries.page().transactions.count == 6)
    }

    @Test("A live income source carries the same economic source across the cutoff")
    func liveIncomeSourceBridge() {
        for (id, label) in [
            ("inc-parents-september-support", "Parental support — September (received)"),
            ("inc-parents-october-support", "Parental support — own share (October, economic)"),
            ("inc-parents-future", "Parental support (after October)"),
            // Renaming a source in the app must not drop its history out of
            // the filter: the id still names the same economic source.
            ("inc-parents-september-support", "Mum and dad"),
            ("income-parents", "Parents"),
        ] {
            #expect(
                HistoryEconomicSource.matchesLive(
                    incomeSourceID: id, incomeSourceLabel: label,
                    selection: [Self.parentalSupport]
                ),
                "\(id) / \(label) should be parental support"
            )
        }
    }

    @Test("Only an income source can put a live row under parental support")
    func liveRowsWithoutAnIncomeSourceNeverMatch() {
        // The wording is deliberately the most tempting possible. None of it
        // is the source dimension, so none of it counts.
        #expect(
            !HistoryEconomicSource.matchesLive(
                incomeSourceID: nil,
                incomeSourceLabel: "Parental support",
                selection: [Self.parentalSupport]
            )
        )
        for (id, label) in [
            ("inc-internship", "Internship gratification"),
            ("inc-student-job", "Student job at SMIC"),
            // A sibling reimbursement is not support, whoever sent the money.
            ("inc-sibling-reimbursement", "Co-resident — shared expense reimbursement"),
            // Whole-word matching: a grandparent stream is not this one.
            ("inc-grandparents-gift", "Grandparents gift"),
        ] {
            #expect(
                !HistoryEconomicSource.matchesLive(
                    incomeSourceID: id, incomeSourceLabel: label,
                    selection: [Self.parentalSupport]
                ),
                "\(id) / \(label) should not be parental support"
            )
        }
    }

    @Test("Archive and live agree on what parental support means")
    func archiveAndLiveAgreeOnTheSourceDimension() throws {
        let installation = try installed()
        let queries = installation.queries
        let selection: Set<String> = [Self.parentalSupport]

        // Archive side: classification decides, counterparty does not.
        let matched = try queries.page(matching: parentalQuery()).transactions
        #expect(Set(matched.map(\.id)) == ["direct-parent", "routed-via-sibling", "split-arrival"])

        // Live side: the income source decides, and the same selection admits
        // exactly the rows the archive side would have admitted — support
        // whoever handed it over, and nothing that merely reads like support.
        let liveCases: [(id: String?, label: String?, isSupport: Bool)] = [
            ("inc-parents-september-support", "Parental support — September (received)", true),
            ("income-parents", "Parents", true),
            ("inc-sibling-reimbursement", "Co-resident — shared expense reimbursement", false),
            (nil, "Parental support via Co-resident", false),
        ]
        for row in liveCases {
            #expect(
                HistoryEconomicSource.matchesLive(
                    incomeSourceID: row.id, incomeSourceLabel: row.label, selection: selection
                ) == row.isSupport,
                "\(row.id ?? "no source") / \(row.label ?? "")"
            )
        }

        // And an unrelated selection admits neither side.
        #expect(
            !HistoryEconomicSource.matchesLive(
                incomeSourceID: "inc-parents-september-support",
                incomeSourceLabel: "Parental support — September (received)",
                selection: [Self.reimbursement]
            )
        )
        var reimbursementOnly = HistoryQuery()
        reimbursementOnly.economicSourceIDs = [Self.reimbursement]
        #expect(
            try queries.page(matching: reimbursementOnly).transactions.map(\.id)
                == ["sibling-reimbursement"]
        )
    }

    @Test("Adding the source dimension leaves the operational document alone")
    func operationalIsolation() throws {
        let container = try container()
        let context = container.mainContext
        let operational = try FinanceStore.developmentFixture()
        try StoredDocumentGraph.replace(
            with: operational, in: context, writtenOn: Day(year: 2026, month: 9, day: 1)
        )
        let before = try FinanceStore(
            context: context, now: fixtureInstant(Day(year: 2026, month: 9, day: 1))
        ).snapshot

        let service = HistoryArchiveService(context: context)
        _ = try service.prepareImport(data: FinanceHistoryInterchange.encode(document(chains())))
        _ = try service.confirmImport()

        let after = try FinanceStore(
            context: context, now: fixtureInstant(Day(year: 2026, month: 9, day: 1))
        ).snapshot
        #expect(try StoredDocumentGraph.load(from: context) == operational)
        #expect(after.accountCash == before.accountCash)
        #expect(after.safeToSpend == before.safeToSpend)
        #expect(after.currentMonth == before.currentMonth)
    }
}

private extension JSONEncoder {
}

/// What happens when support that is only *planned* today is eventually
/// recorded as money that actually arrived.
///
/// The September chain lives in `expectedTransactions`, which never enter
/// Activity. The question these ask is the one that matters when it does
/// arrive: does the recorded transaction still say it was parental support?
@MainActor
@Suite("Recording planned parental support")
struct RecordedParentalSupportTests {

    private func document() -> FinanceDocument {
        EntryFixtures.document()
    }

    @Test("Income cannot be recorded without naming its source at all")
    func incomeSourceIsStructurallyRequired() throws {
        let harness = try EntryFixtures.Harness()
        var draft = EntryFixtures.draft(kind: .income, amount: .eur(1_100))
        draft.incomeSourceID = nil
        #expect(throws: AppEntryError.missingIncomeSource) { try harness.store.add(draft) }
    }

    @Test("A recorded parental arrival keeps its parental income source")
    func wholeArrivalKeepsItsSource() throws {
        let harness = try EntryFixtures.Harness()
        try harness.store.add(
            EntryFixtures.draft(
                kind: .income, amount: .eur(1_100),
                incomeSourceID: EntryFixtures.parents.id, merchant: "Family transfer"
            )
        )
        let row = try #require(
            harness.store.snapshot.activity.flatMap(\.rows)
                .first { $0.title == "Family transfer" }
        )
        #expect(row.incomeSourceID == EntryFixtures.parents.id)
        #expect(
            HistoryEconomicSource.matchesLive(
                incomeSourceID: row.incomeSourceID,
                incomeSourceLabel: row.incomeSourceLabel,
                selection: [HistoryEconomicSource.parentalSupport]
            )
        )
    }

    @Test("A part-owned arrival keeps its source and states only the own share")
    func splitArrivalKeepsItsSource() throws {
        let harness = try EntryFixtures.Harness()
        // The shape of the planned 2026-09-16 chain: EUR 1,000 arrives and
        // EUR 800 of it is the sibling's.
        try harness.store.add(
            EntryFixtures.draft(
                kind: .income, amount: .eur(1_000),
                incomeSourceID: EntryFixtures.parents.id,
                ownShare: .eur(800), merchant: "Family transfer"
            )
        )
        let row = try #require(
            harness.store.snapshot.activity.flatMap(\.rows)
                .first { $0.title == "Family transfer" }
        )
        // Becoming a pass-through must not drop the source: without it the
        // arrival would be findable only by the words somebody typed.
        #expect(row.incomeSourceID == EntryFixtures.parents.id)
        #expect(row.ownedPortion == .eur(800))
        #expect(row.amount.magnitude == .eur(1_000))
        #expect(
            HistoryEconomicSource.matchesLive(
                incomeSourceID: row.incomeSourceID,
                incomeSourceLabel: row.incomeSourceLabel,
                selection: [HistoryEconomicSource.parentalSupport]
            )
        )
    }

    @Test("A zero-amount received stream is named but economically silent")
    func zeroAmountStreamNeverForecasts() throws {
        // `EntryFixtures.parents` is exactly the shape the current-state export
        // uses for support that has already arrived: named, `received`, and
        // 0.00 so the engine cannot forecast one real arrival a second time.
        #expect(EntryFixtures.parents.amount.minorUnits == 0)
        #expect(EntryFixtures.parents.certainty == .received)

        let before = try EntryFixtures.Harness()
        let baseline = before.store.snapshot

        var withStream = EntryFixtures.document()
        withStream.incomeSources.append(
            IncomeSource(
                id: "inc-parents-september-support",
                name: "Parental support — September (received)",
                amount: Money(minorUnits: 0, currency: .eur),
                certainty: .received,
                schedule: .oneShot(on: Day(year: 2026, month: 8, day: 18)),
                arrivesOnAccount: EntryFixtures.bank.id
            )
        )
        let after = try EntryFixtures.Harness(withStream).store.snapshot

        #expect(after.accountCash == baseline.accountCash)
        #expect(after.safeToSpend == baseline.safeToSpend)
        #expect(after.rawShortfall == baseline.rawShortfall)
        #expect(after.currentMonth == baseline.currentMonth)
        #expect(after.runwayPoints == baseline.runwayPoints)
        #expect(after.upcomingEvents == baseline.upcomingEvents)
        // Named and visible, though — that is the whole point of tracking it.
        #expect(after.incomeSources.count == baseline.incomeSources.count + 1)
    }
}
