import SwiftUI

/// The first screen, answering four questions before anything is scrolled:
/// what can I safely use, why is that number constrained, what needs my
/// attention, and what happens next.
///
/// Everything else it used to show — the holdings list, the runway chart, the
/// month card — moved to the destination that owns it. Home summarises and
/// hands over; it does not keep a second copy of Budget, Accounts or Upcoming.
///
/// Reads `FinanceAppSnapshot` and nothing else. No engine type appears in this
/// file, which is why swapping the engine underneath does not touch it.
struct HomeView: View {
    @Environment(FinanceStore.self) private var store
    @Environment(AppNavigation.self) private var navigation

    var body: some View {
        let presentation = store.currentPresentation()
        return Group {
            if store.storeIsUnreadable {
                // Not an empty store: the rows exist and are the only copy of
                // themselves. Onboarding here would offer to replace them.
                setUpScreen { UnreadableStoreView() }
            } else if store.isEmpty {
                setUpScreen { OnboardingView() }
            } else if presentation.snapshot.accounts.isEmpty && !presentation.projectionFailed {
                setUpScreen { FirstAccountCard() }
            } else {
                HomeDashboard(snapshot: presentation.snapshot, attention: presentation.attention, freshness: presentation.freshness)
            }
        }
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    navigation.openHome(.settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier(RouteID.homeSettings)
            }
        }
    }

    private func setUpScreen<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: Theme.Metric.stackSpacing) { content() }
                .padding(.horizontal, Theme.Metric.screenPadding)
                .padding(.bottom, 24)
        }
        .background(Theme.Surface.background)
    }

}

private struct HomeDashboard: View {
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let snapshot: FinanceAppSnapshot
    let attention: AttentionPresentation
    let freshness: BankFreshnessEvaluation

