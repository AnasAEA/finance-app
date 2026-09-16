import SwiftUI

/// Detail destinations retained from the former More screen and reassigned to
/// their production owners. Recurring, instalments and debts are reached from
/// Plan → Upcoming; data and backup is reached from Settings.

// MARK: - Recurring

struct RecurringPaymentsView: View {
    @Environment(FinanceStore.self) private var store

    var body: some View {
        List {
            ForEach(store.snapshot.commitments) { group in
                Section(group.title) {
                    ForEach(group.lines) { line in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.name)
                                HStack(spacing: 6) {
                                    Text(line.cadenceLabel)
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let status = line.statusLabel {
                                        Chip(text: status, tint: Theme.Role.caution)
                                    }
                                }
                            }
                            Spacer()
                            MoneyText(amount: line.amount, size: 17, weight: .medium)
                                .opacity(line.chargesCashNow ? 1 : 0.4)
                        }
                    }
                }
            }
        }
        .navigationTitle("Recurring")
    }
}

// MARK: - Instalments

struct InstalmentsView: View {
    @Environment(FinanceStore.self) private var store

    var body: some View {
        List {
            Section {
                ForEach(store.snapshot.instalments) { line in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.title).font(.headline)
                                Text(line.provider).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                MoneyText(amount: line.remaining, size: 17, weight: .semibold)
                                Text("left").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        ProgressView(
                            value: Double(line.paidCount),
                            total: Double(max(line.totalCount, 1))
                        )
                        .tint(Theme.Role.accent)
                        HStack {
                            Text("\(line.paidCount) of \(line.totalCount) paid")
                            Spacer()
                            if let next = line.nextDueDate {
                                Text("Next \(next.formatted(.dateTime.day().month(.abbreviated)))")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("Instalments move cash but are not new spending — each purchase was already counted at the merchant.")
            }
        }
        .navigationTitle("Instalments")
    }
}

// MARK: - Debts

struct DebtsView: View {
    @Environment(FinanceStore.self) private var store

    var body: some View {
        List {
            ForEach(store.snapshot.debts) { debt in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(debt.name).font(.headline)
                            if let creditor = debt.creditor {
                                Text(creditor).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        MoneyText(amount: debt.outstanding, size: 20, weight: .semibold)
                    }
                    if let months = debt.monthsToClear {
                        Text("\(debt.monthlyRepayment.formatted()) a month · clears in \(months) months")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let note = debt.note {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Debts")
    }
}

// MARK: - Data & Backup

/// Where backing up, restoring and importing live.
///
/// Restore is offered only into an empty store. When there is already a
/// history, the row says so rather than disappearing: a person who exported
/// their state should be told why restoring it is refused, not left looking
/// for the button. Export answers the other half, and refuses in the same
/// voice — most importantly when the store could not be read, because a backup
/// taken then would be a well-formed file holding nothing.
///
/// Three words for three different things, and they are not interchangeable.
/// **Export backup** writes this app's own document out. **Restore backup**
/// reads one back, and is the same operation the empty-store onboarding card
/// offers. **Import historical archive** is the odd one out and keeps the word
/// "import" for that reason: it takes a `FinanceHistoryDocument`, a document
/// type this app cannot produce and does not back up.
struct DataAndBackupView: View {
    @Environment(FinanceStore.self) private var store
    @State private var isImporting = false
    @State private var isImportingHistory = false
    @State private var isExporting = false

    var body: some View {
        List {
            Section {
                Button {
                    isImporting = true
                } label: {
                    Label("Restore backup", systemImage: "square.and.arrow.down")
                }
                .disabled(!store.canImportCurrentState)
            } footer: {
                if let blocker = store.importBlocker {
                    Text(Self.refusal(blocker.message, blocker.recoverySuggestion))
                } else {
                    Text("Bring back accounts, balances, commitments and planning from an exported finance file. You see what is in it before anything is saved.")
                }
            }

            Section {
                Button {
                    isImportingHistory = true
                } label: {
                    Label("Import historical archive", systemImage: "archivebox")
                }
            } header: {
                Text("Historical archive")
            } footer: {
                if let metadata = try? store.history.metadata() {
                    Text(verbatim: "\(metadata.transactionCount.formatted()) private transactions are available from \(metadata.dateRange.lowerBound) through \(metadata.dateRange.upperBound). Reimport safely replaces the archive; it never changes balances or forecasts.")
                } else {
                    Text("Import reconstructed history separately from current state. The archive is searchable in Activity and never changes balances, forecasts, or safe to spend.")
                }
            }

            Section {
                Button {
                    isExporting = true
                } label: {
                    Label("Export backup", systemImage: "square.and.arrow.up")
                }
                .disabled(!store.canExportBackup)
                .accessibilityIdentifier(DataID.exportBackup)
            } footer: {
                if let blocker = store.backupBlocker {
                    Text(Self.refusal(blocker.message, blocker.recoverySuggestion))
                } else {
                    Text("Writes your accounts, balances, transactions and plan to a file you keep. You see what is in it, and it is read back and checked, before it is saved anywhere. Restoring it later needs an app with nothing in it yet.")
                }
            }

            Section {
                LabeledContent("Storage", value: "On this device only")
            } footer: {
                Text("Files you choose here are read once and not kept. What is stored is the accounts and plan themselves.")
            }
        }
        .navigationTitle("Data & Privacy")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isImporting) { ImportCurrentStateView() }
        .sheet(isPresented: $isImportingHistory) { ImportHistoricalArchiveView() }
        .sheet(isPresented: $isExporting) { ExportBackupView() }
    }

    /// A refusal and what to do about it, together.
    ///
    /// Both blockers already carry a `recoverySuggestion`, and this screen used
    /// to drop it — so the one person who most needed it never saw it. The
    /// sheet behind each row shows both halves, but a blocked row is a
    /// *disabled* row: there is no sheet to reach. A store with a history was
    /// therefore told "Import into an existing account history is not
    /// supported yet" and nothing about the fresh install that is the actual
    /// supported recovery, which reads as a defect rather than a boundary.
    ///
    /// Internal rather than private so a test can assert the sentence a person
    /// reads, not the two it was assembled from.
    static func refusal(_ message: String, _ suggestion: String?) -> String {
        guard let suggestion else { return message }
        return "\(message) \(suggestion)"
    }
}
