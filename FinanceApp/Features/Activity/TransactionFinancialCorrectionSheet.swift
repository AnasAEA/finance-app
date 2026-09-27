import SwiftUI

struct TransactionFinancialCorrectionSheet: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: TransactionFinancialDraft
    @State private var amountText: String
    @State private var preview: TransactionFinancialPreview?
    @State private var failure: AppFinancialCorrectionError?

    init(draft: TransactionFinancialDraft) {
        _draft = State(initialValue: draft)
        _amountText = State(initialValue: draft.corrected.amount.editingText)
    }

    private var pickedDate: Binding<Date> {
        Binding(get: { draft.corrected.day.date() ?? Date() }, set: {
            if let day = CalendarDay($0) { draft.corrected.day = day }
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                if let preview {
                    Section {
                        LabeledContent("Type", value: draft.kindLabel)
                        values("Before", preview.draft.original)
                        values("After", preview.draft.corrected)
                        LabeledContent("Reason", value: draft.reason)
                        LabeledContent("Months to review", value: preview.affectedMonths.joined(separator: ", "))
                    } header: { Text("Review correction") } footer: {
                        Text("Budgets and month comparisons will recalculate. Previously accepted month verifications keep their original values and may need review.")
                    }
                    Section {
                        ForEach(preview.accountImpacts) { impact in
                            LabeledContent(impact.name, value: "\(impact.before?.formatted() ?? "Unavailable") → \(impact.after?.formatted() ?? "Unavailable")")
                        }
                    } header: { Text("Derived ledger balances on \(preview.asOf.description)") } footer: {
                        Text("These are ledger calculations, not bank balances. Opening and provider balances stay unchanged. Entries on or before an opening balance's date are already included in that balance.")
                    }
                    Section {
                        Button("Edit correction") { self.preview = nil }
                    } footer: {
                        Text("Confirmation keeps this transaction's identity and records its complete previous financial details. It does not create a second transaction.")
                    }
                } else {
                    Section {
                        LabeledContent("Type", value: draft.kindLabel)
                        TextField("Amount (\(draft.original.amount.currencyCode))", text: $amountText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("transaction.financialAmount")
                        DatePicker("Date", selection: pickedDate, displayedComponents: .date)
                            .accessibilityIdentifier("transaction.financialDate")
                        Picker("Account", selection: $draft.corrected.accountID) {
                            if !draft.accounts.contains(where: { $0.id == draft.original.accountID }) {
                                Text("Previous account").tag(draft.original.accountID)
                            }
                            ForEach(draft.accounts) { account in Text(account.name).tag(account.id) }
                        }
                        .accessibilityIdentifier("transaction.financialAccount")
                        TextField("Reason for correction", text: $draft.reason, axis: .vertical)
                            .accessibilityIdentifier("transaction.financialReason")
                    } footer: {
                        Text("Review the effect before saving. A financial correction keeps the original details in its history. Currency, transaction type and income source stay unchanged.")
                    }
                }
            }
            .financeList()
            .navigationTitle(preview == nil ? "Correct financial details" : "Review correction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(preview == nil ? "Review changes" : "Confirm correction", action: perform)
                        .accessibilityIdentifier(preview == nil ? "transaction.reviewFinancialCorrection" : "transaction.confirmFinancialCorrection")
                }
            }
            .alert("Not corrected", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure?.message ?? "") }
        }
    }

    private func values(_ title: String, _ values: TransactionFinancialValues) -> some View {
        let account = draft.accounts.first { $0.id == values.accountID }?.name ?? "Previous account"
        return LabeledContent(title, value: "\(values.amount.formatted()) · \(values.day) · \(account)")
    }

    private func perform() {
        do {
            if let preview {
                try store.confirmFinancialCorrection(preview)
                dismiss()
            } else {
                do {
                    draft.corrected.amount = try Amount.parse(amountText,
                        currencyCode: draft.original.amount.currencyCode,
                        fractionDigits: draft.original.amount.fractionDigits)
                } catch { throw AppFinancialCorrectionError.invalidAmount }
                preview = try store.previewFinancialCorrection(draft)
            }
        } catch let error as AppFinancialCorrectionError { failure = error }
        catch { failure = .saveFailed }
    }
}
