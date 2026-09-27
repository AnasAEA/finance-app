import SwiftUI
import UniformTypeIdentifiers

/// Restore backup, in four deliberate steps:
///
///     choose a file → preview → review balances → confirm
///
/// The type keeps its older name because the operation is unchanged and the
/// persistence boundary below it is named for the operation. What changed is
/// what a person is told they are doing: they are bringing their own state
/// back, and "Import current state" was the name of a function, not of that.
/// The one thing genuinely *imported* in this app is the historical archive —
/// a document type the app cannot produce — and that screen keeps the word.
///
/// Nothing is written until the last one. The preview exists so a person can
/// recognise their own finances before they become the app's, and the balance
/// review exists because an exported balance is dated: it was true on the day
/// it was observed, and the only person who can say whether it still is, is the
/// one reading the screen.
struct ImportCurrentStateView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss

    private enum Stage: Hashable { case choose, unlock, preview, balances, done }

    @State private var stage: Stage = .choose
    @State private var isPickingFile = false
    @State private var preview: ImportPreview?
    @State private var summary: ImportSummary?
    @State private var edits: [String: BalanceEdit] = [:]
    @State private var failure: AppImportError?
    @State private var encryptedData: Data?
    @State private var password = ""
    @State private var unlocking = false
    @State private var unlockTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .choose: ChooseFileStep(blocker: store.importBlocker) { isPickingFile = true }
                case .unlock:
                    Form {
                        Section("Encrypted backup") {
                            SecureField("Backup password", text: $password)
                                .textContentType(.password).accessibilityIdentifier("restore.password")
                            Text("Enter the password used when this file was saved.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Unlock backup", action: unlockBackup)
                                .disabled(password.isEmpty || unlocking)
                                .accessibilityIdentifier("restore.unlock")
                            if unlocking { ProgressView("Checking backup") }
                        }
                    }
                case .preview:
                    if let preview {
                        PreviewStep(preview: preview) { stage = .balances }
                    }
                case .balances:
                    if let preview {
                        BalanceReviewStep(
                            preview: preview,
                            edits: $edits,
                            onConfirm: confirm
                        )
                    }
                case .done:
                    if let summary {
                        ImportResultStep(summary: summary, onFinish: finish)
                    }
                }
            }
            .financeList()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if stage != .done {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            store.cancelImport()
                            dismiss()
                        }
                    }
                }
            }
        }
        .onDisappear { unlockTask?.cancel(); password = ""; encryptedData = nil; store.cancelImport() }
        .fileImporter(
            isPresented: $isPickingFile,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: chose
        )
        .alert(
            "Restore stopped",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
            presenting: failure
        ) { _ in
            Button("OK", role: .cancel) { failure = nil }
        } message: { error in
            if let suggestion = error.recoverySuggestion {
                Text("\(error.message)\n\n\(suggestion)")
            } else {
                Text(error.message)
            }
        }
    }

    private var title: String {
        switch stage {
        case .choose: "Restore backup"
        case .unlock: "Unlock backup"
        case .preview: "Review file"
        case .balances: "Review balances"
        case .done: "Restored"
        }
    }

    // MARK: - Steps

    private func chose(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            do {
                let data = try store.readBackupFile(at: url)
                if BackupProtection.isEncrypted(data) {
                    encryptedData = data
                    password = ""
                    stage = .unlock
                    return
                }
                let decoded = try store.prepareImport(from: data)
                preview = decoded
                edits = Dictionary(
                    uniqueKeysWithValues: decoded.accounts.map { ($0.id, BalanceEdit($0)) }
                )
                stage = .preview
            } catch let error as AppImportError {
                failure = error
            } catch {
                failure = .fileUnreadable
            }
        case .failure:
            // The picker's own error names a path and nothing actionable.
            failure = .fileUnreadable
        }
    }

    private func unlockBackup() {
        guard let data = encryptedData, !unlocking else { return }
        unlocking = true
        let selectedPassword = password
        unlockTask = Task {
            defer { unlocking = false }
            do {
                let decoded = try await store.prepareEncryptedImport(from: data, password: selectedPassword)
                guard !Task.isCancelled else { return }
                preview = decoded
                edits = Dictionary(uniqueKeysWithValues: decoded.accounts.map { ($0.id, BalanceEdit($0)) })
                password = ""
                encryptedData = nil
                stage = .preview
            } catch let error as AppImportError { failure = error }
            catch { failure = .fileUnreadable }
        }
    }

    private func confirm() {
        guard let preview else { return }
        let corrections = preview.accounts.compactMap { account -> ImportBalanceCorrection? in
            guard let edit = edits[account.id], edit.differs(from: account) else { return nil }
            guard let amount = edit.amount(for: account) else { return nil }
            return ImportBalanceCorrection(
                accountID: account.id,
                balance: amount,
                asOf: edit.asOf
            )
        }
        do {
            summary = try store.confirmImport(balanceCorrections: corrections)
            stage = .done
        } catch let error as AppImportError {
            failure = error
        } catch {
            failure = .persistenceFailed(String(describing: type(of: error)))
        }
    }

    private func finish() {
        navigation.selectedTab = .home
        dismiss()
    }
}

