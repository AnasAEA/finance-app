import SwiftUI

/// Read-only browsing across the private archive and the portion of the live
/// ledger and bank movements after its explicit cutoff. The sources meet in this projection
/// only; no archive row is ever copied into the operational document.
struct HistoryBrowserView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let snapshot: FinanceAppSnapshot
    @Binding var showsSearch: Bool
    /// Owned by Activity, not by this list, so applied filters survive a
    /// switch to To Review and back.
    @Binding var query: HistoryQuery

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var archiveRows: [HistoryTransactionSummary] = []
    @State private var nextOffset: Int?
    @State private var coverageGaps: [HistorySourceGap] = []
    @State private var catalog = HistoryFilterCatalog.empty
    @State private var metadata: HistoryArchiveMetadata?
    @State private var isFiltering = false
    @State private var failureMessage: String?
    @State private var isPendingExpanded = false

    private let pageSize = 80

    private var hasArchive: Bool { store.history.hasImportedArchive }

    private func liveRows() -> [LiveHistoryRow] {
        return snapshot.activity.flatMap { day -> [LiveHistoryRow] in
            let valueDay = day.date
            if let cutoff = metadata?.archiveCutoff,
               !HistoryArchiveBoundary.includesLiveDate(valueDay, cutoff: cutoff) {
                return []
            }
            return day.rows.compactMap { row in
                let candidate = LiveHistoryRow(row: row, date: valueDay)
                return liveMatches(candidate) ? candidate : nil
            }
        }
    }

    private func displayedRows() -> [UnifiedHistoryRow] {
        let liveRows = liveRows()
        let visibleTransactionIDs = Set(liveRows.map { $0.row.id })
        let bankRows = snapshot.bankHistory.filter {
            $0.isVisible(cutoff: metadata?.archiveCutoff, visibleTransactionIDs: visibleTransactionIDs)
                && $0.matches(query, catalog: catalog)
        }
        let combined = archiveRows.map(UnifiedHistoryRow.archive)
            + liveRows.map(UnifiedHistoryRow.live)
            + bankRows.map(UnifiedHistoryRow.bank)
        return combined.sorted { lhs, rhs in
            if query.sort == .newestFirst || query.sort == .oldestFirst,
               (lhs.date == nil) != (rhs.date == nil) {
                return lhs.date != nil
            }
            switch query.sort {
            case .newestFirst:
                return (lhs.sortDate, lhs.id) > (rhs.sortDate, rhs.id)
            case .oldestFirst:
                return (lhs.sortDate, lhs.id) < (rhs.sortDate, rhs.id)
            case .amountHighToLow:
                return (lhs.amountMagnitude, lhs.sortDate, lhs.id) >
                    (rhs.amountMagnitude, rhs.sortDate, rhs.id)
            case .amountLowToHigh:
                return (lhs.amountMagnitude, lhs.sortDate, lhs.id) <
                    (rhs.amountMagnitude, rhs.sortDate, rhs.id)
            }
        }
    }

    /// Adjacent dates are grouped without changing the selected sort order.
    private func dateGroups(_ rows: [UnifiedHistoryRow]) -> [HistoryDateGroup] {
        ActivityTimelineGrouping.adjacent(rows, date: \.date)
    }

    private var hasFilters: Bool { !query.appliedFacets.isEmpty }

    var body: some View {
        let rows = displayedRows()
        let quickIDs = Set(snapshot.syncedObservations.filter(\.canQuicklyCategorize).map(\.id))
        let separatesPending = query.sort == .newestFirst && !hasFilters && searchText.isEmpty
        let pending = separatesPending ? rows.filter(\.isBankPending) : []
        let groups = dateGroups(separatesPending ? rows.filter { !$0.isBankPending } : rows)
        return List {
            if showsSearch {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(Theme.Role.supporting).accessibilityHidden(true)
                    TextField("Search transactions", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .accessibilityIdentifier("activity.search.field")
                }
                .padding(.horizontal, Theme.Space.md)
                .frame(minHeight: Theme.Metric.minimumTarget)
                .background(Theme.Surface.card, in: RoundedRectangle(cornerRadius: Theme.Metric.controlRadius))
                .listRowInsets(EdgeInsets(top: Theme.Space.sm, leading: Theme.Space.xl,
                                         bottom: 0, trailing: Theme.Space.xl))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            browserControls
                .listRowInsets(EdgeInsets(top: 0, leading: Theme.Space.xl,
                                         bottom: 0, trailing: Theme.Space.xl))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            if hasFilters {
                activeFilters
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            if !coverageGaps.isEmpty {
                // On the page, like every other row here. With the default
                // row background it read as a detached white band.
                SourceGapNotice(gaps: coverageGaps)
                    .listRowBackground(Theme.Surface.background)
                    .listRowInsets(EdgeInsets(top: Theme.Space.sm, leading: Theme.Space.xl,
                                             bottom: Theme.Space.sm, trailing: Theme.Space.xl))
            }

            if !pending.isEmpty {
                DisclosureGroup(isExpanded: $isPendingExpanded) {
                    ForEach(pending) { item in historyLink(item, quickIDs: quickIDs) }
                } label: {
                    HStack(spacing: Theme.Space.md) {
                        ActivityMark(symbol: "clock", tint: Theme.Role.information)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Pending at bank").font(Theme.TypeStyle.action)
                            Text("Awaiting completion").font(Theme.TypeStyle.metadata)
                                .foregroundStyle(Theme.Role.supporting)
                        }
                        Spacer(minLength: 8)
                        Text(pending.count.formatted()).font(Theme.TypeStyle.numeric)
                            .foregroundStyle(Theme.Role.information)
                    }
                    .padding(.vertical, Theme.Space.xs)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("activity.bank-pending-summary")
                }
                .tint(Theme.Role.information)
                .listRowBackground(Theme.Surface.background)
                .listRowInsets(EdgeInsets(top: Theme.Space.sm, leading: Theme.Space.xl,
                                         bottom: Theme.Space.sm, trailing: Theme.Space.xl))
            }

            if rows.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty && !hasFilters ? "Nothing here" : "No matches",
                    systemImage: searchText.isEmpty && !hasFilters ? "tray" : "magnifyingglass",
                    description: Text(
                        searchText.isEmpty && !hasFilters
                            ? "Transactions you add, import or sync will appear here."
                            : "Try a different search or clear some filters."
                    )
                )
                .listRowBackground(Color.clear)
            }

            ForEach(groups, id: \.id) { group in
                Section {
                    ForEach(group.rows) { item in historyLink(item, quickIDs: quickIDs) }
                } header: {
                    ActivitySectionHeading(title: dateHeading(group.date), compact: true)
                        .listRowInsets(EdgeInsets(top: 0, leading: Theme.Space.xl,
                                                 bottom: 0, trailing: Theme.Space.xl))
                }
                .headerProminence(.increased)
            }

            if nextOffset != nil {
                Button {
                    loadNextPage()
                } label: {
                    HStack {
                        Spacer()
                        Label("Load more", systemImage: "arrow.down.circle")
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .environment(\.defaultMinListHeaderHeight, 12)
        .financeList()
        .task {
            // The query outlives this list. An open field shows the search it
            // kept; a closed one never leaves a search applied out of sight.
            if showsSearch {
                searchText = query.searchText
            } else {
                query.searchText = ""
            }
            reload()
        }
        .onChange(of: showsSearch) { _, open in
            searchFocused = open
            if !open {
                searchText = ""
                query.searchText = ""
                reload()
            }
        }
        .onChange(of: snapshot.bankHistory) { _, _ in reload() }
        .onChange(of: snapshot.activity) { _, _ in reload() }
        .onChange(of: store.history.hasImportedArchive) { _, _ in reload() }
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, query.searchText != searchText else { return }
            query.searchText = searchText
            reload()
        }
        .sheet(isPresented: $isFiltering) {
            HistoryFiltersView(query: query, catalog: catalog, defaultDay: store.currentDay()) { updated in
                query = updated
                reload()
            }
        }
        .alert(
            "History unavailable",
            isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "The archive could not be read.")
        }
    }

    private var browserControls: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.sm))
            : AnyLayout(HStackLayout(spacing: Theme.Space.lg))
        return layout {
            Menu {
                Picker("Sort", selection: Binding(get: { query.sort }, set: { query.sort = $0; reload() })) {
                    ForEach(HistorySort.allCases.filter {
                        (query.currencies.count == 1 && query.amountFractionDigits != nil)
                            || ($0 != .amountHighToLow && $0 != .amountLowToHigh)
                    }, id: \.self) { Text($0.title).tag($0) }
                }
            } label: {
                Label(query.sort.title, systemImage: "arrow.down")
                    .font(Theme.TypeStyle.metadata.weight(.medium)).foregroundStyle(Theme.Role.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: Theme.Metric.minimumTarget)
            }
            .accessibilityLabel("Sort transactions")
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Theme.Space.sm) }
            Button { isFiltering = true } label: {
                Label(hasFilters ? "Filters on" : "Filters", systemImage: "line.3.horizontal.decrease")
                    .font(Theme.TypeStyle.action).frame(minHeight: Theme.Metric.minimumTarget)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.Role.accent)
            .accessibilityIdentifier(RouteID.activityFilters)
        }
    }

    private func historyLink(_ item: UnifiedHistoryRow, quickIDs: Set<String>) -> some View {
        NavigationLink {
            switch item {
            case let .archive(row): HistoricalTransactionDetailView(transactionID: row.id)
            case let .live(row): TransactionDetailView(row: row.row, date: row.date)
            case let .bank(row):
                if quickIDs.contains(row.id) {
                    ExpenseCategorizationView(draft: ExpenseReviewDraft(observationID: row.id, label: row.title))
                } else { BankHistoryDetailView(observationID: row.id) }
            }
        } label: {
            UnifiedHistoryRowView(item: item, isQuickCategorization: {
                if case let .bank(row) = item { return quickIDs.contains(row.id) }
                return false
            }())
        }
        .listRowBackground(Theme.Surface.background)
        .listRowInsets(EdgeInsets(top: Theme.Space.sm, leading: Theme.Space.xl,
                                 bottom: Theme.Space.sm, trailing: Theme.Space.lg))
        .accessibilityIdentifier(ActivityID.transaction(item.id))
    }

    private func dateHeading(_ date: CalendarDay?) -> String {
        guard let date else { return "Date not provided" }
        return date.year == snapshot.asOf.year
            ? date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// Each applied filter, removable on its own; Clear all removes the rest.
    private var activeFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(query.appliedFacets, id: \.self) { facet in
                    FilterChip(label: chipLabel(facet)) {
                        query = query.removing(facet)
                        reload()
                    }
                    .accessibilityIdentifier("activity.filter-chip.\(facet.rawValue)")
                }
                Button { clearFilters() } label: {
                    Text("Clear all")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.Role.accent)
                        .frame(minWidth: Theme.Metric.minimumTarget,
                               minHeight: Theme.Metric.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, Theme.Space.xs)
            }
            .padding(.horizontal, Theme.Metric.screenPadding)
        }
    }

    /// What a chip says: the one value chosen, or how many were.
    private func chipLabel(_ facet: HistoryFilterFacet) -> String {
        func selection(_ values: Set<String>, _ options: [HistoryFilterOption], _ noun: String) -> String {
            if let value = values.first, values.count == 1 {
                return options.first(where: { $0.id == value })?.name ?? value
            }
            return "\(values.count) \(noun)"
        }
        switch facet {
        case .date:
            guard let range = query.dateRange else { return "Dates" }
            return range.lowerBound.formatted(through: range.upperBound)
        case .accounts: return selection(query.accountIDs, catalog.accounts, "accounts")
        case .categories: return selection(query.categoryIDs, catalog.categories, "categories")
        case .types: return selection(query.economicTypes, catalog.economicTypes, "types")
        case .economicSources:
            return selection(query.economicSourceIDs, catalog.economicSources, "income sources")
        case .currencies: return selection(query.currencies, catalog.currencies, "currencies")
        case .providers: return selection(query.sourceIDs, catalog.sources, "providers")
        case .amount: return amountRangeLabel
        case .evidence: return "Evidence filters"
        }
    }

    private var amountRangeLabel: String {
        guard let currency = catalog.currencies.first(where: { query.currencies.contains($0.id) }),
              let digits = currency.fractionDigits else { return "Amount range" }
        let minimum = query.minimumAmountMinor.map {
            Amount(minorUnits: $0, currencyCode: currency.id, fractionDigits: digits).formatted()
        }
        let maximum = query.maximumAmountMinor.map {
            Amount(minorUnits: $0, currencyCode: currency.id, fractionDigits: digits).formatted()
        }
        switch (minimum, maximum) {
        case let (.some(minimum), .some(maximum)): return "\(minimum)–\(maximum)"
        case let (.some(minimum), nil): return "At least \(minimum)"
        case let (nil, .some(maximum)): return "Up to \(maximum)"
        case (nil, nil): return "Any amount"
        }
    }

    private func reload() {
        guard hasArchive else {
            archiveRows = []
            nextOffset = nil
            coverageGaps = []
            metadata = nil
            catalog = liveFilterCatalog
            return
        }
        do {
            metadata = try store.history.metadata()
            catalog = try store.history.filterCatalog().merging(liveFilterCatalog)
            let page = try store.history.page(matching: query, offset: 0, limit: pageSize)
            archiveRows = page.transactions
            nextOffset = page.nextOffset
            coverageGaps = page.coverageGaps
        } catch {
            failureMessage = "The archive index could not complete this query."
        }
    }

    /// The archive supplies its own canonical catalog. Before an archive has
    /// been imported, the same Filters control remains useful for the live
    /// ledger using only labels already present on the app snapshot.
    private var liveFilterCatalog: HistoryFilterCatalog {
        // One read builds one catalog: the account, category and source lists
        // must all come from the same snapshot.
        let rows = snapshot.activity.flatMap(\.rows)
        func unique(_ values: [HistoryFilterOption]) -> [HistoryFilterOption] {
            Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                .values
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return HistoryFilterCatalog(
            accounts: snapshot.accounts.map {
                HistoryFilterOption(id: $0.id, name: $0.name)
            },
            categories: snapshot.entryOptions.categories.map {
                HistoryFilterOption(id: $0.key, name: $0.name)
            },
            economicTypes: unique(rows.map {
                HistoryFilterOption(id: $0.transactionTypeLabel, name: $0.transactionTypeLabel)
            }),
            economicSources: snapshot.incomeSources.map {
                HistoryFilterOption(id: $0.id, name: $0.name)
            },
            currencies: Dictionary(grouping: rows.map(\.amount) + snapshot.bankHistory.map(\.amount), by: \.currencyCode)
                .map { code, matching in
                    let digits = Set(matching.map(\.fractionDigits))
                    return HistoryFilterOption(
                        id: code, name: code,
                        fractionDigits: digits.count == 1 ? digits.first : nil
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            sources: snapshot.accounts.map {
                HistoryFilterOption(id: $0.id, name: $0.name)
            } + unique(snapshot.bankHistory.map {
                HistoryFilterOption(id: $0.providerID, name: $0.providerName)
            }),
            statuses: unique(snapshot.bankHistory.map {
                HistoryFilterOption(id: $0.status.rawValue, name: $0.status.displayName)
            }),
            provenanceValues: snapshot.bankHistory.isEmpty ? [] : [
                HistoryFilterOption(id: "bank_sync", name: "Bank sync")
            ]
        )
    }

    private func loadNextPage() {
        guard let offset = nextOffset else { return }
        do {
            let page = try store.history.page(matching: query, offset: offset, limit: pageSize)
            archiveRows.append(contentsOf: page.transactions)
            nextOffset = page.nextOffset
            coverageGaps = Array(Set(coverageGaps + page.coverageGaps)).sorted {
                $0.dateRange.lowerBound < $1.dateRange.lowerBound
            }
        } catch {
            failureMessage = "More history could not be loaded."
        }
    }

    private func clearFilters() {
        let sort = query.sort
        query = HistoryQuery()
        query.sort = sort == .amountHighToLow || sort == .amountLowToHigh ? .newestFirst : sort
        searchText = ""
        reload()
    }

    private func liveMatches(_ candidate: LiveHistoryRow) -> Bool {
        let row = candidate.row
        if let range = query.dateRange, !range.contains(candidate.date) { return false }
        if let minimum = query.minimumAmountMinor,
           row.amount.minorUnits.magnitudeForHistoryUI < minimum { return false }
        if let maximum = query.maximumAmountMinor,
           row.amount.minorUnits.magnitudeForHistoryUI > maximum { return false }
        if (query.minimumAmountMinor != nil || query.maximumAmountMinor != nil
            || query.sort == .amountHighToLow || query.sort == .amountLowToHigh),
           row.amount.fractionDigits != query.amountFractionDigits { return false }
        if !query.currencies.isEmpty, !query.currencies.contains(row.amount.currencyCode) { return false }
        if !query.economicTypes.isEmpty,
           !query.economicTypes.contains(where: {
               $0.caseInsensitiveCompare(row.transactionTypeLabel) == .orderedSame
           }) { return false }
        if !query.economicSourceIDs.isEmpty,
           !HistoryEconomicSource.matchesLive(
               incomeSourceID: row.incomeSourceID,
               incomeSourceLabel: row.incomeSourceLabel,
               selection: query.economicSourceIDs
           ) { return false }
        if !query.accountIDs.isEmpty {
            let rowIDs = row.accountIDs
            let selectedNames = catalog.accounts
                .filter { query.accountIDs.contains($0.id) }
                .map { HistorySearchNormalizer.normalize($0.name) }
            let rowNames = [row.primaryAccountLabel, row.secondaryAccountLabel]
                .compactMap { $0 }
                .map(HistorySearchNormalizer.normalize)
            guard !rowIDs.isDisjoint(with: query.accountIDs)
                    || !Set(rowNames).isDisjoint(with: Set(selectedNames)) else { return false }
        }
        if !query.categoryIDs.isEmpty {
            guard let category = row.categoryLabel else { return false }
            let normalized = HistorySearchNormalizer.normalize(category)
            let selected = catalog.categories
                .filter { query.categoryIDs.contains($0.id) }
                .map { HistorySearchNormalizer.normalize($0.name) }
            guard selected.contains(normalized) else { return false }
        }
        if !query.sourceIDs.isEmpty {
            let provider = HistorySearchNormalizer.normalize(row.primaryAccountLabel ?? "live ledger")
            let selected = catalog.sources
                .filter { query.sourceIDs.contains($0.id) }
                .map { HistorySearchNormalizer.normalize($0.name) }
            guard selected.contains(provider) else { return false }
        }
        // Canonical evidence statuses/provenance do not apply to live rows.
        if !query.statuses.isEmpty || !query.provenanceValues.isEmpty { return false }
        let normalizedSearch = HistorySearchNormalizer.normalize(query.searchText)
        return normalizedSearch.isEmpty
            || HistorySearchNormalizer.normalize(row.searchText).contains(normalizedSearch)
    }
}

private struct LiveHistoryRow: Identifiable, Hashable {
    let row: ActivityRow
    let date: CalendarDay
    var id: String { "live:\(row.id)" }
}

private enum UnifiedHistoryRow: Identifiable, Hashable {
    case archive(HistoryTransactionSummary)
    case live(LiveHistoryRow)
    case bank(BankHistoryItem)

    var isBankPending: Bool {
        if case let .bank(row) = self { return row.status == .pending }
        return false
    }

    var id: String {
        switch self {
        case let .archive(row): "archive:\(row.id)"
        case let .live(row): row.id
        case let .bank(row): "bank:\(row.id)"
        }
    }

    var date: CalendarDay? {
        switch self {
        case let .archive(row): row.date
        case let .live(row): row.date
        case let .bank(row): row.date
        }
    }

    // Unknown bank dates sort last without claiming a date on the screen.
    var sortDate: CalendarDay { date ?? CalendarDay(year: 1, month: 1, day: 1) }

    var amountMagnitude: Int64 {
        switch self {
        case let .archive(row): row.amount.minorUnits.magnitudeForHistoryUI
        case let .live(row): row.row.amount.minorUnits.magnitudeForHistoryUI
        case let .bank(row): row.amount.minorUnits.magnitudeForHistoryUI
        }
    }
}

private extension Int64 {
    var magnitudeForHistoryUI: Int64 { self == .min ? .max : Swift.abs(self) }
}

private typealias HistoryDateGroup = ActivityTimelineGroup<UnifiedHistoryRow>

private struct UnifiedHistoryRowView: View {
    let item: UnifiedHistoryRow
    var isQuickCategorization = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                expandedRow
            } else {
                // The compact row has an intrinsic one-line name. If name,
                // amount and state cannot all fit, the whole row reflows;
                // SwiftUI must not squeeze the name into the status column.
                ViewThatFits(in: .horizontal) {
                    compactRow
                    expandedRow
                }
            }
        }
        .padding(.vertical, Theme.Space.sm)
        // One sentence, in the order a person needs it, instead of the
        // combined children — which began with the provider's initials and
        // never said what kind of record this is or what opening it does.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(accessibilityHintText)
    }

    /// Name, amount, what kind of record it is and its state, then where.
    var accessibilityText: String {
        var parts = [title, amount.accessibleDescription(), kindAndState]
        if let personal = personalAmount { parts.append("\(personal.accessibleDescription()) yours") }
        if !subtitle.isEmpty { parts.append(subtitle) }
        return parts.joined(separator: ", ")
    }

    private var kindAndState: String {
        switch item {
        case .archive:
            return "archived record"
        case let .live(row):
            if row.row.isPending { return "recorded, pending" }
            return row.row.trailingNote.map { "recorded, \($0)" } ?? "recorded"
        case let .bank(row):
            if row.status == .pending { return "pending at the bank, no action needed" }
            if row.resolution == .unreviewed {
                return isQuickCategorization ? "bank movement to categorize" : "bank movement, needs review"
            }
            return "bank movement, \(row.status.displayName)"
        }
    }

    /// Where the row goes, matching the destinations `historyLink` opens.
    private var accessibilityHintText: String {
        switch item {
        case .archive: "Opens the archived record"
        case .live: "Opens transaction details"
        case .bank: isQuickCategorization ? "Opens categorization" : "Opens bank details"
        }
    }

    private var mark: some View {
        ActivityMark(symbol: symbol, text: markText,
                     tint: item.isBankPending ? Theme.Role.information : Theme.Role.accent)
    }

    private var amountText: some View {
        MoneyText(amount: amount, size: 17, weight: .semibold, showsSign: !amount.isZero)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var compactRow: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            mark
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.TypeStyle.supporting.weight(.semibold))
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Text(subtitle).font(Theme.TypeStyle.metadata)
                    .foregroundStyle(Theme.Role.supporting)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.sm)
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                amountText
                stateLabel.fixedSize(horizontal: true, vertical: false)
                if let personal = personalAmount {
                    Text("\(personal.formatted()) yours")
                        .font(Theme.TypeStyle.metadata)
                        .foregroundStyle(Theme.Role.supporting)
                }
            }
        }
    }

    private var expandedRow: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            mark
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title).font(Theme.TypeStyle.supporting.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(Theme.TypeStyle.metadata)
                    .foregroundStyle(Theme.Role.supporting)
                    .fixedSize(horizontal: false, vertical: true)
                amountText
                stateLabel
                if let personal = personalAmount {
                    Text("\(personal.formatted()) yours")
                        .font(Theme.TypeStyle.metadata)
                        .foregroundStyle(Theme.Role.supporting)
                }
            }
        }
    }

    private var personalAmount: Amount? {
        switch item {
        case let .archive(row): row.personalAmount
        case let .live(row): row.row.ownedPortion
        case .bank: nil
        }
    }

    private var title: String {
        switch item {
        case let .archive(row):
            guard let merchant = row.merchantOrCounterparty else {
                return row.displayDescription
            }
            // Canonical evidence intentionally preserves raw statement text,
            // but an all-caps bank descriptor is poor list copy. The curated
            // display description is the readable title in that case; detail
            // still exposes the original merchant/evidence verbatim.
            let letters = merchant.unicodeScalars.filter(CharacterSet.letters.contains)
            let looksLikeStatementDescriptor = letters.count >= 4
                && merchant == merchant.uppercased()
            return looksLikeStatementDescriptor ? row.displayDescription : merchant
        case let .live(row): return ActivityTextPresentation.ledgerListTitle(row.row.title)
        case let .bank(row): return ActivityTextPresentation.listTitle(row.title)
        }
    }

    private var subtitle: String {
        switch item {
        case let .archive(row): "\(row.categoryName) · \(row.accountName)"
        case let .live(row):
            [row.row.categoryLabel ?? row.row.transactionTypeLabel,
             row.row.primaryAccountLabel].compactMap { $0 }.joined(separator: " · ")
        case let .bank(row): row.accountName
        }
    }

    private var markText: String? {
        guard case let .bank(row) = item, row.status != .pending else { return nil }
        switch row.providerID {
        case "bnp": return "BNP"
        case "paypal": return "P"
        case "revolut": return "R"
        default: return String(row.providerName.prefix(1)).uppercased()
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch item {
        case .archive:
            ActivityStateLabel(title: "Archived")
        case let .live(row):
            ActivityStateLabel(title: row.row.trailingNote ?? "Recorded",
                               symbol: row.row.isPending ? "clock" : nil,
                               tint: row.row.isPending ? Theme.Role.information : Theme.Role.supporting)
        case let .bank(row):
            if row.status == .pending {
                ActivityStateLabel(title: "Pending", symbol: "clock", tint: Theme.Role.information)
            } else if row.resolution == .unreviewed {
                ActivityStateLabel(title: isQuickCategorization ? "Categorize" : "Needs review",
                                   symbol: isQuickCategorization ? "tag" : "circle.dotted",
                                   tint: isQuickCategorization ? Theme.Role.accent : Theme.Role.caution)
            } else {
                ActivityStateLabel(title: row.status.displayName)
            }
        }
    }

    private var amount: Amount {
        switch item {
        case let .archive(row): row.amount
        case let .live(row): row.row.amount
        case let .bank(row): row.amount
        }
    }

    private var date: CalendarDay? {
        switch item {
        case let .archive(row): row.date
        case let .live(row): row.date
        case let .bank(row): row.date
        }
    }

    private var symbol: String {
        switch item {
        case let .archive(row):
            let type = row.economicType.lowercased()
            if type.contains("income") || type.contains("support") { return "arrow.down.circle" }
            if type.contains("transfer") || type.contains("cash") { return "arrow.left.arrow.right" }
            if type.contains("refund") { return "arrow.uturn.backward.circle" }
            return "cart"
        case let .live(row):
            return row.row.symbolName
        case .bank:
            return "building.columns"
        }
    }
}

