import SwiftUI

struct TransactionCorrectionSheet: View {
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: TransactionCorrectionDraft
    @State private var failure: AppCorrectionError?

    private var merchant: Binding<String> {
        Binding(get: { draft.corrected.merchant ?? "" }, set: { draft.corrected.merchant = $0.isEmpty ? nil : $0 })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Merchant or payer", text: merchant)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("transaction.correctionMerchant")
                    if !draft.categories.isEmpty {
                        Picker("Category", selection: $draft.corrected.categoryKey) {
                            Text("Uncategorized").tag(String?.none)
                            if let key = draft.original.categoryKey, !draft.categories.contains(where: { $0.key == key }) {
                                Text("Previous category").tag(Optional(key))
                            }
                            ForEach(draft.categories) { category in
                                Text(category.name).tag(Optional(category.key))
                            }
                        }
                        .accessibilityIdentifier("transaction.correctionCategory")
                    }
                } footer: {
                    Text("Your changes are saved with their previous values in the correction history. Bank evidence stays unchanged. Category changes update budgets and month verification.")
                }
            }
            .financeList()
            .navigationTitle("Correct transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save changes", action: save)
                        .disabled(draft.corrected == draft.original)
                        .accessibilityIdentifier("transaction.saveCorrection")
                }
            }
            .alert("Not corrected", isPresented: Binding(
                get: { failure != nil }, set: { if !$0 { failure = nil } }
            )) {
                Button("OK", role: .cancel) { failure = nil }
            } message: {
                Text(failure?.message ?? "")
            }
        }
    }

    private func save() {
        do {
            try store.correctTransactionMetadata(draft)
            dismiss()
        } catch let error as AppCorrectionError {
            failure = error
        } catch {
            failure = .persistenceFailed
        }
    }
}
