import SwiftUI

/// Rows that more than one feature needs, so neither feature owns them:
/// holdings on Accounts, planned events on Plan → Upcoming, budget bars on
/// Plan → Budget. They read snapshot values only.

/// One account or holding, with the reason it is not spendable when it is not.
struct HoldingRow: View {
    let holding: HoldingLine

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: holding.kind.symbolName)
                .font(.footnote)
                .foregroundStyle(holding.isSpendableHere ? Theme.Role.accent : Theme.Role.caution)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(holding.title)
                    .font(.subheadline)
                if let carriedAt = holding.carriedAt {
                    // Never added to the euro figure — it is what the cash cost,
                    // not money that can pay a French direct debit.
                    Text("Carried at \(carriedAt.formatted()) · not spendable here")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if !holding.isSpendableHere {
                    Text("Not spendable here")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)
            MoneyText(amount: holding.balance, size: 17, weight: .medium)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    var accessibilityLabel: String {
        let suffix = holding.isSpendableHere ? "" : ", not spendable here"
        return "\(holding.title), \(holding.balance.accessibleDescription())\(suffix)"
    }
}

/// One dated plan event, with everything that qualifies it: recovery, certainty,
/// promised-but-not-received, approximate date.
struct UpcomingRow: View {
    let event: PlannedEvent

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text(event.date.formatted(.dateTime.day()))
                    .font(.money(17, weight: .semibold))
                Text(event.date.formatted(.dateTime.month(.abbreviated)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }
            .frame(width: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.label).font(.subheadline).lineLimit(1)
                HStack(spacing: 6) {
                    if event.isRecovery {
                        Chip(text: "Recovery", tint: Theme.Role.recovery)
                    }
                    if let certainty = event.certaintyLabel {
                        Chip(text: certainty, tint: Theme.Role.caution)
                    }
                    if event.isGuaranteedButNotReceived {
                        // Committed for a named date is a promise, not a
                        // balance. Money already received is a settled row on
                        // Activity and never appears here at all.
                        Chip(text: "Not received yet", systemImage: "clock.badge",
                             tint: Theme.Role.caution)
                    }
                    if event.hasApproximateDate {
                        Text("around this date")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)
            MoneyText(amount: event.amount, size: 17, weight: .medium,
                      showsSign: true, colorBySign: true)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Internal rather than private so a test can assert on the sentence a
    /// person actually hears — "guaranteed" and "already in the account" have
    /// to sound different, and a colour alone cannot say that.
    var accessibilityLabel: String {
        var parts = [
            event.label,
            event.date.formatted(.dateTime.day().month(.wide)),
            "\(event.amount.magnitude.accessibleDescription()) \(event.isInflow ? "in" : "out")"
        ]
        if event.isGuaranteedButNotReceived { parts.append("not received yet") }
        if let certainty = event.certaintyLabel { parts.append(certainty) }
        return parts.joined(separator: ", ")
    }
}

/// A budget bar. Takes the comparisons already made rather than making them:
/// whether a budget is over or near its limit is a decision, and decisions
/// belong on the far side of the facade.
struct BudgetBar: View {
    let fraction: Double
    let isOverspent: Bool
    let isNearLimit: Bool
    var accessibilityValue: String?

    init(fraction: Double, isOverspent: Bool, isNearLimit: Bool, accessibilityValue: String? = nil) {
        self.fraction = fraction
        self.isOverspent = isOverspent
        self.isNearLimit = isNearLimit
        self.accessibilityValue = accessibilityValue
    }

    init(summary: BudgetSummary) {
        self.init(
            fraction: summary.fraction,
            isOverspent: summary.isOverspent,
            isNearLimit: summary.isNearLimit,
            accessibilityValue: "\(summary.spent.formatted()) of \(summary.limit.formatted())"
        )
    }

    init(line: BudgetLine) {
        self.init(
            fraction: line.fraction,
            isOverspent: line.isOverspent,
            isNearLimit: line.fraction > 0.85,
            accessibilityValue: "\(line.spent.formatted()) of \(line.limit.formatted())"
        )
    }

    private var tint: Color {
        if isOverspent { return Theme.Role.negative }
        if isNearLimit { return Theme.Role.caution }
        return Theme.Role.accent
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Surface.inset)
                Capsule().fill(tint).frame(width: max(proxy.size.width * fraction, fraction > 0 ? 6 : 0))
            }
        }
        .frame(height: 8)
        .accessibilityLabel("Budget used")
        .accessibilityValue(accessibilityValue ?? "")
    }
}
