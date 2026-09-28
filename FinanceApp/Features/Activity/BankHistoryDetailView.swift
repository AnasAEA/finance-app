import SwiftUI

struct BankHistoryDetailView: View {
    let observationID: String
    @Environment(FinanceStore.self) private var store

    var body: some View {
        let snapshot = store.snapshot
        if let row = snapshot.bankHistory.first(where: { $0.id == observationID }) {
            FinancePage {
                FinanceSection {
                    Text(row.title).font(Theme.TypeStyle.screen)
                        .fixedSize(horizontal: false, vertical: true)
                    MoneyText(amount: row.amount, size: 44, weight: .bold,
                              showsSign: !row.amount.isZero, colorBySign: false)
                }
                FinanceSection("Bank transaction") {
                    LabeledContent("Bank", value: row.providerName)
                    LabeledContent("Account", value: row.accountName)
                    LabeledContent("Status", value: row.status.displayName)
                    if let date = row.dates.transaction { dateRow("Transaction date", date) }
                    if let date = row.dates.booking { dateRow("Booking date", date) }
                    if let date = row.dates.value { dateRow("Value date", date) }
                    if let date = row.dates.derivedTransaction { dateRow("Reported payment date", date) }
                    if row.date == nil { Text("Your bank did not provide a transaction date.") }
                    LabeledContent("Last received", value: row.observedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                }
                FinanceSection("Recorded meaning") {
                    Text(meaning(row)).foregroundStyle(Theme.Role.supporting)
                    if snapshot.syncedObservations.contains(where: { $0.id == row.id }) {
                        NavigationLink {
                            ObservationReviewView(observationID: row.id)
                        } label: {
                            Label(row.resolution == .unreviewed ? "Review transaction" : "View bank evidence",
                                  systemImage: "doc.text.magnifyingglass")
                        }
                    }
                }
            }
            .navigationTitle("Bank transaction")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Transaction unavailable", systemImage: "doc",
                                   description: Text("This pending payment may have been replaced by a newer bank snapshot."))
        }
    }

    private func dateRow(_ title: String, _ date: CalendarDay) -> some View {
        LabeledContent(title, value: date.formatted(.dateTime.day().month(.wide).year()))
    }

    private func meaning(_ row: BankHistoryItem) -> String {
        switch row.resolution {
        case .linked: "Linked to a recorded transaction."
        case .noEconomicEffect: "Reviewed and recorded as having no economic effect."
        case .provisional: "Pending at your bank. It does not count as recorded spending or income."
        case .outsideBoundary: "Historical bank evidence outside the review period."
        case .ineligible: "Bank evidence that cannot become a recorded transaction in its current state."
        case .unreviewed: "Synced from your bank. Review it to record its meaning in your plan."
        }
    }
}
