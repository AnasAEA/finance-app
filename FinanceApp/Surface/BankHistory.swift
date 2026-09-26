import Foundation

/// A bank's account movement, available in history before its economic
/// meaning is decided. Browsing this row never creates a ledger transaction.
struct BankHistoryItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let accountID: String
    let accountName: String
    let providerID: String
    let providerName: String
    let amount: Amount
    let dates: ObservationDates
    let observedAt: Date
    let status: SyncedObservationStatus
    let resolution: SyncedObservationResolution
    let linkedTransactionID: String?

    var date: CalendarDay? { dates.economicPeriod }
    var subtitle: String {
        [providerName, accountName, status.displayName,
         resolution == .unreviewed ? "Needs review" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    func isVisible(cutoff: CalendarDay?, visibleTransactionIDs: Set<String>) -> Bool {
        if let cutoff, let date, !HistoryArchiveBoundary.includesLiveDate(date, cutoff: cutoff) {
            return false
        }
        // Only a persisted link establishes that the ledger already displays
        // this movement. Similar dates, amounts or names never hide a row.
        return linkedTransactionID.map { !visibleTransactionIDs.contains($0) } ?? true
    }

    func matches(_ query: HistoryQuery, catalog: HistoryFilterCatalog) -> Bool {
        if let range = query.dateRange, date.map(range.contains) != true { return false }
        let magnitude = amount.minorUnits == .min ? Int64.max : abs(amount.minorUnits)
        if let minimum = query.minimumAmountMinor, magnitude < minimum { return false }
        if let maximum = query.maximumAmountMinor, magnitude > maximum { return false }
        if (query.minimumAmountMinor != nil || query.maximumAmountMinor != nil
            || query.sort == .amountHighToLow || query.sort == .amountLowToHigh),
           amount.fractionDigits != query.amountFractionDigits { return false }
        if !query.currencies.isEmpty, !query.currencies.contains(amount.currencyCode) { return false }
        if !query.accountIDs.isEmpty {
            let names = catalog.accounts.filter { query.accountIDs.contains($0.id) }
                .map { HistorySearchNormalizer.normalize($0.name) }
            if !query.accountIDs.contains(accountID),
               !names.contains(HistorySearchNormalizer.normalize(accountName)) { return false }
        }
        if !query.sourceIDs.isEmpty {
            let names = catalog.sources.filter { query.sourceIDs.contains($0.id) }
                .map { HistorySearchNormalizer.normalize($0.name) }
            if !query.sourceIDs.contains(providerID),
               !names.contains(HistorySearchNormalizer.normalize(providerName)) { return false }
        }
        if !query.statuses.isEmpty, !query.statuses.contains(status.rawValue) { return false }
        if !query.provenanceValues.isEmpty, !query.provenanceValues.contains("bank_sync") { return false }
        // Unclassified provider movements do not acquire economic categories
        // or sources just by being shown alongside recorded transactions.
        if !query.categoryIDs.isEmpty || !query.economicTypes.isEmpty
            || !query.economicSourceIDs.isEmpty { return false }
        let search = HistorySearchNormalizer.normalize(query.searchText)
        return search.isEmpty || HistorySearchNormalizer.normalize(
            [title, accountName, providerName, status.displayName].joined(separator: " ")
        ).contains(search)
    }
}

extension HistoryFilterCatalog {
    func merging(_ other: HistoryFilterCatalog) -> HistoryFilterCatalog {
        func merge(_ lhs: [HistoryFilterOption], _ rhs: [HistoryFilterOption]) -> [HistoryFilterOption] {
            Dictionary((lhs + rhs).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                .values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        let currencyOptions = Dictionary(grouping: currencies + other.currencies, by: \.id)
            .map { _, options in
                let first = options[0]
                return HistoryFilterOption(
                    id: first.id, name: first.name,
                    fractionDigits: Set(options.map(\.fractionDigits)).count == 1
                        ? first.fractionDigits : nil
                )
            }.sorted { $0.name < $1.name }
        return HistoryFilterCatalog(
            accounts: merge(accounts, other.accounts), categories: merge(categories, other.categories),
            economicTypes: merge(economicTypes, other.economicTypes),
            economicSources: merge(economicSources, other.economicSources), currencies: currencyOptions,
            sources: merge(sources, other.sources), statuses: merge(statuses, other.statuses),
            provenanceValues: merge(provenanceValues, other.provenanceValues)
        )
    }
}
