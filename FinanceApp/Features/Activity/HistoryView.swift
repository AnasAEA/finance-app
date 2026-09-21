import SwiftUI

/// Read-only browsing across the private archive and the portion of the live
/// ledger after its explicit cutoff. The two sources meet in this projection
/// only; no archive row is ever copied into the operational document.
struct HistoryBrowserView: View {
    @Environment(FinanceStore.self) private var store

    @State private var query = HistoryQuery()
    @State private var searchText = ""
    @State private var archiveRows: [HistoryTransactionSummary] = []
    @State private var nextOffset: Int?
    @State private var coverageGaps: [HistorySourceGap] = []
    @State private var catalog = HistoryFilterCatalog.empty
    @State private var metadata: HistoryArchiveMetadata?
    @State private var isFiltering = false
    @State private var failureMessage: String?

    private let pageSize = 80

    private var hasArchive: Bool { store.history.hasImportedArchive }

    private var liveRows: [LiveHistoryRow] {
        return store.snapshot.activity.flatMap { day -> [LiveHistoryRow] in
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

    private var displayedRows: [UnifiedHistoryRow] {
        let combined = archiveRows.map(UnifiedHistoryRow.archive)
            + liveRows.map(UnifiedHistoryRow.live)
        return combined.sorted { lhs, rhs in
            switch query.sort {
            case .newestFirst:
                return (lhs.date, lhs.id) > (rhs.date, rhs.id)
            case .oldestFirst:
                return (lhs.date, lhs.id) < (rhs.date, rhs.id)
            case .amountHighToLow:
                return (lhs.amountMagnitude, lhs.date, lhs.id) >
                    (rhs.amountMagnitude, rhs.date, rhs.id)
            case .amountLowToHigh:
                return (lhs.amountMagnitude, lhs.date, lhs.id) <
                    (rhs.amountMagnitude, rhs.date, rhs.id)
            }
        }
    }

    /// Adjacent dates are grouped without changing the selected sort order.
    private var dateGroups: [HistoryDateGroup] {
        var groups: [HistoryDateGroup] = []
        for row in displayedRows {
            if groups.last?.date == row.date {
                groups[groups.count - 1].rows.append(row)
            } else {
                groups.append(HistoryDateGroup(id: row.id, date: row.date, rows: [row]))
            }
        }
        return groups
    }

    private var hasFilters: Bool {
        query.dateRange != nil
            || !query.accountIDs.isEmpty
            || !query.categoryIDs.isEmpty
            || !query.economicTypes.isEmpty
            || !query.economicSourceIDs.isEmpty
            || query.minimumAmountMinor != nil
            || query.maximumAmountMinor != nil
            || !query.currencies.isEmpty
            || !query.sourceIDs.isEmpty
            || !query.statuses.isEmpty
            || !query.provenanceValues.isEmpty
    }

    var body: some View {
        List {
            if hasFilters {
                activeFilters
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
            }

            if !coverageGaps.isEmpty {
                SourceGapNotice(gaps: coverageGaps)
            }

            if displayedRows.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty && !hasFilters ? "Nothing here" : "No matches",
                    systemImage: searchText.isEmpty && !hasFilters ? "tray" : "magnifyingglass",
                    description: Text(
                        searchText.isEmpty && !hasFilters
                            ? "Transactions you add or import will appear here."
                            : "Try a different search or clear some filters."
                    )
                )
                .listRowBackground(Color.clear)
            }

            ForEach(dateGroups, id: \.id) { group in
                Section {
                    ForEach(group.rows) { item in
                        NavigationLink {
                            switch item {
                            case let .archive(row):
                                HistoricalTransactionDetailView(transactionID: row.id)
                            case let .live(row):
                                TransactionDetailView(row: row.row, date: row.date)
                            }
                        } label: {
                            UnifiedHistoryRowView(item: item)
                        }
                        .listRowBackground(Theme.Surface.background)
                        .listRowInsets(EdgeInsets(top: Theme.Space.xs, leading: Theme.Space.xl, bottom: Theme.Space.xs, trailing: Theme.Space.lg))
                        .accessibilityIdentifier(ActivityID.transaction(item.id))
                    }
                } header: {
                    Text(group.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()))
                        .font(Theme.TypeStyle.metadata.weight(.semibold)).foregroundStyle(.primary).textCase(nil)
                        .padding(.top, Theme.Space.xs)
                }
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
        .listSectionSpacing(Theme.Space.xs)
        .environment(\.defaultMinListHeaderHeight, 24)
        .financeList()
        .searchable(text: $searchText, prompt: "Search transactions")
        .task { reload() }
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, query.searchText != searchText else { return }
            query.searchText = searchText
            reload()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: Binding(
                        get: { query.sort },
                        set: { query.sort = $0; reload() }
                    )) {
                        ForEach(HistorySort.allCases, id: \.self) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                // A `Label` shown title-only, not a bare `Text`: a
                // text-labelled toolbar button is hosted inside a container
                // that inherits its identifier, so `activity.filters` used to
                // resolve to two elements at the same frame. The words and the
                // state they carry are unchanged.
                Button {
                    isFiltering = true
                } label: {
                    Label(
                        hasFilters ? "Filters on" : "Filters",
                        systemImage: "line.3.horizontal.decrease"
                    )
                    .labelStyle(.titleOnly)
                }
                .accessibilityIdentifier(RouteID.activityFilters)
            }
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

    private var activeFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let range = query.dateRange {
                    FilterChip(label: range.lowerBound == range.upperBound
                               ? range.lowerBound.description
                               : "\(range.lowerBound)–\(range.upperBound)")
                }
                selectionChip("account", values: query.accountIDs, options: catalog.accounts)
                selectionChip("category", values: query.categoryIDs, options: catalog.categories)
                selectionChip("type", values: query.economicTypes, options: catalog.economicTypes)
                selectionChip(
                    "source", values: query.economicSourceIDs, options: catalog.economicSources
                )
                selectionChip("currency", values: query.currencies, options: catalog.currencies)
                selectionChip("source", values: query.sourceIDs, options: catalog.sources)
                if query.minimumAmountMinor != nil || query.maximumAmountMinor != nil {
                    FilterChip(label: amountRangeLabel)
                }
                if !query.statuses.isEmpty || !query.provenanceValues.isEmpty {
                    FilterChip(label: "Advanced")
                }
                Button("Clear all") { clearFilters() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.horizontal, Theme.Metric.screenPadding)
        }
    }

    @ViewBuilder
    private func selectionChip(
        _ noun: String,
        values: Set<String>,
        options: [HistoryFilterOption]
    ) -> some View {
        if let value = values.first, values.count == 1 {
            FilterChip(label: options.first(where: { $0.id == value })?.name ?? value)
        } else if values.count > 1 {
            FilterChip(label: "\(values.count) \(noun)s")
        }
    }

    private var amountRangeLabel: String {
        let minimum = query.minimumAmountMinor.map { Amount(minorUnits: $0, currencyCode: "EUR").formatted() }
        let maximum = query.maximumAmountMinor.map { Amount(minorUnits: $0, currencyCode: "EUR").formatted() }
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
            catalog = try store.history.filterCatalog()
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
        let snapshot = store.snapshot
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
            currencies: unique(rows.map {
                HistoryFilterOption(id: $0.amount.currencyCode, name: $0.amount.currencyCode)
            }),
            sources: snapshot.accounts.map {
                HistoryFilterOption(id: $0.id, name: $0.name)
            },
            statuses: [],
            provenanceValues: []
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
        query.sort = sort
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

    var id: String {
        switch self {
        case let .archive(row): "archive:\(row.id)"
        case let .live(row): row.id
        }
    }

    var date: CalendarDay {
        switch self {
        case let .archive(row): row.date
        case let .live(row): row.date
        }
    }

    var amountMagnitude: Int64 {
        switch self {
        case let .archive(row): row.amount.minorUnits.magnitudeForHistoryUI
        case let .live(row): row.row.amount.minorUnits.magnitudeForHistoryUI
        }
    }
}

