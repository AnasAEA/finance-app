import SwiftUI
import Charts

/// Detailed budget and runway destination. The Plan tab itself is a compact
/// hub; this is where the existing month/scenario/budget semantics continue to
/// live unchanged.
/// One live read per composition. The month picker, runway chart, risk day and
/// budget card are one answer about one civil day; reading the store per card
/// would let a screen built across local midnight mix two projections.
struct BudgetDetailView: View {
    @Environment(FinanceStore.self) private var store

    var body: some View {
        BudgetDetailContent(snapshot: store.snapshot)
    }
}

private struct BudgetDetailContent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(FinanceStore.self) private var store
    let snapshot: FinanceAppSnapshot
    @State private var monthOffset = 0
    @State private var isEditingBudget = false

    private var months: [MonthProjection] { snapshot.monthProjections }

    private var month: MonthProjection? {
        guard months.indices.contains(monthOffset) else { return months.first }
        return months[monthOffset]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Metric.stackSpacing) {
                scenarioPicker
                monthPicker
                if let month {
                    summaryCard(month)
                }
                runwayCard
                budgetCard
            }
            .padding(.horizontal, Theme.Metric.screenPadding)
            .padding(.bottom, 24)
        }
        .background(Theme.Surface.background)
        .financeList()
        .navigationTitle("Budget")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isEditingBudget) { BudgetEditView() }
    }

    // MARK: - Scenario

    private var scenarioPicker: some View {
        @Bindable var store = store
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Scenario", selection: $store.scenario) {
                ForEach(PlanScenario.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text(snapshot.scenario.explanation)
                .font(.caption)
                .foregroundStyle(Theme.Role.supporting)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Month

    private var monthPicker: some View {
        HStack {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { monthOffset -= 1 }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(monthOffset <= 0)

            Spacer()
            if let month {
                Text(month.month.firstDay.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
            }
            Spacer()

            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { monthOffset += 1 }
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(monthOffset >= months.count - 1)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
    }

    // MARK: - Summary

    /// The month as a ledger that adds up: every row on it is a movement of the
    /// same pool, and the four of them are all of them, so they reach the
    /// closing figure exactly. Committed payments and everyday spending are
    /// separate rows because they are separate kinds of promise — one is
    /// already owed to a date, the other is what the budget leaves to live on.
    private func summaryCard(_ month: MonthProjection) -> some View {
        VStack(spacing: 12) {
            LedgerRow(label: "Opening cash", value: month.opening)
            Divider()
            LedgerRow(label: "Planned income", value: month.plannedIncome, colorBySign: false)
            LedgerRow(label: "Committed & scheduled", value: month.committedSpending.negated,
                      caption: "Already promised to a date", colorBySign: true)
            LedgerRow(label: "Everyday spending planned", value: month.everydaySpending.negated,
                      caption: "What the budget lines leave to spend", colorBySign: true)
            Divider()
            LedgerRow(label: "Projected closing cash", value: month.closing, emphasis: true, colorBySign: true)

            if let unfunded = month.unfundedEUR {
                // A settlement failure and a negative closing balance are two
                // different facts, and this month can have either without the
                // other: the pool can hold enough overall while the one account
                // a direct debit must come from does not. Reported, never
                // closed with an invented transfer.
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").font(.caption)
                    Text("\(unfunded.formatted()) of payments may still fail because the account they must come from does not have enough on the day.")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(Theme.Role.negative)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }

            ForEach(month.unfundedInOtherCurrencies, id: \.currencyCode) { unfunded in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle").font(.caption)
                    Text("Also \(unfunded.formatted()) that may fail. No conversion is assumed.")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(Theme.Role.negative)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if PlanningTotals.incomeIsScenarioIndependent(in: month) {
                // Why the three scenarios can look identical here.
                Text("Every payment coming in this month is guaranteed, so the scenario does not change what arrives.")
                    .font(.caption)
                    .foregroundStyle(Theme.Role.supporting)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .financeCard()
    }

    // MARK: - Runway chart

    private var runwayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Eyebrow("Cash runway")
                Spacer()
                if let days = snapshot.cashRunway.daysRemaining {
                    Chip(text: "\(days) days", systemImage: "clock", tint: Theme.Role.negative)
                } else {
                    Chip(text: "No shortfall ahead", systemImage: "checkmark", tint: Theme.Role.positive)
                }
            }

            if !snapshot.runwayPoints.isEmpty {
                if snapshot.runwayPoints.allSatisfy({ $0.date.date() != nil }) {
                Chart {
                    ForEach(snapshot.runwayPoints, id: \.date) { point in
                        if let instant = point.date.date() {
                            AreaMark(
                                x: .value("Date", instant),
                                y: .value("Balance", point.balance.chartValue)
                            )
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [Theme.Role.accent.opacity(0.28), Theme.Role.accent.opacity(0.02)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                            LineMark(
                                x: .value("Date", instant),
                                y: .value("Balance", point.balance.chartValue)
                            )
                            .foregroundStyle(Theme.Role.accent)
                            .interpolationMethod(.monotone)
                        }
                    }
                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(Theme.Surface.separator)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    if let risk = snapshot.firstRisk, let instant = risk.date.date() {
                        RuleMark(x: .value("Risk", instant))
                            .foregroundStyle(Theme.Role.negative.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .annotation(position: .top, alignment: .leading) {
                                Text("Runs out")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.Role.negative)
                            }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Theme.Surface.separator.opacity(0.5))
                        AxisValueLabel {
                            if let number = value.as(Double.self) {
                                Text(axisLabel(number)).font(.caption2)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { value in
                        AxisGridLine().foregroundStyle(Theme.Surface.separator.opacity(0.5))
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .frame(height: 168)
                .accessibilityLabel("Projected balance over the next \(snapshot.horizonDays) days")
                } else {
                    ForEach(snapshot.runwayPoints) { point in
                        LabeledContent(point.date.formatted(.dateTime.day().month(.abbreviated)),
                                       value: point.balance.formatted())
                    }
                }
            }

            Text("Projection on \(snapshot.scenario.displayName.lowercased()) assumptions.")
                .font(.caption).foregroundStyle(Theme.Role.supporting)
        }
        .financeCard()
    }

    private func axisLabel(_ majorUnits: Double) -> String {
        Amount(
            minorUnits: Int64((majorUnits * 100).rounded()),
            currencyCode: snapshot.currencyCode
        )
        .formatted(omitsFractionWhenWhole: true)
    }

    // MARK: - Budget

    private var budget: BudgetOverview { snapshot.budget }

    private var budgetCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Eyebrow("Budget")
                Spacer()
                Button {
                    isEditingBudget = true
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Role.accent)
            }

            if budget.summary.isEmpty && budget.lines.isEmpty {
                Text("No budget set for this month.")
                    .font(.subheadline).foregroundStyle(Theme.Role.supporting)
            } else {
                budgetHeadline
                if budget.lines.isEmpty {
                    // A ceiling with nothing allocated under it is a real
                    // state, not a blank one: it happens in the days before a
                    // plan starts. Saying so beats showing the whole ceiling
                    // as "unallocated" and leaving the reason to be guessed.
                    Text("No budget lines are in effect this month.")
                        .font(.caption).foregroundStyle(Theme.Role.supporting)
                }
                if budget.hasSuggestedLines { suggestionNotice }
                if !budget.lines.isEmpty {
                    Divider()
                    budgetLines
                }
                budgetFooter
            }
        }
        .financeCard()
    }

    private var budgetHeadline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                MoneyText(amount: budget.summary.safeToSpend, size: 26, weight: .bold)
                Text(budget.summary.headlineCaption)
                    .font(.subheadline).foregroundStyle(Theme.Role.supporting)
                Spacer()
            }
            BudgetBar(summary: budget.summary)
            HStack(spacing: 12) {
                budgetStat("Spent", budget.summary.spent)
                budgetStat("Committed", budget.summary.committed)
                if let unallocated = budget.unallocated {
                    budgetStat("Unallocated", unallocated)
                }
            }
            if budget.summary.ceiling == nil {
                Text("No monthly ceiling set. Figures compare against what the lines allocate.")
                    .font(.caption).foregroundStyle(Theme.Role.supporting)
            }
        }
    }

    private func budgetStat(_ label: String, _ value: Amount) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Theme.Role.supporting)
            MoneyText(amount: value, size: 13, weight: .medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var suggestionNotice: some View {
        Label(
            budget.isEntirelySuggested
                ? "These targets are suggestions. Nothing here has been agreed yet."
                : "Some targets are still suggestions.",
            systemImage: "questionmark.circle"
        )
        .font(.caption)
        .foregroundStyle(Theme.Role.caution)
    }

    private var budgetLines: some View {
        ForEach(budget.lines.sorted { $0.limit > $1.limit }) { line in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label {
                        HStack(spacing: 6) {
                            Text(line.name).font(.subheadline)
                            if line.isSuggested {
                                Text("Suggested")
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Theme.Surface.inset, in: Capsule())
                                    .foregroundStyle(Theme.Role.supporting)
                            }
                        }
                    } icon: {
                        Image(systemName: line.symbolName)
                    }
                    Spacer()
                    Text("\(line.spent.formatted()) / \(line.limit.formatted())")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(line.isOverspent ? Theme.Role.negative : Theme.Role.supporting)
                }
                BudgetBar(line: line)
                if let detail = lineDetail(line) {
                    Text(detail).font(.caption2).foregroundStyle(Theme.Role.supporting)
                }
            }
        }
    }

    /// What is left, what is still owed against it, and what that leaves per
    /// day. Only says "a day" while there are days left to say it about.
    private func lineDetail(_ line: BudgetLine) -> String? {
        var parts: [String] = []
        if line.isOverspent {
            parts.append("\(line.remaining.magnitude.formatted()) over")
        } else {
            parts.append("\(line.remaining.formatted()) left")
        }
        if !line.committed.isZero {
            parts.append("\(line.committed.formatted()) still committed")
        }
        if let daily = line.dailyPace, budget.daysRemaining > 0, !daily.isZero {
            parts.append("\(daily.formatted()) a day for \(budget.daysRemaining) days")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var budgetFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !budget.uncategorized.isZero {
                Label(
                    "\(budget.uncategorized.formatted()) of spending is in no category. It still counts in the total.",
                    systemImage: "tray"
                )
                .font(.caption).foregroundStyle(Theme.Role.caution)
            }
            if !budget.financingRepayments.isZero {
                Text("\(budget.financingRepayments.formatted()) of instalment repayments left your accounts this month. Repaying a purchase is not new spending, so it is not counted here.")
                    .font(.caption2).foregroundStyle(Theme.Role.supporting)
            }
            Text("What is left of the budget, not what is in your accounts.")
                .font(.caption2).foregroundStyle(Theme.Role.supporting)
        }
    }

}

