import Foundation

/// Product-facing description of an archive before it is written.
///
/// This intentionally contains no file bytes or FinanceCore types. The file
/// picker can discard the private source data after validation while the UI
/// keeps only the counts a person needs to confirm the import.
struct HistoryImportPreview: Hashable, Sendable {
    let archiveID: String
    let schemaVersion: String
    let transactionCount: Int
    let dateRange: ClosedRange<CalendarDay>
    let archiveCutoff: CalendarDay
    let accounts: [HistoryFilterOption]
    let currencies: [String]
    let sourceCoverageGapCount: Int
    let replacesExistingArchive: Bool
}

struct HistoryArchiveMetadata: Hashable, Sendable {
    let archiveID: String
    let schemaVersion: String
    let sourceRevision: String
    let contentSHA256: String
    let transactionCount: Int
    let dateRange: ClosedRange<CalendarDay>
    let archiveCutoff: CalendarDay
    let importedAt: Date
}

enum HistoryImportOutcome: Hashable, Sendable {
    /// The exact archive id and content digest were already installed.
    case unchanged(HistoryArchiveMetadata)
    /// A previous archive, if any, was atomically replaced.
    case imported(HistoryArchiveMetadata)
}

/// A stable value/label pair used by account, category, type and source
/// filters. Values, rather than labels, are persisted in a query selection.
struct HistoryFilterOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    var fractionDigits: Int? = nil
}

enum HistorySort: String, CaseIterable, Hashable, Sendable {
    case newestFirst
    case oldestFirst
    case amountHighToLow
    case amountLowToHigh
}

/// All filters compose with AND semantics. Multiple values inside one filter
/// compose with OR semantics (for example BNP *or* PayPal, both in 2025).
struct HistoryQuery: Hashable, Sendable {
    var searchText = ""
    var dateRange: ClosedRange<CalendarDay>?
    var accountIDs: Set<String> = []
    var categoryIDs: Set<String> = []
    var economicTypes: Set<String> = []
    /// Canonical economic source: where the money came from economically.
    /// This is deliberately not the category, the merchant, the counterparty,
    /// or the display description — support routed through a family
    /// intermediary belongs here under the parents, not under the sibling
    /// whose name the bank printed.
    var economicSourceIDs: Set<String> = []
    /// Magnitudes in minor units. The sign of an expense or refund is not part
    /// of the range a person types into the amount filter.
    var minimumAmountMinor: Int64?
    var maximumAmountMinor: Int64?
    /// Scale of the sole selected currency when filtering or sorting amounts.
    var amountFractionDigits: Int?
    var currencies: Set<String> = []
    var sourceIDs: Set<String> = []
    /// Advanced evidence filters. Kept out of the primary filter surface.
    var statuses: Set<String> = []
    var provenanceValues: Set<String> = []
    var sort: HistorySort = .newestFirst

    init() {}
}

struct HistoryTransactionSummary: Identifiable, Hashable, Sendable {
    let id: String
    let date: CalendarDay
    let amount: Amount
    /// The share that was economically the owner's. A €1,000 arrival owed
    /// €600 onward is €400 of support, and a total built from `amount` would
    /// claim otherwise. `nil` when the archive states no ownership split.
    let personalAmount: Amount?
    let accountID: String
    let accountName: String
    let merchantOrCounterparty: String?
    let displayDescription: String
    let categoryID: String
    let categoryName: String
    let economicType: String
    let economicSource: String?
    let sourceID: String
    let sourceName: String
    let status: String
}

struct HistoryEvidenceDetail: Hashable, Sendable {
    let source: String
    let provenance: String
    let confidence: String
    let originalDescription: String?
    let ruleID: String
    let basis: String
    let unresolvedReason: String?
    let linkedTransactionID: String?
    let groupID: String?
}

struct HistoryTransactionDetail: Identifiable, Hashable, Sendable {
    let id: String
    let date: CalendarDay
    let amount: Amount
    let accountID: String
    let accountName: String
    let merchant: String?
    let counterparty: String?
    let displayDescription: String
    let categoryID: String
    let categoryName: String
    let economicType: String
    let economicSource: String?
    let personalAmount: Amount?
    let passThrough: String
    let status: String
    let evidence: HistoryEvidenceDetail
}

struct HistorySourceGap: Identifiable, Hashable, Sendable {
    let id: String
    let dateRange: ClosedRange<CalendarDay>
    let accountID: String?
    let sourceID: String?
    /// Safe, curated explanation from the archive. Never a raw provider row.
    let message: String
}

struct HistoryPage: Hashable, Sendable {
    let transactions: [HistoryTransactionSummary]
    let nextOffset: Int?
    let coverageGaps: [HistorySourceGap]
}

