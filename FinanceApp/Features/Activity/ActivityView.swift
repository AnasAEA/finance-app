import SwiftUI

/// The canonical event and work surface. Operational transactions and the
/// private archive share one searchable presentation without becoming one
/// ledger; bank evidence stays a separate review queue underneath the second
/// segment and only becomes economic activity after a decision.
struct ActivityView: View {
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        return VStack(spacing: 0) {
            Picker("Activity section", selection: $navigation.activitySection) {
                ForEach(ActivitySection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Metric.screenPadding)
            .padding(.top, 6)
            .padding(.bottom, 8)
            .accessibilityIdentifier(RouteID.activitySection)

            switch navigation.activitySection {
            case .transactions:
                HistoryBrowserView()
            case .toReview:
                NeedsReviewView()
            }
        }
        .background(Theme.Surface.background)
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    navigation.isAddingTransaction = true
                } label: {
                    Label("Add transaction", systemImage: "plus")
                }
                .accessibilityIdentifier(RouteID.activityAdd)
                .accessibilityLabel("Add transaction")
            }
        }
    }
}

/// User-facing composition of the bank evidence that is waiting for economic
/// meaning. The evidence and expected-payment state machines remain separate;
/// this list does not manufacture a shared status model.
struct ActivityReviewSections: Equatable {
    let needsReview: [SyncedObservationItem]
    let pending: [SyncedObservationItem]

    init(snapshot: FinanceAppSnapshot) {
        needsReview = snapshot.syncedObservations
            .filter { $0.resolution == .unreviewed }
            .sorted { $0.inboxPriority < $1.inboxPriority }
        pending = snapshot.currentPendingSyncedObservations
            .sorted { $0.observedAt > $1.observedAt }
    }

    var isEmpty: Bool { needsReview.isEmpty && pending.isEmpty }
}

/// Copy and amount treatment for provisional evidence. Kept separate from the
/// row so tests can pin that zero remains visible without being styled as a
/// positive cash movement.
enum PendingObservationPresentation {
    static let sectionExplanation =
        "No action needed · Waiting for your bank to complete these payments."
    static let rowStatus = "Pending"

    static func showsAmountSign(_ amount: Amount) -> Bool {
        !amount.isZero
    }
}

struct NeedsReviewView: View {
    @Environment(FinanceStore.self) private var store

    var body: some View {
        Self.content(store: store)
    }

