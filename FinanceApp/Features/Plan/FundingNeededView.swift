import SwiftUI

/// Read-only explanation of the canonical settlement failure behind Home's
/// funding card. Every figure arrives already paired by the presentation
/// mapper; this view performs no subtraction or forecast work.
struct FundingNeededView: View {
    @Environment(FinanceStore.self) private var store

    private var funding: FundingNeededPresentation? {
        store.attentionPresentation.fundingNeeded
    }

    var body: some View {
        FinancePage {
            if let funding {
                FinanceSection {
                    VStack(alignment: .leading, spacing: 5) {
                        if let trigger = funding.trigger {
                            Text(trigger)
                                .font(.headline)
                                .accessibilityIdentifier(FundingID.trigger)
                        }
                        Text(funding.day.formatted(.dateTime.day().month(.wide).year()))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(FundingID.date)
                    }
                    .padding(.vertical, 4)
                }

                FinanceSection {
                    fundingFigures(funding)
                }

                FinanceSection {
                    switch funding.subject {
                    case let .account(name, kind):
                        LabeledContent("Payment account", value: "\(name) · \(kind)")
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier(FundingID.paymentAccount)
                    case let .paymentAccounts(names):
                        VStack(alignment: .leading, spacing: 5) {
                            Text("PAYMENT ACCOUNTS").font(.eyebrow).foregroundStyle(.secondary)
                            Text(names.isEmpty ? "Eligible payment accounts" : names.joined(separator: ", "))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier(FundingID.paymentAccount)
                    }
                }

                if !funding.beforeThen.isEmpty {
                    FinanceSection("Before then") {
                        ForEach(funding.beforeThen) { event in
                            LabeledContent {
                                MoneyText(
                                    amount: event.amount,
                                    size: 17,
                                    showsSign: true,
                                    colorBySign: true
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(event.label)
                                    Text(event.date.formatted(.dateTime.day().month(.abbreviated)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                FinanceSection {
                    Text(funding.footer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(FundingID.explanation)
                }
            } else {
                ContentUnavailableView(
                    "Funding detail unavailable",
                    systemImage: "questionmark.circle",
                    description: Text("The projection didn't provide one settlement failure to explain.")
                )
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Funding Needed")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(RouteID.planFundingNeeded)
    }

    /// Three figures, three accessibility elements.
    ///
    /// They used to be combined into one, which read as a single unbroken
    /// utterance of six values and left no element for any one of them to be
    /// named by. Each figure now carries its own label-and-amount pair, which
    /// is both the pairing VoiceOver wants and the granularity an automation
    /// needs.
    private func fundingFigures(_ funding: FundingNeededPresentation) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                figures(funding)
            }
            VStack(alignment: .leading, spacing: 14) {
                figures(funding)
            }
        }
    }

    @ViewBuilder
    private func figures(_ funding: FundingNeededPresentation) -> some View {
        figure("Due that day", funding.requested, identifier: FundingID.due)
        figure("Expected to be covered", funding.settled, identifier: FundingID.covered)
        figure("Still needed", funding.unsettled, identifier: FundingID.stillNeeded)
    }

    private func figure(
        _ label: String,
        _ amount: Amount,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.eyebrow)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            MoneyText(amount: amount, size: 20, weight: .semibold)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}
