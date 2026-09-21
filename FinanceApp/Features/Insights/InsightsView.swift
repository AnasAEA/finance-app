import SwiftUI

/// The period review: what happened, what changed, and whether the answer can
/// be trusted.
///
/// Reads `InsightsPresentation` and nothing else. No engine type appears in
/// this file and no threshold is applied here — a card exists because
/// `ReviewEngine` returned a finding, not because this screen judged something
/// interesting.
struct InsightsView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(AppNavigation.self) private var navigation

    @State private var selection = LaunchOptions.current.insightsSelection
        ?? ReviewPeriodSelection()

    /// Bumped after a checkpoint write attempt, and read for nothing else.
    ///
    /// A checkpoint write reaches its own repository and mutates no observed
    /// property of `FinanceStore`, so nothing here would otherwise re-read.
    /// This exists so the review below is computed again; it answers no
    /// question about whether a month is verified, changed, ready or writable,
    /// and every such answer still comes from the store on the next read.
    @State private var refreshGeneration = 0

    var body: some View {
        // A period the store cannot review is reported as exactly that. The
        // screen never falls back to a clean or empty review of it, and never
        // moves to a different period it could have shown instead.
        Group {
            if let review = store.review(selection) {
                InsightsPeriodView(
                    review: review,
                    selection: $selection,
                    refreshGeneration: $refreshGeneration
                )
            } else {
                InsightsUnavailablePeriodView(selection: $selection)
            }
        }
        .navigationDestination(for: InsightsRoute.self) { route in
            switch route {
            case let .monthVerification(target):
                if let verification = store.endedMonthVerification(target)?.presentation {
                    PeriodVerificationDetailView(
                        verification: verification,
                        selection: target,
                        refreshGeneration: $refreshGeneration
                    )
                } else {
                    Text("This period cannot be reviewed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: navigation.insightsSelection, initial: true) { _, new in
            if let new { selection = new }
        }
    }
}

/// The reviewed period itself. Reads one `InsightsPresentation` and nothing
/// else — the store has already decided this period could be reviewed.
private struct InsightsPeriodView: View {
    @Environment(AppNavigation.self) private var navigation

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let review: InsightsPresentation
    @Binding var selection: ReviewPeriodSelection

    /// Passed through untouched. This screen neither reads nor changes it.
    @Binding var refreshGeneration: Int

    @State private var showsDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FinancePage {
            FinanceSection { header }
            verificationSection
            FinanceSection { summaryCard }
            FinanceSection {
                Text(review.recordsQualityStatement)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Records")
            }
            findingsSection
            if review.showsHistoricalHomePointer {
                FinanceSection {
                    Button("Today's outlook is on Home") {
                        navigation.selectedTab = .home
                    }
                }
            }
            FinanceSection {
                Button(showsDetails ? "Hide Details" : "Show Details") {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showsDetails.toggle() }
                }
                .font(Theme.TypeStyle.action)
                .frame(minHeight: Theme.Metric.minimumTarget)
                .accessibilityIdentifier(InsightsID.showDetails)
            }
            if showsDetails {
                coverageSection
                budgetSection
                spendingSection
                incomeSection
                expectationsSection
                goalsSection
                // Forward-looking risk belongs to the period being lived. A
                // past period never restates today's amount or date, behind a
                // disclosure or otherwise; its pointer to Home is the whole
                // answer.
                if !review.showsHistoricalHomePointer { outlookSection }
            }
        }
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Period", selection: $selection.scope) {
                ForEach(ReviewPeriodScope.allCases) { scope in
                    Text(scope.title)
                        .tag(scope)
                        .accessibilityIdentifier(InsightsID.scope(scope))
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier(RouteID.insightsScope)
            .onChange(of: selection.scope) { _, _ in selection.offset = 0 }

            if Theme.Layout.insightsStacksPeriodControls(dynamicTypeSize) {
                VStack(alignment: .leading, spacing: 10) {
                    periodTitle
                    HStack(spacing: 12) {
                        previousButton
                        nextButton
                    }
                }
            } else {
                HStack(spacing: 12) {
                    previousButton
                    periodTitle.frame(maxWidth: .infinity, alignment: .leading)
                    nextButton
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var periodTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(review.title).font(.headline)
            Text(review.rangeLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var previousButton: some View {
        Button {
            selection.offset -= 1
        } label: {
            Image(systemName: "chevron.left").frame(width: 28, height: 28)
        }
        .buttonStyle(.bordered)
        .disabled(!review.canGoBack)
        .accessibilityLabel("Previous period")
        .accessibilityIdentifier(RouteID.insightsPrevious)
    }

    private var nextButton: some View {
        Button {
            selection.offset += 1
        } label: {
            Image(systemName: "chevron.right").frame(width: 28, height: 28)
        }
        .buttonStyle(.bordered)
        .disabled(!review.canGoForward)
        .accessibilityLabel("Next period")
        .accessibilityIdentifier(RouteID.insightsNext)
    }

    // MARK: - Summary

    /// The identifier sits on the sentence, not on the card.
    ///
    /// SwiftUI hands an identifier applied to a plain container down to every
    /// accessibility element inside it, so `insights.summary` on this stack
    /// named the sentence, both eyebrows and both figures — five elements
    /// answering to one name. The figures stay separate elements, which is
    /// what a person hearing them wants, so the name belongs to the sentence
    /// that is actually the summary.
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(review.summary)
                .font(Theme.TypeStyle.screen)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(RouteID.insightsSummary)

            // Reflows into a column at accessibility sizes so a figure is
            // never truncated to fit beside another one.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    figure("Spent", review.spending)
                    figure("Came in", review.income)
                }
                VStack(alignment: .leading, spacing: 14) {
                    figure("Spent", review.spending)
                    figure("Came in", review.income)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func figure(_ label: String, _ value: ReviewFigure) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.eyebrow)
                .foregroundStyle(.secondary)
            switch value {
            case let .known(amount):
                MoneyText(amount: amount, size: 28)
            case .unavailable:
                // Not "€0". An unknown total and a zero total are different
                // answers and must never look the same.
                Text("Unavailable")
                    .font(.money(20, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Data quality

    private var coverageSection: some View {
        FinanceSection {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(review.coverage.quality.title)
                        .font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: coverageSymbol)
                        .foregroundStyle(coverageTint)
                }
                Text(review.coverage.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !review.coverage.missingRanges.isEmpty {
                    Text(missingRangeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(RouteID.insightsCoverage)
        } header: {
            Text("Data quality")
        }
    }

    private var coverageSymbol: String {
        switch review.coverage.quality {
        case .complete: "checkmark.seal"
        case .partial: "exclamationmark.triangle"
        case .insufficient: "questionmark.circle"
        }
    }

    private var coverageTint: Color {
        switch review.coverage.quality {
        case .complete: Theme.Role.positive
        case .partial: Theme.Role.caution
        case .insufficient: .secondary
        }
    }

    private var missingRangeText: String {
        let ranges = review.coverage.missingRanges.map { range in
            range.lowerBound == range.upperBound
                ? dayText(range.lowerBound)
                : "\(dayText(range.lowerBound))–\(dayText(range.upperBound))"
        }
        return "Missing: " + ranges.joined(separator: ", ")
    }

    // MARK: - Budget

    @ViewBuilder private var budgetSection: some View {
        if !review.monthContexts.isEmpty {
            FinanceSection {
                ForEach(review.monthContexts) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(context.monthLabel).font(.subheadline.weight(.semibold))
                            Spacer()
                            // A spend figure is shown only when the days
                            // behind it are accounted for. Printing 0,00 €
                            // here would say "you spent nothing" when the
                            // honest answer is that nobody knows yet.
                            if review.zeroMeansZero {
                                MoneyText(amount: context.periodSpendingInMonth, size: 17)
                            }
                        }
                        if !review.zeroMeansZero {
                            Text(unavailableMonthStatus(context))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let ceiling = context.ceiling {
                            Text(monthStatus(context, ceiling: ceiling))
                                .font(.footnote)
                                .foregroundStyle(context.overage.map(\.isPositive) == true
                                    ? Theme.Role.negative : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("No monthly budget set.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text(review.monthContexts.count > 1 ? "Budget · months touched" : "Budget")
            } footer: {
                if review.monthContexts.count > 1 {
                    // The engine never prorates a monthly ceiling into a weekly
                    // one, and neither does this screen.
                    Text("A week that crosses a month end is shown against each "
                         + "month's own budget, not a share of one.")
                }
            }
        }
    }

    /// The month's ceiling is a plan, so it is still worth stating; what is
    /// spent against it is not knowable while records are incomplete.
    private func unavailableMonthStatus(_ context: ReviewMonthContext) -> String {
        guard let ceiling = context.ceiling else {
            return "No monthly budget set."
        }
        return "\(ceiling.formatted()) budgeted · spending not available "
            + "while records are incomplete"
    }

    private func monthStatus(_ context: ReviewMonthContext, ceiling: Amount) -> String {
        let month = "\(context.monthSpending.formatted()) of \(ceiling.formatted()) this month"
        if let overage = context.overage, overage.isPositive {
            return month + " · \(overage.formatted()) over"
        }
        if let remaining = context.remaining {
            return month + " · \(remaining.formatted()) left"
        }
        return month
    }

    // MARK: - Spending

    @ViewBuilder private var spendingSection: some View {
        FinanceSection {
            if !review.topCategories.isEmpty {
                ForEach(review.topCategories) { category in
                    LabeledContent {
                        MoneyText(amount: category.amount, size: 17)
                    } label: {
                        Text(category.name)
                    }
                }
            } else {
                Text(review.zeroMeansZero
                     ? "No spending recorded."
                     : "Spending breakdown unavailable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(review.exceptional) { purchase in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(purchase.label)
                        Spacer()
                        MoneyText(amount: purchase.amount, size: 17)
                    }
                    Text("One-off · \(dayText(purchase.day))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Where it went")
        }
    }

    // MARK: - Income and support

    private var incomeSection: some View {
        FinanceSection {
            let income = review.incomeBreakdown
            if !income.earnedOrOther.isZero {
                row("Earned and other", income.earnedOrOther)
            }
            if !income.supportOwned.isZero {
                row("Support", income.supportOwned)
                if income.supportHasOnwardShare {
                    Text("\(income.supportGross.formatted()) arrived; "
                         + "\(income.passThroughNotMine.formatted()) of it was passed on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !income.reimbursements.isZero {
                row("Reimbursements", income.reimbursements)
            }
            if !income.otherPersonal.isZero {
                row("Other income", income.otherPersonal)
            }
            if !income.unresolved.isZero {
                VStack(alignment: .leading, spacing: 2) {
                    row("Unresolved", income.unresolved)
                    Text("Money arrived that the evidence does not yet explain. "
                         + "It is not counted as income.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if isIncomeEmpty {
                Text(review.zeroMeansZero
                     ? "No income recorded."
                     : "Income unavailable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Income and support")
        } footer: {
            if !review.incomeBreakdown.passThroughNotMine.isZero {
                Text("Money held for somebody else is not income and is not "
                     + "part of the total.")
            }
        }
    }

    private var isIncomeEmpty: Bool { review.incomeBreakdown.isEmpty }

    // MARK: - Expected vs actual

    @ViewBuilder private var expectationsSection: some View {
        if !review.expectations.isEmpty {
            FinanceSection {
                ForEach(review.expectations) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(item.name)
                            Spacer()
                            MoneyText(amount: item.actual ?? item.expected, size: 17)
                        }
                        Text(expectationText(item))
                            .font(.caption)
                            .foregroundStyle(item.state == .missed ? Theme.Role.caution : .secondary)
                    }
                }
            } header: {
                Text("Expected and actual")
            }
        }
    }

    private func expectationText(_ item: ReviewExpectationRow) -> String {
        switch item.state {
        case .matched: "Settled · due \(dayText(item.day))"
        case .missed: "Not seen · was due \(dayText(item.day))"
        case .expected: "Due \(dayText(item.day))"
        case .skipped: "Skipped · was due \(dayText(item.day))"
        case .noLongerDue: "No longer due"
        }
    }

    // MARK: - Goals

    @ViewBuilder private var goalsSection: some View {
        if !review.goals.currentlySetAside.isZero || !review.goals.active.isEmpty {
            FinanceSection {
                row("Set aside now", review.goals.currentlySetAside)
                ForEach(review.goals.active) { goal in
                    LabeledContent {
                        MoneyText(amount: goal.reserved, size: 17)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(goal.name)
                            if let day = goal.targetDay {
                                Text("Target \(goal.target.formatted()) by \(dayText(day))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Goals and set aside")
            } footer: {
                Text("Shown for context. Reviewing does not change reservations.")
            }
        }
    }

    // MARK: - What changed

    @ViewBuilder
    private var findingsSection: some View {
        if !review.findings.isEmpty {
            FinanceSection {
                ForEach(review.findings) { finding in findingRow(finding) }
            } header: {
                Text("What changed")
            } footer: {
                if case let .unavailable(reason) = review.comparison {
                    Text(reason)
                }
            }
        }
    }

    @ViewBuilder
    private var verificationSection: some View {
        if let verification = review.verification {
            FinanceSection {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        VerificationHeading(state: verification.verificationState, title: verification.verificationState.headline)
                            .accessibilityIdentifier(InsightsID.verification)
                        if let summary = verification.changeSummary {
                            VerificationChangeExplanation(summary: summary)
                                .accessibilityIdentifier(InsightsID.verificationChange)
                        }
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                                Text("\(verification.decisionCount) decision\(verification.decisionCount == 1 ? "" : "s") waiting")
                                Text("\(verification.limitationCount) limitation\(verification.limitationCount == 1 ? "" : "s")")
                            }
                            .font(Theme.TypeStyle.supporting)
                            .fixedSize(horizontal: false, vertical: true)
                        } else {
                            HStack(spacing: Theme.Space.md) {
                                Text("\(verification.decisionCount) decision\(verification.decisionCount == 1 ? "" : "s")")
                                Text("·").accessibilityHidden(true)
                                Text("\(verification.limitationCount) limitation\(verification.limitationCount == 1 ? "" : "s")")
                            }
                            .font(Theme.TypeStyle.supporting).foregroundStyle(.secondary)
                        }
                        Text(verification.totalsStatement)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        NavigationLink {
                            PeriodVerificationDetailView(
                                verification: verification,
                                selection: selection,
                                refreshGeneration: $refreshGeneration
                            )
                        } label: {
                            ActionLabel(title: verification.verificationState == .verified ? "View verification" : "What's unresolved")
                        }
                        .buttonStyle(FinancePressStyle())
                        .accessibilityIdentifier(InsightsID.unresolved)
                    }
                    .padding(.vertical, 3)
                }
            } header: {
                Text("\(verification.periodLabel) · Verification")
            }
        }
    }

    private func findingRow(_ finding: ReviewFindingCard) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label {
                Text(finding.title).font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: toneSymbol(finding.tone))
                    .foregroundStyle(toneTint(finding.tone))
            }
            Text(finding.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func toneSymbol(_ tone: ReviewFindingTone) -> String {
        switch tone {
        case .important: "exclamationmark.circle"
        case .warning: "exclamationmark.triangle"
        case .info: "info.circle"
        }
    }

    private func toneTint(_ tone: ReviewFindingTone) -> Color {
        switch tone {
        case .important: Theme.Role.negative
        case .warning: Theme.Role.caution
        case .info: .secondary
        }
    }

    // MARK: - Outlook

    private var outlookSection: some View {
        FinanceSection {
            row("Available now", review.outlook.liquidityNow)
            if let day = review.outlook.firstRiskDay {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Runs short")
                        Spacer()
                        if let shortfall = review.outlook.shortfall {
                            MoneyText(amount: shortfall, size: 17)
                        }
                    }
                    Text(riskText(day))
                        .font(.caption)
                        .foregroundStyle(Theme.Role.negative)
                }
            } else if let floor = review.outlook.floorWarningDay {
                Text("Dips below your safety floor on \(dayText(floor)).")
                    .font(.footnote)
                    .foregroundStyle(Theme.Role.caution)
            } else {
                Text("Nothing scheduled puts cash at risk before \(dayText(review.outlook.horizonEnd)).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // Forward-looking engine findings belong here, not under What
            // changed, and appear in exactly one of the two.
            ForEach(review.forwardFindings) { finding in findingRow(finding) }
            ForEach(review.outlook.upcoming) { item in
                LabeledContent {
                    MoneyText(amount: item.amount, size: 17)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                        Text(dayText(item.day)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Current outlook")
        } footer: {
            // Says plainly that this is forward-looking, so nobody reads it as
            // the balance at the end of the reviewed period.
            Text("Looking forward from \(dayText(review.outlook.asOfDay)), not a "
                 + "balance for the period above.")
        }
    }

    private func riskText(_ day: CalendarDay) -> String {
        guard let label = review.outlook.firstRiskLabel else { return dayText(day) }
        return "\(label) · \(dayText(day))"
    }

    // MARK: - Shared

    private func row(_ label: String, _ amount: Amount) -> some View {
        LabeledContent {
            MoneyText(amount: amount, size: 17)
        } label: {
            Text(label)
        }
    }

    private func dayText(_ day: CalendarDay) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return "\(day.day) \(months[max(0, min(11, day.month - 1))])"
    }
}

/// The explanation behind an ended month's verification, the one place a person
/// may explicitly accept a limitation it carries, and the one place a month is
/// verified.
///
/// Three kinds of action live here and they are kept apart on purpose. A
/// *Decision* row navigates to the underlying transaction or expected payment,
/// where the real issue can be worked on; opening one decides nothing about
/// the checkpoint. An *acceptance* is a statement about the checkpoint itself,
/// made by ticking rows and then pressing the acceptance action; it is held in
/// memory and stores nothing. *Verifying* is the durability moment, and the
/// only one: it is the sole action here that reaches a store. None of the three
/// stands in for another — in particular, accepting never verifies, and
/// verifying never accepts what was only ticked.
private struct PeriodVerificationDetailView: View {
    @Environment(FinanceStore.self) private var store

    /// The preview the previous screen already computed. It is what this screen
    /// shows if the period can no longer be re-evaluated from here.
    let verification: PeriodVerificationPresentation
    let selection: ReviewPeriodSelection

    /// Bumped once after every verify attempt so this screen and the one behind
    /// it read the stored checkpoint again. It carries no answer of its own.
    @Binding var refreshGeneration: Int

    /// Live acknowledgment state, created with this screen and discarded with
    /// it. Leaving and coming back is a month with nothing decided again.
    @State private var acknowledgment = EndedMonthAcknowledgmentModel()

    /// The message from the last failed verify attempt, and nothing else. A
    /// successful attempt sets no state here: it is visible because the stored
    /// truth this screen re-reads has changed.
    @State private var failure: String?

    var body: some View {
        // Read so that a completed verify attempt re-enters here. A checkpoint
        // write changes nothing this view observes, so without this the screen
        // would keep showing the reading it was built with.
        let _ = refreshGeneration
        // Re-evaluated on every read, carrying whatever has been explicitly
        // accepted so far. Every verdict below is the evaluator's; nothing on
        // this screen works one out for itself.
        let screen = acknowledgment.screen(for: selection, in: store)
        let shown = screen?.verification ?? verification

        FinancePage {
            verificationStatusSection(shown, readiness: screen?.readinessState)

            FinanceSection {
                Text(shown.totalsStatement)
                    .fixedSize(horizontal: false, vertical: true)
                if let statement = shown.categoryStatement {
                    Text(statement).fixedSize(horizontal: false, vertical: true)
                }
                if let statement = shown.auditStatement {
                    Text(statement).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("What the figures can say")
            }

            if let section = screen?.acknowledgment {
                acknowledgmentSection(section)
            }

            if !shown.decisions.isEmpty {
                FinanceSection("Decisions") {
                    ForEach(shown.decisions) { issue in
                        if let destination = issue.destination {
                            NavigationLink {
                                destinationView(destination)
                            } label: {
                                issueRow(issue)
                            }
                        }
                    }
                }
            }

            if !shown.limitations.isEmpty {
                FinanceSection {
                    ForEach(shown.limitations) { issue in
                        issueRow(issue)
                            .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Known Limitations")
                } footer: {
                    Text("Nothing to decide here.")
                }
            }
        }
        .navigationTitle("What's unresolved")
        .navigationBarTitleDisplayMode(.inline)
        // A decision is about one month. Pointing this screen at another one
        // starts over rather than offering the first month's subjects as
        // authority for the second.
        .onChange(of: selection) { _, _ in acknowledgment.reset() }
        .alert("Couldn\u{2019}t verify", isPresented: Binding(
            get: { failure != nil },
            set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }

    // MARK: - Verifying the month

    /// Where the month stands, and the action that changes it.
    ///
    /// The headline is the same value the row behind this screen renders, read
    /// from the same fresh presentation, so the two can never disagree. This
    /// screen states no verification of its own and holds no flag that would
    /// let it.
    @ViewBuilder
    private func verificationStatusSection(
        _ shown: PeriodVerificationPresentation,
        readiness: EndedMonthAcknowledgmentReadinessState?
    ) -> some View {
        FinanceSection {
            VerificationHeading(state: shown.verificationState, title: shown.verificationState.headline)
                .sensoryFeedback(trigger: shown.verificationState) { previous, current in
                    current == .verified && previous != .verified ? .success : nil
                }
            if let summary = shown.changeSummary {
                VerificationChangeExplanation(summary: summary)
            }
            if offersVerification(shown) {
                Button("Verify month") { verifyMonth() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canVerify(readiness))
                    .accessibilityIdentifier(InsightsID.verify)
            }
        } header: {
            Text("\(shown.periodLabel) \u{00B7} Verification")
        } footer: {
            Text("Verifying records this month as checked, with whatever is "
                 + "accepted above. It changes no amount, date or total.")
        }
    }

    /// The explicit action, and the only thing on this screen that stores
    /// anything.
    ///
    /// Synchronous on purpose. The writer's guarantee is that readiness, the
    /// chain tip, classification and the store all land in one turn, so there
    /// is no suspension point to put a spinner around and nothing for a second
    /// tap to interleave with.
    private func verifyMonth() {
        switch EndedMonthCheckpointAction.perform(
            for: selection,
            confirming: acknowledgment.confirmedAcknowledgments,
            in: store
        ) {
        case .written:
            // Deliberately nothing. Success is the stored reading changing
            // below, which the fresh read this bump forces will show. Holding
            // it here would be a second, unaccountable answer.
            break
        case let .failed(message):
            failure = message
        }
        // Both outcomes. A refusal is usually the month having moved, and that
        // is exactly when the screen most needs to say what it carries now.
        refreshGeneration += 1
    }

    /// Whether an action could be offered at all, from the stored reading.
    ///
    /// A hint, not permission: the writer decides at tap time. Verified months
    /// are already current, and a month whose history cannot be read or
    /// compared cannot be written by this build either, so neither is offered
    /// an action that would only fail.
    private func offersVerification(_ shown: PeriodVerificationPresentation) -> Bool {
        switch shown.verificationState {
        case .notVerified, .changedSinceVerification: true
        case .verified, .unavailable: false
        }
    }

    /// Whether the offered action can be taken, from the evaluator's answer.
    ///
    /// Nil readiness means the month can no longer be evaluated from here, so
    /// there is no answer to act on. Blocked and undecided both fail closed —
    /// and blocked is why this reads the readiness rather than whether an
    /// acknowledgment section exists, because a blocked month carrying no
    /// exception has no section either.
    private func canVerify(_ readiness: EndedMonthAcknowledgmentReadinessState?) -> Bool {
        switch readiness {
        case .nothingToDecide, .readyWithAcknowledgments: true
        case .needsDecisions, .blocked, nil: false
        }
    }

    // MARK: - Accepting a limitation

    private func acknowledgmentSection(
        _ section: EndedMonthAcknowledgmentSection
    ) -> some View {
        FinanceSection {
            Text(section.statement)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(InsightsID.acknowledgmentState)

            ForEach(section.rows) { row in acknowledgmentRow(row) }

            if acknowledgment.lastConfirmationWasRefused {
                Text("Nothing was accepted: what was chosen no longer matches what this "
                     + "month is carrying. The list above is up to date.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Role.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The authority event. Ticking rows above reaches the checkpoint in
            // no way at all; this does, and only when pressed.
            Button("Accept selected") {
                acknowledgment.confirmSelection(for: selection, in: store)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .disabled(!acknowledgment.hasSelection || !section.allowsConfirmation)
            .accessibilityIdentifier(InsightsID.acknowledge)
        } header: {
            Text("Limitations to accept")
        } footer: {
            Text("Accepting says you have seen a limitation and accept it for this check. "
                 + "It changes no amount, date or total, and nothing is kept — these "
                 + "decisions last only while this screen is open.")
        }
    }

    private func acknowledgmentRow(_ row: EndedMonthAcknowledgmentRow) -> some View {
        Button {
            acknowledgment.toggle(row)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: rowSymbol(row))
                    .foregroundStyle(row.isAcknowledged ? Theme.Role.positive : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.title).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        if let amount = row.amount {
                            MoneyText(amount: amount, size: 16, showsSign: true)
                        }
                    }
                    Text(row.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(row.isAcknowledged)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isAcknowledged ? [.isSelected] : [])
    }

    private func rowSymbol(_ row: EndedMonthAcknowledgmentRow) -> String {
        if row.isAcknowledged { return "checkmark.circle.fill" }
        return acknowledgment.isSelected(row) ? "circle.inset.filled" : "circle"
    }

    // MARK: - Shared

    private func issueRow(_ issue: PeriodVerificationIssue) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(issue.title).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if let amount = issue.amount {
                    MoneyText(amount: amount, size: 16, showsSign: true)
                }
            }
            Text(issue.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func destinationView(_ destination: PeriodVerificationDestination) -> some View {
        switch destination {
        case let .observationReview(id):
            ObservationReviewView(observationID: id)
        case let .expectedPayment(payment):
            ExpectedPaymentDetailView(payment: payment)
        }
    }
}

/// The sentences the mapper already decided. The view does not classify
/// change, occupancy or financial meaning; it only renders them.
private struct VerificationChangeExplanation: View {
    let summary: VerificationChangeSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(summary.statements.enumerated()), id: \.offset) { _, statement in
                Text(statement)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Shown when the selected period cannot be reviewed at all — its dates lie
/// outside the range the day engine can express.
///
/// It states that and offers the way back. It shows no totals, no coverage
/// verdict and no findings, because none were computed: an empty review of a
/// period would claim nothing happened in it.
private struct InsightsUnavailablePeriodView: View {
    @Binding var selection: ReviewPeriodSelection

    var body: some View {
        FinancePage {
            FinanceSection {
                Picker("Period", selection: $selection.scope) {
                    ForEach(ReviewPeriodScope.allCases) { scope in
                        Text(scope.title)
                            .tag(scope)
                            .accessibilityIdentifier(InsightsID.scope(scope))
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(RouteID.insightsScope)
                .onChange(of: selection.scope) { _, _ in selection.offset = 0 }
            }
            FinanceSection {
                Text("This period cannot be reviewed. Its dates fall outside the range this app can calculate.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Go to the current period") { selection.offset = 0 }
                    .accessibilityIdentifier(RouteID.insightsNext)
                    .disabled(selection.offset == 0)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.bottom, Theme.Metric.floatingTabBarClearance, for: .scrollContent)
        .navigationTitle("Insights")
        .navigationBarTitleDisplayMode(.inline)
    }
}
