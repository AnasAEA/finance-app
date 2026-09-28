import SwiftUI

/// Connected Accounts.
///
/// The screen answers three questions in order: is this device allowed to sync,
/// which bank accounts does it know about, and which of those does this ledger
/// actually track. Every fetch persists provider evidence first. When the
/// separate default-off Trusted Automation control is enabled, only explicitly
/// approved safe expense rules may then resolve newly eligible rows.
struct BankSyncView: View {
    @Environment(FinanceStore.self) private var store

    @State private var isPairing = false
    @State private var mappingTarget: MappableRemoteAccount?
    @State private var failure: String?

    /// One live read per composition: the connection list and the mappable
    /// accounts describe the same provider directory at the same moment.
    var body: some View {
        content(store.snapshot)
    }

    private func content(_ snapshot: FinanceAppSnapshot) -> some View {
        let connections = snapshot.providerConnections
        let remoteAccounts = snapshot.mappableRemoteAccounts
        return List {
            switch store.pairingState {
            case .notConfigured:
                Section {
                    ContentUnavailableView(
                        "Bank sync is not configured",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("This build has no sync service address.")
                    )
                }
            case .unpaired, .revoked:
                pairingSection
            case .paired:
                syncSection
                connectionsSection(connections)
                accountsSection(remoteAccounts)
                deviceSection
            }
            // Omitted rather than shown as unavailable: this screen already
            // says, at the top and in as many words, that the build has no
            // sync service. A second card repeating it under a different
            // heading would be noise. Settings → Automation is the screen a
            // person reaches while actually looking for this control, and that
            // one does explain its absence.
            if store.pairingState.canReceiveBankEvidence {
                trustedAutomationSection
            }
        }
        .financeList()
        .navigationTitle("Banks & Sync")
        .sheet(isPresented: $isPairing) { PairDeviceSheet() }
        .sheet(item: $mappingTarget) { account in
            MapAccountSheet(remote: account)
        }
        .alert("Couldn’t complete", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    // MARK: - Sections

    private var trustedAutomationSection: some View {
        Section {
            Toggle(
                "Trusted Automation",
                isOn: Binding(
                    get: { store.trustedAutomationEnabled },
                    set: { enabled in
                        do { try store.setTrustedAutomationEnabled(enabled) }
                        catch let error as BankReviewError { failure = error.message }
                        catch { failure = "The setting could not be saved." }
                    }
                )
            )
            if let diagnostic = store.trustedAutomationDiagnostic {
                Label(diagnostic, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.Role.caution)
                    .font(.callout)
            }
        } footer: {
            Text("Automatically handles only transactions covered by rules you explicitly approved. Risky transaction types always remain in To Review. Turning this on does not process the current queue.")
        }
    }

    private var pairingSection: some View {
        Section {
            Button {
                isPairing = true
            } label: {
                Label("Pair this device", systemImage: "key.horizontal")
            }
        } header: {
            Text(store.pairingState == .revoked ? "Disconnected" : "Not paired")
        } footer: {
            Text(store.pairingState == .revoked
                 ? "This device was disconnected from the sync service. Pair it again to resume. Everything already on this device is unaffected."
                 : "This device signs its own requests with a key it generates and never sends. Ask for a pairing code, then enter it here.")
        }
    }

    private var syncSection: some View {
        Section {
            Button {
                Task { await store.syncNow() }
            } label: {
                HStack {
                    Label(store.bankSyncActivity.isSyncing
                          ? (allBanksChecked ? "Saving activity…" : "Checking banks…") : "Sync Now",
                          systemImage: "arrow.clockwise")
                    Spacer()
                    if store.bankSyncActivity.isSyncing { ProgressView() }
                }
            }
            .disabled(store.bankSyncActivity.isSyncing)

            if !store.bankSyncRuns.isEmpty {
                let completed = store.bankSyncRuns.filter { $0.state == "finished" || $0.state == nil }.count
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(store.bankSyncActivity.isSyncing
                             ? (allBanksChecked ? "Saving bank activity" : "Checking your banks")
                             : "Latest bank check")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(completed) of \(store.bankSyncRuns.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Theme.Role.supporting)
                    }
                    ProgressView(value: Double(completed), total: Double(store.bankSyncRuns.count))
                        .tint(hasBankWarning ? Theme.Role.caution : Theme.Role.accent)
                        .accessibilityLabel("Banks checked")
                        .accessibilityValue("\(completed) of \(store.bankSyncRuns.count)")
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("bank.sync.progress")

                ForEach(store.bankSyncRuns, id: \.provider) { run in
                    BankProviderSyncRow(run: run)
                }
            }

            switch store.bankSyncActivity {
            case let .succeeded(at):
                LabeledContent("Last sync") {
                    Text(at, format: .dateTime.day().month().hour().minute())
                }
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.Role.caution)
                    .font(.callout)
            case .syncing:
                Text(allBanksChecked
                     ? "Saving new bank activity on this device…"
                     : "New bank activity will appear after the check finishes. You can leave this screen while it runs.")
                    .font(.callout)
                    .foregroundStyle(Theme.Role.supporting)
            case .idle:
                EmptyView()
            }
        } footer: {
            Text(store.trustedAutomationEnabled
                 ? "Syncing saves bank evidence first. Trusted Automation may then handle only newly eligible activity covered by an explicitly approved safe expense rule."
                 : "Syncing brings in bank evidence only. Nothing becomes spending or income until you review it in To Review.")
        }
    }

