import SwiftUI

/// Planning opens with the answer, then the tools.
///
/// Each concept keeps one management home in the workspace below. What changed is that it no longer *starts*
/// there: a hub whose first line was "Budget — 198,00 € left of 750,00 € this
/// month" said the same reassuring thing whether or not the plan could fund
/// itself, and left the person who had just been told money was missing to
/// guess which of five rows led to it.
///
/// The status states a condition and offers one route. It is composed by
/// `AttentionPresentationMapper` from the same evaluation Home reads, so the
/// two tabs cannot disagree about one forecast.
struct PlanView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// One live read per composition: every row below describes the same plan
    /// at the same moment, including the day-derived upcoming and waiting counts.
    var body: some View {
        let presentation = store.currentPresentation()
        return content(presentation.snapshot, status: presentation.attention.plan)
    }

    private func content(
        _ snapshot: FinanceAppSnapshot,
        status: PlanStatusPresentation
    ) -> some View {
        FinancePage(spacing: Theme.Space.lg) {
            planStatus(status)

            FinanceSection("Spending policy") {
                if Theme.Layout.planHubStacksValueBelowTitle(dynamicTypeSize) {
                    VStack(spacing: Theme.Space.md) {
                        policyTile(snapshot, budget: true)
                        Divider()
                        policyTile(snapshot, budget: false)
                    }
                } else {
                    HStack(alignment: .top, spacing: Theme.Space.lg) {
                        policyTile(snapshot, budget: true)
                        Rectangle().fill(Theme.Surface.separator).frame(width: 1)
                        policyTile(snapshot, budget: false)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
            let workspaceLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.xl))
                : AnyLayout(HStackLayout(alignment: .top, spacing: Theme.Space.xl))
            workspaceLayout {
                commitments(snapshot)
                    .frame(maxWidth: .infinity, alignment: .leading)
                protectedMoney(snapshot)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            NavigationLink(value: PlanRoute.affordability) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ActionLabel(title: "Can I afford this?")
                    Text("Try a purchase against your plan.")
                        .font(Theme.TypeStyle.supporting).foregroundStyle(Theme.Role.supporting)
                }
                .padding(.top, Theme.Space.sm)
                .overlay(alignment: .top) { Rectangle().fill(Theme.Surface.separator).frame(height: 1) }
            }
            .buttonStyle(FinancePressStyle())
            .accessibilityIdentifier(RouteID.planAfford)
        }
        .navigationTitle("Plan")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func commitments(_ snapshot: FinanceAppSnapshot) -> some View {
        FinanceSection("Commitments") {
            NavigationLink(value: PlanRoute.upcoming) {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    ActionLabel(title: "Upcoming")
                    Text(Self.upcomingDetail(snapshot))
                        .font(Theme.TypeStyle.supporting).foregroundStyle(Theme.Role.supporting)
                    if let value = Self.matchingValue(snapshot) {
                        Chip(text: value, tint: Theme.Role.information)
                    }
                }
            }
            .buttonStyle(FinancePressStyle())
            .accessibilityIdentifier(RouteID.planUpcoming)
        }
    }

    private func protectedMoney(_ snapshot: FinanceAppSnapshot) -> some View {
        NavigationLink(value: PlanRoute.goals) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                ActionLabel(title: "Goals & Set Aside")
                let totals = PlanningTotals.setAsideTotals(from: snapshot)
                if totals.isEmpty {
                    Text(Amount.zero(snapshot.currencyCode).formatted())
                        .font(Theme.TypeStyle.numeric).foregroundStyle(.primary)
                } else {
                    ForEach(totals) { total in
                        Text(total.amount.formatted())
                            .font(Theme.TypeStyle.numeric).foregroundStyle(.primary)
                    }
                }
                Text(Self.goalsDetail(snapshot))
                    .font(Theme.TypeStyle.supporting).foregroundStyle(Theme.Role.supporting)
            }
        }
        .buttonStyle(FinancePressStyle())
        .accessibilityIdentifier(RouteID.planGoals)
    }

    private func policyTile(_ snapshot: FinanceAppSnapshot, budget: Bool) -> some View {
        NavigationLink(value: budget ? PlanRoute.budget : PlanRoute.safetyReserve) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(budget ? "Budget" : "Safety reserve")
                    .font(Theme.TypeStyle.action).foregroundStyle(Theme.Role.accent)
                    .fixedSize(horizontal: false, vertical: true)
                if budget && !snapshot.everydayBudget.isEmpty {
                    MoneyText(amount: snapshot.everydayBudget.headlineAmount, size: 23)
                } else if !budget, let reserve = snapshot.safetyReserve {
                    MoneyText(amount: reserve, size: 23)
                } else {
                    Text("Not set").font(Theme.TypeStyle.numeric)
                }
                Text(budget ? Self.budgetDetail(snapshot) : Self.reserveDetail(snapshot))
                    .font(Theme.TypeStyle.metadata).foregroundStyle(Theme.Role.supporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.primary)
        }
        .buttonStyle(FinancePressStyle())
        .accessibilityIdentifier(budget ? RouteID.planBudget : RouteID.planReserve)
    }

    // MARK: - Status

    /// One condition and at most one route. Not a card stack: the tools below
    /// are the detail, and repeating their figures here would only invite a
    /// comparison between a budget ceiling, a policy floor and protected money
    /// that means nothing.
    @ViewBuilder
    private func planStatus(_ status: PlanStatusPresentation) -> some View {
        Group {
            if let action = status.action {
                Button { open(action.destination) } label: {
                    statusBody(status, actionTitle: action.title)
                }
                .buttonStyle(FinancePressStyle())
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier(RouteID.planStatus)
            } else {
                statusBody(status, actionTitle: nil)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(RouteID.planStatus)
            }
        }

    }

    private func statusBody(
        _ status: PlanStatusPresentation,
        actionTitle: String?
    ) -> some View {
        StatusSurface(tone: .plan(status.kind), filled: false) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(PlanStatusPresentation.eyebrow).font(.eyebrow)
                    .foregroundStyle(FinanceTone.plan(status.kind).color)
                Text(status.headline).font(Theme.TypeStyle.editorial)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = status.detail {
                    Text(detail).font(Theme.TypeStyle.supporting).foregroundStyle(Theme.Role.supporting)
                }
                if let actionTitle { ActionLabel(title: actionTitle) }
            }
        }
        .contentShape(Rectangle())
    }

    /// Plan routes to the screen that owns the answer, and never to a copy of
    /// it. Every case here is a destination the app already had.
    private func open(_ destination: AttentionDestination) {
        switch destination {
        case .planFundingNeeded: navigation.openPlan(.fundingNeeded)
        case .planUpcoming: navigation.openPlan(.upcoming)
        case .planSafetyReserve: navigation.openPlan(.safetyReserve)
        case .banksAndSync: navigation.showHome([.settings, .banks])
        case let .account(id): navigation.showHome([.accounts, .account(id)])
        case .observationReview, .expectedPayment, .activityToReview:
            navigation.openToReview()
        case let .insightsMonthVerification(selection):
            navigation.openInsightsVerification(selection)
        }
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

/// Known future cash and the definitions that produce it. Booked income stays
/// in Activity; this view only reads the existing planned/expected surfaces.
struct UpcomingView: View {
    @Environment(FinanceStore.self) private var store

    /// One live read per composition. "Coming up", the expected-payment
    /// caption and the risk attribution are all day-derived; they must
    /// describe the same civil day.
    var body: some View {
        let presentation = store.currentPresentation()
        return content(presentation.snapshot, status: presentation.attention.plan)
    }

    private func content(
        _ snapshot: FinanceAppSnapshot,
        status: PlanStatusPresentation
    ) -> some View {
        FinancePage {
            FinanceSection("Coming up") {
                if snapshot.upcomingEvents.isEmpty {
                    Text("Nothing scheduled.")
                        .foregroundStyle(Theme.Role.supporting)
                } else {
                    ForEach(snapshot.upcomingEvents.prefix(20)) { event in
                        // The status sends a person here to find out which
                        // payment it meant. Arriving at twenty identical rows
                        // answered nothing: the 480,00 € that broke the plan
                        // looked exactly like the 29,00 € that did not.
                        UpcomingRow(
                            event: event,
                            marksPlanRisk: event.id == status.triggerEventID
                        )
                    }
                }
            }

            FinanceSection("Expected") {
                NavigationLink {
                    ExpectedPaymentsView()
                } label: {
                    destinationRow("Expected payments", detail: Self.expectedDetail(snapshot))
                }
            }

            FinanceSection("Plan definitions") {
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
            ActionLabel(title: title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.Role.supporting)
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
        return FinancePage {
            FinanceSection {
                if snapshot.plannedPurchases.isEmpty {
                    Text(PlanningCopy.emptyGoals)
                        .foregroundStyle(Theme.Role.supporting)
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
                        .frame(minWidth: Theme.Metric.minimumTarget, minHeight: Theme.Metric.minimumTarget)
                        .accessibilityIdentifier(PlanningControlID.addGoal)
                }
            }

            FinanceSection {
                if standaloneFunds.isEmpty {
                    Text("Set-aside not tied to a goal appears here.")
                        .foregroundStyle(Theme.Role.supporting)
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
                        .frame(minWidth: Theme.Metric.minimumTarget, minHeight: Theme.Metric.minimumTarget)
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
        return FinancePage {
            if let goal {
                FinanceSection {
                    LabeledContent("Name", value: goal.name)
                    LabeledContent("Target") { MoneyText(amount: goal.target, size: 17, weight: .medium) }
                    LabeledContent("Status", value: goal.status.displayName)
                    LabeledContent("Funding", value: goal.fundingLabel)
                    if let date = goal.targetDate {
                        LabeledContent("Target date", value: date.formatted(date: .long, time: .omitted))
                    }
                }
                if let linkedFund {
                    FinanceSection("Set aside") {
                        NavigationLink {
                            SetAsideDetailView(fundID: linkedFund.id)
                        } label: {
                            FundPlanRow(fund: linkedFund)
                        }
                    }
                } else if goal.reserved.isPositive {
                    FinanceSection("Set aside") {
                        LabeledContent("Protected for this goal") {
                            MoneyText(amount: goal.reserved, size: 17, weight: .medium)
                        }
                    }
                }
                FinanceSection {
                    Button("Delete goal", role: .destructive) { confirmsDelete = true }
                        .buttonStyle(.bordered).controlSize(.large)
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
        FinancePage {
            if let fund {
                FinanceSection {
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
                FinanceSection {
                    Button("Delete set-aside", role: .destructive) { confirmsDelete = true }
                        .buttonStyle(.bordered).controlSize(.large)
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
