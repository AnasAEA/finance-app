import SwiftUI
import UniformTypeIdentifiers

/// Export backup, in two deliberate steps:
///
///     prepare and verify → save
///
/// Preparing is where the work is. The bytes are produced and read back before
/// this screen says anything about them, so every figure below is counted from
/// the file that is about to be saved rather than from the store it came from.
/// A person who reads "128 transactions" here is reading the file.
///
/// The mirror of import, and deliberately shaped like it: import shows what is
/// in a file before it becomes the app, and this shows what is in the app
/// before it becomes a file.
struct ExportBackupView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Four states, and the refusal is one of them rather than an alert over
    /// another one. A person who cannot have a backup needs the reason on the
    /// screen they opened, not a dialog to dismiss back to a blank one.
    private enum Stage: Hashable { case preparing, blocked, ready, saved }

    @State private var stage: Stage = .preparing
    @State private var backup: FinanceBackup?
    @State private var problem: AppExportError?
    @State private var isSaving = false
    @State private var savedFileName: String?
    @State private var encryptionEnabled = true
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var exportData: Data?
    @State private var protecting = false
    @State private var protectionError: String?
    @State private var protectionTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .preparing:
                    ProgressView("Preparing your backup")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.Surface.background)
                case .blocked:
                    if let problem {
                        ExportBlockedStep(problem: problem)
                    }
                case .ready:
                    if let backup {
                        ExportReadyStep(backup: backup, encryptionEnabled: $encryptionEnabled,
                            password: $password, passwordConfirmation: $passwordConfirmation,
                            protecting: protecting, protectionError: protectionError, onSave: beginSave)
                    }
                case .saved:
                    if let savedFileName {
                        ExportSavedStep(fileName: savedFileName) { dismiss() }
                    }
                }
            }
            .financeList()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if stage != .saved {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .task { prepare() }
        .onDisappear { protectionTask?.cancel(); password = ""; passwordConfirmation = ""; exportData = nil }
        .fileExporter(
            isPresented: $isSaving,
            document: exportData.map { FinanceBackupFile(data: $0) },
            contentType: .json,
            defaultFilename: backup?.fileName
        ) { result in
            saved(result)
        }
    }

    private var title: String {
        switch stage {
        case .preparing, .blocked: "Export backup"
        case .ready: "Your backup"
        case .saved: "Saved"
        }
    }

    /// Produces and verifies the file. Nothing leaves the device here — the
    /// bytes exist in memory and go no further until the person saves them.
    private func prepare() {
        guard stage == .preparing else { return }
        do {
            backup = try store.exportBackup()
            stage = .ready
        } catch let error as AppExportError {
            problem = error
            stage = .blocked
        } catch {
            problem = .documentUnencodable
            stage = .blocked
        }
    }

    private func beginSave() {
        guard let backup, !protecting else { return }
        guard encryptionEnabled else { exportData = backup.data; isSaving = true; return }
        guard password.count >= 12, password.utf8.count <= 1024, password == passwordConfirmation else { return }
        protecting = true
        protectionError = nil
        let selectedPassword = password
        protectionTask = Task {
            defer { protecting = false }
            do {
                let data = try await backup.encrypted(password: selectedPassword)
                guard !Task.isCancelled else { return }
                exportData = data
                password = ""
                passwordConfirmation = ""
                isSaving = true
            } catch { protectionError = "The backup could not be protected. Try again." }
        }
    }

    private func saved(_ result: Result<URL, Error>) {
        switch result {
        case let .success(url):
            // The chosen location can be anywhere the person picked. Only the
            // file's own name is shown back; the path is not ours to print.
            savedFileName = url.lastPathComponent
            stage = .saved
        case .failure:
            // The exporter's own error names a path and nothing actionable.
            // A cancelled save is also reported here and is not a problem, so
            // this returns to the ready step rather than announcing a failure.
            stage = .ready
        }
    }
}

/// The produced bytes, as a document the system file exporter can write.
///
/// Read-only on purpose: restoring is the import path's job, and it has four
/// steps and a preview for good reasons. Reading a backup in here would be a
/// second, quieter way into the store.
struct FinanceBackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        wrapper
    }

    /// The bytes as the system will write them. Separate from
    /// `fileWrapper(configuration:)` because `FileDocumentWriteConfiguration`
    /// has no public initializer, so this is the only way to prove that what
    /// reaches the disk is the verified file and not a re-encoding of it.
    var wrapper: FileWrapper { FileWrapper(regularFileWithContents: data) }
}

// MARK: - Steps
//
// Internal rather than private so each state can be rendered on its own, in
// light and dark and at accessibility type sizes. A flow whose states can only
// be reached through a system file picker is a flow whose states are never
// checked.

/// Why there is no backup to offer.
struct ExportBlockedStep: View {
    let problem: AppExportError

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.stackSpacing) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.Role.caution)
                        .fixedSize(horizontal: false, vertical: true)
                    if let suggestion = problem.recoverySuggestion {
                        Text(suggestion)
                            .font(.footnote)
                            .foregroundStyle(Theme.Role.supporting)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .financeCard()
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(DataID.exportBlocked)
            }
            .padding(Theme.Metric.screenPadding)
        }
        .background(Theme.Surface.background)
    }
}