    private var allBanksChecked: Bool {
        !store.bankSyncRuns.isEmpty && store.bankSyncRuns.allSatisfy {
            $0.state == "finished" || $0.state == nil
        }
    }

    private var hasBankWarning: Bool {
        store.bankSyncRuns.contains { run in
            run.state == "finished" && run.outcome != "success" &&
                run.outcome != "skipped_no_connection"
        }
    }

    @ViewBuilder
    private func connectionsSection(_ connections: [ProviderConnectionStatus]) -> some View {
        if !connections.isEmpty {
            Section("Connections") {
                ForEach(connections) { connection in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(connection.providerName).font(.body.weight(.medium))
                            Spacer()
                            Text(connection.state.displayName)
                                .font(.caption)
                                .foregroundStyle(connection.state.needsAttention
                                                 ? Theme.Role.caution : Theme.Role.positive)
                        }
                        if let institution = connection.institution {
                            Text(institution).font(.caption).foregroundStyle(Theme.Role.supporting)
                        }
                        if let last = connection.lastSyncedAt {
                            Text("Last synced \(last, format: .dateTime.day().month().hour().minute())")
                                .font(.caption2).foregroundStyle(Theme.Role.supporting)
                        }
                        if let expires = connection.consentExpires {
                            Text("Access expires \(expires.formatted(.dateTime.day().month().year()))")
                                .font(.caption2)
                                .foregroundStyle(connection.state == .expiringSoon
                                                 ? Theme.Role.caution : Theme.Role.supporting)
                        }
                        if connection.state.needsAttention {
                            // Consent is never renewed silently. Reauthorization
                            // means the person talking to their bank.
                            Text("Reconnect this bank to keep syncing.")
                                .font(.caption2).foregroundStyle(Theme.Role.caution)
                        }
                        if let error = connection.lastErrorMessage {
                            Text(error).font(.caption2).foregroundStyle(Theme.Role.caution)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func accountsSection(_ remoteAccounts: [MappableRemoteAccount]) -> some View {
        if remoteAccounts.isEmpty {
            Section("Accounts") {
                Text("Sync to see the accounts your banks report.")
                    .font(.callout).foregroundStyle(Theme.Role.supporting)
            }
        } else {
            Section {
                ForEach(remoteAccounts) { account in
                    Button {
                        mappingTarget = account
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(account.displayName).font(.body.weight(.medium))
                                Spacer()
                                Text(account.isMapped ? "Mapped" : "Not mapped")
                                    .font(.caption)
                                    .foregroundStyle(account.isMapped
                                                     ? Theme.Role.positive : Theme.Role.supporting)
                            }
                            Text([account.providerName, account.currencyCode]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(Theme.Role.supporting)
                            if let local = account.mappedLocalAccountName {
                                Text("→ \(local)").font(.caption2).foregroundStyle(Theme.Role.supporting)
                            }
                            if let boundary = account.syncStartBoundary {
                                Text("New activity after \(boundary.formatted(.dateTime.day().month().year()))")
                                    .font(.caption2).foregroundStyle(Theme.Role.supporting)
                            }
                        }
                    }
                    .tint(.primary)
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Only mapped accounts create work in To Review. Leave an account unmapped and this app ignores it entirely.")
            }
        }
    }

    private var deviceSection: some View {
        Section {
            Button(role: .destructive) {
                do { try store.unpairDevice() }
                catch { failure = "The device could not be disconnected. Try again." }
            } label: {
                Label("Disconnect this device", systemImage: "minus.circle")
            }
        } footer: {
            Text("Disconnecting removes this device's sync key. Your accounts, transactions and reviewed items stay on this device.")
        }
    }
}

private struct BankProviderSyncRow: View {
    let run: MobileSyncRun

    private var name: String {
        switch run.provider {
        case "bnp": "BNP"
        case "paypal": "PayPal"
        case "revolut": "Revolut"
        default: "Bank"
        }
    }

    private var status: String {
        if run.state == "queued" { return "Waiting" }
        if run.state == "running" { return "Checking…" }
        switch run.outcome {
        case "success": return "Up to date"
        case "skipped_no_connection": return "Not connected"
        case "skipped_rate_limited": return "Rate limited"
        case "skipped_reauth_required": return "Reconnect bank"
        case "skipped_in_progress": return "Already checking"
        default: return "Couldn’t check"
        }
    }

    private var needsAttention: Bool {
        run.state == "finished" &&
            run.outcome != "success" && run.outcome != "skipped_no_connection"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: run.state == "finished"
                  ? (needsAttention ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                  : "circle.dotted")
                .foregroundStyle(needsAttention ? Theme.Role.caution
                                 : run.state == "finished" ? Theme.Role.positive : Theme.Role.accent)
                .accessibilityHidden(true)
            Text(name).font(.body.weight(.medium))
            Spacer()
            Text(status).font(.subheadline)
                .foregroundStyle(needsAttention ? Theme.Role.caution : Theme.Role.supporting)
            if run.state == "running" { ProgressView().controlSize(.small) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("bank.sync.provider.\(run.provider)")
    }
}

/// Entering the pairing code.
struct PairDeviceSheet: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ABCD-EFGH-JKLM", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Pairing code")
                } footer: {
                    Text("Single use, and it expires within a few minutes. It is never stored on this device.")
                }

                Section {
                    Button {
                        Task {
                            // Dismiss on success, before anything slower runs.
                            if await store.pairDevice(code: code, label: deviceLabel) {
                                dismiss()
                                await store.refreshFromService()
                            }
                        }
                    } label: {
                        HStack {
                            Text("Pair device")
                            Spacer()
                            if store.bankSyncActivity.isSyncing { ProgressView() }
                        }
                    }
                    .disabled(code.trimmingCharacters(in: .whitespaces).count < 8
                              || store.bankSyncActivity.isSyncing)
                }

                if case let .failed(message) = store.bankSyncActivity {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(Theme.Role.caution)
                    }
                }
            }
            .financeList()
            .navigationTitle("Pair device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// A human label for the operator's device list. Not an identifier.
    private var deviceLabel: String {
        #if canImport(UIKit)
        UIDevice.current.name
        #else
        "iPhone"
        #endif
    }
}

/// Choosing the local account a remote one belongs to, and its cutover.
struct MapAccountSheet: View {
    let remote: MappableRemoteAccount

    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?
    @State private var boundary: CalendarDay?
    @State private var failure: String?