    var body: some View {
        FinancePage(spacing: Theme.Space.lg) {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                if attention.heroIsAvailable { safeToUse(attention) }
                cashSection(freshness)
            }
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                attentionAnswer(attention)
            }
            FinanceSection {
                weekAhead(attention)
                Divider()
                nextSevenDays(attention)
            } header: {
                HStack {
                    Text("Next 7 days").font(Theme.TypeStyle.section)
                    Spacer()
                    Button("View all") { navigation.openPlan(.upcoming) }
                        .font(Theme.TypeStyle.action)
                        .foregroundStyle(Theme.Role.accent)
                        .frame(minHeight: Theme.Metric.minimumTarget)
                        .accessibilityIdentifier(RouteID.homeUpcomingAll)
                }
            }
        }
    }

    // MARK: - Safe to use

    /// The primary answer. When a forecast shortfall is what holds it at zero,
    /// the zero stays and the shortfall is said underneath it: those are two
    /// different facts, and replacing the first with the second would answer a
    /// question nobody asked.
    ///
    /// Tapping it asks the second question — why that figure — which is a
    /// drill-down rather than a card, because a person who already trusts the
    /// number should not have to read its arithmetic every morning.
    private func safeToUse(_ attention: AttentionPresentation) -> some View {
        Button {
            navigation.openHome(.safeToUse)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Safe to use")
                        .font(Theme.TypeStyle.section)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                MoneyText(amount: snapshot.safeToSpend, size: Theme.TypeStyle.heroSize, weight: .bold)
                if !primaryFundingCardIsShowing(attention) {
                    Text(snapshot.safeToSpendReason.explanation)
                        .font(Theme.TypeStyle.supporting)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(FinancePressStyle())
        // The identifier belongs to the combined element, not to the figure
        // inside it: a name on a child of a combined element is inherited by
        // the combination as well, and `home.safe` resolved to two elements.
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows how this amount is worked out")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(RouteID.homeSafeToUse)
    }

    private func primaryFundingCardIsShowing(_ attention: AttentionPresentation) -> Bool {
        guard case let .act(card, _) = attention.home else { return false }
        return card.destination == .planFundingNeeded
    }

    // MARK: - Cash and freshness

    /// Cash is supporting, not a competing headline: labelled, tappable, and
    /// carrying the answer to "is this current?" as a caption rather than a
    /// permanent sync widget.
    ///
    /// Set-aside money is deliberately absent. `safeToSpend` does not yet
    /// subtract planning reservations, so printing both here would imply it
    /// did. It lives on Plan → Goals & Set Aside until that is decided.
    @ViewBuilder
    private func cashSection(_ freshness: BankFreshnessEvaluation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Button {
                navigation.openHome(.accounts)
            } label: {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Space.sm))
                    : AnyLayout(HStackLayout(spacing: Theme.Space.sm))
                layout {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cash").font(.subheadline.weight(.medium))
                        Text("Accounts").font(.caption).foregroundStyle(.secondary)
                    }
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Theme.Space.sm) }
                    MoneyText(amount: snapshot.accountCash, size: 20, weight: .semibold)
                    if !dynamicTypeSize.isAccessibilitySize {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Cash, \(snapshot.accountCash.accessibleDescription()), accounts")
                .accessibilityAddTraits(.isButton)
            }
            .buttonStyle(FinancePressStyle())
            .padding(.vertical, Theme.Space.sm)
            .accessibilityIdentifier(RouteID.homeCash)

            if let caption = freshness.caption {
                Text(caption).font(Theme.TypeStyle.metadata).foregroundStyle(.secondary)
                    .accessibilityIdentifier(RouteID.homeSync)
            }
        }
    }

    // MARK: - Attention

    @ViewBuilder
    private func attentionAnswer(_ attention: AttentionPresentation) -> some View {
        switch attention.home {
        case let .act(card, reviewCount):
            Button { open(card.destination) } label: {
                StatusSurface(tone: attentionTone(card)) {
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        Text(attentionLabel(card)).font(.eyebrow).foregroundStyle(attentionTone(card).color)
                        Text(card.title).font(Theme.TypeStyle.card).fixedSize(horizontal: false, vertical: true)
                        if let detail = card.detail {
                            Text(detail).font(Theme.TypeStyle.supporting).foregroundStyle(.secondary)
                        }
                        ActionLabel(title: card.actionTitle)
                    }
                }
            }
            .buttonStyle(FinancePressStyle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(RouteID.homeAttention)
            if reviewCount > 0 { reviewSummary(reviewCount) }

        case let .reviewOnly(reviewCount):
            VStack(alignment: .leading, spacing: 8) {
                Label("Nothing urgent.", systemImage: "checkmark.circle").font(Theme.TypeStyle.card)
                    .foregroundStyle(Theme.Role.positive)
                if reviewCount > 0 { reviewSummary(reviewCount) }
            }
            .accessibilityIdentifier(RouteID.homeAttention)

        case let .quiet(detail):
            VStack(alignment: .leading, spacing: 5) {
                Label("Nothing needs you right now.", systemImage: "checkmark.circle").font(Theme.TypeStyle.card)
                    .foregroundStyle(Theme.Role.positive)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(RouteID.homeAttention)

        case let .indeterminate(uncertainty):
            if let destination = uncertainty.destination {
                Button { open(destination) } label: { uncertaintyRow(uncertainty.message, tappable: true) }
                    .buttonStyle(FinancePressStyle())
                    .accessibilityIdentifier(RouteID.homeAttention)
            } else {
                uncertaintyRow(uncertainty.message, tappable: false)
                    .accessibilityIdentifier(RouteID.homeAttention)
            }
        }
    }

    private func attentionTone(_ card: HomeAttentionCard) -> FinanceTone {
        switch card.destination {
        case .planFundingNeeded: .deficit
        case .planUpcoming, .planSafetyReserve: .plan(attention.plan.kind)
        case .banksAndSync, .account: .information
        case .insightsMonthVerification: .information
        case .observationReview, .expectedPayment, .activityToReview: .caution
        }
    }

    private func attentionLabel(_ card: HomeAttentionCard) -> String {
        switch card.destination {
        case .banksAndSync: "CONNECTION"
        case .account: "BALANCE CHECK"
        case .insightsMonthVerification: "MONTH REVIEW"
        case .planFundingNeeded: "FUNDING NEEDED"
        case .planUpcoming, .planSafetyReserve:
            attention.plan.kind == .reserveWarning ? "RESERVE WARNING" : "NEEDS ACTION"
        default: "TO REVIEW"
        }
    }

    private func reviewSummary(_ count: Int) -> some View {
        Button { navigation.openToReview() } label: {
            HStack {
                Text("\(count) thing\(count == 1 ? "" : "s") to review")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Theme.Metric.minimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(FinancePressStyle())
        .accessibilityIdentifier(RouteID.homeReview)
    }

    private func uncertaintyRow(_ message: String, tappable: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if tappable {
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func open(_ destination: AttentionDestination) {
        switch destination {
        case .planFundingNeeded:
            navigation.openPlan(.fundingNeeded)
        case .planUpcoming:
            navigation.openPlan(.upcoming)
        case .planSafetyReserve:
            navigation.openPlan(.safetyReserve)
        case .banksAndSync:
            navigation.showHome([.settings, .banks])
        case let .account(id):
            navigation.showHome([.accounts, .account(id)])
        case .observationReview, .expectedPayment, .activityToReview:
            navigation.openToReview()
        case let .insightsMonthVerification(selection):
            navigation.openInsightsVerification(selection)
        }
    }

    // MARK: - Next 7 days

    /// What the week does to the money, above the list of what happens in it.
    ///
    /// Projected *cash* — the pool at each day's close — and deliberately not
    /// a second Safe to Use: the headline answers what can be used now, this
    /// answers where the balance goes if the plan happens. Neither is derived
    /// from the other and the two are not expected to reconcile.
    ///
    /// Absent whenever the projection cannot support the claim. A week with no
    /// projected points produces no minimum rather than a zero.
    @ViewBuilder
    private func weekAhead(_ attention: AttentionPresentation) -> some View {
        if let week = WeekAheadSummary.make(from: snapshot, isAvailable: attention.heroIsAvailable) {
            VStack(alignment: .leading, spacing: 6) {
                LedgerRow(
                    label: WeekAheadSummary.title,
                    value: week.low,
                    caption: week.dayText,
                    emphasis: true,
                    // Calm unless the pool is actually projected below zero.
                    // A balance that merely falls is not a warning.
                    valueTint: week.low.isNegative ? Theme.Role.negative : nil
                )
                ForEach(week.notes, id: \.self) { note in
                    Text(note.sentence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(RouteID.homeWeekLow)
        }
    }

    @ViewBuilder
    private func nextSevenDays(_ attention: AttentionPresentation) -> some View {
        let events = PlanningTotals.nextSevenDays(
            from: snapshot,
            limit: PlanningTotals.homeUpcomingLimit(hasShortfall: primaryFundingCardIsShowing(attention)),
            excludingEventID: attention.summarizedUpcomingEventID
        )
        if events.isEmpty {
            if let end = PlanningTotals.sevenDayWindowEnd(from: snapshot) {
                Text("Nothing scheduled through \(end.formatted(.dateTime.day().month(.abbreviated))).")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("The upcoming date range is unavailable.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } else {
            ForEach(events) { event in
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                        eventLabel(event)
                        Spacer(minLength: Theme.Space.sm)
                        MoneyText(amount: event.amount, size: 17, weight: .medium, showsSign: true)
                    }
                    VStack(alignment: .leading, spacing: Theme.Space.sm) {
                        eventLabel(event)
                        MoneyText(amount: event.amount, size: 19, weight: .medium, showsSign: true)
                    }
                }
                .padding(.vertical, Theme.Space.xs)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(RouteID.homeWeekEvent(event.id))
            }
        }
    }
    private func eventLabel(_ event: PlannedEvent) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(event.label).font(Theme.TypeStyle.supporting.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(event.date.formatted(.dateTime.day().month(.abbreviated)))
                .font(Theme.TypeStyle.metadata).foregroundStyle(.secondary)
        }
    }

}

private struct FirstAccountCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "building.columns.circle")
                .font(.system(size: 38))
                .foregroundStyle(Theme.Role.accent)
            Text("Add your first account")
                .font(.title2.bold())
            Text("Accounts show where money is held. Start with a bank, wallet, or cash balance as of a date.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            NavigationLink {
                AccountEditorView()
            } label: {
                Label("Add account", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .financeCard()
        .padding(.top, 8)
    }
}

#Preview {
    NavigationStack { HomeView() }
        .environment(FinanceStore.preview())
        .environment(AppNavigation())
}