private extension Int64 {
    var magnitudeForHistoryUI: Int64 { self == .min ? .max : Swift.abs(self) }
}

private struct HistoryDateGroup: Identifiable {
    let id: String
    let date: CalendarDay
    var rows: [UnifiedHistoryRow]
}

private struct UnifiedHistoryRowView: View {
    let item: UnifiedHistoryRow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.sm))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Space.md))
        layout {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title).font(Theme.TypeStyle.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(Theme.TypeStyle.metadata).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Theme.Space.sm) }
            VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: Theme.Space.xs) {
                MoneyText(amount: amount, size: 18, weight: .semibold, showsSign: true)
                if let personal = personalAmount {
                    Text("\(personal.formatted()) yours")
                        .font(Theme.TypeStyle.metadata).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .accessibilityElement(children: .combine)
    }

    private var personalAmount: Amount? {
        switch item {
        case let .archive(row): row.personalAmount
        case let .live(row): row.row.ownedPortion
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
        case let .live(row): return row.row.title
        }
    }

    private var subtitle: String {
        switch item {
        case let .archive(row): "\(row.categoryName) · \(row.accountName)"
        case let .live(row): row.row.subtitle
        }
    }

    private var amount: Amount {
        switch item {
        case let .archive(row): row.amount
        case let .live(row): row.row.amount
        }
    }

    private var date: CalendarDay {
        switch item {
        case let .archive(row): row.date
        case let .live(row): row.date
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
        }
    }
}