struct HistoryFilterCatalog: Hashable, Sendable {
    let accounts: [HistoryFilterOption]
    let categories: [HistoryFilterOption]
    let economicTypes: [HistoryFilterOption]
    let economicSources: [HistoryFilterOption]
    let currencies: [HistoryFilterOption]
    let sources: [HistoryFilterOption]
    let statuses: [HistoryFilterOption]
    let provenanceValues: [HistoryFilterOption]

    static let empty = HistoryFilterCatalog(
        accounts: [], categories: [], economicTypes: [], economicSources: [],
        currencies: [], sources: [], statuses: [], provenanceValues: []
    )
}

/// One explicit boundary joins the read-only archive to live activity without
/// guessing from amounts or merchant text. The archive owns the cutoff day;
/// the live timeline begins on the following day.
enum HistoryArchiveBoundary {
    static func includesArchiveDate(_ date: CalendarDay, cutoff: CalendarDay) -> Bool {
        date <= cutoff
    }

    static func includesLiveDate(_ date: CalendarDay, cutoff: CalendarDay) -> Bool {
        date > cutoff
    }
}

/// Presentation and cross-boundary meaning of the canonical economic-source
/// vocabulary.
///
/// The archive stores canonical tokens verbatim so the reconstruction stays
/// the authority on classification. Only the label a person reads lives here.
enum HistoryEconomicSource {
    /// Canonical token this audit cares about, named once instead of spelled
    /// out at each call site.
    static let parentalSupport = "PARENTAL_SUPPORT_SELF"

    private struct Meaning {
        let name: String
        /// Whole-word tokens that name the same economic source on the live
        /// side. The live ledger has no canonical economic source, only an
        /// income source, and these are the sole bridge between those two
        /// source dimensions.
        ///
        /// They are matched against an income source's own **id and name**
        /// and nothing else. A merchant, a counterparty, a note or a
        /// description can never pull a row in, and a row carrying no income
        /// source at all can never match however it is worded. Matching the
        /// id as well as the name means renaming a source in the app does not
        /// silently drop its history out of the filter.
        let liveIncomeSourceTokens: [String]
    }

    /// Entries exist only where a live income source has been confirmed to
    /// describe the same economic source. Anything absent falls back to the
    /// generic token rendering and matches no live row, which is the honest
    /// answer rather than a guess from a similar-looking name.
    private static let vocabulary: [String: Meaning] = [
        parentalSupport: Meaning(
            name: "Parental support", liveIncomeSourceTokens: ["parents", "parental support"]
        ),
        "PARENTAL_SUPPORT_OTHER_PERSON_PASSTHROUGH": Meaning(
            name: "Parental support (pass-through)", liveIncomeSourceTokens: []
        ),
        "PARTNER_SUPPORT": Meaning(name: "Partner support", liveIncomeSourceTokens: []),
        "SHARED_EXPENSE_REIMBURSEMENT": Meaning(
            name: "Shared expense reimbursement", liveIncomeSourceTokens: []
        ),
        "OTHER_REIMBURSEMENT": Meaning(name: "Reimbursement", liveIncomeSourceTokens: []),
        "UNRESOLVED_INCOMING": Meaning(name: "Unresolved incoming", liveIncomeSourceTokens: []),
        "OTHER_ECONOMIC_RESOURCE": Meaning(name: "Other resource", liveIncomeSourceTokens: []),
    ]

    static func displayName(for id: String) -> String {
        vocabulary[id]?.name ?? id.replacingOccurrences(of: "_", with: " ").lowercased().capitalized
    }

    static func option(for id: String) -> HistoryFilterOption {
        HistoryFilterOption(id: id, name: displayName(for: id))
    }

    /// The canonical economic source a live income stream names, if any.
    ///
    /// Same rule as `matchesLive`, asked the other way round: a stream
    /// qualifies through its own id and name, never through a merchant,
    /// counterparty, note or description. A stream matching no entry returns
    /// nil, which leaves its inflows unresolved rather than guessed.
    static func canonicalSource(
        forLiveIncomeSourceID id: String,
        name: String?
    ) -> String? {
        vocabulary.keys.sorted().first { token in
            matchesLive(
                incomeSourceID: id, incomeSourceLabel: name, selection: [token]
            )
        }
    }

    /// Whether a live row belongs to one of the selected economic sources.
    ///
    /// A live row qualifies only through its own income source. That keeps the
    /// filter on the source dimension across the archive/live boundary instead
    /// of falling back to whatever text the rail happened to print.
    static func matchesLive(
        incomeSourceID: String?,
        incomeSourceLabel: String?,
        selection: Set<String>
    ) -> Bool {
        guard let incomeSourceID else { return false }
        // Padded so tokens match whole words: "grandparents" is not "parents".
        let haystack = " \(HistorySearchNormalizer.normalize(incomeSourceID)) "
            + "\(HistorySearchNormalizer.normalize(incomeSourceLabel ?? "")) "
        return selection.contains { id in
            guard let meaning = vocabulary[id] else { return false }
            return meaning.liveIncomeSourceTokens.contains { haystack.contains(" \($0) ") }
        }
    }
}