/// An applied filter that removes itself when tapped. The capsule stays
/// compact; the tap target is the full 44-point row height.
private struct FilterChip: View {
    let label: String
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            HStack(spacing: 6) {
                Text(label).font(.caption.weight(.medium))
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.Role.accent.opacity(0.12), in: Capsule())
            .foregroundStyle(Theme.Role.accent)
            .frame(minWidth: Theme.Metric.minimumTarget, minHeight: Theme.Metric.minimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove filter: \(label)")
    }
}

private struct SourceGapNotice: View {
    let gaps: [HistorySourceGap]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Theme.Role.caution)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Some records are incomplete")
                    .font(.subheadline.weight(.medium))
                Text(gaps.count == 1
                     ? gaps[0].message
                     : "Bank records for parts of this period are incomplete. Missing periods are never treated as zero spending.")
                    .font(.caption)
                    .foregroundStyle(Theme.Role.supporting)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct HistoricalTransactionDetailView: View {
    @Environment(FinanceStore.self) private var store
    let transactionID: String

    @State private var detail: HistoryTransactionDetail?
    @State private var failed = false

    var body: some View {
        Group {
            if let detail {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(detail.merchant ?? detail.displayDescription).font(.headline)
                            MoneyText(amount: detail.amount, size: 34, weight: .bold,
                                      showsSign: true, colorBySign: true)
                        }
                        .padding(.vertical, 6)
                    }

                    Section("Transaction") {
                        LabeledContent("Date", value: detail.date.formatted(date: .long, time: .omitted))
                        LabeledContent("Account", value: detail.accountName)
                        if let merchant = detail.merchant {
                            LabeledContent("Merchant", value: merchant)
                        }
                        if let counterparty = detail.counterparty {
                            LabeledContent("Counterparty", value: counterparty)
                        }
                        LabeledContent("Category", value: detail.categoryName)
                        LabeledContent("Type", value: detail.economicType.displayHistoryToken)
                        if let economicSource = detail.economicSource {
                            LabeledContent(
                                "Economic source",
                                value: HistoryEconomicSource.displayName(for: economicSource)
                            )
                        }
                        if let personal = detail.personalAmount {
                            LabeledContent("Your share") {
                                MoneyText(amount: personal, size: 17, weight: .semibold,
                                          showsSign: true, colorBySign: true)
                            }
                            LabeledContent(
                                "Pass-through", value: detail.passThrough.displayHistoryToken
                            )
                        }
                    }

                    Section("Details") {
                        LabeledContent("Description", value: detail.displayDescription)
                        LabeledContent("Status", value: detail.status.displayHistoryToken)
                    }

                    Section {
                        DisclosureGroup("Advanced evidence") {
                            LabeledContent("Source", value: detail.evidence.source)
                            LabeledContent("Provenance", value: detail.evidence.provenance.displayHistoryToken)
                            LabeledContent("Confidence", value: detail.evidence.confidence.capitalized)
                            LabeledContent("Classification rule", value: detail.evidence.ruleID)
                            LabeledContent("Evidence basis", value: detail.evidence.basis)
                            if let original = detail.evidence.originalDescription {
                                LabeledContent("Original description", value: original)
                            }
                            if let unresolved = detail.evidence.unresolvedReason {
                                LabeledContent("Unresolved", value: unresolved)
                            }
                            if let linked = detail.evidence.linkedTransactionID {
                                LabeledContent("Linked transaction", value: linked)
                            }
                            if let group = detail.evidence.groupID {
                                LabeledContent("Group", value: group)
                            }
                        }
                    }
                }
            } else if failed {
                ContentUnavailableView("Transaction unavailable", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView("Loading transaction…")
            }
        }
        .navigationTitle("History detail")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                detail = try store.history.detail(id: transactionID)
                failed = detail == nil
            } catch {
                failed = true
            }
        }
    }
}

