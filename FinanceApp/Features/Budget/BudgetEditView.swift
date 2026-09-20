import SwiftUI

/// Editing the month's budget: the gross ceiling, the lines that claim parts
/// of it, and which categories feed each line.
///
/// The screen keeps two facts apart that are easy to blur. The ceiling is what
/// may be *consumed* in a month, housing included and before any assistance.
/// Account liquidity is a different question, answered elsewhere. Nothing here
/// reduces an obligation because help might arrive.
struct BudgetEditView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var ceilingText = ""
    @State private var editing: BudgetLineDraft?
    @State private var error: String?

    /// One live read per composition: the ceiling, what it allocates and the
    /// lines under it are one month's budget, read once.
    var body: some View {
        content(store.snapshot.budget)
    }

    private func content(_ budget: BudgetOverview) -> some View {
        NavigationStack {
            List {
                ceilingSection(budget)
                allocationSection(budget)
                linesSection(budget)
                if budget.hasSuggestedLines { confirmSection }
                unlinkedCommitmentsSection(budget)
            }
            .financeList()
            .navigationTitle("Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        editing = BudgetLineDraft()
                    } label: {
                        Label("Add line", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editing) { draft in
                BudgetLineEditor(draft: draft)
            }
            .alert("Not saved", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
            .onAppear {
                ceilingText = budget.summary.ceiling.map { $0.editingText } ?? ""
            }
        }
    }

    // MARK: - Ceiling

    private func ceilingSection(_ budget: BudgetOverview) -> some View {
        Section {
            HStack {
                Text("Monthly ceiling")
                Spacer()
                TextField("None", text: $ceilingText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 140)
                    .onSubmit(saveCeiling)
            }
            Button("Save ceiling", action: saveCeiling)
                .disabled(ceilingText == (budget.summary.ceiling.map { $0.editingText } ?? ""))
        } header: {
            Text("Gross economic spending")
        } footer: {
            Text("Everything you consume in a month, rent included, measured before any assistance. Housing assistance you have not received is income elsewhere in the plan — it never makes the rent smaller here.")
        }
    }

    private func saveCeiling() {
        let trimmed = ceilingText.trimmingCharacters(in: .whitespaces)
        do {
            if trimmed.isEmpty {
                try store.setMonthlyEconomicCeiling(nil)
            } else {
                let parsed = try Amount.parse(trimmed, currencyCode: "EUR", fractionDigits: 2)
                try store.setMonthlyEconomicCeiling(parsed)
            }
        } catch let failure as AppManagementError {
            error = failure.message
        } catch {
            self.error = "Enter an amount in euro, or leave it blank for no ceiling."
        }
    }

    // MARK: - Allocation

    private func allocationSection(_ budget: BudgetOverview) -> some View {
        Section("This month") {
            LabeledContent("Allocated") { MoneyText(amount: budget.target, size: 15, weight: .medium) }
            if let unallocated = budget.unallocated {
                LabeledContent("Unallocated") {
                    MoneyText(amount: unallocated, size: 15, weight: .medium)
                }
                if unallocated.isNegative {
                    Label("The lines allocate more than the ceiling allows.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Theme.Role.negative)
                }
            }
            LabeledContent("Spent") { MoneyText(amount: budget.summary.spent, size: 15, weight: .medium) }
            LabeledContent("Still committed") {
                MoneyText(amount: budget.summary.committed, size: 15, weight: .medium)
            }
        }
    }

    // MARK: - Lines

    private func linesSection(_ budget: BudgetOverview) -> some View {
        Section {
            if budget.lines.isEmpty {
                Text("No lines yet. Add one to claim part of the ceiling.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(budget.lines) { line in
                Button {
                    editing = draft(for: line)
                } label: {
                    BudgetLineEditRow(line: line)
                }
                .buttonStyle(.plain)
            }
            .onDelete(perform: delete)
        } header: {
            Text("Lines")
        } footer: {
            Text("A category can only feed one line, so spending is never counted twice. Spending in a category no line claims stays in the month's total and is shown separately.")
        }
    }

    private func draft(for line: BudgetLine) -> BudgetLineDraft {
        BudgetLineDraft(
            id: line.key,
            name: line.name,
            monthlyTarget: line.limit,
            spendingClass: line.spendingClass,
            categoryKeys: store.categoryKeys(forBudget: line.key)
        )
    }

    private func delete(_ offsets: IndexSet) {
        // A deletion is its own operation, not part of a render.
        let lines = store.snapshot.budget.lines
        for index in offsets where lines.indices.contains(index) {
            do {
                try store.deleteBudgetLine(id: lines[index].key)
            } catch let failure as AppManagementError {
                error = failure.message
            } catch {
                self.error = String(describing: error)
            }
        }
    }

    // MARK: - Confirmation

    private var confirmSection: some View {
        Section {
            Button("Accept the suggested targets") {
                do {
                    try store.confirmSuggestedBudgetLines()
                } catch let failure as AppManagementError {
                    error = failure.message
                } catch {
                    self.error = String(describing: error)
                }
            }
        } footer: {
            Text("Suggested targets are the app's proposal from your own figures. They stay marked as proposals until you accept or change them.")
        }
    }

    // MARK: - Commitments

    /// Recurring charges with no line to land in. Until one is chosen their
    /// settled charges count in the month total but in no category.
    private func unlinkedCommitmentsSection(_ budget: BudgetOverview) -> some View {
        Section {
            let unlinked = store.unlinkedCommitments()
            if unlinked.isEmpty {
                Text("Every recurring charge belongs to a line.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(unlinked) { commitment in
                Picker(commitment.name, selection: budgetBinding(for: commitment.id)) {
                    Text("No line").tag(String?.none)
                    ForEach(budget.lines) { line in
                        Text(line.name).tag(Optional(line.key))
                    }
                }
            }
        } header: {
            Text("Recurring charges")
        } footer: {
            Text("Linking a charge to a line puts the money it takes inside that line, both while it is still owed and once it is paid.")
        }
    }

    private func budgetBinding(for obligationID: String) -> Binding<String?> {
        Binding(
            get: { store.budgetID(forObligation: obligationID) },
            set: { newValue in
                do {
                    try store.setBudget(newValue, forObligation: obligationID)
                } catch let failure as AppManagementError {
                    error = failure.message
                } catch {
                    self.error = String(describing: error)
                }
            }
        )
    }
}

private struct BudgetLineEditRow: View {
    let line: BudgetLine

    var body: some View {
        HStack {
            Label(line.name, systemImage: line.symbolName)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(amount: line.limit, size: 15, weight: .medium)
                if line.isSuggested {
                    Text("Suggested").font(.caption2).foregroundStyle(Theme.Role.caution)
                }
            }
        }
    }
}

/// One line's name, target, class and categories.
struct BudgetLineEditor: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft: BudgetLineDraft
    @State private var targetText: String
    @State private var error: String?

    init(draft: BudgetLineDraft) {
        _draft = State(initialValue: draft)
        _targetText = State(initialValue: draft.monthlyTarget.isZero ? "" : draft.monthlyTarget.editingText)
    }

    private var spendingCategories: [CategoryOption] {
        store.snapshot.entryOptions.categories.filter { !$0.isIncome && !$0.isTransfer }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Line") {
                    TextField("Name", text: $draft.name)
                    HStack {
                        Text("Monthly target")
                        Spacer()
                        TextField("0.00", text: $targetText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 140)
                    }
                    Picker("Kind", selection: $draft.spendingClass) {
                        ForEach(BudgetSpendingClass.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                }

                Section {
                    ForEach(spendingCategories) { category in
                        Button {
                            toggle(category.key)
                        } label: {
                            HStack {
                                Label(category.name, systemImage: category.symbolName)
                                Spacer()
                                if draft.categoryKeys.contains(category.key) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.Role.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Counts towards this line")
                } footer: {
                    Text("A line with no categories is still fed by any recurring charge linked to it.")
                }
            }
            .financeList()
            .navigationTitle(draft.id == nil ? "New line" : "Edit line")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
            .alert("Not saved", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func toggle(_ key: String) {
        if let index = draft.categoryKeys.firstIndex(of: key) {
            draft.categoryKeys.remove(at: index)
        } else {
            draft.categoryKeys.append(key)
        }
    }

    private func save() {
        var saved = draft
        do {
            let text = targetText.trimmingCharacters(in: .whitespaces)
            saved.monthlyTarget = text.isEmpty
                ? .zeroEUR
                : try Amount.parse(text, currencyCode: "EUR", fractionDigits: 2)
            try store.saveBudgetLine(saved)
            dismiss()
        } catch let failure as AppManagementError {
            error = failure.message
        } catch {
            self.error = "Enter a target in euro, for example 70.00."
        }
    }
}
