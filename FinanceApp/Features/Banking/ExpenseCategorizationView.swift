import SwiftUI

struct ExpenseReviewDraft: Identifiable {
    let observationID: String
    let label: String
    var relatedObservationID: String? = nil
    var expectedPaymentID: String? = nil
    var allowingPotentialDuplicate = false
    var id: String { observationID }
}

/// The category is part of the same explicit save as the expense and its links.
struct ExpenseCategorizationView: View {
    let draft: ExpenseReviewDraft
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var categoryKey: String?
    @State private var search = ""
    @State private var chargedAmountText = ""
    @State private var failure: String?
    @State private var didInitialize = false

    var body: some View {
        let snapshot = store.snapshot
        let item = snapshot.syncedObservations.first { $0.id == draft.observationID }
        let categories = snapshot.entryOptions.categories.filter { !$0.isIncome && !$0.isTransfer }
        let suggested = item.flatMap {
            store.suggestedExpenseCategory(merchant: draft.label, currency: $0.amount.currencyCode)
        }
        return FinancePage {
            if let item {
                FinanceSection {
                    Text(ActivityTextPresentation.readableTitle(draft.label)).font(Theme.TypeStyle.screen)
                    MoneyText(amount: item.amount, size: 36, showsSign: true)
                    Text(item.providerAccountName).font(Theme.TypeStyle.metadata).foregroundStyle(Theme.Role.supporting)
                }
                if item.requiresChargedAmount, let code = item.accountCurrencyCode {
                    FinanceSection("Amount charged in \(code)") {
                        Text("\(item.providerName) reported the purchase in \(item.amount.currencyCode). Enter the exact amount charged to \(item.providerAccountName) in \(code), including any conversion fee. Check your statement; no exchange rate is estimated.")
                            .font(Theme.TypeStyle.supporting).foregroundStyle(Theme.Role.supporting)
                        TextField("Amount in \(code)", text: $chargedAmountText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("review.expense.chargedAmount")
                        if !chargedAmountText.isEmpty && chargedAmount(for: item) == nil {
                            Text("Enter a positive amount with the currency’s exact precision.")
                                .font(Theme.TypeStyle.metadata).foregroundStyle(Theme.Role.caution)
                        }
                    }
                }
                FinanceSection("Merchant") {
                    TextField("Merchant", text: $label).textInputAutocapitalization(.words)
                        .accessibilityIdentifier("review.expense.merchant")
                }
                FinanceSection("Category") {
                    TextField("Find a category", text: $search)
                        .padding(Theme.Space.md).background(Theme.Surface.inset, in: RoundedRectangle(cornerRadius: 12))
                    if let suggested, let category = categories.first(where: { $0.key == suggested }) {
                        Text("Previously used for this merchant: \(category.name)")
                            .font(Theme.TypeStyle.metadata).foregroundStyle(Theme.Role.accent)
                    }
                    ForEach(categories.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { category in
                        Button { categoryKey = category.key } label: {
                            HStack(spacing: Theme.Space.md) {
                                ActivityMark(symbol: category.symbolName)
                                Text(category.name).foregroundStyle(.primary)
                                Spacer()
                                if categoryKey == category.key { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Role.accent) }
                            }
                            .padding(.vertical, Theme.Space.sm)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("review.category.\(category.key)")
                        .accessibilityAddTraits(categoryKey == category.key ? .isSelected : [])
                    }
                }
                NavigationLink { ObservationReviewView(observationID: item.id) } label: {
                    Label("See evidence and other options", systemImage: "doc.text.magnifyingglass")
                }
            } else {
                ContentUnavailableView("Payment unavailable", systemImage: "doc")
            }
        }
        .navigationTitle("Categorize payment")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if item?.resolution == .unreviewed {
                Button("Record expense") { save() }
                    .buttonStyle(.borderedProminent).tint(Theme.Role.accent)
                    .disabled(categoryKey == nil || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (item?.requiresChargedAmount == true && item.flatMap(chargedAmount) == nil))
                    .frame(maxWidth: .infinity).padding(Theme.Space.lg)
                    .background(Theme.Surface.background)
                    .accessibilityIdentifier("review.expense.save")
            }
        }
        .onAppear {
            guard !didInitialize else { return }
            didInitialize = true
            label = draft.label
            categoryKey = categories.contains { $0.key == suggested } ? suggested : nil
        }
        .alert("Couldn’t record expense", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "Nothing was changed.") }
    }

    private func chargedAmount(for item: SyncedObservationItem) -> Amount? {
        guard item.requiresChargedAmount, let code = item.accountCurrencyCode,
              let digits = item.accountCurrencyFractionDigits,
              let value = try? Amount.parse(chargedAmountText, currencyCode: code, fractionDigits: digits),
              value.isPositive else { return nil }
        return value
    }

    private func save() {
        do {
            try store.createExpense(from: draft.observationID, userLabel: label, categoryKey: categoryKey,
                                    chargedAmount: store.snapshot.syncedObservations.first { $0.id == draft.observationID }.flatMap(chargedAmount),
                                    including: draft.relatedObservationID,
                                    settlingExpectedPaymentID: draft.expectedPaymentID,
                                    allowingPotentialDuplicate: draft.allowingPotentialDuplicate)
            dismiss()
        } catch let error as BankReviewError { failure = error.message }
        catch { failure = "The expense could not be saved. Please try again." }
    }
}