private extension String {
    var displayHistoryToken: String {
        replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
            .capitalized
    }
}

private extension HistorySort {
    var title: String {
        switch self {
        case .newestFirst: "Newest first"
        case .oldestFirst: "Oldest first"
        case .amountHighToLow: "Amount high to low"
        case .amountLowToHigh: "Amount low to high"
        }
    }
}

// MARK: - Filters

private struct HistoryFiltersView: View {
    @Environment(\.dismiss) private var dismiss

    let catalog: HistoryFilterCatalog
    let onApply: (HistoryQuery) -> Void

    @State private var draft: HistoryQuery
    @State private var dateMode: HistoryDateMode
    @State private var dateAnchor: CalendarDay?
    @State private var customStart: CalendarDay?
    @State private var customEnd: CalendarDay?
    @State private var minimumAmount: String
    @State private var maximumAmount: String
    @State private var validationMessage: String?

    init(
        query: HistoryQuery,
        catalog: HistoryFilterCatalog,
        defaultDay: CalendarDay?,
        onApply: @escaping (HistoryQuery) -> Void
    ) {
        self.catalog = catalog
        self.onApply = onApply
        _draft = State(initialValue: query)
        let start = query.dateRange?.lowerBound ?? defaultDay
        let end = query.dateRange?.upperBound ?? defaultDay
        _dateMode = State(initialValue: query.dateRange == nil ? .all : .custom)
        _dateAnchor = State(initialValue: start)
        _customStart = State(initialValue: start)
        _customEnd = State(initialValue: end)
        let digits = catalog.currencies.first(where: { query.currencies.contains($0.id) })?.fractionDigits
        _minimumAmount = State(initialValue: Self.majorText(query.minimumAmountMinor, digits: digits))
        _maximumAmount = State(initialValue: Self.majorText(query.maximumAmountMinor, digits: digits))
    }