/// What is in the file, before it is saved anywhere.
struct ExportReadyStep: View {
    let backup: FinanceBackup
    @Binding var encryptionEnabled: Bool
    @Binding var password: String
    @Binding var passwordConfirmation: String
    var protecting: Bool
    var protectionError: String?
    let onSave: () -> Void

    init(backup: FinanceBackup, encryptionEnabled: Binding<Bool> = .constant(false),
         password: Binding<String> = .constant(""), passwordConfirmation: Binding<String> = .constant(""),
         protecting: Bool = false, protectionError: String? = nil, onSave: @escaping () -> Void) {
        self.backup = backup
        self._encryptionEnabled = encryptionEnabled
        self._password = password
        self._passwordConfirmation = passwordConfirmation
        self.protecting = protecting
        self.protectionError = protectionError
        self.onSave = onSave
    }

    private var summary: BackupSummary { backup.summary }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(backup.fileName)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(summary.fileSizeLabel)\(encryptionEnabled ? " before encryption" : "") · schema \(summary.schemaVersion)")
                        .font(.caption)
                        .foregroundStyle(Theme.Role.supporting)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(DataID.exportSummary)
            } footer: {
                Text("Checked by reading it back before it was offered. Everything below was counted from the file itself, not from this device.")
            }

            Section("Protection") {
                Toggle("Encrypt backup", isOn: $encryptionEnabled)
                    .accessibilityIdentifier("backup.encrypt")
                if encryptionEnabled {
                    SecureField("Password (at least 12 characters)", text: $password)
                        .textContentType(.newPassword).accessibilityIdentifier("backup.password")
                    SecureField("Confirm password", text: $passwordConfirmation)
                        .textContentType(.newPassword).accessibilityIdentifier("backup.password-confirmation")
                    Text("Keep this password somewhere safe. It is not stored in the app and cannot be recovered.")
                        .font(.footnote).foregroundStyle(Theme.Role.supporting)
                }
                if protecting { ProgressView("Protecting and checking backup") }
                if let protectionError { Text(protectionError).foregroundStyle(.red) }
            }
            .disabled(protecting)

            Section("What is in it") {
                ExportCountRow(label: "Accounts", count: summary.accountCount)
                ExportCountRow(label: "Transactions", count: summary.transactionCount)
                ExportCountRow(
                    label: "Expected payments", count: summary.expectedTransactionCount
                )
                ExportCountRow(label: "Income sources", count: summary.incomeSourceCount)
                ExportCountRow(
                    label: "Recurring commitments", count: summary.recurringCommitmentCount
                )
                ExportCountRow(label: "Budgets", count: summary.budgetCount)
                ExportCountRow(label: "Instalments", count: summary.instalmentCount)
                ExportCountRow(label: "Debts", count: summary.debtCount)
                ExportCountRow(label: "Goals", count: summary.goalCount)
                ExportCountRow(label: "Set-aside", count: summary.setAsideCount)
                if summary.hasFullRecovery {
                    ExportCountRow(label: "Historical transactions", count: summary.historicalTransactionCount)
                    ExportCountRow(label: "Verified-month revisions", count: summary.checkpointRevisionCount)
                    ExportCountRow(label: "Transaction corrections", count: summary.transactionCorrectionCount)
                }
                ExportCountRow(
                    label: "Bank evidence",
                    count: summary.bankEvidenceCount,
                    caption: "What the bank said, and the decisions made about it"
                )
            }

            Section {
                ForEach(summary.exclusions, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(Theme.Role.supporting)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Not in it")
            } footer: {
                Text("Restoring this file needs an app with nothing in it yet, because restoring on top of an existing history could duplicate money.")
            }

            Section {
                Button(action: onSave) {
                    Label("Save to Files", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .accessibilityIdentifier(DataID.exportSave)
                .disabled(protecting || (encryptionEnabled && (password.count < 12 || password.utf8.count > 1024 || password != passwordConfirmation)))
            } footer: {
                Text(encryptionEnabled ? "The file is password protected. Your accounts, classifications and plan can be read only with its password." : "The file holds your accounts, classifications and plan in readable text. Put it somewhere you are willing to keep that.")
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// Written, and where.
struct ExportSavedStep: View {
    let fileName: String
    let onFinish: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.stackSpacing) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.Role.positive)
                    Text("Backup saved")
                        .font(.title3.bold())
                    Text(fileName)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Role.supporting)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .financeCard()
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(DataID.exportSaved)

                Text("Nothing on this device changed. Take another whenever the plan moves — a backup is only as current as the day it was written.")
                    .font(.caption)
                    .foregroundStyle(Theme.Role.supporting)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)

                Button(action: onFinish) {
                    Text("Done").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(Theme.Metric.screenPadding)
        }
        .background(Theme.Surface.background)
    }
}

/// A count, set in the same rounded digits the money rows use.
struct ExportCountRow: View {
    let label: String
    let count: Int
    var caption: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.subheadline)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(Theme.Role.supporting)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            Text("\(count)")
                .font(.money(17, weight: .semibold))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