    /// One body pass, one attention snapshot. `attentionPresentation` samples
    /// the clock and recomposes on every read, so a list that reached for it
    /// once per section paid for the whole evaluation each time and could
    /// cross the 48h freshness boundary halfway down itself. Taking the store
    /// as a parameter is what lets a test build this exact list.
    static func content(store: FinanceStore) -> some View {
        let sections = store.attentionPresentation.activity
        return List {
            if sections.isEmpty {
                ContentUnavailableView(
                    "Nothing needs review",
                    systemImage: "checkmark.circle",
                    description: Text("New bank activity waits here until you decide what it means.")
                )
                .listRowBackground(Color.clear)
            }
            if !sections.decisions.isEmpty {
                Section {
                    ForEach(sections.decisions) { item in
                        NavigationLink {
                            destination(item.destination)
                        } label: {
                            decisionRow(item)
                        }
                        .accessibilityIdentifier(ActivityID.decision(item.id))
                    }
                } header: {
                    Text("Needs a Decision")
                }
            }

            if !sections.paymentsToConfirm.isEmpty {
                Section("Payments to Confirm") {
                    ForEach(sections.paymentsToConfirm) { item in
                        NavigationLink {
                            destination(item.destination)
                        } label: {
                            decisionRow(item)
                        }
                        .accessibilityIdentifier(ActivityID.payment(item.id))
                    }
                }
            }

            if !sections.pending.isEmpty {
                Section {
                    ForEach(sections.pending) { item in
                        PendingObservationRow(item: item)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pending")
                        Text(PendingObservationPresentation.sectionExplanation)
                            .font(.caption2)
                            .textCase(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(ActivityID.pendingSection)
                }
            }

            if !sections.limitations.isEmpty {
                Section {
                    ForEach(sections.limitations) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(item.title).font(.subheadline.weight(.semibold))
                                Spacer(minLength: 8)
                                if let amount = item.amount {
                                    MoneyText(amount: amount, size: 16, showsSign: true)
                                }
                            }
                            Text(item.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 3)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(ActivityID.limitation(item.id))
                    }
                } header: {
                    Text("Known Limitations")
                } footer: {
                    Text("Nothing to decide here.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, Theme.Metric.floatingTabBarClearance, for: .scrollContent)
        .accessibilityIdentifier(RouteID.activityReviewQueue)
    }

    private static func decisionRow(_ item: ActivityAttentionRow) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body).fixedSize(horizontal: false, vertical: true)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            MoneyText(amount: item.amount, size: 17, weight: .medium, showsSign: true)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private static func destination(_ route: AttentionDestination) -> some View {
        switch route {
        case let .observationReview(id):
            ObservationReviewView(observationID: id)
        case let .expectedPayment(payment):
            ExpectedPaymentDetailView(payment: payment)
        case .planFundingNeeded:
            FundingNeededView()
        case .banksAndSync:
            BankSyncView()
        case let .account(id):
            AccountDetailView(accountID: id)
        case .activityToReview:
            EmptyView()
        }
    }
}

/// Current provider snapshot evidence. Deliberately not a link or a button:
/// pending rows carry no durable identity and offer no economic action.
private struct PendingObservationRow: View {
    let item: ActivityPendingRow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    labels
                    amountAndStatus
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "clock")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                    labels
                    Spacer(minLength: 8)
                    amountAndStatus
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(ActivityID.pending(item.id))
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(item.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let day = item.day {
                Text(day.formatted(.dateTime.day().month().year()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var amountAndStatus: some View {
        VStack(
            alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing,
            spacing: 3
        ) {
            MoneyText(
                amount: item.amount,
                size: 16,
                weight: .medium,
                showsSign: PendingObservationPresentation.showsAmountSign(item.amount),
                colorBySign: item.amount.isZero
            )
            Text(PendingObservationPresentation.rowStatus)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TransactionRow: View {
    let row: ActivityRow
    /// Settles a recurring commitment. Shown as one quiet word, because an
    /// ordinary row is still an ordinary row: reconciliation is a detail about
    /// this payment, not a second thing that happened.
    var isMatchedToRecurring = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityLayout
            } else {
                compactLayout
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens transaction details")
    }

    private var compactLayout: some View {
        HStack(spacing: 12) {
            rowIcon
            rowLabels

            Spacer(minLength: 8)
            rowAmount
        }
    }

    private var accessibilityLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                rowIcon
                rowLabels
            }
            HStack {
                Spacer(minLength: 46)
                rowAmount
            }
        }
    }

    /// Decoration. The row already states itself in one sentence, so the
    /// symbol adds nothing to hear — and left visible it put one element named
    /// after the SF Symbol into the tree for every row on the screen.
    private var rowIcon: some View {
        Image(systemName: row.symbolName)
            .font(.system(size: 15))
            .foregroundStyle(Theme.Role.accent)
            .frame(width: 34, height: 34)
            .background(Theme.Role.accent.opacity(0.1), in: Circle())
            .accessibilityHidden(true)
    }

    private var rowLabels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.title)
                .font(.body)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .strikethrough(row.isReversed, color: .secondary)
            Text(row.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            if let owned = row.ownedPortion {
                Text("\(owned.formatted()) yours · the rest passes through")
                    .font(.caption2)
                    .foregroundStyle(Theme.Role.caution)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            }
            if isMatchedToRecurring {
                Text("Matched to recurring payment")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
        }
    }

    private var rowAmount: some View {
        VStack(alignment: .trailing, spacing: 2) {
            MoneyText(amount: row.amount, size: 17, weight: .medium,
                      showsSign: true, colorBySign: true)
                .opacity(row.isReversed ? 0.4 : 1)
            if let note = row.trailingNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(row.isReversed ? Theme.Role.caution : .secondary)
            }
        }
    }

    var accessibilityLabel: String {
        let amount = row.amount.magnitude.accessibleDescription()
        switch row.flow {
        case .spending:
            return "\(row.title), \(amount), paid from \(row.primaryAccountLabel ?? "account")"
        case .income:
            let source = row.incomeSourceLabel.map { ", income source \($0)" } ?? ""
            return "\(row.title), \(amount), received in \(row.primaryAccountLabel ?? "account")\(source)"
        case .movement:
            return "\(row.title), \(amount), from \(row.primaryAccountLabel ?? "account") to \(row.secondaryAccountLabel ?? "account")"
        case .neutral:
            return "\(row.title), \(amount), account \(row.primaryAccountLabel ?? "unknown")"
        }
    }
}

struct TransactionDetailView: View {
    let row: ActivityRow
    let date: CalendarDay

    @Environment(FinanceStore.self) private var store
    @State private var isPicking = false
    @State private var failure: AppReconciliationError?

    /// One live read per composition: whether this row is reconciled and, if
    /// not, what could match it are two halves of one answer about one day.
    var body: some View {
        let snapshot = store.snapshot
        let reconciliation = snapshot.reconciliations[row.id]
        let candidates = reconciliation == nil ? store.matches(forTransaction: row.id) : []
        return content(snapshot, reconciliation, candidates)
    }

    private func content(
        _ snapshot: FinanceAppSnapshot,
        _ reconciliation: ReconciliationSummary?,
        _ candidates: [PaymentMatch]
    ) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title).font(.headline)
                    MoneyText(amount: row.amount, size: 34, weight: .bold,
                              showsSign: true, colorBySign: true)
                }
                .padding(.vertical, 6)
            }

