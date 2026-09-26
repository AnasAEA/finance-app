import Foundation
import SwiftData
import FinanceCore

enum HistoryArchiveQueryError: Error, Equatable, CustomStringConvertible {
    case invalidPage(offset: Int, limit: Int)
    case invalidDate(Int32)
    case unrepresentableQueryRange
    case invalidAmountRange
    case amountCurrencyRequired

    var description: String {
        switch self {
        case let .invalidPage(offset, limit):
            "invalid history page (offset: \(offset), limit: \(limit))"
        case let .invalidDate(value):
            "stored history date \(value) is invalid"
        case .unrepresentableQueryRange:
            "the requested history date range cannot be stored"
        case .invalidAmountRange:
            "minimum history amount is greater than maximum"
        case .amountCurrencyRequired:
            "amount filtering and sorting require exactly one currency"
        }
    }
}

/// Indexed, paged reads over the archive graph. No method in this type fetches
/// or mutates operational FinanceDocument rows.
@MainActor
final class HistoryArchiveQueries {
    private let context: ModelContext?

    init(context: ModelContext?) {
        self.context = context
    }

    var hasImportedArchive: Bool {
        get throws {
            guard let context else { return false }
            var descriptor = FetchDescriptor<StoredHistoryArchive>()
            descriptor.fetchLimit = 1
            return try !context.fetch(descriptor).isEmpty
        }
    }

    func metadata() throws -> HistoryArchiveMetadata? {
        guard let context, let archive = try currentArchive(in: context) else { return nil }
        return try HistoryArchivePersistence.metadata(archive)
    }

    func page(
        matching query: HistoryQuery = HistoryQuery(),
        offset: Int = 0,
        limit: Int = 100
    ) throws -> HistoryPage {
        guard offset >= 0, limit > 0, limit <= 500 else {
            throw HistoryArchiveQueryError.invalidPage(offset: offset, limit: limit)
        }
        guard let context, let archive = try currentArchive(in: context) else {
            return HistoryPage(transactions: [], nextOffset: nil, coverageGaps: [])
        }
        if let minimum = query.minimumAmountMinor,
           let maximum = query.maximumAmountMinor,
           minimum > maximum {
            throw HistoryArchiveQueryError.invalidAmountRange
        }
        let comparesAmounts = query.minimumAmountMinor != nil || query.maximumAmountMinor != nil
            || query.sort == .amountHighToLow || query.sort == .amountLowToHigh
        if comparesAmounts && (query.currencies.count != 1 || query.amountFractionDigits == nil) {
            throw HistoryArchiveQueryError.amountCurrencyRequired
        }

        let archiveID = archive.identifier
        let fromDay = try query.dateRange.map { try ordinal($0.lowerBound) } ?? Int32.min
        let throughDay = try query.dateRange.map { try ordinal($0.upperBound) } ?? Int32.max
        let normalizedText = HistorySearchNormalizer.normalize(query.searchText)
        let minimumAmount = query.minimumAmountMinor ?? 0
        let maximumAmount = query.maximumAmountMinor ?? Int64.max
        let singleCurrency = query.currencies.count == 1 ? (query.currencies.first ?? "") : ""
        let amountDigits = query.amountFractionDigits ?? -1

        // Keep the SQL-facing predicate deliberately small. SwiftData's
        // Predicate macro cannot type-check one expression containing seven
        // captured Set/Array membership clauses in a reasonable amount of
        // time, and fetching the entire archive to work around that would put
        // thousands of rows in memory on every search keystroke. The indexed
        // range/text constraints run in the store; the remaining exact-token
        // filters are applied while scanning bounded pages below.
        let predicate = #Predicate<StoredHistoricalTransaction> { row in
            row.archiveIdentifier == archiveID
                && row.valueDay >= fromDay
                && row.valueDay <= throughDay
                && row.absoluteAmountMinor >= minimumAmount
                && row.absoluteAmountMinor <= maximumAmount
                && (!comparesAmounts || row.currencyExponent == amountDigits)
                && (singleCurrency.isEmpty || row.currencyCode == singleCurrency)
                && (normalizedText.isEmpty || row.normalizedSearchText.contains(normalizedText))
        }

        // When SQL contains every active filter, ask the store for precisely
        // this page. Secondary token filters still need bounded scanning.
        let hasSecondaryFilters = !query.accountIDs.isEmpty || !query.categoryIDs.isEmpty
            || !query.economicTypes.isEmpty || !query.economicSourceIDs.isEmpty
            || query.currencies.count > 1 || !query.sourceIDs.isEmpty
            || !query.statuses.isEmpty || !query.provenanceValues.isEmpty
        let batchSize = hasSecondaryFilters ? min(250, max(80, limit * 2)) : limit + 1
        var storageOffset = hasSecondaryFilters ? 0 : offset
        var matchedOffset = hasSecondaryFilters ? 0 : offset
        var selected: [StoredHistoricalTransaction] = []
        var exhausted = false
        while selected.count < limit + 1, !exhausted {
            var descriptor = FetchDescriptor<StoredHistoricalTransaction>(
                predicate: predicate,
                sortBy: sortDescriptors(for: query.sort)
            )
            descriptor.fetchOffset = storageOffset
            descriptor.fetchLimit = batchSize
            let batch = try context.fetch(descriptor)
            exhausted = batch.count < batchSize
            storageOffset += batch.count

            for row in batch where matchesSecondaryFilters(row, query: query) {
                if matchedOffset < offset {
                    matchedOffset += 1
                    continue
                }
                selected.append(row)
                if selected.count == limit + 1 { break }
            }
        }

