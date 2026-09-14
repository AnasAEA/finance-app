import SwiftUI

/// Create or edit a planned purchase. Saving this is not a transaction.
struct GoalEditorView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft: PlannedPurchaseDraft
    @State private var error: String?
    @State private var isCreatingFund = false
    @State private var confirmDelete = false

    init(draft: PlannedPurchaseDraft = PlannedPurchaseDraft()) {
        _draft = State(initialValue: draft)
    }

    private func compatibleFunds(_ snapshot: FinanceAppSnapshot) -> [SinkingFundSummary] {
        snapshot.sinkingFunds.filter {
            $0.status == .active && $0.target.currencyCode == draft.currencyCode
        }
    }

    /// The person opening this editor is a separate operation from rendering it.
    static func defaultDate(store: FinanceStore) -> CalendarDay? {
        store.currentDay()
    }

    /// One live read per composition.
    var body: some View {
        content(store.snapshot)
    }

    private func content(_ snapshot: FinanceAppSnapshot) -> some View {
        let compatibleFunds = compatibleFunds(snapshot)
        return NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .accessibilityIdentifier(PlanningControlID.goalName)
                    HStack {
                        Text("Amount")
                        Spacer()
                        TextField("0", text: $draft.amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier(PlanningControlID.goalAmount)
                    }
                    Picker("Currency", selection: $draft.currencyCode) {
                        ForEach(CurrencyOption.common) { option in
                            Text(option.code).tag(option.code)
                        }
                    }
                    .onChange(of: draft.currencyCode) { _, code in
                        draft.fractionDigits = CurrencyOption.common.first { $0.code == code }?.fractionDigits ?? 2
                    }
                } footer: {
                    Text("This is a plan, not a payment. Nothing is booked until you enter a real transaction.")
                }

                Section {
                    Toggle("Target date", isOn: $draft.hasTargetDate)
                    if draft.hasTargetDate {
                        CivilDatePicker("On", selection: $draft.targetDate)
                    }
                    Picker("Status", selection: $draft.status) {
                        ForEach(GoalStatus.allCases) { status in
                            Text(status.displayName).tag(status)
                        }
                    }
                    .accessibilityIdentifier("goal.status")
                    Text(draft.status.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Pay with", selection: $draft.funding) {
                        ForEach(GoalFundingKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .accessibilityIdentifier("goal.funding")
                    .onChange(of: draft.funding) { _, kind in
                        if kind != .sinkingFund { draft.sinkingFundID = nil }
                        if kind != .financing { draft.installmentPlanID = nil }
                    }
                    if draft.funding == .sinkingFund {
                        if compatibleFunds.isEmpty {
                            Text("No compatible fund yet. Create a sinking fund first — one is not created automatically.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Create a fund") { isCreatingFund = true }
                        } else {
                            Picker("Sinking fund", selection: $draft.sinkingFundID) {
                                Text("Choose a fund").tag(Optional<String>.none)
                                ForEach(compatibleFunds) { fund in
                                    Text(fund.name).tag(Optional(fund.id))
                                }
                            }
                            Button("Create another fund") { isCreatingFund = true }
                                .font(.caption)
                        }
                    }
                    if draft.funding == .financing {
                        if snapshot.instalments.isEmpty {
                            Text("No financing plan is on file. This stays a plan; it does not create repayments.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Existing plan", selection: $draft.installmentPlanID) {
                                Text("None yet").tag(Optional<String>.none)
                                ForEach(snapshot.instalments) { plan in
                                    Text(plan.title).tag(Optional(plan.id))
                                }
                            }
                        }
                    }
                } footer: {
                    Text("A sinking fund owns the reservation. This goal does not copy that amount.")
                }

                Section("Note") {
                    TextField("Optional", text: $draft.note, axis: .vertical)
                }

                if draft.id != nil {
                    Section {
                        Button("Delete goal", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .onAppear { if draft.targetDate == nil { draft.targetDate = Self.defaultDate(store: store) } }
        .navigationTitle(draft.id == nil ? "New goal" : "Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .accessibilityIdentifier(PlanningControlID.goalSave)
                }
            }
            .sheet(isPresented: $isCreatingFund) {
                SinkingFundEditorView(draft: fundDraftForNewFund)
            }
            .confirmationDialog("Delete this goal?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteGoal() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the plan item. It does not delete a transaction.")
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

    private var fundDraftForNewFund: SinkingFundDraft {
        var created = SinkingFundDraft()
        created.currencyCode = draft.currencyCode
        created.fractionDigits = draft.fractionDigits
        created.goalID = draft.id
        return created
    }

    private func save() {
        do {
            try store.savePlannedPurchase(draft)
            dismiss()
        } catch let problem as AppManagementError {
            error = problem.message
        } catch {
            self.error = AppManagementError.persistenceFailed(String(describing: error)).message
        }
    }

    private func deleteGoal() {
        guard let id = draft.id else { return }
        do {
            try store.deletePlannedPurchase(id: id)
            dismiss()
        } catch let problem as AppManagementError {
            error = problem.message
        } catch {
            self.error = AppManagementError.persistenceFailed(String(describing: error)).message
        }
    }
}
