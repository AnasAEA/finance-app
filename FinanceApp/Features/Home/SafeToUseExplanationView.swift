import SwiftUI

/// The answer behind Home's headline: what the figure is made of, what is
/// pressing on it, and where to go to see the obligations themselves.
///
/// Read-only, and arithmetic-free. Every figure arrives already reconciled
/// from `SafeToUseExplanation`; this file subtracts nothing, clamps nothing
/// and decides nothing about what is safe. When the components do not
/// reconcile with the headline, there is no breakdown to render and it says so
/// rather than printing one.
struct SafeToUseExplanationView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        // One live read per composition, so the headline, the two terms and
        // the notes all describe the same plan at the same moment.
        let presentation = store.currentPresentation()
        let explanation = SafeToUseExplanation.make(
            from: presentation.snapshot,
            isAvailable: presentation.attention.heroIsAvailable
        )
        return Group {
            switch explanation {
            case let .explained(breakdown):
                explained(breakdown)
            case let .unavailable(reason):
                unavailable(reason)
            }
        }
        .navigationTitle("Safe to Use")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(SafeToUseID.screen)
    }

    // MARK: - Explained

    private func explained(_ breakdown: SafeToUseBreakdown) -> some View {
        List {
            Section { headline(breakdown) }

            Section {
                LedgerRow(label: "Money on your accounts", value: breakdown.cash)
                    .accessibilityIdentifier(SafeToUseID.cash)
                LedgerRow(
                    label: "Already committed",
                    value: breakdown.committed.negated,
                    caption: breakdown.windowCaption,
                    colorBySign: true
                )
                .accessibilityIdentifier(SafeToUseID.committed)
                LedgerRow(
                    label: breakdown.resultLabel,
                    value: breakdown.resultValue,
                    emphasis: true,
                    valueTint: breakdown.isShort ? Theme.Role.negative : nil
                )
                .accessibilityIdentifier(SafeToUseID.result)
            } header: {
                Text("How it's worked out")
            } footer: {
                Text(breakdown.methodFooter)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(breakdown.notes, id: \.self) { note in
                noteSection(note)
            }

            Section {
                Button {
                    navigation.openPlan(.upcoming)
                } label: {
                    HStack {
                        Text("See what's committed")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier(SafeToUseID.seeCommitted)
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, Theme.Metric.floatingTabBarClearance, for: .scrollContent)
    }

    /// The headline is restated, not recalculated: the same figure the person
    /// tapped, so arriving here can never look like a different answer.
    private func headline(_ breakdown: SafeToUseBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("Safe to use", tint: breakdown.isShort ? Theme.Role.negative : .secondary)
            MoneyText(amount: breakdown.safeToUse, size: 34, weight: .bold)
                .accessibilityIdentifier(SafeToUseID.headline)
            Text(breakdown.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(SafeToUseID.summary)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func noteSection(_ note: SafeToUseNote) -> some View {
        switch note {
        case let .setAside(amount):
            Section {
                LedgerRow(label: "Set aside for goals", value: amount)
            } header: {
                Text("Already inside this figure")
            } footer: {
                Text("This money is still on your accounts, so it is part of the amount above. Setting it aside does not reduce what is safe to use.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier(SafeToUseID.setAside)

        case let .notCounted(holdings):
            Section {
                ForEach(holdings) { holding in
                    LedgerRow(
                        label: holding.title,
                        value: holding.balance,
                        caption: holding.subtitle
                    )
                }
            } header: {
                Text("Not counted")
            } footer: {
                Text("Notes, coins and money held in another currency are outside this figure. It counts only balances that can settle a payment from an account.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier(SafeToUseID.notCounted)
        }
    }

    // MARK: - Unavailable

    private func unavailable(_ reason: SafeToUseUnavailability) -> some View {
        Group {
            switch reason {
            case .projectionUnavailable:
                ContentUnavailableView(
                    "No figure to explain",
                    systemImage: "questionmark.circle",
                    description: Text("Today's projection hasn't finished, so there is no safe-to-use amount yet.")
                )
            case .componentsDoNotReconcile:
                ContentUnavailableView(
                    "Explanation unavailable",
                    systemImage: "questionmark.circle",
                    description: Text("The figures behind today's amount don't account for it exactly, so this screen won't guess at them.")
                )
            }
        }
        .accessibilityIdentifier(SafeToUseID.unavailable)
    }
}

#Preview {
    NavigationStack { SafeToUseExplanationView() }
        .environment(FinanceStore.preview())
        .environment(AppNavigation())
}
