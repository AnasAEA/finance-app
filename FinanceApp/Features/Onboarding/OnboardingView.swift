import SwiftUI

/// First launch, with nothing in the store.
///
/// Two ways in and no third: restore a state that already exists somewhere, or
/// start from the accounts you have. There is no sample data behind either
/// button — an app that seeds a plausible history teaches a person to distrust
/// every figure it shows afterwards.
struct OnboardingView: View {
    @Environment(FinanceStore.self) private var store
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: Theme.Metric.stackSpacing) {
            header
            OnboardingChoice(
                title: "Import current state",
                explanation: "Restore accounts, balances, commitments and planning from an exported finance file.",
                systemImage: "square.and.arrow.down",
                isPrimary: true
            ) {
                isImporting = true
            }
            OnboardingChoice(
                title: "Set up manually",
                explanation: "Start with your current accounts and balances.",
                systemImage: "plus.circle",
                isPrimary: false,
                destination: { AccountEditorView() }
            )
            footnote
        }
        .sheet(isPresented: $isImporting) { ImportCurrentStateView() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "wallet.bifold")
                .font(.system(size: 38))
                .foregroundStyle(Theme.Role.accent)
            Text("Set up your money")
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing is here yet. Choose how to begin.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var footnote: some View {
        Text("Everything stays on this device. There is no server, no sync and no sample data.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// One of the two ways in. Either pushes a destination or runs an action, so
/// the manual path keeps the Phase 2.1 account editor exactly as it is.
private struct OnboardingChoice<Destination: View>: View {
    let title: String
    let explanation: String
    let systemImage: String
    let isPrimary: Bool
    var destination: (() -> Destination)?
    var action: (() -> Void)?

    init(
        title: String,
        explanation: String,
        systemImage: String,
        isPrimary: Bool,
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.title = title
        self.explanation = explanation
        self.systemImage = systemImage
        self.isPrimary = isPrimary
        self.destination = destination
        self.action = nil
    }

    var body: some View {
        Group {
            if let destination {
                NavigationLink { destination() } label: { label }
            } else {
                Button { action?() } label: { label }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(explanation)")
        .accessibilityAddTraits(.isButton)
    }

    private var label: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(isPrimary ? Color.white : Theme.Role.accent)
                .frame(width: 40, height: 40)
                .background(
                    isPrimary ? AnyShapeStyle(Theme.Role.accent) : AnyShapeStyle(Theme.Role.accent.opacity(0.12)),
                    in: RoundedRectangle(cornerRadius: Theme.Metric.controlRadius, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .financeCard()
    }
}

extension OnboardingChoice where Destination == Never {
    init(
        title: String,
        explanation: String,
        systemImage: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.explanation = explanation
        self.systemImage = systemImage
        self.isPrimary = isPrimary
        self.destination = nil
        self.action = action
    }
}

/// Shown instead of onboarding when the stored graph could not be read.
///
/// An unreadable store is not an empty one. Offering "import current state"
/// here would invite someone to replace rows that are still the only copy of
/// themselves, so the choice is not offered and the reason is said out loud.
struct UnreadableStoreView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.Role.caution)
            Text("Your data could not be opened")
                .font(.title3.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text("The records on this device are still there. This version of the app could not read them, so it has not changed or replaced anything.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Importing is unavailable until they can be read, because an import would overwrite them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .financeCard()
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Onboarding") {
    NavigationStack {
        ScrollView { OnboardingView().padding(Theme.Metric.screenPadding) }
            .background(Theme.Surface.background)
    }
    .environment(FinanceStore.emptyPreview())
}

#Preview("Onboarding · dark, large type") {
    NavigationStack {
        ScrollView { OnboardingView().padding(Theme.Metric.screenPadding) }
            .background(Theme.Surface.background)
    }
    .environment(FinanceStore.emptyPreview())
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif

#Preview("Unreadable store") {
    ScrollView { UnreadableStoreView().padding(Theme.Metric.screenPadding) }
        .background(Theme.Surface.background)
}
