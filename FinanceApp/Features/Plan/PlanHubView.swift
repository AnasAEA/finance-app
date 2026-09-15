import SwiftUI

/// Planning starts as a choice of task, not as a runway chart. Each concept has
/// one management home below this list.
struct PlanView: View {
    @Environment(FinanceStore.self) private var store

    /// One live read per composition: every row below describes the same plan
    /// at the same moment, including the day-derived upcoming and waiting counts.
    var body: some View {
        content(store.snapshot)
    }

    private func content(_ snapshot: FinanceAppSnapshot) -> some View {
        List {
            NavigationLink(value: PlanRoute.budget) {
                PlanHubRow(
                    title: "Budget",
                    detail: Self.budgetDetail(snapshot),
                    value: snapshot.everydayBudget.isEmpty
                        ? nil
                        : snapshot.everydayBudget.headlineAmount.formatted()
                )
            }
            .accessibilityIdentifier(RouteID.planBudget)

            NavigationLink(value: PlanRoute.safetyReserve) {
                PlanHubRow(
                    title: "Safety reserve",
                    detail: Self.reserveDetail(snapshot),
                    value: snapshot.safetyReserve?.formatted()
                )
            }
            .accessibilityIdentifier(RouteID.planReserve)

            NavigationLink(value: PlanRoute.upcoming) {
                PlanHubRow(
                    title: "Upcoming",
                    detail: Self.upcomingDetail(snapshot),
                    value: Self.matchingValue(snapshot)
                )
            }
            .accessibilityIdentifier(RouteID.planUpcoming)

            NavigationLink(value: PlanRoute.goals) {
                PlanHubRow(
                    title: "Goals & Set Aside",
                    detail: Self.goalsDetail(snapshot),
                    value: PlanningTotals.setAside(from: snapshot).formatted()
                )
            }
            .accessibilityIdentifier(RouteID.planGoals)

            NavigationLink(value: PlanRoute.affordability) {
                PlanHubRow(
                    title: "Can I afford this?",
                    detail: "Check a purchase against cash, the ceiling, and what is set aside."
                )
            }
            .accessibilityIdentifier(RouteID.planAfford)
        }
        .listStyle(.insetGrouped)
        .contentMargins(.bottom, Theme.Metric.floatingTabBarClearance, for: .scrollContent)
        .navigationTitle("Plan")
    }

    private static func budgetDetail(_ snapshot: FinanceAppSnapshot) -> String {
        let budget = snapshot.everydayBudget
        return budget.isEmpty ? "No ceiling this month" : budget.headlineCaption
    }

    private static func reserveDetail(_ snapshot: FinanceAppSnapshot) -> String {
        snapshot.safetyReserve == nil
            ? "Cash you want to keep as a buffer"
            : "Cash the plan should not fall below"
    }

    private static func upcomingDetail(_ snapshot: FinanceAppSnapshot) -> String {
        guard let next = snapshot.upcomingEvents.first else { return "Nothing scheduled" }
        return "\(next.label) · \(next.date.formatted(.dateTime.day().month(.abbreviated)))"
    }

    private static func matchingValue(_ snapshot: FinanceAppSnapshot) -> String? {
        let waiting = snapshot.unresolvedExpectedPayments.count
        return waiting == 0 ? nil : "\(waiting) to match"
    }

    private static func goalsDetail(_ snapshot: FinanceAppSnapshot) -> String {
        let active = snapshot.plannedPurchases.filter {
            $0.status == .wishlist || $0.status == .saving
        }.count
        if active == 0 && snapshot.sinkingFunds.isEmpty {
            return "Plan something you're saving for"
        }
        return "\(active) active goal\(active == 1 ? "" : "s")"
    }
}

struct PlanHubRow: View {
    let title: String
    let detail: String
    var value: String? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if Theme.Layout.planHubStacksValueBelowTitle(dynamicTypeSize) {
                vertical
            } else {
                horizontal
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    /// Everyday size: title and figure share a line. The figure is one line so
    /// "206,70 €" cannot hyphenate; a long caption wraps under the title.
    private var horizontal: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            labels
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if let value { figure(value) }
        }
    }

    /// Accessibility and overflow: title, then the whole figure, then the caption.
    private var vertical: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.body.weight(.medium))
            if let value { figure(value) }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.body.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func figure(_ value: String) -> some View {
        Text(value)
            .font(.body.monospacedDigit().weight(.medium))
            .lineLimit(1)
            .multilineTextAlignment(.leading)
    }
}