private struct FilterChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.Role.accent.opacity(0.12), in: Capsule())
            .foregroundStyle(Theme.Role.accent)
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
                    .foregroundStyle(.secondary)
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
        _minimumAmount = State(initialValue: Self.majorText(query.minimumAmountMinor))
        _maximumAmount = State(initialValue: Self.majorText(query.maximumAmountMinor))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    Picker("Range", selection: $dateMode) {
                        ForEach(HistoryDateMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    switch dateMode {
                    case .all:
                        EmptyView()
                    case .month:
                        CivilDatePicker("Month containing", selection: $dateAnchor)
                    case .year:
                        CivilDatePicker("Year containing", selection: $dateAnchor)
                    case .custom:
                        CivilDatePicker("From", selection: $customStart)
                        CivilDatePicker("Through", selection: $customEnd)
                    }
                }

                FilterSelectionSection(title: "Account", options: catalog.accounts, selection: $draft.accountIDs)
                FilterSelectionSection(title: "Category", options: catalog.categories, selection: $draft.categoryIDs)
                FilterSelectionSection(title: "Economic type", options: catalog.economicTypes, selection: $draft.economicTypes)
                FilterSelectionSection(
                    title: "Economic source",
                    options: catalog.economicSources,
                    selection: $draft.economicSourceIDs,
                    footer: "Where the money came from economically, whoever handed it over."
                )

                Section("Amount") {
                    TextField("Minimum", text: $minimumAmount)
                        .keyboardType(.decimalPad)
                    TextField("Maximum", text: $maximumAmount)
                        .keyboardType(.decimalPad)
                }

                FilterSelectionSection(title: "Currency", options: catalog.currencies, selection: $draft.currencies)
                FilterSelectionSection(title: "Source", options: catalog.sources, selection: $draft.sourceIDs)

                Section {
                    DisclosureGroup("Advanced") {
                        FilterSelectionRows(options: catalog.statuses, selection: $draft.statuses)
                        FilterSelectionRows(options: catalog.provenanceValues, selection: $draft.provenanceValues)
                    }
                } footer: {
                    Text("Status and provenance describe evidence quality, not ordinary spending categories.")
                }

                if hasSelections {
                    Section {
                        Button("Clear all", role: .destructive) { clear() }
                    }
                }
            }
            .navigationTitle("Transaction filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                }
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
        draft.dateRange = selectedDateRange
        draft.minimumAmountMinor = Self.minorUnits(minimumAmount)
        draft.maximumAmountMinor = Self.minorUnits(maximumAmount)
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
        draft.sort = sort
        dateMode = .all
        minimumAmount = ""
        maximumAmount = ""
    }

    private static func majorText(_ minor: Int64?) -> String {
        guard let minor else { return "" }
        return NSDecimalNumber(value: Double(minor) / 100).stringValue
    }

    private static func minorUnits(_ value: String) -> Int64? {
        let normalized = value.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        var scaled = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else { return nil }
        return Int64(truncating: NSDecimalNumber(decimal: rounded))
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

    var body: some View {
        Section {
            DisclosureGroup {
                FilterSelectionRows(options: options, selection: $selection)
            } label: {
                HStack {
                    Text(title)
                    Spacer()
                    if !selection.isEmpty {
                        Text(selection.count.formatted())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }
}

private struct FilterSelectionRows: View {
    let options: [HistoryFilterOption]
    @Binding var selection: Set<String>

    var body: some View {
        if options.isEmpty {
            Text("No options").foregroundStyle(.secondary)
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
                        if selection.contains(option.id) {
                            Image(systemName: "checkmark").foregroundStyle(Theme.Role.accent)
                        }
                    }
                }
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
