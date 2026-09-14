import SwiftUI

/// Explicit “Can I afford this?” check. Running it does not book a purchase.
/// The sheet remains available for goal-scoped checks; production Plan uses
/// the pushed `AffordabilityCheckView` below as the canonical route.
struct AffordabilitySheet: View {
    private let draft: AffordabilityDraft

    init(draft: AffordabilityDraft = AffordabilityDraft()) {
        self.draft = draft
    }

    var body: some View {
        NavigationStack {
            AffordabilityCheckView(draft: draft, showsClose: true)
        }
    }
}

/// Full navigation destination for input, explanation, result and future
/// expansion. Evaluation is still the same pure store call.
struct AffordabilityCheckView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let showsClose: Bool
    @State private var draft: AffordabilityDraft
    @State private var result: AffordabilityPresentation?
    @State private var error: String?
    @State private var showAdvanced = false
    @State private var pickerRange: ClosedRange<Date>?
    @FocusState private var amountFocused: Bool

    init(draft: AffordabilityDraft = AffordabilityDraft(), showsClose: Bool = false) {
        self.showsClose = showsClose
        _draft = State(initialValue: draft)
    }

    /// One live read per composition. The pickers below are all filled from
    /// the same plan state; reading the store per picker would let one sheet
    /// built across local midnight offer choices from two civil days. The
    /// `onAppear` default below is deliberately a separate operation — it is
    /// the person opening the sheet, not this render.
    var body: some View {
        let snapshot = store.snapshot
        return Form {
            inputSection(snapshot)
            if showAdvanced { advancedSection(snapshot) }
            if let result {
                resultSections(result)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            let defaults = store.affordabilityDefaults()
            if draft.on == nil { draft.on = defaults.day }
            pickerRange = defaults.range
        }
        .navigationTitle("Can I afford this?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { amountFocused = false }
            }
            if showsClose {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Check") { run() }
                    .accessibilityIdentifier(PlanningControlID.checkAffordability)
            }
        }
        .alert("Could not check", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func inputSection(_ snapshot: FinanceAppSnapshot) -> some View {
        Section {
            if !snapshot.plannedPurchases.isEmpty {
                Picker("Prefill from a goal", selection: $draft.plannedPurchaseID) {
                    Text("None").tag(Optional<String>.none)
                    ForEach(snapshot.plannedPurchases) { goal in
                        Text(goal.name).tag(Optional(goal.id))
                    }
                }
                .onChange(of: draft.plannedPurchaseID) { _, id in
                    if let id { draft = store.affordabilityDraft(prefilledFromGoalID: id) }
                }
                .accessibilityIdentifier("afford.goal")
            }
            HStack {
                Text("Amount")
                Spacer()
                TextField("0", text: $draft.amountText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .focused($amountFocused)
                    .accessibilityIdentifier("afford.amount")
            }
            Picker("Currency", selection: $draft.currencyCode) {
                ForEach(CurrencyOption.common) { option in
                    Text(option.code).tag(option.code)
                }
            }
            .onChange(of: draft.currencyCode) { _, code in
                draft.fractionDigits = CurrencyOption.common.first { $0.code == code }?.fractionDigits ?? 2
            }
            CivilDatePicker("When", selection: $draft.on, in: pickerRange)
                .accessibilityIdentifier("afford.date")
            Picker("Pay from", selection: $draft.accountID) {
                Text("Any eligible account").tag(Optional<String>.none)
                ForEach(snapshot.accounts.filter(\.isActive)) { account in
                    Text(account.name).tag(Optional(account.id))
                }
            }
            .accessibilityIdentifier("afford.account")
            Picker("How it pays", selection: $draft.rail) {
                ForEach(PaymentRailChoice.allCases) { rail in
                    Text(rail.displayName).tag(rail)
                }
            }
            Button(showAdvanced ? "Hide details" : "More details") {
                showAdvanced.toggle()
            }
            .font(.caption)
        } footer: {
            Text("This is a check, not a decision and not a payment.")
        }
    }

    private func advancedSection(_ snapshot: FinanceAppSnapshot) -> some View {
        Section("Funding") {
            Picker("Pay with", selection: $draft.funding) {
                ForEach(GoalFundingKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .onChange(of: draft.funding) { _, kind in
                if kind != .sinkingFund { draft.sinkingFundID = nil }
                if kind != .financing { draft.installmentPlanID = nil }
            }
            if draft.funding == .sinkingFund {
                Picker("Sinking fund", selection: $draft.sinkingFundID) {
                    Text("Choose a fund").tag(Optional<String>.none)
                    ForEach(snapshot.sinkingFunds.filter { $0.status == .active }) { fund in
                        Text(fund.name).tag(Optional(fund.id))
                    }
                }
            }
            if draft.funding == .financing {
                if snapshot.instalments.isEmpty {
                    Text("No financing plan on file. The check will treat this as a cash purchase.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Plan", selection: $draft.installmentPlanID) {
                        Text("Choose a plan").tag(Optional<String>.none)
                        ForEach(snapshot.instalments) { plan in
                            Text(plan.title).tag(Optional(plan.id))
                        }
                    }
                }
            }
            Toggle("This is only setting money aside", isOn: $draft.asReservation)
        }
    }

    @ViewBuilder
    private func resultSections(_ result: AffordabilityPresentation) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(result.overall.displayName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(overallTint(result.overall))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(PlanningControlID.affordabilityOverall)
                ForEach(result.why, id: \.self) { line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if result.countsAsSpending {
            Section("Monthly budget") {
                if let remaining = result.budgetRemaining, let after = result.budgetAfter {
                    LedgerRow(label: "Remaining now", value: remaining)
                    LedgerRow(label: "This purchase", value: result.purchaseEconomic)
                    LedgerRow(label: "After purchase", value: after, colorBySign: true)
                    if result.withinBudget == false {
                        Text("This would go over the monthly spending budget, even if the cash is there.")
                            .font(.caption)
                            .foregroundStyle(Theme.Role.negative)
                    }
                } else {
                    Text("No monthly budget ceiling is set, so the budget axis cannot be judged.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Section("Monthly budget") {
                Text("Setting money aside is not spending, so it does not use the monthly budget.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Cash") {
            LedgerRow(label: "On the accounts", value: result.ledgerCash)
            LedgerRow(label: "Set aside", value: result.reserved)
            LedgerRow(label: "Unreserved", value: result.unreservedCash)
            Text("Unreserved cash is not Home “safe to spend”. That Home figure is unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("This payment") {
            if result.settlementCovers {
                Text("The selected account and rail can settle this amount.")
                    .font(.subheadline)
            } else if result.poolUnreserved.minorUnits >= result.settlementAvailable.minorUnits {
                Text("You have enough cash overall, but \(result.settlementAccountName ?? "this account") does not have enough to make the payment. No transfer is assumed.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Role.caution)
            } else {
                Text("There is not enough unreserved cash to settle this payment.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Role.negative)
            }
            LedgerRow(label: "Available on this rail", value: result.settlementAvailable)
        }

        Section("Cash risk") {
            switch result.firstRiskKind {
            case .none:
                Text("No cash-risk date in the plan window.")
                    .font(.subheadline)
            case .hardDeficit:
                Text(riskLine(prefix: "Cash would go below zero", result: result))
                    .font(.subheadline)
                    .foregroundStyle(Theme.Role.negative)
                    .accessibilityIdentifier(PlanningControlID.affordabilityRisk)
            case .reserveWarning:
                Text(riskLine(prefix: "Cash would dip below the safety reserve, without going negative", result: result))
                    .font(.subheadline)
                    .foregroundStyle(Theme.Role.caution)
                    .accessibilityIdentifier(PlanningControlID.affordabilityRisk)
            }
        }

        if let income = result.requiredIncome {
            Section("Only if") {
                Text("Affordable only if \(income) actually arrives. That is not treated as money you have.")
                    .font(.subheadline)
            }
        }

        if let before = result.sinkingReservedBefore,
           let used = result.sinkingConsumed,
           let after = result.sinkingReservedAfter {
            Section("Sinking fund") {
                LedgerRow(label: "Set aside now", value: before)
                LedgerRow(label: "Used by this purchase", value: used)
                LedgerRow(label: "Still set aside after", value: after)
                Text("This is a simulation. The fund is not changed until you edit it yourself.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if let note = result.financingNote {
            Section("Financing") {
                Text(note)
                    .font(.subheadline)
            }
        }
    }

    private func overallTint(_ overall: AffordabilityOverallKind) -> Color {
        switch overall {
        case .affordable: Theme.Role.positive
        case .affordableConditionally: Theme.Role.caution
        case .notAffordable: Theme.Role.negative
        }
    }

    private func riskLine(prefix: String, result: AffordabilityPresentation) -> String {
        guard let date = result.firstRiskDate else { return prefix + "." }
        let day = date.formatted(.dateTime.day().month(.wide))
        if let label = result.firstRiskLabel, !label.isEmpty {
            return "\(prefix) on \(day) — \(label)."
        }
        return "\(prefix) on \(day)."
    }

    private func run() {
        amountFocused = false
        do {
            result = try store.evaluateAffordability(draft)
            error = nil
        } catch let problem as AppManagementError {
            error = problem.message
        } catch {
            self.error = String(describing: error)
        }
    }
}
