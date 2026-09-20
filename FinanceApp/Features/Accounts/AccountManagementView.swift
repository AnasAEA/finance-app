import SwiftUI

/// Where the money is. A financial destination reached from Home, not a
/// settings page: it answers "which account holds this" and "is that figure
/// current", and it never asks about connections. Pairing, reconnecting and
/// mapping stay in Settings → Banks & Sync, because healthy infrastructure
/// should be quiet.
/// One live read per composition: the cash figures, the physical-cash section
/// and the account rows are one statement of holdings.
struct AccountsView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        let presentation = store.currentPresentation()
        return content(presentation.snapshot, presentation.freshness)
    }

    private func content(
        _ snapshot: FinanceAppSnapshot, _ freshness: BankFreshnessEvaluation
    ) -> some View {
        let holdingsByID = Dictionary(
            snapshot.trackedHoldings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        return List {
            if snapshot.accounts.isEmpty {
                ContentUnavailableView {
                    Label("No accounts", systemImage: "building.columns")
                } description: {
                    Text("Add where your money is held. Opening balances are recorded as account truth, not income.")
                } actions: {
                    NavigationLink("Add account") {
                        AccountEditorView()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    LedgerRow(
                        label: "Cash available",
                        value: snapshot.accountCash,
                        caption: freshness.caption,
                        emphasis: true
                    )
                } footer: {
                    if !snapshot.physicalCash.isEmpty {
                        // Said out loud rather than left to be inferred from a
                        // tint: the figure above deliberately excludes cash in
                        // hand and anything held in another currency.
                        Text("Cash in hand is listed separately and is not part of the figure above.")
                    }
                }

                Section("Accounts") {
                    ForEach(snapshot.accounts) { account in
                        NavigationLink {
                            AccountDetailView(accountID: account.id)
                        } label: {
                            AccountRegisterRow(account: account, holding: holdingsByID[account.id])
                        }
                        .accessibilityIdentifier(RouteID.account(account.id))
                    }
                }
            }
        }
        .accessibilityIdentifier(RouteID.accountsList)
        .financeList()
        .navigationTitle("Accounts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    AccountEditorView()
                } label: {
                    Label("Add account", systemImage: "plus")
                }
            }
        }
    }
}

/// One row of the register. Uses the shared holding row when the account has a
/// recorded balance, so "not spendable here" and "carried at" keep saying what
/// they say everywhere else.
private struct AccountRegisterRow: View {
    let account: AccountSummary
    let holding: HoldingLine?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let holding {
                HoldingRow(holding: holding)
            } else {
                HStack {
                    Image(systemName: account.kind.symbolName)
                        .font(.footnote)
                        .foregroundStyle(Theme.Role.accent)
                        .frame(width: 20)
                    Text(account.name).font(.subheadline)
                    Spacer(minLength: 8)
                    MoneyText(amount: account.balance, size: 17, weight: .medium)
                }
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(account.name), \(account.balance.accessibleDescription())")
            }
            HStack(spacing: 6) {
                Text(account.secondaryLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !account.isActive { Chip(text: "Inactive") }
            }
            .padding(.leading, 30)
        }
    }
}

/// One account: what it holds, when that was true, what has moved through it,
/// and the way to edit it. Provider status appears only when this account is
/// actually bound to one.
/// One live read per composition: the balance, its provider binding, the
/// connection behind it and the recent rows describe one moment.
struct AccountDetailView: View {
    let accountID: String

    @Environment(FinanceStore.self) private var store

    var body: some View {
        AccountDetailContent(accountID: accountID, snapshot: store.snapshot)
    }
}

private struct AccountDetailContent: View {
    let accountID: String
    let snapshot: FinanceAppSnapshot

    @Environment(FinanceStore.self) private var store
    @Environment(AppNavigation.self) private var navigation

    private var account: AccountSummary? {
        snapshot.accounts.first { $0.id == accountID }
    }

    private var holding: HoldingLine? {
        snapshot.trackedHoldings.first { $0.id == accountID }
    }

    private var binding: ProviderAccountBinding? {
        snapshot.providerAccountBindings.first { $0.localAccountID == accountID }
    }

    private var connection: ProviderConnectionStatus? {
        guard let binding else { return nil }
        return snapshot.providerConnections.first { $0.providerName == binding.providerName }
    }

    private var recent: [ActivityRow] {
        Array(
            snapshot.activity
                .flatMap(\.rows)
                .filter { $0.accountIDs.contains(accountID) }
                .prefix(8)
        )
    }

