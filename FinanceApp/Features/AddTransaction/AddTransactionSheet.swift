import SwiftUI

/// Fast daily entry with two independent identities: the account says where
/// money moved; an income source says why an inflow exists.
struct AddTransactionSheet: View {
    @Environment(FinanceStore.self) private var store

    private let initialKind: TransactionDraft.Kind

    init(initialKind: TransactionDraft.Kind = LaunchOptions.current.initialEntryKind ?? .expense) {
        self.initialKind = initialKind
    }

    /// The person opening this sheet is a separate operation from rendering it.
    static func defaultDate(store: FinanceStore) -> CalendarDay? {
        store.currentDay()
    }

    /// One live read per composition. Every field below describes the same
    /// entry options and the same currency; reading the store per field would
    /// let one sheet built across local midnight mix two civil days.
    var body: some View {
        AddTransactionContent(initialKind: initialKind, snapshot: store.snapshot)
    }
}

private struct AddTransactionContent: View {
    let snapshot: FinanceAppSnapshot

    init(initialKind: TransactionDraft.Kind, snapshot: FinanceAppSnapshot) {
        self.snapshot = snapshot
        _kind = State(initialValue: initialKind)
    }

    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var amountText = ""
    @State private var kind: TransactionDraft.Kind
    @State private var categoryKey = ""
    @State private var accountID: String?
    @State private var counterAccountID: String?
    @State private var incomeSourceID: String?
    @State private var counterparty = ""
    @State private var date: CalendarDay?
    @State private var notes = ""
    @State private var showsAdvanced = false
    @State private var splitsWithSomeoneElse = false
    @State private var myShareText = ""
    @State private var saveError: String?

    @FocusState private var amountFocused: Bool

    private var options: EntryOptions { snapshot.entryOptions }
    private var account: AccountOption? { options.account(accountID) }
    private var currencyCode: String { account?.currencyCode ?? snapshot.currencyCode }
    private var fractionDigits: Int { account?.fractionDigits ?? 2 }

    private func parseAmount(_ text: String) -> Result<Amount, Amount.ParseFailure> {
        do {
            return .success(try Amount.parse(text, currencyCode: currencyCode, fractionDigits: fractionDigits))
        } catch let failure as Amount.ParseFailure {
            return .failure(failure)
        } catch {
            return .failure(.notANumber)
        }
    }

    private var amount: Amount? {
        guard case let .success(parsed) = parseAmount(amountText), parsed.isPositive else { return nil }
        return parsed
    }

    private var myShare: Amount? {
        guard splitsWithSomeoneElse, kind.supportsOwnShareEntry else { return nil }
        guard case let .success(parsed) = parseAmount(myShareText), parsed.isPositive else { return nil }
        return parsed
    }

    private func precisionProblem(in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        guard case let .failure(failure) = parseAmount(text) else { return nil }
        switch failure {
        case .empty: return nil
        case .notANumber: return "Enter a number."
        case let .excessPrecision(allowed):
            return AppEntryError
                .excessPrecision(currencyCode: currencyCode, allowedFractionDigits: allowed)
                .message
        }
    }

    private var amountProblem: String? { precisionProblem(in: amountText) }
    private var shareProblem: String? {
        splitsWithSomeoneElse && kind.supportsOwnShareEntry ? precisionProblem(in: myShareText) : nil
    }
    private var counterAccountOptions: [AccountOption] {
        options.transferDestinations(from: accountID)
    }
    private var hasBlockedCrossCurrencyDestinations: Bool {
        guard kind == .transfer, let account else { return false }
        return options.accounts.contains {
            $0.id != account.id && $0.currencyCode != account.currencyCode
        }
    }
    private var canSave: Bool {
        guard amount != nil, accountID != nil, amountProblem == nil, shareProblem == nil else { return false }
        if kind == .income, incomeSourceID == nil { return false }
        if splitsWithSomeoneElse, kind.supportsOwnShareEntry, myShare == nil { return false }
        if kind.requiresCounterAccount { return counterAccountID != nil && counterAccountID != accountID }
        return true
    }