    /// Same currency only, and not already spoken for. Mapping a EUR bank
    /// account onto a MAD cash account would silently invent an exchange rate.
    /// One live read per composition: eligibility and existing bindings are one
    /// question about one moment.
    private static func candidates(
        _ snapshot: FinanceAppSnapshot, _ remote: MappableRemoteAccount
    ) -> [AccountSummary] {
        let spokenFor = Set(
            snapshot.providerAccountBindings.filter(\.isActive).map(\.localAccountID)
        )
        return snapshot.accounts.filter {
            $0.isActive
                && (remote.currencyCode == nil || $0.currencyCode == remote.currencyCode)
                && !spokenFor.contains($0.id)
        }
    }

    var body: some View {
        content(Self.candidates(store.snapshot, remote))
    }

    private func content(_ candidates: [AccountSummary]) -> some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Bank account", value: remote.displayName)
                    LabeledContent("Provider", value: remote.providerName)
                    if let currency = remote.currencyCode {
                        LabeledContent("Currency", value: currency)
                    }
                }

                if remote.isMapped {
                    Section {
                        LabeledContent("Mapped to", value: remote.mappedLocalAccountName ?? "—")
                        Button(role: .destructive) {
                            act { try store.unmapRemoteAccount(bindingID: "binding-\(remote.id)") }
                        } label: {
                            Text("Stop syncing this account")
                        }
                    } footer: {
                        Text("Evidence already reviewed stays. The account simply stops producing new To Review items.")
                    }
                } else if candidates.isEmpty {
                    Section {
                        Text("No unmapped local account in this currency. Create one first, or leave this account unmapped.")
                            .font(.callout).foregroundStyle(Theme.Role.supporting)
                    }
                } else {
                    Section("Map to") {
                        ForEach(candidates) { account in
                            Button {
                                selection = account.id
                                boundary = store.defaultBoundaryDay(for: account.id)
                            } label: {
                                HStack {
                                    Text(account.name)
                                    Spacer()
                                    if selection == account.id {
                                        Image(systemName: "checkmark").foregroundStyle(Theme.Role.accent)
                                    }
                                }
                            }
                            .tint(.primary)
                        }
                    }

                    if selection != nil {
                        Section {
                            CivilDatePicker("Import new activity after", selection: $boundary)
                        } footer: {
                            Text("Defaults to the day this account's balance was last stated. Activity on or before that day is already inside that balance, so importing it would count the same money twice.")
                        }

                        Section {
                            Button("Map account") {
                                guard let selection, let boundary else { return }
                                act {
                                    try store.mapRemoteAccount(
                                        remote.id,
                                        toLocalAccount: selection,
                                        boundary: boundary
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .financeList()
            .navigationTitle("Account mapping")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn’t map", isPresented: Binding(
                get: { failure != nil }, set: { if !$0 { failure = nil } }
            )) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
    }

    private func act(_ work: () throws -> Void) {
        do {
            try work()
            dismiss()
        } catch let error as BankReviewError {
            failure = error.message
        } catch {
            failure = "That change could not be saved."
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack { BankSyncView() }
        .environment(FinanceStore.bankInboxPreview())
}
#endif