/// Known future cash and the definitions that produce it. Booked income stays
/// in Activity; this view only reads the existing planned/expected surfaces.
struct UpcomingView: View {
    @Environment(FinanceStore.self) private var store

    /// One live read per composition. "Coming up" and the expected-payment
    /// caption are both day-derived; they must describe the same civil day.
    var body: some View {
        content(store.snapshot)
    }

    private func content(_ snapshot: FinanceAppSnapshot) -> some View {
        List {
            Section("Coming up") {
                if snapshot.upcomingEvents.isEmpty {
                    Text("Nothing scheduled.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.upcomingEvents.prefix(20)) { event in
                        UpcomingRow(event: event)
                    }
                }
            }

            Section("Expected") {
                NavigationLink {
                    ExpectedPaymentsView()
                } label: {
                    destinationRow("Expected payments", detail: Self.expectedDetail(snapshot))
                }
            }

            Section("Plan definitions") {
                NavigationLink {
                    RecurringPaymentsView()
                } label: {
                    destinationRow(
                        "Recurring payments",
                        detail: "\(snapshot.commitments.flatMap(\.lines).count) on file"
                    )
                }
                NavigationLink {
                    IncomeSourcesView()
                } label: {
                    destinationRow(
                        "Income sources",
                        detail: "\(snapshot.incomeSources.count) on file"
                    )
                }
                NavigationLink {
                    InstalmentsView()
                } label: {
                    destinationRow(
                        "Instalments",
                        detail: "\(snapshot.instalments.count) plan\(snapshot.instalments.count == 1 ? "" : "s")"
                    )
                }
                NavigationLink {
                    DebtsView()
                } label: {
                    let active = snapshot.debts.filter { !$0.outstanding.isZero }.count
                    destinationRow(
                        "Debts & arrears",
                        detail: "\(active) with a balance"
                    )
                }
            }
        }
        .navigationTitle("Upcoming")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static func expectedDetail(_ snapshot: FinanceAppSnapshot) -> String {
        let waiting = snapshot.unresolvedExpectedPayments.count
        if snapshot.expectedPayments.isEmpty {
            return "Dated recurring payments appear here."
        }
        if waiting == 0 { return "Everything expected so far has been answered." }
        let overdue = snapshot.overdueExpectedPayments.count
        return overdue == 0
            ? "\(waiting) waiting to be matched."
            : "\(waiting) waiting · \(overdue) past due."
    }

    private func destinationRow(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// One production destination for the purpose and the protected money behind
/// it. A linked fund appears inside its goal; only unlinked funds get a second
/// list section.
struct GoalsAndSetAsideView: View {
    @Environment(FinanceStore.self) private var store
    @State private var isEditingGoal = false
    @State private var isEditingFund = false

    /// One live read per composition: the goals list and the unlinked-fund
    /// section are two halves of one answer.
    var body: some View {
        content(store.snapshot)
    }

    private static func standaloneFunds(_ snapshot: FinanceAppSnapshot) -> [SinkingFundSummary] {
        snapshot.sinkingFunds.filter { fund in
            fund.goalID == nil
                && !snapshot.plannedPurchases.contains { $0.sinkingFundID == fund.id }
        }
    }

    private func content(_ snapshot: FinanceAppSnapshot) -> some View {
        let standaloneFunds = Self.standaloneFunds(snapshot)
        return List {
            Section {
                if snapshot.plannedPurchases.isEmpty {
                    Text(PlanningCopy.emptyGoals)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.plannedPurchases) { goal in
                        NavigationLink {
                            GoalDetailView(goalID: goal.id)
                        } label: {
                            GoalPlanRow(goal: goal)
                        }
                        .accessibilityIdentifier("plan.goal.\(goal.id)")
                    }
                }
            } header: {
                HStack {
                    Text("Goals")
                    Spacer()
                    Button("Add") { isEditingGoal = true }
                    .accessibilityIdentifier(PlanningControlID.addGoal)
                }
            }

            Section {
                if standaloneFunds.isEmpty {
                    Text("Set-aside not tied to a goal appears here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(standaloneFunds) { fund in
                        NavigationLink {
                            SetAsideDetailView(fundID: fund.id)
                        } label: {
                            FundPlanRow(fund: fund)
                        }
                        .accessibilityIdentifier("plan.fund.\(fund.id)")
                    }
                }
            } header: {
                HStack {
                    Text("Standalone set-aside")
                    Spacer()
                    Button("Add") { isEditingFund = true }
                    .accessibilityIdentifier(PlanningControlID.addFund)
                }
            }
        }
        .navigationTitle("Goals & Set Aside")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isEditingGoal) { GoalEditorView() }
        .sheet(isPresented: $isEditingFund) { SinkingFundEditorView() }
    }
}

struct GoalDetailView: View {
    let goalID: String

    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var confirmsDelete = false
    @State private var error: String?

