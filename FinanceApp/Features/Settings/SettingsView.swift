import SwiftUI

/// Configuration reached from Home's gear. Financial browsing stays on Home
/// and Plan; this list owns provider setup, automation, privacy and app-level
/// behaviour after the production More tab is removed.
struct SettingsView: View {
    @Environment(FinanceStore.self) private var store

    /// One live read per composition: the rule count and the bank freshness
    /// caption come from the same sample, so they cannot describe two moments.
    var body: some View {
        let presentation = store.currentPresentation()
        return content(presentation.snapshot, presentation.freshness)
    }

    private func content(
        _ snapshot: FinanceAppSnapshot, _ freshness: BankFreshnessEvaluation
    ) -> some View {
        List {
            Section {
                NavigationLink(value: HomeRoute.banks) {
                    settingsRow(
                        "Banks & Sync",
                        systemImage: "antenna.radiowaves.left.and.right",
                        detail: Self.banksDetail(freshness, pairing: store.pairingState)
                    )
                }
                .accessibilityIdentifier(RouteID.settingsBanks)

                NavigationLink(value: HomeRoute.automation) {
                    settingsRow(
                        "Automation",
                        systemImage: "checkmark.shield",
                        detail: "\(snapshot.trustedRules.count) trusted rule\(snapshot.trustedRules.count == 1 ? "" : "s")"
                    )
                }
                .accessibilityIdentifier(RouteID.settingsAutomation)
            }

            Section {
                NavigationLink(value: HomeRoute.data) {
                    settingsRow(
                        "Data & Privacy",
                        systemImage: "lock.shield",
                        detail: "On this device only"
                    )
                }
                .accessibilityIdentifier(RouteID.settingsData)

                NavigationLink(value: HomeRoute.appSettings) {
                    settingsRow(
                        "App Settings",
                        systemImage: "slider.horizontal.3",
                        detail: "Appearance and accessibility"
                    )
                }
                .accessibilityIdentifier(RouteID.settingsApp)
            }

            Section {
                LabeledContent("Accounts", value: "\(snapshot.accounts.count)")
            } footer: {
                Text("Browse balances and account activity from Home → Cash. Provider configuration stays in Banks & Sync.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The one line under "Banks & Sync", and the only place a person reads
    /// about sync before deciding whether to open it.
    ///
    /// Configuration is asked first, and `BankFreshness` cannot answer it.
    /// That type answers "is my bank data current?", and for a build with no
    /// service address and a device that simply has not paired it correctly
    /// gives the same answer — `notConnected`, say nothing — because Home has
    /// nothing to report in either case. Settings is not Home: it is where a
    /// person comes to *act*, and the two states need opposite actions. One is
    /// fixed with a pairing code. The other cannot be fixed from inside the
    /// app at all, and "Not paired" would send somebody looking for a Pair
    /// button that the screen behind this row deliberately does not offer.
    ///
    /// Internal rather than private so a test can assert the sentence itself
    /// rather than the state that produced it.
    static func banksDetail(
        _ evaluation: BankFreshnessEvaluation, pairing: BankPairingState
    ) -> String {
        if pairing == .notConfigured { return "Not available on this build" }
        return switch evaluation.state {
        case .notConnected: "Not paired"
        case .neverSynced: "Not synced yet"
        case .updated: evaluation.caption ?? "Synced"
        case .stale: "Needs attention"
        case .needsAttention: "Reconnect or check sync"
        }
    }

    private func settingsRow(_ title: String, systemImage: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.Role.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The master switch and the rules it can apply are one control surface. The
/// existing store methods remain the only mutation boundary.
struct AutomationView: View {
    @Environment(FinanceStore.self) private var store
    @State private var failure: String?

    var body: some View {
        List {
            Section {
                Toggle(
                    "Trusted Automation",
                    isOn: Binding(
                        get: { store.trustedAutomationEnabled },
                        set: { enabled in
                            do {
                                try store.setTrustedAutomationEnabled(enabled)
                            } catch {
                                failure = "The setting could not be saved."
                            }
                        }
                    )
                )
                if let diagnostic = store.trustedAutomationDiagnostic {
                    Label(diagnostic, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.Role.caution)
                }
            } footer: {
                Text("Only rules you explicitly approved. Risky types stay in To Review. Turning this on does not process the current queue.")
            }

            Section {
                NavigationLink("Trusted Rules") {
                    TrustedRulesView()
                }
            } footer: {
                Text("Rules begin as suggestions. Automatic resolution is a separate approval.")
            }
        }
        .navigationTitle("Automation")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn’t save", isPresented: Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }
}

struct AppSettingsView: View {
    var body: some View {
        List {
            Section("Interface") {
                LabeledContent("Appearance", value: "Follows system")
                LabeledContent("Text size", value: "System setting")
            }
            Section("Privacy") {
                LabeledContent("Analytics", value: "None")
                LabeledContent("Storage", value: "On this device")
            }
        }
        .navigationTitle("App Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}
