import SwiftUI

/// An optional manual search. Merely opening it never marks anything as a match.
struct RecordedPaymentLookupView: View {
    let observationID: String
    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selected: RecordedPaymentCandidate?
    @State private var failure: String?

    var body: some View {
        let rows = store.recordedPaymentCandidates(for: observationID, search: search)
        return List {
            Section {
                Text("Recorded payments with the same account and amount. Choose one only if it represents this exact payment.")
                    .font(Theme.TypeStyle.supporting).foregroundStyle(.secondary)
            }.listRowBackground(Theme.Surface.background)
            if rows.isEmpty {
                ContentUnavailableView("No recorded payments", systemImage: "magnifyingglass",
                                       description: Text("Try another merchant name, or record this as a new payment."))
            }
            ForEach(rows) { row in
                Button { selected = row } label: {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text(row.title).font(Theme.TypeStyle.action).foregroundStyle(.primary)
                        HStack {
                            Text(row.day.formatted(.dateTime.day().month(.abbreviated).year()))
                            Spacer()
                            MoneyText(amount: row.amount, size: 16, showsSign: true)
                        }.font(Theme.TypeStyle.metadata).foregroundStyle(.secondary)
                        Text(row.accountName).font(Theme.TypeStyle.metadata).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Theme.Space.sm).contentShape(Rectangle())
                }
                .buttonStyle(.plain).listRowBackground(Theme.Surface.background)
            }
        }
        .listStyle(.plain).financeList().navigationTitle("Find recorded payment")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find merchant")
        .confirmationDialog("Link to this recorded payment?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }),
                            titleVisibility: .visible) {
            Button("Link bank evidence") {
                guard let selected else { return }
                do { try store.matchObservation(observationID, toTransaction: selected.id); dismiss() }
                catch let error as BankReviewError { failure = error.message }
                catch { failure = "The evidence could not be linked." }
                self.selected = nil
            }
            Button("Cancel", role: .cancel) { selected = nil }
        } message: {
            Text("This adds bank evidence to the recorded payment. It does not create another expense.")
        }
        .alert("Couldn’t link payment", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "Nothing was changed.") }
    }
}
