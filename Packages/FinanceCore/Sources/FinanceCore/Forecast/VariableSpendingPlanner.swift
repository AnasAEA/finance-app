/// Turns monthly budget allocations into daily forecast events.
///
/// **Documented assumption (v1):** each month's envelope is spent *evenly*
/// across the days of that month. Each day receives `floor(month / days)` and
/// the leftover minor units are distributed one cent at a time to the earliest
/// days of the month (largest-remainder), so the parts sum back exactly.
/// No seasonality, no intra-month spikes. This is an explicit planning
/// simplification, chosen so daily balances stay meaningful without a
/// behavioral spending model.
public enum VariableSpendingPlanner {

    /// The rails variable spending is assumed to settle on: euro card /
    /// electronic payment. (Groceries could also be paid in euro cash; a
    /// deployment can override by post-processing events — kept simple here
    /// because euro cash is excluded from the spendable pool by definition.)
    public static let defaultRequirement = PaymentRequirement(
        currency: .eur,
        acceptableRails: [.cardDebit, .electronicPayment]
    )

    /// Expands `budgets` into one `variableSpending` event per day inside
    /// `[start, end]`, per allocation.
    ///
    /// What gets spread is the line's **remaining** envelope: the gross monthly
    /// amount minus the scheduled charges already promised to that line-month,
    /// clamped at zero. A budget line is a gross envelope — a €480.00 housing
    /// line with the €480.00 rent linked to it *is* the rent — so spreading the
    /// gross amount on top of the scheduled debit would take the same euros out
    /// of the pool twice.
    ///
    /// `committedByBudgetMonth` must come from `BudgetCommitmentAttribution`,
    /// over the same window and the same reconciliation ledger as the scheduled
    /// debits in the request. Unlinked obligations are absent from that map by
    /// construction and so stay charged in full, and a commitment only ever
    /// nets a line-month of its own currency.
    ///
    /// The daily spread itself is untouched: the same even, largest-remainder
    /// allocation over the days of the month, only over a smaller amount.
    public static func events(
        budgets: [BudgetAllocation],
        committedByBudgetMonth: [BudgetCommitmentAttribution.Key: Money] = [:],
        from start: Day,
        to end: Day,
        requirement: PaymentRequirement = VariableSpendingPlanner.defaultRequirement
    ) -> [ForecastEvent] {
        guard start <= end else { return [] }
        var events: [ForecastEvent] = []
        var month = start.monthKey
        while month <= end.monthKey {
            let daysInMonth = month.firstDay.lastDayOfMonth.day
            for budget in budgets {
                guard let monthly = budget.amount(for: month), monthly.minorUnits != 0 else { continue }
                let committed = committedByBudgetMonth[
                    BudgetCommitmentAttribution.Key(
                        budgetID: budget.id, month: month, currency: monthly.currency)
                ]?.magnitude.minorUnits ?? 0
                let remaining = monthly.magnitude.minorUnits - committed
                guard remaining > 0 else { continue }
                let parts = Money(minorUnits: remaining, currency: monthly.currency)
                    .allocated(ratios: Array(repeating: 1, count: daysInMonth))
                for (offset, part) in parts.enumerated() where part.minorUnits != 0 {
                    // `offset` is under the month's own length, so this day
                    // exists whenever the month does.
                    guard let day = month.firstDay.advanced(by: offset),
                          day >= start, day <= end else { continue }
                    events.append(
                        ForecastEvent(
                            id: "var-\(budget.id)-\(day.isoString)",
                            day: day,
                            phase: .variableSpending,
                            effect: .debit(part, requirement: requirement),
                            sourceRef: budget.id
                        )
                    )
                }
            }
            // The final requested month has been planned; the month after it
            // need not exist.
            guard month < end.monthKey, let following = month.next else { break }
            month = following
        }
        return events
    }
}