    /// One live read per composition: the goal and the fund protecting it are
    /// one answer, not two independently sampled ones.
    var body: some View {
        content(store.snapshot)
    }

    private func content(_ snapshot: FinanceAppSnapshot) -> some View {
        let goal = snapshot.plannedPurchases.first { $0.id == goalID }
        let linkedFund = goal?.sinkingFundID.flatMap { id in
            snapshot.sinkingFunds.first { $0.id == id }
        }
        return List {
            if let goal {
                Section {
                    LabeledContent("Name", value: goal.name)
                    LabeledContent("Target") { MoneyText(amount: goal.target, size: 17, weight: .medium) }
                    LabeledContent("Status", value: goal.status.displayName)
                    LabeledContent("Funding", value: goal.fundingLabel)
                    if let date = goal.targetDate {
                        LabeledContent("Target date", value: date.formatted(date: .long, time: .omitted))
                    }
                }
                if let linkedFund {
                    Section("Set aside") {
                        NavigationLink {
                            SetAsideDetailView(fundID: linkedFund.id)
                        } label: {
                            FundPlanRow(fund: linkedFund)
                        }
                    }
                } else if goal.reserved.isPositive {
                    Section("Set aside") {
                        LabeledContent("Protected for this goal") {
                            MoneyText(amount: goal.reserved, size: 17, weight: .medium)
                        }
                    }
                }
                Section {
                    Button("Delete goal", role: .destructive) { confirmsDelete = true }
                }
            } else {
                ContentUnavailableView("Goal not available", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(goal?.name ?? "Goal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { isEditing = true }
                    .disabled(goal == nil)
            }
        }
        .sheet(isPresented: $isEditing) {
            // Read the draft when the sheet is created. Assigning it on the
            // Edit tap and presenting in the same turn can open an empty editor.
            GoalEditorView(draft: store.plannedPurchaseDraft(id: goalID) ?? PlannedPurchaseDraft())
        }
        .confirmationDialog("Delete this goal?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Not deleted", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func delete() {
        do {
            try store.deletePlannedPurchase(id: goalID)
            dismiss()
        } catch let problem as AppManagementError {
            error = problem.message
        } catch {
            self.error = String(describing: error)
        }
    }
}

struct SetAsideDetailView: View {
    let fundID: String

    @Environment(FinanceStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var confirmsDelete = false
    @State private var error: String?

    private var fund: SinkingFundSummary? {
        store.snapshot.sinkingFunds.first { $0.id == fundID }
    }

    var body: some View {
        List {
            if let fund {
                Section {
                    LabeledContent("Target") { MoneyText(amount: fund.target, size: 17, weight: .medium) }
                    LabeledContent("Set aside") { MoneyText(amount: fund.reserved, size: 17, weight: .medium) }
                    if fund.remaining.isPositive {
                        LabeledContent("Still to set aside") {
                            MoneyText(amount: fund.remaining, size: 17, weight: .medium)
                        }
                    }
                    LabeledContent("Custody", value: fund.custody.displayName)
                    if let account = fund.dedicatedAccountName {
                        LabeledContent("Held in", value: account)
                    }
                    if let goal = fund.goalName {
                        LabeledContent("Goal", value: goal)
                    }
                }
                Section {
                    Button("Delete set-aside", role: .destructive) { confirmsDelete = true }
                }
            } else {
                ContentUnavailableView("Set-aside not available", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(fund?.name ?? "Set Aside")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { isEditing = true }
                    .disabled(fund == nil)
            }
        }
        .sheet(isPresented: $isEditing) {
            SinkingFundEditorView(draft: store.sinkingFundDraft(id: fundID) ?? SinkingFundDraft())
        }
        .confirmationDialog("Delete this set-aside?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Not deleted", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func delete() {
        do {
            try store.deleteSinkingFund(id: fundID)
            dismiss()
        } catch let problem as AppManagementError {
            error = problem.message
        } catch {
            self.error = String(describing: error)
        }
    }
}