    var body: some View {
        NavigationStack {
            FinancePage {
                FinanceSection("When") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                        ForEach(HistoryDateMode.allCases) { mode in
                            Button { dateMode = mode } label: {
                                Text(mode == .all ? "Any time" : mode.title)
                                    .font(Theme.TypeStyle.action).frame(maxWidth: .infinity, minHeight: 44)
                                    .padding(.horizontal, 8)
                                    .foregroundStyle(dateMode == mode ? Theme.Role.accent : .primary)
                                    .background(dateMode == mode ? Theme.Surface.inset : Theme.Surface.card,
                                                in: RoundedRectangle(cornerRadius: Theme.Metric.controlRadius))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(dateMode == mode ? .isSelected : [])
                        }
                    }
                    switch dateMode {
                    case .all: EmptyView()
                    case .month: CivilDatePicker("Month containing", selection: $dateAnchor)
                    case .year: CivilDatePicker("Year containing", selection: $dateAnchor)
                    case .custom:
                        CivilDatePicker("From", selection: $customStart)
                        CivilDatePicker("Through", selection: $customEnd)
                    }
                }
                FilterSelectionSection(title: "Account", options: catalog.accounts, selection: $draft.accountIDs)
                FilterSelectionSection(title: "Category", options: catalog.categories, selection: $draft.categoryIDs)
                DisclosureGroup("More filters") {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        FilterSelectionSection(title: "Currency", options: catalog.currencies, selection: $draft.currencies)
                        FinanceSection("Amount") {
                            TextField("Minimum", text: $minimumAmount).keyboardType(.decimalPad)
                            Divider()
                            TextField("Maximum", text: $maximumAmount).keyboardType(.decimalPad)
                            Text("Choose one currency to compare amounts.")
                                .font(Theme.TypeStyle.metadata).foregroundStyle(Theme.Role.supporting)
                        }
                        FilterSelectionSection(title: "Type", options: catalog.economicTypes, selection: $draft.economicTypes)
                        FilterSelectionSection(title: "Income source", options: catalog.economicSources,
                                               selection: $draft.economicSourceIDs)
                        FilterSelectionSection(title: "Provider", options: catalog.sources, selection: $draft.sourceIDs)
                        FilterSelectionSection(title: "Evidence status", options: catalog.statuses, selection: $draft.statuses)
                        FilterSelectionSection(title: "Evidence provenance", options: catalog.provenanceValues,
                                               selection: $draft.provenanceValues,
                                               footer: "Evidence quality is separate from spending categories.")
                    }.padding(.top, Theme.Space.lg)
                }
                .font(Theme.TypeStyle.action).tint(Theme.Role.accent)
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.circle")
                        .font(Theme.TypeStyle.supporting).foregroundStyle(Theme.Role.negative)
                }
            }
            .navigationTitle("Transaction filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if hasSelections { Button("Reset") { clear() } }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Show transactions") { apply() }
                    .buttonStyle(.borderedProminent).tint(Theme.Role.accent)
                    .frame(maxWidth: .infinity).padding(Theme.Space.lg)
                    .background(Theme.Surface.background)
                    .accessibilityIdentifier("activity.filters.apply")
            }
        }
    }

    private var hasSelections: Bool {
        dateMode != .all
            || !draft.accountIDs.isEmpty
            || !draft.categoryIDs.isEmpty
            || !draft.economicTypes.isEmpty
            || !draft.economicSourceIDs.isEmpty
            || !minimumAmount.isEmpty
            || !maximumAmount.isEmpty
            || !draft.currencies.isEmpty
            || !draft.sourceIDs.isEmpty
            || !draft.statuses.isEmpty
            || !draft.provenanceValues.isEmpty
    }

    private func apply() {
        guard dateMode == .all || selectedDateRange != nil else { return }
        let hasAmount = !minimumAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !maximumAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let amountSort = draft.sort == .amountHighToLow || draft.sort == .amountLowToHigh
        if hasAmount || amountSort {
            guard draft.currencies.count == 1,
                  let currency = catalog.currencies.first(where: { draft.currencies.contains($0.id) }),
                  let digits = currency.fractionDigits else {
                validationMessage = "Choose one currency before filtering or sorting by amount."
                return
            }
            do {
                draft.minimumAmountMinor = try Self.minorUnits(minimumAmount, currency: currency.id, digits: digits)
                draft.maximumAmountMinor = try Self.minorUnits(maximumAmount, currency: currency.id, digits: digits)
                draft.amountFractionDigits = digits
            } catch {
                validationMessage = "Enter an exact amount within this currency’s supported range."
                return
            }
            if let minimum = draft.minimumAmountMinor, let maximum = draft.maximumAmountMinor,
               minimum > maximum {
                validationMessage = "Minimum amount must not exceed maximum amount."
                return
            }
        } else {
            draft.minimumAmountMinor = nil
            draft.maximumAmountMinor = nil
            draft.amountFractionDigits = draft.currencies.count == 1
                ? catalog.currencies.first(where: { draft.currencies.contains($0.id) })?.fractionDigits
                : nil
        }
        draft.dateRange = selectedDateRange
        validationMessage = nil
        onApply(draft)
        dismiss()
    }

    private var selectedDateRange: ClosedRange<CalendarDay>? {
        switch dateMode {
        case .all:
            return nil
        case .month:
            guard let anchor = dateAnchor, (1...12).contains(anchor.month) else { return nil }
            let year = anchor.year
            let month = anchor.month
            return CalendarDay(year: year, month: month, day: 1)...CalendarDay(
                year: year,
                month: month,
                day: DayCount.daysInMonth(year: year, month: month)
            )
        case .year:
            guard let anchor = dateAnchor else { return nil }
            let year = anchor.year
            return CalendarDay(year: year, month: 1, day: 1)...CalendarDay(year: year, month: 12, day: 31)
        case .custom:
            guard let start = customStart,
                  let end = customEnd
            else { return nil }
            return min(start, end)...max(start, end)
        }
    }

    private func clear() {
        let sort = draft.sort
        draft = HistoryQuery()
        draft.sort = sort == .amountHighToLow || sort == .amountLowToHigh ? .newestFirst : sort
        dateMode = .all
        minimumAmount = ""
        maximumAmount = ""
        validationMessage = nil
    }

    private static func majorText(_ minor: Int64?, digits: Int?) -> String {
        guard let minor, let digits else { return "" }
        return Amount(minorUnits: minor, currencyCode: "", fractionDigits: digits).editingText
    }

    private static func minorUnits(_ value: String, currency: String, digits: Int) throws -> Int64? {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try Amount.parse(value, currencyCode: currency, fractionDigits: digits).minorUnits
    }
}

