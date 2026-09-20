import SwiftUI

/// Create or edit a sinking fund. Saving this is not spending.
struct SinkingFundEditorView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft: SinkingFundDraft
    @State private var error: String?
    @State private var confirmDelete = false

    init(draft: SinkingFundDraft = SinkingFundDraft()) {
        _draft = State(initialValue: draft)
    }

    private func compatibleAccounts(_ snapshot: FinanceAppSnapshot) -> [AccountSummary] {
        snapshot.accounts.filter {
            $0.isActive && $0.currencyCode == draft.currencyCode
        }
    }

    /// One live read per composition.
    var body: some View {
        content(store.snapshot)
    }

    private func content(_ snapshot: FinanceAppSnapshot) -> some View {
        let compatibleAccounts = compatibleAccounts(snapshot)
        return NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .accessibilityIdentifier(PlanningControlID.fundName)
                    amountRow("Target", text: $draft.targetText, identifier: "fund.target")
                    amountRow("Set aside", text: $draft.reservedText, identifier: "fund.reserved")
                    Picker("Currency", selection: $draft.currencyCode) {
                        ForEach(CurrencyOption.common) { option in
                            Text(option.code).tag(option.code)
                        }
                    }
                    .onChange(of: draft.currencyCode) { _, code in
                        draft.fractionDigits = CurrencyOption.common.first { $0.code == code }?.fractionDigits ?? 2
                        if let accountID = draft.dedicatedAccountID,
                           !store.snapshot.accounts.contains(where: {
                               $0.id == accountID && $0.isActive && $0.currencyCode == code
                           }) {
                            draft.dedicatedAccountID = nil
                        }
                    }
                } footer: {
                    Text("Set aside is not spent. It does not change the monthly budget.")
                }

                Section {
                    Picker("Where it lives", selection: $draft.custody) {
                        ForEach(FundCustodyKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .accessibilityIdentifier("fund.custody")
                    .onChange(of: draft.custody) { _, kind in
                        if kind != .dedicated { draft.dedicatedAccountID = nil }
                    }
                    Text(draft.custody.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if draft.custody == .dedicated {
                        if compatibleAccounts.isEmpty {
                            Text("No account in this currency. Dedicated custody needs an existing local account.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Account", selection: $draft.dedicatedAccountID) {
                                Text("Choose an account").tag(Optional<String>.none)
                                ForEach(compatibleAccounts) { account in
                                    Text(account.name).tag(Optional(account.id))
                                }
                            }
                            .accessibilityIdentifier("fund.account")
                        }
                    }
                }

                Section {
                    Picker("Linked goal", selection: $draft.goalID) {
                        Text("None").tag(Optional<String>.none)
                        ForEach(snapshot.plannedPurchases) { goal in
                            Text(goal.name).tag(Optional(goal.id))
                        }
                    }
                    amountRow("Monthly set-aside (optional)", text: $draft.contributionText, identifier: "fund.contribution")
                    Picker("Status", selection: $draft.status) {
                        ForEach(FundStatusOption.allCases) { status in
                            Text(status.displayName).tag(status)
                        }
                    }
                }

                Section("Note") {
                    TextField("Optional", text: $draft.note, axis: .vertical)
                }

                if draft.id != nil {
                    Section {
                        Button("Delete fund", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .financeList()
            .navigationTitle(draft.id == nil ? "New fund" : "Sinking fund")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier(PlanningControlID.fundSave)
                }
            }
            .confirmationDialog("Delete this fund?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteFund() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the reservation from the plan. It does not move money or book spending.")
            }
            .alert("Not saved", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func amountRow(_ label: String, text: Binding<String>, identifier: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(identifier)
        }
    }

    private func save() {
        do {
            try store.saveSinkingFund(draft)
            dismiss()
        } catch let problem as AppManagementError {
            error = problem.message
        } catch {
            self.error = AppManagementError.persistenceFailed(String(describing: error)).message
        }
    }

    private func deleteFund() {
        guard let id = draft.id else { return }
        do {
            try store.deleteSinkingFund(id: id)
            dismiss()
        } catch let problem as AppManagementError {
            error = problem.message
        } catch {
            self.error = AppManagementError.persistenceFailed(String(describing: error)).message
        }
    }
}
