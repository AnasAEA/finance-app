import Foundation
import FinanceCore

/// A small, entirely synthetic history archive.
///
/// Shared by the suites that need *an* archive rather than a particular one.
/// Nothing here is anybody's data: the merchant, the account names, the rule
/// ids and the amounts are invented for the tests, and a real archive is never
/// checked in, copied into Resources, or referenced from a test.
enum HistoryArchiveFixture {

    static let archiveID = "synthetic-shared-archive"
    static let cutoff = Day(year: 2026, month: 8, day: 19)
    static let recordCount = 4

    static func record(
        id: String,
        day: Day,
        accountID: String = "acct-a",
        provider: String = "provider_a",
        amount: Int64 = -1_000,
        currency: String = "EUR",
        categoryTop: String = "essential",
        categorySub: String? = "groceries",
        type: String = "expense"
    ) -> FinanceHistoricalRecord {
        FinanceHistoricalRecord(
            historicalID: id,
            date: day,
            accountID: accountID,
            provider: provider,
            rail: "card",
            merchant: "Synthetic Merchant",
            description: "Synthetic transaction",
            rawDescription: "SAFE SYNTHETIC RAW",
            originalAmount: FinanceHistoryOriginalAmount(cents: amount, currency: currency),
            bookedAmountEURCents: currency == "EUR" ? amount : nil,
            economicAmountEURCents: currency == "EUR" ? amount : nil,
            personalAmountEURCents: currency == "EUR" ? amount : nil,
            category: FinanceHistoryCategory(top: categoryTop, sub: categorySub),
            economicType: type,
            status: "booked",
            provenance: "canonical",
            confidence: "high",
            economicViewRole: "personal",
            evidence: FinanceHistoryEvidence(
                ruleID: "synthetic.rule", basis: "Synthetic test evidence"
            )
        )
    }

    /// Four rows across two accounts, all on or before the cutoff, with one
    /// declared coverage gap.
    static func document() throws -> FinanceHistoryDocument {
        let records = [
            record(id: "h-1", day: Day(year: 2024, month: 3, day: 4), amount: -2_450),
            record(id: "h-2", day: Day(year: 2025, month: 7, day: 19), amount: -1_299),
            record(
                id: "h-3", day: Day(year: 2026, month: 2, day: 2),
                accountID: "acct-b", provider: "provider_b", amount: -899
            ),
            record(id: "h-4", day: cutoff, amount: -4_500, categorySub: "household"),
        ]
        let payload = FinanceHistoryPayload(
            archiveCutoff: cutoff,
            recordCount: records.count,
            dateRange: FinanceHistoryDateRange(
                start: Day(year: 2024, month: 3, day: 4), end: cutoff
            ),
            accounts: [
                FinanceHistoryAccount(id: "acct-a", name: "Synthetic A", provider: "provider_a"),
                FinanceHistoryAccount(id: "acct-b", name: "Synthetic B", provider: "provider_b"),
            ],
            sourceGaps: [
                FinanceHistorySourceGap(
                    startMonth: MonthKey(year: 2024, month: 9),
                    endMonth: MonthKey(year: 2024, month: 11),
                    completeness: "PARTIAL",
                    affectedSources: ["provider_a"],
                    message: "Records for part of this period are incomplete."
                )
            ],
            records: records
        )
        return try FinanceHistoryInterchange.make(
            archiveID: archiveID, sourceRevision: "synthetic-revision", payload: payload
        )
    }

    static func data() throws -> Data {
        try FinanceHistoryInterchange.encode(document())
    }
}