struct GoalPlanRow: View {
    let goal: PlannedPurchaseSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(goal.name).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                MoneyText(amount: goal.target, size: 15, weight: .semibold)
            }
            HStack(spacing: 8) {
                Chip(text: goal.status.displayName, tint: statusTint)
                Text(goal.fundingLabel)
                    .font(.caption)
                    .foregroundStyle(Theme.Role.supporting)
                if let date = goal.targetDate {
                    Text(date.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.caption)
                        .foregroundStyle(Theme.Role.supporting)
                }
            }
            if goal.reserved.isPositive {
                Text("Set aside \(goal.reserved.formatted())")
                    .font(.caption)
                    .foregroundStyle(Theme.Role.supporting)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityIdentifier("plan.goal.\(goal.id)")
    }

    private var statusTint: Color {
        switch goal.status {
        case .wishlist: Theme.Role.supporting
        case .saving: Theme.Role.accent
        case .bought: Theme.Role.positive
        case .cancelled: Theme.Role.supporting
        }
    }

    private var label: String {
        var parts = [goal.name, goal.status.displayName, goal.target.accessibleDescription(), goal.fundingLabel]
        if goal.reserved.isPositive {
            parts.append("set aside \(goal.reserved.accessibleDescription())")
        }
        return parts.joined(separator: ", ")
    }
}

