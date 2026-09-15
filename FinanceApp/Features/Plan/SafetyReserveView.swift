import SwiftUI

/// The planning control for the cash floor the forecast already uses.
///
/// Read the configured amount, see how the projection sits against it, and
/// change the floor. Saving writes only the planning reserve through the
/// store; it does not move money, rewrite history, or invent a second local
/// value.
struct SafetyReserveView: View {
    @Environment(FinanceStore.self) private var store

    @State private var amountText = ""
    @State private var error: String?

    var body: some View {
        let presentation = store.currentPresentation()
        let explanation = SafetyReserveExplanation.make(
            from: presentation.snapshot,
            isAvailable: presentation.attention.heroIsAvailable
        )
        return content(explanation, snapshot: presentation.snapshot)
            .navigationTitle("Safety reserve")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(SafetyReserveID.screen)
            .onAppear { amountText = presentation.snapshot.safetyReserve?.editingText ?? "" }
            .alert("Not saved", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
    }

    @ViewBuilder
    private func content(
        _ explanation: SafetyReserveExplanation,
        snapshot: FinanceAppSnapshot
    ) -> some View {
        List {
            Section {
                switch explanation {
                case .none:
                    Text("No safety reserve")
                        .font(.title2.weight(.semibold))
                        .accessibilityIdentifier(SafetyReserveID.amount)
                case let .configured(breakdown):
                    MoneyText(amount: breakdown.amount, size: 34, weight: .semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(SafetyReserveID.amount)
                }
                Text(SafetyReserveBreakdown.meaning)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(SafetyReserveID.meaning)
            }

            comparisonSection(explanation)

            Section {
                HStack {
                    Text("Amount")
                    Spacer()
                    TextField("None", text: $amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 140)
                        .accessibilityIdentifier(PlanningControlID.reserveAmount)
                        .onSubmit(save)
                }
                Button("Save reserve", action: save)
                    .disabled(amountText == (snapshot.safetyReserve?.editingText ?? ""))
                    .accessibilityIdentifier(PlanningControlID.reserveSave)
            } header: {
                Text("Change reserve")
            } footer: {
                Text(SafetyReserveBreakdown.distinction)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func comparisonSection(_ explanation: SafetyReserveExplanation) -> some View {
        switch explanation {
        case .none:
            EmptyView()
        case let .configured(breakdown):
            Section {
                switch breakdown.comparison {
                case .unavailable:
                    Text(breakdown.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(SafetyReserveID.unavailable)
                case let .staysAbove(lowest, _):
                    LedgerRow(label: "Lowest projected cash", value: lowest)
                        .accessibilityIdentifier(SafetyReserveID.lowest)
                    LedgerRow(label: "Safety reserve", value: breakdown.amount)
                    Text(breakdown.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(SafetyReserveID.comparison)
                case let .dipsBelow(lowest, _, _):
                    LedgerRow(
                        label: "Lowest projected cash",
                        value: lowest,
                        colorBySign: true,
                        valueTint: lowest.isNegative ? Theme.Role.negative : Theme.Role.caution
                    )
                    .accessibilityIdentifier(SafetyReserveID.lowest)
                    LedgerRow(label: "Safety reserve", value: breakdown.amount)
                    Text(breakdown.summary)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Role.caution)
                        .accessibilityIdentifier(SafetyReserveID.comparison)
                }
            } header: {
                Text("Against the plan")
            }
        }
    }

    private func save() {
        let trimmed = amountText.trimmingCharacters(in: .whitespaces)
        do {
            if trimmed.isEmpty {
                try store.setSafetyReserve(nil)
            } else {
                let parsed = try Amount.parse(trimmed, currencyCode: "EUR", fractionDigits: 2)
                try store.setSafetyReserve(parsed)
            }
            amountText = store.snapshot.safetyReserve?.editingText ?? ""
        } catch let failure as AppManagementError {
            error = failure.message
        } catch {
            self.error = "Enter an amount in euro, or leave it blank for no reserve."
        }
    }
}