// MARK: - Editing one balance

/// A balance as the reviewer is currently editing it.
struct BalanceEdit: Hashable {
    var text: String
    var asOf: CalendarDay

    init(_ account: ImportAccountPreview) {
        text = NSDecimalNumber(decimal: account.balance.decimalValue).stringValue
        asOf = account.asOf
    }

    /// The typed figure read at the account's own scale, or nil when it is not
    /// a figure in that currency. Never rounded into one.
    func amount(for account: ImportAccountPreview) -> Amount? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let isNegative = trimmed.hasPrefix("-")
        let magnitude = isNegative ? String(trimmed.dropFirst()) : trimmed
        guard let parsed = try? Amount.parse(
            magnitude,
            currencyCode: account.currencyCode,
            fractionDigits: account.fractionDigits
        ) else { return nil }
        return isNegative ? parsed.negated : parsed
    }

    func differs(from account: ImportAccountPreview) -> Bool {
        if asOf != account.asOf { return true }
        guard let amount = amount(for: account) else { return false }
        return amount != account.balance
    }

    func isValid(for account: ImportAccountPreview) -> Bool { amount(for: account) != nil }
}

// MARK: - Step 1: choose a file
//
// The four steps below are internal rather than private so each screen state
// can be rendered on its own — light, dark and at accessibility type sizes.
// A flow whose middle states can only be reached by tapping through a file
// picker is a flow whose middle states are never checked.

