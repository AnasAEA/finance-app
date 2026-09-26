import SwiftUI

/// The canonical event and work surface. Operational transactions and the
/// private archive share one searchable presentation without becoming one
/// ledger. Synced bank movements are visible before review, with their bank
/// status; the second segment collects the decisions still needed.
struct ActivityView: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(FinanceStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        @Bindable var navigation = navigation
        let presentation = store.currentPresentation()
        let sections = presentation.attention.activity
        let reviewCount = sections.decisions.count + sections.paymentsToConfirm.count
        let tabLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: Theme.Space.xl))
        return VStack(spacing: 0) {
            tabLayout {
                ForEach(ActivitySection.allCases) { section in
                    Button {
                        navigation.activitySection = section
                    } label: {
                        VStack(spacing: Theme.Space.sm) {
                            HStack(spacing: 6) {
                                Text(section.title).font(Theme.TypeStyle.action)
                                if section == .toReview, reviewCount > 0 {
                                    Text(reviewCount.formatted()).font(.caption.monospacedDigit())
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Theme.Surface.inset, in: Capsule())
                                }
                                if dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                            }
                            .frame(minHeight: 32)
                            Rectangle().fill(navigation.activitySection == section
                                             ? Theme.Role.accent : Color.clear).frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(navigation.activitySection == section ? Theme.Role.accent : .secondary)
                    .accessibilityIdentifier("activity.section.\(section.rawValue)")
                    .accessibilityLabel(section.title)
                    .accessibilityValue(section == .toReview && reviewCount > 0
                                        ? "\(reviewCount) items need a decision" : "")
                    .accessibilityAddTraits(navigation.activitySection == section ? .isSelected : [])
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
            }
            .padding(.horizontal, Theme.Metric.screenPadding)
            .padding(.top, Theme.Space.sm)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.Surface.separator).frame(height: 0.5) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(RouteID.activitySection)

            switch navigation.activitySection {
            case .transactions:
                HistoryBrowserView(snapshot: presentation.snapshot)
            case .toReview:
                NeedsReviewView.content(sections: sections, observations: presentation.snapshot.syncedObservations,
                                        reduceMotion: reduceMotion)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: navigation.activitySection)
        .background(Theme.Surface.background)
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Self.content(store: store, reduceMotion: reduceMotion)
    }

    /// One body pass, one attention snapshot. `attentionPresentation` samples
    /// the clock and recomposes on every read, so a list that reached for it
    /// once per section paid for the whole evaluation each time and could
    /// cross the 48h freshness boundary halfway down itself. Taking the store
    /// as a parameter is what lets a test build this exact list.
    static func content(store: FinanceStore, reduceMotion: Bool = true) -> some View {
        let presentation = store.currentPresentation()
        return content(sections: presentation.attention.activity,
                       observations: presentation.snapshot.syncedObservations, reduceMotion: reduceMotion)
    }

    static func content(sections: ActivityAttentionPresentation, observations: [SyncedObservationItem] = [],
                        reduceMotion: Bool = true) -> some View {
        let quickIDs = Set(observations.filter(\.canQuicklyCategorize).map(\.id))
        let quick = sections.decisions.filter { quickIDs.contains($0.id) }
        let decisions = sections.decisions.filter { !quickIDs.contains($0.id) }
        return List {
            if !sections.decisions.isEmpty {
                Section {
                    NavigationLink { TrustedRulesView() } label: {
                        Label("Rules for repeat merchants", systemImage: "checkmark.shield")
                            .font(Theme.TypeStyle.action).foregroundStyle(Theme.Role.accent)
                    }
                    .listRowBackground(Theme.Surface.background)
                } footer: {
                    Text("Approve a merchant rule once to reduce future reviews.")
                }
            }
            if !quick.isEmpty {
                Section {
                    ForEach(quick) { item in
                        NavigationLink {
                            ExpenseCategorizationView(draft: ExpenseReviewDraft(observationID: item.id, label: item.title))
                        } label: { decisionRow(item) }
                        .listRowBackground(Theme.Surface.background)
                        .accessibilityIdentifier(ActivityID.decision(item.id))
                    }
                } header: {
                    ActivitySectionHeading(title: "Quick categorization", count: quick.count,
                                           detail: "Choose a category and confirm the purchase.")
                }
            }
            if sections.isEmpty {
                ContentUnavailableView(
                    "Nothing needs review",
                    systemImage: "checkmark.circle",
                    description: Text("New bank activity waits here until you decide what it means.")
                )
                .listRowBackground(Color.clear)
            }
            if !decisions.isEmpty {
                Section {
                    ForEach(decisions) { item in
                        NavigationLink {
                            destination(item.destination)
                        } label: {
                            decisionRow(item)
                        }
                        .listRowBackground(Theme.Surface.background)
                        .accessibilityIdentifier(ActivityID.decision(item.id))
                    }
                } header: {
                    ActivitySectionHeading(title: "Needs a Decision", count: decisions.count,
                                           detail: "Decide what these bank movements mean.")
                }
            }

            if !sections.paymentsToConfirm.isEmpty {
                Section {
                    ForEach(sections.paymentsToConfirm) { item in
                        NavigationLink {
                            destination(item.destination)
                        } label: {
                            decisionRow(item)
                        }
                        .listRowBackground(Theme.Surface.background)
                        .accessibilityIdentifier(ActivityID.payment(item.id))
                    }
                } header: {
                    ActivitySectionHeading(title: "Payments to Confirm", count: sections.paymentsToConfirm.count)
                }
            }

            if !sections.pending.isEmpty {
                Section {
                    ForEach(sections.pending) { item in
                        PendingObservationRow(item: item)
                    }
                } header: {
                    ActivitySectionHeading(title: "Pending", count: sections.pending.count,
                                           detail: PendingObservationPresentation.sectionExplanation)
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
                    ActivitySectionHeading(title: "Known Limitations", count: sections.limitations.count)
                } footer: {
                    Text("Nothing to decide here.")
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .environment(\.defaultMinListHeaderHeight, 12)
        .financeList()
        .contentMargins(.bottom, Theme.Metric.floatingTabBarClearance, for: .scrollContent)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: sections.decisions.map(\.id))
        .accessibilityIdentifier(RouteID.activityReviewQueue)
    }

    /// What the bank called it, where and when — and then what the decision
    /// actually is.
    ///
    /// The last two lines are the point. Without them this queue stated a
    /// merchant, an account and a date for every row, so a cash withdrawal
    /// that is not spending at all, a charge that settles a recurring payment,
    /// and a debit whose real merchant is unresolved were one shape repeated,
    /// ordered by a priority the person could not see. Each had to be opened
    /// to find out which it was.
    private static func decisionRow(_ item: ActivityAttentionRow) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                    Text(ActivityTextPresentation.readableTitle(item.title)).font(Theme.TypeStyle.body.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Space.sm)
                    MoneyText(amount: item.amount, size: 18, weight: .semibold, showsSign: true)
                }
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(ActivityTextPresentation.readableTitle(item.title)).font(Theme.TypeStyle.body.weight(.semibold))
                    MoneyText(amount: item.amount, size: 18, weight: .semibold, showsSign: true)
                }
            }
            Text(item.subtitle).font(Theme.TypeStyle.metadata).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let decision = item.decision {
                Label(decision, systemImage: "arrow.turn.down.right")
                    .font(Theme.TypeStyle.supporting.weight(.medium))
                    .foregroundStyle(Theme.Role.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caution = item.caution {
                Label(caution.label, systemImage: "exclamationmark.triangle")
                    .font(Theme.TypeStyle.metadata.weight(.medium))
                    .foregroundStyle(Theme.Role.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Space.sm)
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
        // Destinations no Activity row produces. The projection's risks
        // belong to Home and Plan; Activity links evidence and payments.
        case .activityToReview, .insightsMonthVerification, .planUpcoming,
             .planSafetyReserve:
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let row: ActivityRow
    let date: CalendarDay

    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var isPicking = false
    @State private var failure: AppReconciliationError?
    @State private var confirmsRemoval = false
    /// Why the last removal attempt was refused. Set only by a refusal — a
    /// successful removal leaves this alone and closes the screen instead.
    @State private var removalFailure: AppRemovalError?

    /// One live read per composition: whether this row is reconciled, what
    /// could match it, and whether it can be removed are all answers about the
    /// same row at the same moment, and a screen that sampled them separately
    /// could offer to remove something it had just described as matched.
    var body: some View {
        let snapshot = store.snapshot
        let reconciliation = snapshot.reconciliations[row.id]
        let candidates = reconciliation == nil ? store.matches(forTransaction: row.id) : []
        return content(
            snapshot,
            reconciliation,
            candidates,
            store.removalBlocker(forTransaction: row.id),
            store.linkedEvidence(forTransaction: row.id)
        )
    }

    private func content(
        _ snapshot: FinanceAppSnapshot,
        _ reconciliation: ReconciliationSummary?,
        _ candidates: [PaymentMatch],
        _ removalBlocker: AppRemovalError?,
        _ evidence: [TransactionEvidenceSummary]
    ) -> some View {
        FinancePage {
            FinanceSection {
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.title).font(Theme.TypeStyle.editorial)
                        .fixedSize(horizontal: false, vertical: true)
                    MoneyText(amount: row.amount, size: 44, weight: .medium, showsSign: true)
                    Text(date.formatted(date: .long, time: .omitted))
                        .font(Theme.TypeStyle.supporting).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }

            FinanceSection("Details") {
                LabeledContent("Type", value: row.transactionTypeLabel)
                if let category = row.categoryLabel {
                    LabeledContent("Category", value: category)
                }
                if let counterparty = row.counterparty {
                    LabeledContent(row.flow == .income ? "From / payer" : "Merchant", value: counterparty)
                }
            }

            FinanceSection("Accounts") {
                if let primary = row.primaryAccountLabel {
                    LabeledContent(primaryAccountLabel, value: primary)
                }
                if let secondary = row.secondaryAccountLabel {
                    LabeledContent("To", value: secondary)
                }
            }

            if let source = row.incomeSourceLabel {
                FinanceSection("Income") {
                    LabeledContent("Income source", value: source)
                }
            }

            if let reconciliation {
                FinanceSection {
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
                FinanceSection {
                    Button {
                        isPicking = true
                    } label: {
                        Label("Matches expected payment", systemImage: "link")
                    }
                } footer: {
                    Text("Link this to a recurring payment the plan is still expecting, so it is not counted twice.")
                }
            }

            sourceSection(evidence)

            if let note = row.note {
                FinanceSection("Notes") { Text(note) }
            }

            Divider()
            removalSection(removalBlocker)
        }
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove this transaction?",
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive, action: remove)
            Button("Cancel", role: .cancel) {}
        } message: {
            // Names the row being removed, so a confirmation that arrived
            // after a mis-tap is recognisably about the wrong thing.
            Text("\(row.title) · \(row.amount.formatted()) · \(date.formatted(date: .abbreviated, time: .omitted))")
        }
        .alert(
            "Not removed",
            isPresented: Binding(
                get: { removalFailure != nil }, set: { if !$0 { removalFailure = nil } }
            ),
            presenting: removalFailure
        ) { _ in
            Button("OK", role: .cancel) { removalFailure = nil }
        } message: { problem in
            if let suggestion = problem.recoverySuggestion {
                Text("\(problem.message)\n\n\(suggestion)")
            } else {
                Text(problem.message)
            }
        }
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

    /// Where this transaction came from, when evidence says so.
    ///
    /// Absent entirely when there is no link. That is not a missing state to
    /// fill in: a row somebody typed has no external source, and a section
    /// saying so would invite the reader to look for one.
    ///
    /// Each row opens the evidence screen the app already owns. That screen
    /// reads the observation and offers actions only while it is still
    /// unreviewed, so arriving from here cannot reopen a decision that has
    /// been made — it shows the evidence and the state it was left in.
    @ViewBuilder
    private func sourceSection(_ evidence: [TransactionEvidenceSummary]) -> some View {
        if !evidence.isEmpty {
            FinanceSection {
                ForEach(evidence) { item in
                    NavigationLink {
                        ObservationReviewView(observationID: item.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            let layout = dynamicTypeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.xs))
                                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Theme.Space.sm))
                            layout {
                                Label(item.title, systemImage: "arrow.up.right")
                                    .font(Theme.TypeStyle.card)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Theme.Space.sm) }
                                MoneyText(amount: item.amount, size: 17, weight: .medium,
                                          showsSign: true)
                            }
                            Text(item.detailLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, Theme.Space.sm)
                        .frame(minHeight: Theme.Metric.minimumTarget)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.accessibilityLabel)
                    }
                    .accessibilityIdentifier(ActivityID.evidence(item.id))
                }
            } header: {
                Text(TransactionEvidenceSummary.sectionTitle)
                    .accessibilityIdentifier(ActivityID.evidenceSection)
            } footer: {
                Text(TransactionEvidenceSummary.footer)
            }
        }
    }

    /// Removal, offered or explained — never hidden.
    ///
    /// A blocked row keeps the section and says why, because the question
    /// "can I delete this?" deserves an answer either way: an action that is
    /// simply absent reads as an app that cannot do it at all, and the
    /// person would go looking for it somewhere else.
    ///
    /// `notFound` is the exception. It means the row is already gone from
    /// under this screen, and offering to explain that is noise on a screen
    /// that is about to be dismissed anyway.
    @ViewBuilder
    private func removalSection(_ blocker: AppRemovalError?) -> some View {
        switch blocker {
        case .none:
            FinanceSection {
                Button(role: .destructive) {
                    confirmsRemoval = true
                } label: {
                    Label("Remove transaction", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier(ActivityID.removeTransaction)
            } footer: {
                Text("Removes it from your records. Balances and totals are worked out again without it.")
            }
        case .notFound:
            EmptyView()
        case let .some(blocker):
            FinanceSection {
                VStack(alignment: .leading, spacing: 6) {
                    Label(blocker.message, systemImage: "lock")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let suggestion = blocker.recoverySuggestion {
                        Text(suggestion)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(ActivityID.removeBlocked)
            } header: {
                Text("Removing")
            }
        }
    }

    /// Asks the store to remove it, and closes only if it did.
    ///
    /// The store re-checks eligibility itself, so a row that became linked
    /// while this screen was open is refused here rather than removed. On
    /// success there is nothing left for this screen to show, and the list
    /// behind it has already recomputed from the store's own published state.
    private func remove() {
        do {
            try store.deleteActivityRow(id: row.id)
            dismiss()
        } catch let problem as AppRemovalError {
            removalFailure = problem
        } catch {
            removalFailure = .persistenceFailed(String(describing: error))
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
