import SwiftUI

/// Development-fed review surface. It deliberately starts with evidence and a
/// question; nothing on this screen is economic truth until an action succeeds.
struct BankInboxView: View {
    @Environment(FinanceStore.self) private var store

    var body: some View {
        Self.content(store: store)
    }

    /// One live read per composition. Each partition below asks the same
    /// question of the same evidence; reading the store once per partition
    /// would let a list built across local midnight mix two civil days.
    /// Taking the store as a parameter is what lets a test build this list.
    static func content(store: FinanceStore) -> some View {
        let snapshot = store.snapshot
        let observations = snapshot.syncedObservations
        let riskyItems = observations.filter { $0.inboxPriority == .risky }
        let highConfidenceItems = observations.filter {
            $0.inboxPriority == .highConfidenceSuggestion
        }
        let judgmentItems = observations.filter { $0.inboxPriority == .needsHumanJudgment }
        let provisional = observations.filter {
            $0.resolution == .provisional || $0.resolution == .ineligible
        }
        let resolved = observations.filter {
            $0.resolution.isResolved && $0.inboxPriority == .reviewed
        }
        return List {
            Section {
                NavigationLink {
                    TrustedRulesView()
                } label: {
                    LabeledContent("Trusted rules") {
                        Text(snapshot.trustedRules.count, format: .number)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Rules begin as suggestions. Automatic resolution requires separate explicit approval, and risky economics always stay with you.")
            }

            if riskyItems.isEmpty && highConfidenceItems.isEmpty
                && judgmentItems.isEmpty && provisional.isEmpty && resolved.isEmpty {
                ContentUnavailableView(
                    "No synced activity",
                    systemImage: "tray",
                    description: Text("New booked account evidence will wait here for review.")
                )
                .listRowBackground(Color.clear)
            }

            if !riskyItems.isEmpty {
                Section {
                    ForEach(riskyItems) { item in
                        NavigationLink {
                            ObservationReviewView(observationID: item.id)
                        } label: {
                            SyncedObservationRow(item: item)
                        }
                    }
                } header: {
                    Text("Risky or unresolved")
                } footer: {
                    Text("Transfers, cash, FX, financing, refunds, unusual credits, ownership, and cross-provider ambiguity always require your judgment.")
                }
            }

            if !highConfidenceItems.isEmpty {
                Section {
                    ForEach(highConfidenceItems) { item in
                        NavigationLink {
                            ObservationReviewView(observationID: item.id)
                        } label: {
                            SyncedObservationRow(item: item)
                        }
                    }
                } header: {
                    Text("High-confidence suggestions")
                } footer: {
                    Text("These suggestions explain the exact prior confirmation or deterministic match behind them. They remain proposals until resolved.")
                }
            }

            if !judgmentItems.isEmpty {
                Section {
                    ForEach(judgmentItems) { item in
                        NavigationLink {
                            ObservationReviewView(observationID: item.id)
                        } label: {
                            SyncedObservationRow(item: item)
                        }
                    }
                } header: {
                    Text("Needs your judgment")
                } footer: {
                    Text("A bank debit or credit is account evidence, not a category. Nothing here changes spending or income until you decide.")
                }
            }

            if !snapshot.providerBalanceStatuses.isEmpty {
                Section {
                    ForEach(snapshot.providerBalanceStatuses) { balance in
                        NavigationLink {
                            ProviderBalanceDetailView(balanceID: balance.id)
                        } label: {
                            ProviderBalanceRow(balance: balance)
                        }
                    }
                } header: {
                    Text("Balance evidence")
                } footer: {
                    Text("Provider balances are compared with the ledger. A difference starts reconciliation; it never silently corrects the ledger.")
                }
            }

            if !provisional.isEmpty {
                Section {
                    ForEach(provisional) { item in
                        NavigationLink {
                            ObservationReviewView(observationID: item.id)
                        } label: {
                            SyncedObservationRow(item: item)
                        }
                    }
                } header: {
                    Text("Provisional evidence")
                } footer: {
                    Text("Pending and rejected rows are retained as evidence but cannot create a durable actual.")
                }
            }

            if !resolved.isEmpty {
                Section("Reviewed") {
                    ForEach(resolved) { item in
                        NavigationLink {
                            ObservationReviewView(observationID: item.id)
                        } label: {
                            SyncedObservationRow(item: item)
                        }
                    }
                }
            }
        }
        .navigationTitle("Bank Inbox")
    }
}

private struct SyncedObservationRow: View {
    let item: SyncedObservationItem
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    labels
                    amount
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                        .frame(width: 32, height: 32)
                        .background(tint.opacity(0.1), in: Circle())
                    labels
                    Spacer(minLength: 8)
                    amount
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.displayMerchant)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(item.providerName) · \(item.providerAccountName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let suggestion = item.primarySuggestion {
                Text(suggestion.title)
                    .font(.caption2)
                    .foregroundStyle(suggestion.kind == .merchantUnresolved ? Theme.Role.caution : Theme.Role.accent)
                    .fixedSize(horizontal: false, vertical: true)
            } else if item.resolution == .linked {
                Text("Linked to transaction")
                    .font(.caption2)
                    .foregroundStyle(Theme.Role.positive)
            } else if item.resolution == .noEconomicEffect {
                Text("No economic effect")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var amount: some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 3) {
            MoneyText(amount: item.amount.magnitude, size: 17, weight: .semibold)
            Text(item.status.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var symbol: String {
        switch item.resolution {
        case .linked: "link.circle.fill"
        case .noEconomicEffect: "checkmark.circle.fill"
        case .provisional: "clock"
        case .ineligible: "xmark.circle"
        default: "building.columns"
        }
    }

    private var tint: Color {
        switch item.resolution {
        case .linked, .noEconomicEffect: Theme.Role.positive
        case .provisional, .ineligible: Theme.Role.caution
        default: Theme.Role.accent
        }
    }
}

struct ObservationReviewView: View {
    let observationID: String

    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var failure: BankReviewError?
    @State private var pendingExpenseLabel: String?
    @State private var pendingRelatedObservationID: String?
    @State private var pendingExpectedPaymentID: String?

    /// One live read per composition: the observation, the related evidence it
    /// names and the counterpart accounts must all describe one civil day.
    var body: some View {
        content(store.snapshot)
    }

    private func content(_ snapshot: FinanceAppSnapshot) -> some View {
        let item = snapshot.syncedObservations.first { $0.id == observationID }
        let existingMatches = item?.suggestions.filter { $0.kind == .existingTransaction } ?? []
        let recurringMatches = item?.suggestions.filter { $0.kind == .recurring } ?? []
        let crossProviderMatch = item?.suggestions.first {
            $0.kind == .crossProvider && $0.relatedObservationID != nil
        }
        return Group {
            if let item {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.displayMerchant).font(.headline)
                            MoneyText(
                                amount: item.amount,
                                size: 34,
                                weight: .bold,
                                showsSign: true,
                                colorBySign: false
                            )
                        }
                        .padding(.vertical, 6)
                    }

                    Section("Provider evidence") {
                        LabeledContent("Provider account", value: "\(item.providerName) · \(item.providerAccountName)")
                        LabeledContent("Status", value: item.status.displayName)
                        if let merchant = item.observedMerchant {
                            LabeledContent("Observed merchant", value: merchant)
                        }
                        if let code = item.bankTransactionCode {
                            LabeledContent("Transaction code", value: code)
                        }
                        if let email = item.merchantEmail {
                            LabeledContent("Merchant email", value: email)
                        }
                        if let raw = item.rawMerchantText, raw != item.observedMerchant {
                            evidenceText("Raw provider text", raw)
                        }
                        if let remittance = item.remittance, remittance != item.rawMerchantText {
                            evidenceText("Remittance", remittance)
                        }
                    }

                    dates(item)

                    if !item.suggestions.isEmpty {
                        Section("Suggested interpretation") {
                            ForEach(item.suggestions) { suggestion in
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(suggestion.title, systemImage: suggestionSymbol(suggestion.kind))
                                        .foregroundStyle(suggestion.kind == .merchantUnresolved
                                                         ? Theme.Role.caution : .primary)
                                    if let explanation = suggestion.explanation {
                                        Text(explanation)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if suggestion.kind == .trustedRule {
                                        Text(suggestion.automaticResolutionEligible
                                             ? "Explicitly approved automatic rule"
                                             : "Suggestion only — confirmation required")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(suggestion.automaticResolutionEligible
                                                             ? Theme.Role.positive : Theme.Role.accent)
                                    }
                                }
                            }
                        }
                    }

                    if let conflict = item.duplicateConflict {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(
                                    "This may already be accounted for",
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.headline)
                                .foregroundStyle(Theme.Role.caution)
                                Text(conflict.context)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                                ForEach(conflict.transactionIDs, id: \.self) { transactionID in
                                    Label(activityTitle(snapshot, transactionID), systemImage: "link")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let relatedID = conflict.relatedObservationID,
                                   let related = snapshot.syncedObservations.first(where: {
                                       $0.id == relatedID
                                   }) {
                                    Label(
                                        "Related provider evidence: \(related.displayMerchant)",
                                        systemImage: "arrow.triangle.branch"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("review.duplicate.warning")
                        } footer: {
                            Text(conflict.warning)
                        }
                    }

                    if let reason = item.trustedAutomationReviewReason {
                        Section {
                            Label(reason, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(Theme.Role.caution)
                        } footer: {
                            Text("No automatic transaction was created. Review this activity and choose its meaning once.")
                        }
                    }

                    if item.resolution == .unreviewed {
                        actions(
                            item, snapshot,
                            existingMatches: existingMatches,
                            recurringMatches: recurringMatches,
                            crossProviderMatch: crossProviderMatch
                        )
                    } else {
                        Section {
                            LabeledContent("Review state", value: resolutionLabel(item.resolution))
                        } footer: {
                            Text("The provider evidence remains unchanged and available here after review.")
                        }
                    }
                }
            } else {
                ContentUnavailableView("Item unavailable", systemImage: "exclamationmark.triangle")
            }
        }
        .navigationTitle("Review activity")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn’t save review", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure?.message ?? "Nothing was changed.")
        }
        .confirmationDialog(
            "This may already be recorded",
            isPresented: Binding(
                get: { pendingExpenseLabel != nil },
                set: {
                    if !$0 {
                        pendingExpenseLabel = nil
                        pendingRelatedObservationID = nil
                        pendingExpectedPaymentID = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Create expense anyway", role: .destructive) {
                guard let item, let label = pendingExpenseLabel else { return }
                let related = pendingRelatedObservationID
                let expected = pendingExpectedPaymentID
                pendingExpenseLabel = nil
                pendingRelatedObservationID = nil
                pendingExpectedPaymentID = nil
                act {
                    try store.createExpense(
                        from: item.id,
                        userLabel: label,
                        including: related,
                        settlingExpectedPaymentID: expected,
                        allowingPotentialDuplicate: true
                    )
                }
            }
            .accessibilityIdentifier("review.createExpenseAnyway")
            Button("Cancel", role: .cancel) {
                pendingExpenseLabel = nil
                pendingRelatedObservationID = nil
                pendingExpectedPaymentID = nil
            }
        } message: {
            Text(item?.duplicateCreationWarning ?? "Creating a new expense can record the same movement twice.")
        }
    }

    @ViewBuilder
    private func dates(_ item: SyncedObservationItem) -> some View {
        let dates = item.dates
        if dates.booking != nil || dates.transaction != nil || dates.value != nil || dates.derivedTransaction != nil {
            Section("Dates") {
                if let day = dates.booking { dayRow("Booking date", day) }
                if let day = dates.transaction { dayRow("Transaction date", day) }
                if let day = dates.value { dayRow("Value date", day) }
                if let day = dates.derivedTransaction {
                    dayRow("Derived transaction date", day)
                    if let provenance = dates.derivedProvenanceLabel {
                        Text(provenance).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(
        _ item: SyncedObservationItem,
        _ snapshot: FinanceAppSnapshot,
        existingMatches: [ObservationSuggestion],
        recurringMatches: [ObservationSuggestion],
        crossProviderMatch: ObservationSuggestion?
    ) -> some View {
        Section {
            if !existingMatches.isEmpty {
                Menu {
                    ForEach(existingMatches) { suggestion in
                        if let transactionID = suggestion.targetTransactionID {
                            Button(activityTitle(snapshot, transactionID)) {
                                act { try store.matchObservation(item.id, toTransaction: transactionID) }
                            }
                        }
                    }
                } label: {
                    Label("Match Existing", systemImage: "link")
                }
                .accessibilityIdentifier("review.matchExisting")
            }

            if let crossProviderMatch,
               let related = crossProviderMatch.relatedObservationID,
               item.amount.isNegative {
                Button {
                    let label = store.snapshot.syncedObservations.first { $0.id == related }?.observedMerchant
                        ?? item.displayMerchant
                    requestCreateExpense(from: item, userLabel: label, including: related)
                } label: {
                    Label("Create one expense with merchant evidence", systemImage: "link.badge.plus")
                }
            }

            if item.amount.isNegative && !isATMSuggestion(item) && !isRefundSuggestion(item) {
                Button {
                    requestCreateExpense(from: item, userLabel: item.displayMerchant)
                } label: {
                    Label("Create expense", systemImage: "cart")
                }
                .accessibilityIdentifier("review.createExpense")
            }

            if item.amount.isPositive && !isRefundSuggestion(item) {
                Button {
                    act { try store.createIncome(from: item.id, userLabel: item.displayMerchant) }
                } label: {
                    Label("Create income", systemImage: "arrow.down.circle")
                }
            }

            let counterpartAccounts = snapshot.accounts.filter {
                $0.isActive && $0.currencyCode == item.amount.currencyCode
                    && $0.name != item.providerAccountName
            }
            if !counterpartAccounts.isEmpty {
                Menu {
                    ForEach(counterpartAccounts) { account in
                        Button(account.name) {
                            act { try store.createTransfer(from: item.id, counterpartAccountID: account.id) }
                        }
                    }
                } label: {
                    Label("Create transfer", systemImage: "arrow.left.arrow.right")
                }
            }

            if !recurringMatches.isEmpty {
                Menu {
                    ForEach(recurringMatches) { suggestion in
                        if let expectedID = suggestion.targetExpectedPaymentID {
                            Button(suggestion.title) {
                                requestCreateExpense(
                                    from: item,
                                    userLabel: suggestion.title.replacingOccurrences(
                                        of: "Matches expected ", with: ""
                                    ),
                                    settlingExpectedPaymentID: expectedID
                                )
                            }
                        }
                    }
                } label: {
                    Label("Match recurring payment", systemImage: "calendar.badge.checkmark")
                }
            }

            if item.duplicateConflict == nil {
                Button {
                    act { try store.markObservationNoEconomicEffect(item.id) }
                } label: {
                    Label("Mark no economic effect", systemImage: "nosign")
                }
            }

            Button("Leave unresolved", systemImage: "clock") { dismiss() }
        } header: {
            Text("Your decision")
        } footer: {
            Text("Suggestions do not act on their own. Your selection creates or links economic truth once.")
        }
    }

    private func isATMSuggestion(_ item: SyncedObservationItem) -> Bool {
        item.suggestions.contains { $0.kind == .atmCashMovement }
    }

    private func isRefundSuggestion(_ item: SyncedObservationItem) -> Bool {
        item.suggestions.contains { $0.kind == .refundOrReversal }
    }

    private func evidenceText(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body).textSelection(.enabled)
        }
    }

    private func dayRow(_ label: String, _ day: CalendarDay) -> some View {
        LabeledContent(label) {
            Text(day.formatted(.dateTime.day().month(.wide).year()))
        }
    }

    private func activityTitle(_ snapshot: FinanceAppSnapshot, _ id: String) -> String {
        snapshot.activity.flatMap(\.rows).first { $0.id == id }?.title ?? "Existing transaction"
    }

    private func suggestionSymbol(_ kind: ObservationSuggestionKind) -> String {
        switch kind {
        case .recurring: "calendar.badge.checkmark"
        case .existingTransaction: "link"
        case .crossProvider: "arrow.triangle.branch"
        case .likelyTransfer: "arrow.left.arrow.right"
        case .atmCashMovement: "banknote"
        case .refundOrReversal: "arrow.uturn.backward"
        case .merchantUnresolved: "questionmark.circle"
        case .trustedRule: "checkmark.shield"
        }
    }

    private func resolutionLabel(_ resolution: SyncedObservationResolution) -> String {
        switch resolution {
        case .linked: "Linked to transaction"
        case .noEconomicEffect: "No economic effect"
        case .provisional: "Provisional only"
        case .ineligible: "Economically ineligible"
        case .outsideBoundary: "Before sync boundary"
        case .unreviewed: "Unreviewed"
        }
    }

    private func requestCreateExpense(
        from item: SyncedObservationItem,
        userLabel: String,
        including relatedObservationID: String? = nil,
        settlingExpectedPaymentID: String? = nil
    ) {
        if item.duplicateCreationWarning != nil {
            pendingRelatedObservationID = relatedObservationID
            pendingExpectedPaymentID = settlingExpectedPaymentID
            pendingExpenseLabel = userLabel
            return
        }
        act {
            try store.createExpense(
                from: item.id,
                userLabel: userLabel,
                including: relatedObservationID,
                settlingExpectedPaymentID: settlingExpectedPaymentID
            )
        }
    }

    private func act(_ work: () throws -> Void) {
        do { try work() }
        catch let error as BankReviewError { failure = error }
        catch { failure = .persistenceFailed(String(describing: type(of: error))) }
    }
}

struct TrustedRulesView: View {
    @Environment(FinanceStore.self) private var store

    var body: some View {
        content(store.snapshot.trustedRules)
    }

    private func content(_ rules: [TrustedRuleSummary]) -> some View {
        List {
            if rules.isEmpty {
                ContentUnavailableView(
                    "No trusted rules",
                    systemImage: "checkmark.shield",
                    description: Text("Repeated explicit confirmations can support a narrow rule. No rule is active by default.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(rules) { rule in
                    NavigationLink {
                        TrustedRuleDetailView(ruleID: rule.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.title).font(.body.weight(.medium))
                            Text("\(rule.lifecycle) · \(rule.trust)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("\(rule.supportCount) prior confirmation(s)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("Trusted Rules")
    }
}

private struct TrustedRuleDetailView: View {
    let ruleID: String
    @Environment(FinanceStore.self) private var store
    @State private var failure: BankReviewError?
    @State private var confirmsAutomaticApproval = false

    private var rule: TrustedRuleSummary? {
        store.snapshot.trustedRules.first { $0.id == ruleID }
    }

    var body: some View {
        List {
            if let rule {
                Section("Trust") {
                    LabeledContent("State", value: rule.lifecycle)
                    LabeledContent("Trust level", value: rule.trust)
                    LabeledContent("Prior confirmations", value: "\(rule.supportCount)")
                    LabeledContent("Semantic fingerprint") {
                        Text(rule.semanticFingerprint)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    if let approvedAt = rule.approvedAt {
                        LabeledContent("Approved") {
                            Text(approvedAt, format: .dateTime.day().month().year().hour().minute())
                        }
                    }
                    if let disabledAt = rule.disabledAt {
                        LabeledContent("Disabled") {
                            Text(disabledAt, format: .dateTime.day().month().year().hour().minute())
                        }
                    }
                }

                Section("Exact provider-evidence match") {
                    LabeledContent("Provider", value: rule.providerName)
                    LabeledContent("Account", value: rule.accountName)
                    LabeledContent("Binding", value: rule.bindingReference)
                    LabeledContent("Evidence field", value: rule.merchantEvidenceField)
                    LabeledContent("Evidence value", value: rule.merchantEvidenceValue)
                    LabeledContent("Direction", value: rule.direction)
                    LabeledContent("Currency", value: rule.currency)
                    if let amount = rule.exactAmount {
                        LabeledContent("Exact amount") {
                            MoneyText(amount: amount, size: 17, weight: .semibold, showsSign: true)
                        }
                    } else {
                        LabeledContent("Exact amount", value: "Any")
                    }
                    if let providerCode = rule.providerCode {
                        LabeledContent("Provider code", value: providerCode)
                    } else {
                        LabeledContent("Provider code", value: "Any")
                    }
                }

                Section("Economic interpretation") {
                    LabeledContent("Economic kind", value: rule.economicKind)
                    LabeledContent("Category", value: rule.category ?? "None")
                    LabeledContent("User label", value: rule.userLabel ?? "None")
                    LabeledContent(
                        "Recurring obligation",
                        value: rule.recurringObligation ?? "None"
                    )
                    LabeledContent("Economic source", value: rule.economicSource ?? "None")
                    LabeledContent("Counterparty", value: "Not inferred")
                    LabeledContent("Ownership", value: "Not inferred")
                    Text("Provider description, merchant evidence, category, label, economic source, counterparty, and ownership remain separate dimensions. Rules never infer ownership.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                TrustedRuleSafetySection(rule: rule)
                TrustedRuleSupportSection(supports: rule.supportingConfirmations)

                if rule.canApproveSuggestionOnly || rule.canApproveAutomatic {
                    Section {
                        if rule.canApproveSuggestionOnly {
                            Button("Approve as suggestion-only") {
                                updateRule {
                                    try store.approveTrustedRuleForSuggestions(rule.id)
                                }
                            }
                        }
                        if rule.canApproveAutomatic {
                            Button("Approve automatic handling") {
                                confirmsAutomaticApproval = true
                            }
                            .foregroundStyle(Theme.Role.positive)
                        }
                    } header: {
                        Text("Approval")
                    } footer: {
                        Text("Suggestion approval only activates proposals. Automatic approval grants future trust but does not apply the rule to any existing Inbox match.")
                    }
                }

                if !rule.audit.isEmpty {
                    Section("Audit trail") {
                        ForEach(rule.audit) { event in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.action).font(.body.weight(.medium))
                                Text(event.occurredAt, format: .dateTime.day().month().year().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(event.explanation)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                if rule.canDisable {
                    Section {
                        Button("Disable rule", role: .destructive) {
                            updateRule { try store.disableTrustedRule(rule.id) }
                        }
                    } footer: {
                        Text("Disabling stops future matches. It does not rewrite previously reviewed history.")
                    }
                }
            }
        }
        .navigationTitle(rule?.title ?? "Trusted Rule")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn’t update rule", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure?.message ?? "Nothing was changed.")
        }
        .confirmationDialog(
            "Approve automatic handling?",
            isPresented: $confirmsAutomaticApproval,
            titleVisibility: .visible
        ) {
            Button("Approve future automatic handling") {
                guard let rule else { return }
                updateRule {
                    try store.approveTrustedRuleForAutomaticHandling(rule.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only future separately authorized automatic processing may apply this rule. Existing Inbox observations remain untouched.")
        }
    }

    private func updateRule(_ operation: () throws -> Void) {
        do { try operation() }
        catch let error as BankReviewError { failure = error }
        catch { failure = .persistenceFailed(String(describing: type(of: error))) }
    }
}

private struct TrustedRuleSafetySection: View {
    let rule: TrustedRuleSummary

    var body: some View {
        Section("Phase 2.6 safety") {
            Text(rule.safetyExplanation).font(.callout)
            LabeledContent("Current Inbox matches", value: String(rule.currentMatchCount))
            LabeledContent(
                "Automatically eligible",
                value: String(rule.currentAutomaticallyEligibleCount)
            )
            LabeledContent("Suggestion only", value: String(rule.currentSuggestionOnlyCount))
            ForEach(rule.currentSuggestionOnlyReasons, id: \.self) { reason in
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Blocked", value: String(rule.currentBlockedMatches.count))
            ForEach(rule.currentBlockedMatches) { match in
                VStack(alignment: .leading, spacing: 3) {
                    Text("Blocked current match").font(.caption.weight(.medium))
                    ForEach(match.reasons, id: \.self) { reason in
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct TrustedRuleSupportSection: View {
    let supports: [TrustedRuleSupportSummary]

    var body: some View {
        Section("Supporting confirmations") {
            ForEach(supports) { support in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Explicitly confirmed").font(.body.weight(.medium))
                    Text(
                        support.confirmedAt,
                        format: .dateTime.day().month().year().hour().minute()
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let economicDate = support.economicDate {
                        LabeledContent("Economic date") {
                            Text(economicDate.formatted(.dateTime.day().month().year()))
                        }
                        .font(.caption)
                    }
                    if let amount = support.amount {
                        LabeledContent("Provider amount") {
                            MoneyText(
                                amount: amount,
                                size: 14,
                                weight: .medium,
                                showsSign: true
                            )
                        }
                    }
                    if let category = support.category {
                        LabeledContent("Category at confirmation", value: category)
                            .font(.caption)
                    }
                    if let userLabel = support.userLabel {
                        LabeledContent("User label at confirmation", value: userLabel)
                            .font(.caption)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }
}

private struct ProviderBalanceRow: View {
    let balance: ProviderBalanceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(balance.accountName).font(.body.weight(.medium))
                    Text("\(balance.providerName) · \(balance.balanceType)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                MoneyText(amount: balance.providerBalance, size: 17, weight: .semibold)
            }
            if let difference = balance.difference, !difference.isZero {
                Text("Difference \(difference.formatted(showsSign: true))")
                    .font(.caption)
                    .foregroundStyle(Theme.Role.caution)
            } else if balance.difference != nil {
                Text("Matches ledger")
                    .font(.caption)
                    .foregroundStyle(Theme.Role.positive)
            }
        }
        .padding(.vertical, 3)
    }
}

struct ProviderBalanceDetailView: View {
    let balanceID: String
    @Environment(FinanceStore.self) private var store

    private var balance: ProviderBalanceStatus? {
        store.snapshot.providerBalanceStatuses.first { $0.id == balanceID }
    }

    var body: some View {
        List {
            if let balance {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(balance.accountName).font(.headline)
                        Text("\(balance.providerName) · \(balance.balanceType)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Comparison") {
                    LabeledContent("Ledger") {
                        MoneyText(amount: balance.ledgerBalance, size: 17, weight: .semibold)
                    }
                    LabeledContent("Bank") {
                        MoneyText(amount: balance.providerBalance, size: 17, weight: .semibold)
                    }
                    if let difference = balance.difference {
                        LabeledContent("Difference") {
                            MoneyText(
                                amount: difference, size: 17, weight: .semibold,
                                showsSign: true, colorBySign: true
                            )
                        }
                    } else {
                        Text("The provider and ledger currencies differ, so no difference is invented.")
                            .foregroundStyle(Theme.Role.caution)
                    }
                }

                Section {
                    if let referenceDate = balance.referenceDate {
                        LabeledContent("Reference date") {
                            Text(referenceDate.formatted(.dateTime.day().month(.wide).year()))
                        }
                    }
                    LabeledContent("Observed") {
                        Text(balance.observedAt, format: .dateTime.day().month().hour().minute())
                    }
                } footer: {
                    Text("Provider balance evidence never overwrites the local ledger. Resolve the difference by reviewing missing or incorrect economic entries.")
                }
            }
        }
        .navigationTitle("Balance evidence")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview {
    NavigationStack { BankInboxView() }
        .environment(FinanceStore.bankInboxPreview())
}
#endif
