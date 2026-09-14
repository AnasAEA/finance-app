import SwiftUI

struct IncomeSourcesView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// One live read per composition.
    var body: some View {
        content(store.snapshot.incomeSources)
    }

    private func content(_ incomeSources: [IncomeSourceSummary]) -> some View {
        List {
            if incomeSources.isEmpty {
                ContentUnavailableView {
                    Label("No income sources", systemImage: "arrow.down.circle")
                } description: {
                    Text("Income sources explain why money arrived. They stay separate from the account that received it.")
                } actions: {
                    NavigationLink("Add income source") {
                        IncomeSourceEditorView()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)

                Section("Suggestions") {
                    ForEach(IncomeSourceEditorView.suggestions, id: \.self) { suggestion in
                        NavigationLink {
                            IncomeSourceEditorView(suggestedName: suggestion)
                        } label: {
                            Label(suggestion, systemImage: "plus.circle")
                        }
                    }
                }
            } else {
                ForEach(incomeSources) { source in
                    NavigationLink {
                        IncomeSourceEditorView(source: source)
                    } label: {
                        IncomeSourceManagementRow(source: source)
                    }
                }
            }
        }
        .navigationTitle("Income Sources")
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    IncomeSourceEditorView()
                } label: {
                    Label("Add income source", systemImage: "plus")
                }
            }
        }
    }
}

private struct IncomeSourceManagementRow: View {
    let source: IncomeSourceSummary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    sourceName
                    if !source.amount.isZero {
                        MoneyText(amount: source.amount, size: 16, weight: .medium)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    sourceName
                    Spacer()
                    if !source.amount.isZero {
                        MoneyText(amount: source.amount, size: 16, weight: .medium)
                    }
                }
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.certainty.displayName)
                    if let account = source.preferredAccountName {
                        Label(account, systemImage: "arrow.down.to.line")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Text(source.certainty.displayName)
                    if let account = source.preferredAccountName {
                        Text("·")
                        Label(account, systemImage: "arrow.down.to.line")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var sourceName: some View {
        HStack(spacing: 6) {
            Text(source.name).font(.headline)
            if !source.isActive { Chip(text: "Inactive") }
        }
    }
}

struct IncomeSourceEditorView: View {
    static let suggestions = [
        "Parents", "Internship", "Student job", "CAF", "CROUS", "Freelance", "Sale", "Other"
    ]

    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let existing: IncomeSourceSummary?
    @State private var name: String
    @State private var certainty: IncomeCertaintyOption
    @State private var isActive: Bool
    @State private var preferredAccountID: String?
    @State private var note: String
    @State private var errorMessage: String?

    init(source: IncomeSourceSummary? = nil, suggestedName: String = "") {
        existing = source
        _name = State(initialValue: source?.name ?? suggestedName)
        _certainty = State(initialValue: source?.certainty ?? .received)
        _isActive = State(initialValue: source?.isActive ?? true)
        _preferredAccountID = State(initialValue: source?.preferredAccountID)
        _note = State(initialValue: source?.note ?? "")
    }

    var body: some View {
        Form {
            Section("Income source") {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                Picker("Certainty", selection: $certainty) {
                    ForEach(IncomeCertaintyOption.allCases) {
                        Text($0.displayName).tag($0)
                    }
                }
                if existing != nil {
                    Toggle("Active for new income", isOn: $isActive)
                }
            }

            Section {
                let snapshot = store.snapshot
                Picker("Preferred receiving account", selection: $preferredAccountID) {
                    Text("No preference").tag(String?.none)
                    if let selected = preferredAccountID,
                       !snapshot.entryOptions.accounts.contains(where: { $0.id == selected }),
                       let inactive = snapshot.accounts.first(where: { $0.id == selected }) {
                        Text("\(inactive.name) · Inactive").tag(Optional(selected))
                    }
                    ForEach(snapshot.entryOptions.accounts) { account in
                        Text("\(account.name) · \(account.currencyCode)")
                            .tag(Optional(account.id))
                    }
                }
            } footer: {
                Text("This only suggests “Received in” during entry. It never forces where a transaction is recorded.")
            }

            Section("Notes") {
                TextField("Payer or context", text: $note, axis: .vertical)
                    .lineLimit(2...5)
            }

            if let existing {
                Section("Planning context") {
                    LabeledContent("Recurrence", value: existing.recurrenceLabel)
                    if !existing.amount.isZero {
                        LabeledContent("Planned amount", value: existing.amount.formatted())
                    }
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Role.negative)
                }
            }
        }
        .navigationTitle(existing == nil ? "Add Income Source" : "Edit Income Source")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func save() {
        do {
            try store.saveIncomeSource(
                IncomeSourceDraft(
                    id: existing?.id,
                    name: name,
                    certainty: certainty,
                    isActive: isActive,
                    preferredAccountID: preferredAccountID,
                    note: note.isEmpty ? nil : note
                )
            )
            dismiss()
        } catch let error as AppManagementError {
            errorMessage = error.message
        } catch {
            errorMessage = AppManagementError.persistenceFailed(String(describing: error)).message
        }
    }
}

#Preview {
    NavigationStack { IncomeSourcesView() }
        .environment(FinanceStore.preview())
}