            Section("Transaction") {
                LabeledContent("Type", value: row.transactionTypeLabel)
                LabeledContent("Date", value: date.formatted(date: .long, time: .omitted))
                if let category = row.categoryLabel {
                    LabeledContent("Category", value: category)
                }
                if let counterparty = row.counterparty {
                    LabeledContent(row.flow == .income ? "From / payer" : "Merchant", value: counterparty)
                }
            }

            Section("Accounts") {
                if let primary = row.primaryAccountLabel {
                    LabeledContent(primaryAccountLabel, value: primary)
                }
                if let secondary = row.secondaryAccountLabel {
                    LabeledContent("To", value: secondary)
                }
            }

            if let source = row.incomeSourceLabel {
                Section("Income") {
                    LabeledContent("Income source", value: source)
                }
            }

            if let reconciliation {
                Section {
                    LabeledContent("Recurring", value: reconciliation.ruleName)
                    LabeledContent("Expected") {
                        Text(reconciliation.expectedDate.formatted(.dateTime.day().month(.wide)))
                    }
                    LabeledContent("Paid") {
                        Text(reconciliation.actualDate.formatted(.dateTime.day().month(.wide)))
                    }
                    if let account = reconciliation.accountLabel {
                        LabeledContent("Account", value: account)
                    }
                    Button(role: .destructive) {
                        act {
                            try store.unmatchExpectedPayment(
                                id: expectedPaymentID(snapshot, for: reconciliation)
                            )
                        }
                    } label: {
                        Label("Remove match", systemImage: "arrow.uturn.backward")
                    }
                } header: {
                    Text("Recurring payment")
                } footer: {
                    Text(reconciliation.amountDifferenceAccepted
                         ? "The amounts differ and that difference was accepted deliberately. This payment is counted once."
                         : "This payment settles the expected one, so it is counted once rather than twice.")
                }
            } else if !candidates.isEmpty {
                Section {
                    Button {
                        isPicking = true
                    } label: {
                        Label("Matches expected payment", systemImage: "link")
                    }
                } footer: {
                    Text("Link this to a recurring payment the plan is still expecting, so it is not counted twice.")
                }
            }

            if let note = row.note {
                Section("Notes") { Text(note) }
            }
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isPicking) {
            MatchPickerView(
                title: "Expected payments",
                explanation: "Choose the expected payment this transaction settles.",
                matches: candidates,
                side: .expected
            ) { match, acceptsDifference in
                try store.matchPayment(
                    expectedPaymentID: match.expectedPaymentID,
                    transactionID: match.transactionID,
                    acceptingAmountDifference: acceptsDifference
                )
            }
        }
        .alert(
            "Not done",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) { failure = nil }
        } message: { error in
            Text(error.message)
        }
    }

    /// The occurrence this transaction settles, found by asking the snapshot
    /// rather than rebuilding an id from a name and a date.
    private func expectedPaymentID(
        _ snapshot: FinanceAppSnapshot, for reconciliation: ReconciliationSummary
    ) -> String {
        snapshot.expectedPayments
            .first { $0.status.matchedTransactionID == row.id }?
            .id ?? ""
    }

    private func act(_ work: () throws -> Void) {
        do { try work() } catch let error as AppReconciliationError {
            failure = error
        } catch {
            failure = .persistenceFailed(String(describing: error))
        }
    }

    private var primaryAccountLabel: String {
        switch row.flow {
        case .spending: "Paid from"
        case .income: "Received in"
        case .movement: "From"
        case .neutral: "Account"
        }
    }
}

#Preview {
    NavigationStack { ActivityView() }
        .environment(FinanceStore.preview())
        .environment(AppNavigation())
}