struct FundPlanRow: View {
    let fund: SinkingFundSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(fund.name).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Chip(text: fund.status.displayName)
            }
            LedgerRow(label: "Target", value: fund.target)
            LedgerRow(label: "Set aside", value: fund.reserved)
            if fund.remaining.isPositive {
                LedgerRow(label: "Still to set aside", value: fund.remaining)
            }
            Text(custodyLine)
                .font(.caption)
                .foregroundStyle(Theme.Role.supporting)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityIdentifier("plan.fund.\(fund.id)")
    }

    private var custodyLine: String {
        switch fund.custody {
        case .virtual:
            fund.custody.caption
        case .dedicated:
            if let name = fund.dedicatedAccountName {
                "Set aside in \(name). That reserved slice is not free cash."
            } else {
                fund.custody.caption
            }
        }
    }

    private var label: String {
        var parts = [
            fund.name,
            "target \(fund.target.accessibleDescription())",
            "set aside \(fund.reserved.accessibleDescription())",
            fund.custody.displayName
        ]
        if let goal = fund.goalName { parts.append("linked to \(goal)") }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    NavigationStack { BudgetDetailView() }.environment(FinanceStore.preview())
}

#if DEBUG
#Preview("Goals and funds") {
    NavigationStack { GoalsAndSetAsideView() }.environment(FinanceStore.planningPreview())
}
#endif
