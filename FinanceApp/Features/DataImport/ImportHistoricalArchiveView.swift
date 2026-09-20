import SwiftUI
import UniformTypeIdentifiers

/// A separate, atomic import path for private reconstructed history.
///
/// Current-state import replaces the operational graph; this flow can run
/// alongside it because it writes only the three archive tables. The chosen
/// file is decoded and validated in memory, previewed, then discarded after a
/// successful write.
struct ImportHistoricalArchiveView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum Stage { case choose, preview, done }

    @State private var stage: Stage = .choose
    @State private var isPickingFile = false
    @State private var preview: HistoryImportPreview?
    @State private var outcome: HistoryImportOutcome?
    @State private var failureMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .choose:
                    chooseStep
                case .preview:
                    if let preview { previewStep(preview) }
                case .done:
                    if let outcome { resultStep(outcome) }
                }
            }
            .financeList()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if stage != .done {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            store.history.cancelImport()
                            dismiss()
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: chose
        )
        .alert(
            "Import stopped",
            isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "The archive could not be imported.")
        }
    }

    private var title: String {
        switch stage {
        case .choose: "Import historical archive"
        case .preview: "Review archive"
        case .done: "Archive imported"
        }
    }

    private var chooseStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.stackSpacing) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.Role.accent)
                    Text("Bring your reconstructed history to this device")
                        .font(.title3.bold())
                    Text("The archive is checked before anything is saved. It stays separate from balances, forecasts, commitments, and safe to spend.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .financeCard()

                Button {
                    isPickingFile = true
                } label: {
                    Label("Choose private archive", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("The source file is read once and is not copied into the app bundle. Only normalized, indexed rows are stored on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            .padding(Theme.Metric.screenPadding)
        }
        .background(Theme.Surface.background)
    }

    private func previewStep(_ preview: HistoryImportPreview) -> some View {
        List {
            Section("Archive") {
                HistoryPreviewCountRow(label: "Transactions", value: preview.transactionCount.formatted())
                LabeledContent("Date range") {
                    Text(verbatim: "\(preview.dateRange.lowerBound) → \(preview.dateRange.upperBound)")
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Archive cutoff", value: preview.archiveCutoff.description)
                HistoryPreviewCountRow(label: "Accounts", value: preview.accounts.count.formatted())
                HistoryPreviewCountRow(label: "Currencies", value: preview.currencies.count.formatted())
                HistoryPreviewCountRow(
                    label: "Source coverage gaps",
                    value: preview.sourceCoverageGapCount.formatted()
                )
            }

            if !preview.accounts.isEmpty {
                Section("Accounts") {
                    ForEach(preview.accounts) { account in
                        Text(account.name)
                    }
                }
            }

            if !preview.currencies.isEmpty {
                Section("Currencies") {
                    Text(preview.currencies.joined(separator: ", "))
                }
            }

            if preview.sourceCoverageGapCount > 0 {
                Section {
                    Label(
                        "Bank records for parts of the archive are incomplete.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(Theme.Role.caution)
                } footer: {
                    Text("Missing periods will be marked in History and will never be presented as zero spending.")
                }
            }

            Section {
                Label(
                    preview.replacesExistingArchive
                        ? "This replaces the existing archive atomically."
                        : "This installs a separate read-only archive.",
                    systemImage: "checkmark.shield"
                )
            } footer: {
                Text("Current accounts, balances, forecasts, and budget state are not part of this write.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: confirm) {
                Label(
                    preview.replacesExistingArchive ? "Replace historical archive" : "Import archive",
                    systemImage: "archivebox.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(Theme.Metric.screenPadding)
            .background(.bar)
        }
    }

    private func resultStep(_ outcome: HistoryImportOutcome) -> some View {
        let metadata: HistoryArchiveMetadata
        let unchanged: Bool
        switch outcome {
        case let .unchanged(value):
            metadata = value
            unchanged = true
        case let .imported(value):
            metadata = value
            unchanged = false
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.stackSpacing) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: unchanged ? "checkmark.circle" : "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.Role.positive)
                    Text(unchanged ? "Archive already up to date" : "History is ready")
                        .font(.title2.bold())
                    Text(verbatim: "\(metadata.transactionCount.formatted()) transactions · \(metadata.dateRange.lowerBound) through \(metadata.dateRange.upperBound)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Browse it under Activity → History. It remains separate from the live ledger.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .financeCard()

                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
            .padding(Theme.Metric.screenPadding)
        }
        .background(Theme.Surface.background)
    }

    private func chose(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            do {
                preview = try store.history.prepareImport(contentsOf: url)
                stage = .preview
            } catch let error as HistoryArchiveImportError {
                failureMessage = error.description
            } catch {
                failureMessage = "The selected file is not a valid historical archive."
            }
        case .failure:
            failureMessage = "The selected historical archive could not be read."
        }
    }

    private func confirm() {
        do {
            outcome = try store.history.confirmImport()
            stage = .done
        } catch let error as HistoryArchiveImportError {
            failureMessage = error.description
        } catch {
            failureMessage = "The historical archive could not be saved. The previous archive is unchanged."
        }
    }
}

private struct HistoryPreviewCountRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label, value: value)
    }
}