private enum HistoryDateMode: String, CaseIterable, Identifiable {
    case all, month, year, custom
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

private struct FilterSelectionSection: View {
    let title: String
    let options: [HistoryFilterOption]
    @Binding var selection: Set<String>
    var footer: String?
    @State private var search = ""

    var body: some View {
        FinanceSection(title) {
            NavigationLink {
                List {
                    FilterSelectionRows(options: options.filter {
                        search.isEmpty || $0.name.displayHistoryToken.localizedCaseInsensitiveContains(search)
                    }, selection: $selection)
                        .listRowBackground(Theme.Surface.background)
                }
                .listStyle(.plain).financeList()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "Find \(title.lowercased())")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Clear") { selection.removeAll() } } }
            } label: {
                HStack(spacing: Theme.Space.md) {
                    Text(selection.isEmpty ? (title == "Category" ? "All categories" : title == "Account" ? "All accounts" : "Any \(title.lowercased())")
                         : options.filter { selection.contains($0.id) }.map { $0.name.displayHistoryToken }.joined(separator: ", "))
                        .foregroundStyle(selection.isEmpty ? Theme.Role.supporting : Theme.Role.accent)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.Role.supporting)
                }
                .frame(minHeight: Theme.Metric.minimumTarget)
                .padding(Theme.Space.md)
                .background(Theme.Surface.card, in: RoundedRectangle(cornerRadius: Theme.Metric.controlRadius))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("activity.filter.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
            if let footer { Text(footer).font(Theme.TypeStyle.metadata).foregroundStyle(Theme.Role.supporting) }
        }
    }
}

private struct FilterSelectionRows: View {
    let options: [HistoryFilterOption]
    @Binding var selection: Set<String>

    var body: some View {
        if options.isEmpty {
            Text("No options").foregroundStyle(Theme.Role.supporting)
        } else {
            ForEach(options) { option in
                Button {
                    if selection.contains(option.id) {
                        selection.remove(option.id)
                    } else {
                        selection.insert(option.id)
                    }
                } label: {
                    HStack {
                        Text(option.name.displayHistoryToken)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: selection.contains(option.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.contains(option.id) ? Theme.Role.accent : Theme.Role.supporting)
                    }
                    .frame(minHeight: Theme.Metric.minimumTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection.contains(option.id) ? .isSelected : [])
            }
        }
    }
}

private enum DayCount {
    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31 // Caller proves month is in 1...12.
        }
    }
}
