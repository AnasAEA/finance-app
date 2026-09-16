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
                        detail: Self.automationDetail(
                            ruleCount: snapshot.trustedRules.count,
                            pairing: store.pairingState
                        )
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

    /// The one line under "Automation".
    ///
    /// A rule count invites a person into a screen whose main control cannot do
    /// anything on a build with no sync service — Trusted Automation only ever
    /// acts as the last phase of a bank-evidence import, and no import can
    /// happen here. It says the same thing the Banks & Sync row says in the
    /// same words, because it is the same fact about the same build.
    ///
    /// Internal rather than private so a test can assert the sentence itself
    /// rather than the state that produced it.
    static func automationDetail(ruleCount: Int, pairing: BankPairingState) -> String {
        guard pairing.canReceiveBankEvidence else { return "Not available on this build" }
        return "\(ruleCount) trusted rule\(ruleCount == 1 ? "" : "s")"
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
///
/// The switch is offered only where it can do something. Trusted Automation has
/// exactly one effect: after a bank-evidence import lands, it may resolve rows
/// that import made newly eligible. It never reprocesses a queue — the footer
/// below has always said so — so on a build with no sync service, where no
/// import can ever happen, the toggle is a control with no reachable outcome.
///
/// Nothing is written when it is unavailable. The stored preference is a
/// device-local `StoredEntryPreferences` value, untouched by this screen and by
/// a restore, so a build that later gains a sync service finds the person's
/// choice exactly as they left it.
struct AutomationView: View {
    @Environment(FinanceStore.self) private var store
    @State private var failure: String?

    var body: some View {
        List {
            if store.pairingState.canReceiveBankEvidence {
                automationSwitch
            } else {
                unavailable
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

    @ViewBuilder
    private var automationSwitch: some View {
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
    }

    /// Said here rather than on Banks & Sync, because this is the screen a
    /// person reaches while looking for this control.
    ///
    /// The second line appears only for somebody who had already turned it on,
    /// and exists so that "unavailable" cannot be read as "we switched your
    /// setting off". Nothing on this path writes.
    @ViewBuilder
    private var unavailable: some View {
        Section {
            // "Trusted Automation unavailable" is too long for the title of a
            // `ContentUnavailableView`, which gives its title one line and
            // truncates it — measured on the phone as "Trusted Automation
            // una…". The screen is already called Automation, so the title is
            // short and the description names the control in its first words.
            ContentUnavailableView(
                "Automation unavailable",
                systemImage: "checkmark.shield",
                description: Text(Self.unavailableReason(wasEnabled: store.trustedAutomationEnabled))
            )
            .accessibilityIdentifier(AutomationID.unavailable)
        }
    }

    /// Internal rather than private so a test can assert the claim, including
    /// the promise that a stored preference survives.
    static func unavailableReason(wasEnabled: Bool) -> String {
        let reason = "Trusted Automation acts on bank activity as it arrives. Bank sync is not configured for this build, so none can."
        guard wasEnabled else { return reason }
        return "\(reason) Your choice to turn it on is kept, and applies again if this build gains bank sync."
    }
}

/// The Automation screen's one addressable region.
enum AutomationID {
    static let unavailable = "automation.unavailable"
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