    var body: some View {
        NavigationStack {
            Group {
                if options.accounts.isEmpty {
                    accountRequiredView
                } else {
                    entryForm
                }
            }
            .navigationTitle("New Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if !options.accounts.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save)
                            .fontWeight(.semibold)
                            .disabled(!canSave)
                    }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .onAppear {
            if date == nil { date = AddTransactionSheet.defaultDate(store: store) }
            chooseDefaultAccount(for: kind)
            categoryKey = defaultCategoryKey(for: kind)
            amountFocused = !options.accounts.isEmpty
        }
        .onChange(of: options.accounts) { _, accounts in
            if accountID == nil, !accounts.isEmpty { chooseDefaultAccount(for: kind) }
        }
    }

    private var accountRequiredView: some View {
        ContentUnavailableView {
            Label("An account is required", systemImage: "building.columns")
        } description: {
            Text("Add where money is held before recording a transaction.")
        } actions: {
            NavigationLink("Add your first account") {
                AccountEditorView()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var entryForm: some View {
        Form {
            amountSection
            if let amountProblem { validationRow(amountProblem) }
            kindSection

            switch kind {
            case .expense: expenseSection
            case .income: incomeSection
            case .transfer: transferSection
            }

            if showsAdvanced { advancedSection }
            advancedToggle
            if let saveError { validationRow(saveError) }
        }
        .onChange(of: kind) { _, newValue in
            categoryKey = defaultCategoryKey(for: newValue)
            chooseDefaultAccount(for: newValue)
            counterAccountID = nil
            saveError = nil
            if !newValue.supportsOwnShareEntry {
                splitsWithSomeoneElse = false
                myShareText = ""
            }
        }
        .onChange(of: accountID) { _, _ in
            saveError = nil
            if let counterAccountID,
               !counterAccountOptions.contains(where: { $0.id == counterAccountID }) {
                self.counterAccountID = nil
            }
        }
        .onChange(of: incomeSourceID) { _, sourceID in
            saveError = nil
            guard let preferred = options.incomeSource(sourceID)?.preferredAccountID,
                  options.account(preferred) != nil else { return }
            accountID = preferred
        }
        .onChange(of: amountText) { _, _ in saveError = nil }
        .onChange(of: counterAccountID) { _, _ in saveError = nil }
    }

    private func validationRow(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(Theme.Role.negative)
                .accessibilityLabel("Cannot save. \(message)")
        }
    }

    private var amountPlaceholder: String {
        fractionDigits == 0 ? "0" : "0." + String(repeating: "0", count: fractionDigits)
    }

    private var currencySymbol: String {
        switch currencyCode {
        case "EUR": "€"
        case "MAD": "DH"
        case "USD": "$"
        case "GBP": "£"
        case "JPY": "¥"
        default: currencyCode
        }
    }

    private var amountSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Spacer(minLength: 0)
                Text(currencySymbol)
                    .font(.money(34, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(amountPlaceholder, text: $amountText)
                    .font(.money(46, weight: .bold))
                    .keyboardType(.decimalPad)
                    .focused($amountFocused)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Amount in \(currencyCode)")
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
        }
    }

    private var kindSection: some View {
        Section {
            Picker("Type", selection: $kind) {
                ForEach(TransactionDraft.Kind.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        }
    }

    private var expenseSection: some View {
        Section {
            accountPicker("Paid from")
            TextField("Merchant (optional)", text: $counterparty)
                .textInputAutocapitalization(.words)
            Picker("Category", selection: $categoryKey) {
                ForEach(expenseCategories) { option in
                    Label(option.name, systemImage: option.symbolName).tag(option.key)
                }
            }
            CivilDatePicker("Date", selection: $date)
        }
    }

    @ViewBuilder
    private var incomeSection: some View {
        Section {
            accountPicker("Received in")
            if options.incomeSources.isEmpty {
                NavigationLink {
                    IncomeSourceEditorView()
                } label: {
                    Label("Add an income source", systemImage: "plus.circle")
                }
            } else {
                Picker("Income source", selection: $incomeSourceID) {
                    Text("Choose").tag(String?.none)
                    ForEach(options.incomeSources) { source in
                        Text(source.name).tag(Optional(source.id))
                    }
                }
            }
            TextField("From / payer (optional)", text: $counterparty)
                .textInputAutocapitalization(.words)
            CivilDatePicker("Date", selection: $date)
        } footer: {
            Text("Income source explains why the money arrived. Received in records where it landed.")
        }
    }

    private var transferSection: some View {
        Section {
            accountPicker("From")
            counterAccountPicker
            CivilDatePicker("Date", selection: $date)
        } footer: {
            if hasBlockedCrossCurrencyDestinations {
                Text("Only same-currency accounts are available. Cross-currency transfers and cash withdrawals need both amounts and an exchange rate; that editor is the next slice.")
            } else {
                Text("Transfers move money between your accounts and do not count as spending or income.")
            }
        }
    }

    private func accountPicker(_ label: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Text(label)
                    HStack {
                        Spacer()
                        sourceAccountMenu
                    }
                }
            } else {
                HStack {
                    Text(label)
                    Spacer(minLength: 12)
                    sourceAccountMenu
                }
            }
        }
    }

    private var counterAccountPicker: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Text("To")
                    HStack {
                        Spacer()
                        destinationAccountMenu
                    }
                }
            } else {
                HStack {
                    Text("To")
                    Spacer(minLength: 12)
                    destinationAccountMenu
                }
            }
        }
    }

    private var sourceAccountMenu: some View {
        Menu {
            ForEach(options.accounts) { option in
                Button {
                    accountID = option.id
                } label: {
                    Label("\(option.name) · \(option.secondaryLabel)", systemImage: option.kind.symbolName)
                }
            }
        } label: {
            accountSelectionLabel(account)
        }
    }

    private var destinationAccountMenu: some View {
        Menu {
            ForEach(counterAccountOptions) { option in
                Button {
                    counterAccountID = option.id
                } label: {
                    Label("\(option.name) · \(option.secondaryLabel)", systemImage: option.kind.symbolName)
                }
            }
        } label: {
            accountSelectionLabel(options.account(counterAccountID))
        }
        .disabled(counterAccountOptions.isEmpty)
    }

    private func accountSelectionLabel(_ selected: AccountOption?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(selected?.name ?? "Choose account")
            if let selected {
                Text(selected.secondaryLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.trailing)
    }

    private var expenseCategories: [CategoryOption] {
        options.categories.filter { !$0.isIncome && !$0.isTransfer }
    }

    private var advancedToggle: some View {
        Section {
            Button {
                withAnimation(.snappy) { showsAdvanced.toggle() }
            } label: {
                Label(showsAdvanced ? "Hide details" : "More details",
                      systemImage: showsAdvanced ? "chevron.up" : "chevron.down")
                    .font(.subheadline)
            }
        }
    }

    private var advancedSection: some View {
        Section("Details") {
            if kind.supportsOwnShareEntry {
                Toggle("Part of this is someone else's", isOn: $splitsWithSomeoneElse.animation(.snappy))
                if splitsWithSomeoneElse {
                    HStack {
                        Text("My share")
                        Spacer()
                        TextField(amountPlaceholder, text: $myShareText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 120)
                    }
                    if let shareProblem {
                        Text(shareProblem).font(.caption).foregroundStyle(Theme.Role.negative)
                    } else {
                        Text("Only your share counts as income. The rest passes through.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            TextField("Notes", text: $notes, axis: .vertical).lineLimit(1...4)
        }
    }

    private func chooseDefaultAccount(for kind: TransactionDraft.Kind) {
        switch kind {
        case .income: accountID = options.defaultIncomeAccountID
        case .expense, .transfer: accountID = options.defaultExpenseAccountID
        }
    }

    private func defaultCategoryKey(for kind: TransactionDraft.Kind) -> String {
        switch kind {
        case .income: options.categories.first(where: \.isIncome)?.key ?? ""
        case .transfer: options.categories.first(where: \.isTransfer)?.key ?? ""
        case .expense:
            expenseCategories.first(where: { $0.key == "food" })?.key
                ?? expenseCategories.first?.key ?? ""
        }
    }

    private func save() {
        guard let amount, let accountID else {
            saveError = AppEntryError.invalidAmount.message
            return
        }
        guard let day = date else {
            saveError = AppEntryError.invalidDate.message
            return
        }
        let draft = TransactionDraft(
            day: day,
            kind: kind,
            amount: amount,
            accountID: accountID,
            counterAccountID: kind.requiresCounterAccount ? counterAccountID : nil,
            incomeSourceID: kind == .income ? incomeSourceID : nil,
            categoryKey: kind == .transfer ? nil : categoryKey,
            merchant: counterparty.isEmpty ? nil : counterparty,
            ownShare: myShare,
            notes: notes.isEmpty ? nil : notes
        )
        do {
            try store.add(draft)
            dismiss()
        } catch let error as AppEntryError {
            saveError = error.message
        } catch {
            saveError = AppEntryError.persistenceFailed(String(describing: error)).message
        }
    }
}

#Preview {
    AddTransactionSheet().environment(FinanceStore.preview())
}