        let hasMore = selected.count > limit
        if hasMore { selected.removeLast(selected.count - limit) }

        return HistoryPage(
            transactions: try selected.map(summary),
            nextOffset: hasMore ? offset + limit : nil,
            coverageGaps: try gaps(
                archiveID: archiveID,
                fromDay: fromDay,
                throughDay: throughDay,
                accountIDs: query.accountIDs,
                sourceIDs: query.sourceIDs,
                in: context
            )
        )
    }

    private func matchesSecondaryFilters(
        _ row: StoredHistoricalTransaction,
        query: HistoryQuery
    ) -> Bool {
        (query.accountIDs.isEmpty || query.accountIDs.contains(row.accountIdentifier))
            && (query.categoryIDs.isEmpty || query.categoryIDs.contains(row.categoryIdentifier))
            && (query.economicTypes.isEmpty || query.economicTypes.contains(row.economicTypeRaw))
            && (
                query.economicSourceIDs.isEmpty
                    || row.economicSourceRaw.map(query.economicSourceIDs.contains) == true
            )
            && (query.currencies.isEmpty || query.currencies.contains(row.currencyCode))
            && (query.sourceIDs.isEmpty || query.sourceIDs.contains(row.sourceIdentifier))
            && (query.statuses.isEmpty || query.statuses.contains(row.statusRaw))
            && (query.provenanceValues.isEmpty || query.provenanceValues.contains(row.provenanceRaw))
    }

    func detail(id: String) throws -> HistoryTransactionDetail? {
        guard let context, let archive = try currentArchive(in: context) else { return nil }
        let archiveID = archive.identifier
        var descriptor = FetchDescriptor<StoredHistoricalTransaction>(
            predicate: #Predicate { $0.archiveIdentifier == archiveID && $0.identifier == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first.map(detail)
    }

    func filterCatalog() throws -> HistoryFilterCatalog {
        guard let context, let archive = try currentArchive(in: context) else { return .empty }
        let archiveID = archive.identifier
        func options(_ ids: [String], _ names: [String]) -> [HistoryFilterOption] {
            zip(ids, names).map { HistoryFilterOption(id: $0.0, name: $0.1) }
        }
        return HistoryFilterCatalog(
            accounts: options(archive.accountIdentifiers, archive.accountNames),
            categories: options(archive.categoryIdentifiers, archive.categoryNames),
            economicTypes: archive.economicTypes.map { HistoryFilterOption(id: $0, name: $0) },
            economicSources: archive.economicSources
                .map(HistoryEconomicSource.option)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            currencies: try archive.currencies.map { code in
                var descriptor = FetchDescriptor<StoredHistoricalTransaction>(
                    predicate: #Predicate { $0.archiveIdentifier == archiveID && $0.currencyCode == code }
                )
                descriptor.fetchLimit = 1
                let first = try context.fetch(descriptor).first?.currencyExponent
                let digits: Int?
                if let first {
                    var conflict = FetchDescriptor<StoredHistoricalTransaction>(
                        predicate: #Predicate {
                            $0.archiveIdentifier == archiveID
                                && $0.currencyCode == code
                                && $0.currencyExponent != first
                        }
                    )
                    conflict.fetchLimit = 1
                    digits = try context.fetch(conflict).isEmpty ? first : nil
                } else {
                    digits = nil
                }
                return HistoryFilterOption(
                    id: code, name: code, fractionDigits: digits
                )
            },
            sources: options(archive.sourceIdentifiers, archive.sourceNames),
            statuses: archive.statuses.map { HistoryFilterOption(id: $0, name: $0) },
            provenanceValues: archive.provenanceValues.map { HistoryFilterOption(id: $0, name: $0) }
        )
    }

    private func currentArchive(in context: ModelContext) throws -> StoredHistoryArchive? {
        var descriptor = FetchDescriptor<StoredHistoryArchive>(
            sortBy: [SortDescriptor(\.importedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func sortDescriptors(
        for sort: HistorySort
    ) -> [SortDescriptor<StoredHistoricalTransaction>] {
        switch sort {
        case .newestFirst:
            [SortDescriptor(\.valueDay, order: .reverse), SortDescriptor(\.identifier)]
        case .oldestFirst:
            [SortDescriptor(\.valueDay), SortDescriptor(\.identifier)]
        case .amountHighToLow:
            [SortDescriptor(\.absoluteAmountMinor, order: .reverse), SortDescriptor(\.valueDay, order: .reverse)]
        case .amountLowToHigh:
            [SortDescriptor(\.absoluteAmountMinor), SortDescriptor(\.valueDay, order: .reverse)]
        }
    }

    private func gaps(
        archiveID: String,
        fromDay: Int32,
        throughDay: Int32,
        accountIDs: Set<String>,
        sourceIDs: Set<String>,
        in context: ModelContext
    ) throws -> [HistorySourceGap] {
        let descriptor = FetchDescriptor<StoredHistorySourceGap>(
            predicate: #Predicate {
                $0.archiveIdentifier == archiveID
                    && $0.startDay <= throughDay
                    && $0.endDay >= fromDay
            },
            sortBy: [SortDescriptor(\.startDay)]
        )
        return try context.fetch(descriptor)
            .filter { row in
                (accountIDs.isEmpty || row.accountIdentifier.map(accountIDs.contains) != false)
                    && (
                        sourceIDs.isEmpty
                            || row.sourceIdentifier.map(sourceIDs.contains) == true
                            || !sourceIDs.isDisjoint(with: row.affectedSourceIdentifiers)
                    )
            }
            .map { row in
                HistorySourceGap(
                    id: row.identifier,
                    dateRange: try day(row.startDay)...day(row.endDay),
                    accountID: row.accountIdentifier,
                    sourceID: row.sourceIdentifier,
                    message: row.message
                )
            }
    }

    private func summary(_ row: StoredHistoricalTransaction) throws -> HistoryTransactionSummary {
        HistoryTransactionSummary(
            id: row.identifier,
            date: try day(row.valueDay),
            amount: Amount(
                minorUnits: row.amountMinor,
                currencyCode: row.currencyCode,
                fractionDigits: row.currencyExponent
            ),
            personalAmount: personalAmount(row),
            accountID: row.accountIdentifier,
            accountName: row.accountName,
            merchantOrCounterparty: row.merchant ?? row.counterparty,
            displayDescription: row.displayDescription,
            categoryID: row.categoryIdentifier,
            categoryName: row.categoryName,
            economicType: row.economicTypeRaw,
            economicSource: row.economicSourceRaw,
            sourceID: row.sourceIdentifier,
            sourceName: row.sourceName,
            status: row.statusRaw
        )
    }

    private func detail(_ row: StoredHistoricalTransaction) throws -> HistoryTransactionDetail {
        HistoryTransactionDetail(
            id: row.identifier,
            date: try day(row.valueDay),
            amount: Amount(
                minorUnits: row.amountMinor,
                currencyCode: row.currencyCode,
                fractionDigits: row.currencyExponent
            ),
            accountID: row.accountIdentifier,
            accountName: row.accountName,
            merchant: row.merchant,
            counterparty: row.counterparty,
            displayDescription: row.displayDescription,
            categoryID: row.categoryIdentifier,
            categoryName: row.categoryName,
            economicType: row.economicTypeRaw,
            economicSource: row.economicSourceRaw,
            personalAmount: personalAmount(row),
            passThrough: row.passThroughRaw,
            status: row.statusRaw,
            evidence: HistoryEvidenceDetail(
                source: row.sourceName,
                provenance: row.provenanceRaw,
                confidence: row.confidenceRaw,
                originalDescription: row.originalDescription,
                ruleID: row.evidenceRuleIdentifier,
                basis: row.evidenceBasis,
                unresolvedReason: row.evidenceUnresolvedReason,
                linkedTransactionID: row.linkedTransactionIdentifier,
                groupID: row.groupIdentifier
            )
        )
    }

    /// The self-owned share, surfaced only when part of the money was never
    /// the owner's. A €1,000 arrival owed €600 onward reports €400; a row the
    /// owner kept in full reports nothing extra and prints one figure.
    private func personalAmount(_ row: StoredHistoricalTransaction) -> Amount? {
        guard let personal = row.personalAmountEURMinor,
              let moved = row.economicAmountEURMinor ?? row.bookedAmountEURMinor,
              personal != moved else { return nil }
        return Amount(minorUnits: personal, currencyCode: "EUR", fractionDigits: 2)
    }

    private func ordinal(_ day: CalendarDay) throws -> Int32 {
        guard let value = Day(validatingYear: day.year, month: day.month, day: day.day)?
            .checkedPersistenceOrdinal
        else {
            throw HistoryArchiveQueryError.unrepresentableQueryRange
        }
        return value
    }

    private func day(_ storedOrdinal: Int32) throws -> CalendarDay {
        guard let day = Day(persistenceOrdinal: storedOrdinal) else {
            throw HistoryArchiveQueryError.invalidDate(storedOrdinal)
        }
        return CalendarDay(year: day.year, month: day.month, day: day.day)
    }
}