    var body: some View {
        List {
            if let account {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        MoneyText(amount: account.balance, size: 30, weight: .bold)
                        Text("\(account.kind.displayName) · \(account.currencyCode)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("As of \(account.balanceAsOf.formatted(.dateTime.day().month(.abbreviated).year()))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let holding, !holding.isSpendableHere {
                            Text(holding.carriedAt == nil
                                 ? "Not spendable here."
                                 : "Carried at \(holding.carriedAt!.formatted()) · not spendable here.")
                                .font(.caption)
                                .foregroundStyle(Theme.Role.caution)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !account.isActive {
                            Text("Inactive. Past transactions still resolve to it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                }

                if let binding {
                    Section("Provider") {
                        LabeledContent("Connected as", value: binding.providerName)
                        if let connection {
                            LabeledContent("Connection", value: connection.state.displayName)
                        }
                        Button("Banks & Sync") {
                            navigation.showHome([.settings, .banks])
                        }
                    }
                }

                Section("Recent activity") {
                    if recent.isEmpty {
                        Text("No activity on this account yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recent) { row in
                            HStack {
                                Text(row.title).font(.subheadline).lineLimit(1)
                                Spacer(minLength: 8)
                                MoneyText(amount: row.amount, size: 15, weight: .medium,
                                          showsSign: true, colorBySign: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                Section {
                    NavigationLink("Edit account") {
                        AccountEditorView(account: account)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Account not available",
                    systemImage: "questionmark.folder",
                    description: Text("It may have been removed.")
                )
            }
        }
        .financeList()
        .navigationTitle(account?.name ?? "Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AccountEditorView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let existing: AccountSummary?
    @State private var name: String
    @State private var kind: HoldingKind
    @State private var currencyCode: String
    @State private var openingBalanceText: String
    @State private var openingBalanceDate: CalendarDay?
    @State private var isActive: Bool
    @State private var errorMessage: String?

    init(account: AccountSummary? = nil) {
        existing = account
        _name = State(initialValue: account?.name ?? "")
        _kind = State(initialValue: account?.kind ?? .bank)
        _currencyCode = State(initialValue: account?.currencyCode ?? "EUR")
        _openingBalanceText = State(
            initialValue: account.map { NSDecimalNumber(decimal: $0.balance.decimalValue).stringValue } ?? ""
        )
        _openingBalanceDate = State(initialValue: account?.balanceAsOf)
        _isActive = State(initialValue: account?.isActive ?? true)
    }

    private var currency: CurrencyOption {
        CurrencyOption.common.first { $0.code == currencyCode }
            ?? CurrencyOption(code: currencyCode, name: currencyCode, fractionDigits: existing?.fractionDigits ?? 2)
    }

    private var openingBalance: Amount? {
        if let existing { return existing.balance }
        let text = (openingBalanceText.isEmpty ? "0" : openingBalanceText)
            .trimmingCharacters(in: .whitespaces)
        let isNegative = text.hasPrefix("-")
        let magnitudeText = isNegative ? String(text.dropFirst()) : text
        guard let magnitude = try? Amount.parse(
            magnitudeText,
            currencyCode: currency.code,
            fractionDigits: currency.fractionDigits
        ) else { return nil }
        return isNegative ? magnitude.negated : magnitude
    }

    var body: some View {
        Form {
            Section("Account") {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                Picker("Kind", selection: $kind) {
                    ForEach([HoldingKind.bank, .wallet, .cash], id: \.self) {
                        Label($0.displayName, systemImage: $0.symbolName).tag($0)
                    }
                }
                if existing == nil {
                    Picker("Currency", selection: $currencyCode) {
                        ForEach(CurrencyOption.common) { option in
                            Text("\(option.code) · \(option.name)").tag(option.code)
                        }
                    }
                } else {
                    LabeledContent("Currency", value: currencyCode)
                }
            }

            if existing == nil {
                Section {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Opening balance")
                            openingBalanceField
                        }
                    } else {
                        HStack {
                            Text("Opening balance")
                            Spacer()
                            openingBalanceField
                        }
                    }
                    CivilDatePicker("Balance as of", selection: $openingBalanceDate)
                } footer: {
                    Text("This is the source-proven balance on that date. It is not recorded as income.")
                }
            } else {
                Section {
                    Toggle("Active for new entries", isOn: $isActive)
                } footer: {
                    Text("Inactive accounts remain visible on past transactions and in Activity filters.")
                }
            }

            Section {
                DisclosureGroup("Payment capabilities") {
                    Text(capabilityExplanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Payment capabilities are inferred conservatively from account kind and currency.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Role.negative)
                }
            }
        }
        .financeList()
        .navigationTitle(existing == nil ? "Add Account" : "Edit Account")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if openingBalanceDate == nil { openingBalanceDate = store.currentDay() } }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || openingBalance == nil)
            }
        }
    }

    private var openingBalanceField: some View {
        HStack {
            if dynamicTypeSize.isAccessibilitySize { Spacer() }
            TextField("0", text: $openingBalanceText)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 150)
            Text(currencyCode).foregroundStyle(.secondary)
        }
    }

    private var capabilityExplanation: String {
        switch kind {
        case .bank: currencyCode == "EUR" ? "Bank transfer, direct debit and card payments." : "Card and electronic payments."
        case .wallet: currencyCode == "EUR" ? "Electronic, card and euro transfer payments." : "Card and electronic payments."
        case .cash: "Physical cash payments only."
        }
    }

    private func save() {
        guard let openingBalance else { return }
        guard let openingDay = openingBalanceDate else {
            errorMessage = AppManagementError.invalidDate.message
            return
        }
        let draft = AccountDraft(
            id: existing?.id,
            name: name,
            kind: kind,
            currencyCode: currency.code,
            fractionDigits: currency.fractionDigits,
            openingBalance: openingBalance,
            openingBalanceDay: openingDay,
            isActive: isActive
        )
        do {
            try store.saveAccount(draft)
            dismiss()
        } catch let error as AppManagementError {
            errorMessage = error.message
        } catch {
            errorMessage = AppManagementError.persistenceFailed(String(describing: error)).message
        }
    }
}

#Preview {
    NavigationStack { AccountsView() }
        .environment(FinanceStore.preview())
        .environment(AppNavigation())
}