struct ChooseFileStep: View {
    let blocker: AppImportError?
    let onChoose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.stackSpacing) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 34))
                        .foregroundStyle(Theme.Role.accent)
                    Text("Restore from a backup")
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Choose an exported finance file. Accounts, balances, commitments and planning are read from it, checked, and shown to you before anything is saved.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .financeCard()

                if let blocker {
                    BlockedCard(blocker: blocker)
                } else {
                    Button(action: onChoose) {
                        Label("Choose file", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                Text("The file is read once and not kept. What is saved is the accounts and plan themselves, on this device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
            .padding(Theme.Metric.screenPadding)
        }
        .background(Theme.Surface.background)
    }
}

private struct BlockedCard: View {
    let blocker: AppImportError

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(blocker.message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.Role.caution)
                .fixedSize(horizontal: false, vertical: true)
            if let suggestion = blocker.recoverySuggestion {
                Text(suggestion)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .financeCard()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Step 2: preview

struct PreviewStep: View {
    let preview: ImportPreview
    let onContinue: () -> Void

    var body: some View {
        List {
            Section {
                LedgerRow(
                    label: "Electronic liquidity",
                    value: preview.electronicLiquidity,
                    caption: "Held in accounts that can pay a euro obligation"
                )
                ForEach(preview.physicalCash) { total in
                    LedgerRow(
                        label: "Physical cash",
                        value: total.amount,
                        caption: "Notes and coins. Not part of the figure above."
                    )
                }
            } header: {
                Text("What is held")
            } footer: {
                Text("Cash in hand is never added to the account figure. \(preview.accounts.count) accounts in total.")
            }

            Section("Balances") {
                ForEach(preview.accounts) { account in
                    ImportBalanceRow(account: account)
                }
            }

            Section("Commitments and obligations") {
                CountRow(label: "Recurring commitments", count: preview.recurringCommitmentCount)
                if preview.uncommittedCommitmentCount > 0 {
                    CountRow(
                        label: "Hypothetical commitments",
                        count: preview.uncommittedCommitmentCount,
                        caption: "Not counted as committed outflows"
                    )
                }
                CountRow(label: "Instalments", count: preview.installmentCount)
                if preview.installmentCount > 0 {
                    LedgerRow(label: "Instalments remaining · EUR", value: preview.installmentRemaining)
                    ForEach(preview.foreignInstallmentRemaining) { total in
                        LedgerRow(label: "Instalments remaining · \(total.amount.currencyCode)", value: total.amount)
                    }
                }
                CountRow(label: "Debts", count: preview.debtCount)
                if preview.debtCount > 0 {
                    LedgerRow(label: "Debt outstanding · EUR", value: preview.debtOutstanding)
                    ForEach(preview.foreignDebtOutstanding) { total in
                        LedgerRow(label: "Debt outstanding · \(total.amount.currencyCode)", value: total.amount)
                    }
                }
                if preview.unscheduledDebtCount > 0 {
                    CountRow(
                        label: "Debts with no agreed schedule",
                        count: preview.unscheduledDebtCount,
                        caption: "Owed, but committing no dated payment"
                    )
                }
            }

            Section("Income and events") {
                CountRow(label: "Income sources", count: preview.incomeSourceCount)
                CountRow(label: "Expected future transactions", count: preview.expectedTransactionCount)
                CountRow(label: "Recorded transactions", count: preview.observedTransactionCount)
                CountRow(label: "Budgets", count: preview.budgetCount)
                if preview.hasFullRecovery {
                    CountRow(label: "Historical transactions", count: preview.historicalTransactionCount)
                    CountRow(label: "Verified-month revisions", count: preview.checkpointRevisionCount)
                    CountRow(label: "Transaction corrections", count: preview.transactionCorrectionCount)
                    Text("Restores the archive and verified-month history together with your ledger.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Export", value: preview.sourceLabel)
                LabeledContent("Schema", value: preview.schemaVersion)
                if let note = preview.note {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("Source")
            } footer: {
                Text("Nothing has been saved yet.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onContinue) {
                Label("Review balances", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(Theme.Metric.screenPadding)
            .background(.bar)
        }
    }
}

private struct CountRow: View {
    let label: String
    let count: Int
    var caption: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.subheadline)
                if let caption {
                    Text(caption).font(.caption).foregroundStyle(.secondary)
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

/// A balance with the date it was observed on, always.
///
/// The as-of date is not decoration. "€361.95" alone reads as a live reading of
/// the account; "€361.95, as of 20 Aug" is what the file actually says. The
/// word "current" appears nowhere in this row.
struct ImportBalanceRow: View {
    let account: ImportAccountPreview

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: account.kind.symbolName)
                .font(.footnote)
                .foregroundStyle(account.isSpendableHere ? Theme.Role.accent : Theme.Role.caution)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.name).font(.subheadline.weight(.medium))
                HStack(spacing: 6) {
                    Text(Self.caption(for: account))
                        .font(.caption)
                        .foregroundStyle(account.freshness.isStale ? Theme.Role.caution : .secondary)
                    if !account.isSpendableHere {
                        Text("· not spendable here")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            MoneyText(amount: account.balance, size: 17, weight: .semibold)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Internal rather than private so a test can assert on the sentence a
    /// person actually hears: the figure and the day it was observed are one
    /// statement, and a figure spoken alone would be the claim this row exists
    /// to avoid making.
    var accessibilityLabel: String {
        var parts = [account.name, account.balance.accessibleDescription(), Self.caption(for: account)]
        if !account.isSpendableHere { parts.append("not spendable here") }
        return parts.joined(separator: ", ")
    }

    static func caption(for account: ImportAccountPreview) -> String {
        account.freshness.caption(asOf: account.asOf) { day in
            day.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}

// MARK: - Step 3: review balances

struct BalanceReviewStep: View {
    let preview: ImportPreview
    @Binding var edits: [String: BalanceEdit]
    let onConfirm: () -> Void

    private var allValid: Bool {
        preview.accounts.allSatisfy { edits[$0.id]?.isValid(for: $0) ?? false }
    }

    var body: some View {
        List {
            if preview.hasStaleBalances {
                Section {
                    Label(
                        "\(preview.staleAccounts.count) of \(preview.accounts.count) balances were observed before today. Correct any that have moved.",
                        systemImage: "clock.badge.exclamationmark"
                    )
                    .font(.subheadline)
                    .foregroundStyle(Theme.Role.caution)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(preview.accounts) { account in
                Section {
                    BalanceEditor(
                        account: account,
                        edit: Binding(
                            get: { edits[account.id] ?? BalanceEdit(account) },
                            set: { edits[account.id] = $0 }
                        )
                    )
                } header: {
                    Text(account.name)
                } footer: {
                    Text("Imported as \(account.balance.formatted()), \(ImportBalanceRow.caption(for: account).lowercased()).")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 6) {
                Button(action: onConfirm) {
                    Label("Confirm restore", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!allValid)
                Text("All of it is saved, or none of it is.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.Metric.screenPadding)
            .background(.bar)
        }
    }
}

private struct BalanceEditor: View {
    let account: ImportAccountPreview
    @Binding var edit: BalanceEdit
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Balance")
                    amountField
                }
            } else {
                HStack {
                    Text("Balance")
                    Spacer()
                    amountField
                }
            }
            CivilDatePicker("As of", selection: $edit.asOf)
            if edit.amount(for: account) == nil {
                Label(
                    "Enter an amount in \(account.currencyCode).",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(Theme.Role.negative)
            }
        }
    }

    private var amountField: some View {
        HStack {
            if dynamicTypeSize.isAccessibilitySize { Spacer() }
            TextField("0", text: $edit.text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 150)
            Text(account.currencyCode).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Step 4: result

struct ImportResultStep: View {
    let summary: ImportSummary
    let onFinish: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metric.stackSpacing) {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(Theme.Role.positive)
                    Text("Restored")
                        .font(.title2.bold())
                }

                VStack(spacing: 0) {
                    ResultLine(label: "Accounts", value: "\(summary.accountCount)")
                    Divider()
                    ResultLine(label: "Recurring commitments", value: "\(summary.recurringCommitmentCount)")
                    Divider()
                    ResultLine(label: "Income sources", value: "\(summary.incomeSourceCount)")
                    Divider()
                    ResultLine(label: "Instalments", value: "\(summary.installmentCount)")
                    Divider()
                    ResultLine(label: "Expected transactions", value: "\(summary.expectedTransactionCount)")
                    Divider()
                    ResultLine(label: "Debt · EUR", value: summary.debtOutstanding.formatted())
                    ForEach(summary.foreignDebtOutstanding) { total in
                        ResultLine(label: "Debt · \(total.amount.currencyCode)", value: total.amount.formatted())
                    }
                    Divider()
                    ResultLine(label: "In accounts", value: summary.electronicLiquidity.formatted())
                    ForEach(summary.physicalCash) { total in
                        Divider()
                        ResultLine(label: "Cash in hand", value: total.amount.formatted())
                    }
                }
                .financeCard()

                if summary.hasFullRecovery {
                    ResultLine(label: "Historical transactions", value: "\(summary.historicalTransactionCount)")
                    ResultLine(label: "Verified-month revisions", value: "\(summary.checkpointRevisionCount)")
                    ResultLine(label: "Transaction corrections", value: "\(summary.transactionCorrectionCount)")
                }
                ExclusionsCard(hasFullRecovery: summary.hasFullRecovery)

                Button(action: onFinish) {
                    Label("Go to Home", systemImage: "house.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(Theme.Metric.screenPadding)
        }
        .background(Theme.Surface.background)
        .interactiveDismissDisabled()
    }
}

/// What did not come back, said where a person is about to go looking for it.
///
/// The export screen already lists these before the file is written, but that
/// is the wrong end of the story: a person reads it while everything they own
/// is still on screen, and remembers it months later, if at all. Here they
/// have just restored onto an empty install and are one tap from Home, and
/// this is the moment the absent verified months and the missing bank pairing
/// would otherwise read as data loss rather than as a documented boundary.
///
/// The lines are `BackupSummary.exclusions` verbatim rather than a second
/// wording of them, so a backup that started carrying one of these could not
/// go on being described as not carrying it on one screen out of two.
struct ExclusionsCard: View {
    var hasFullRecovery = false
    private var exclusions: [String] {
        hasFullRecovery ? BackupSummary.fullRecoveryExclusions : BackupSummary.exclusions
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not included")
                .font(.subheadline.weight(.medium))
            ForEach(exclusions, id: \.self) { line in
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .financeCard()
        .accessibilityElement(children: .combine)
    }
}

private struct ResultLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline)
            Spacer(minLength: 12)
            Text(value).font(.money(17, weight: .semibold)).monospacedDigit()
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Choose file") {
    ImportCurrentStateView()
        .environment(FinanceStore.emptyPreview())
        .environment(AppNavigation())
}
#endif
