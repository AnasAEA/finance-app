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
        .navigationBarTitleDisplayMode(.large)
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
    let snapshot: FinanceAppSnapshot
    let attention: AttentionPresentation
    let freshness: BankFreshnessEvaluation

    var body: some View {
        return List {
            if attention.heroIsAvailable {
                Section { safeToUse(attention) }
            }
            Section { attentionAnswer(attention) }
            cashSection(freshness)
            Section {
                nextSevenDays(attention)
            } header: {
                HStack {
                    Text("Next 7 days")
                    Spacer()
                    Button("View all") { navigation.openPlan(.upcoming) }
                        .font(.caption)
                        .textCase(.none)
                        .accessibilityIdentifier(RouteID.homeUpcomingAll)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.bottom, Theme.Metric.floatingTabBarClearance, for: .scrollContent)
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
                    Text("SAFE TO USE")
                        .font(.eyebrow)
                        .foregroundStyle(snapshot.safeToSpendReason.isShortfall ? Theme.Role.negative : .secondary)
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                MoneyText(amount: snapshot.safeToSpend, size: 34, weight: .bold)
                if !primaryFundingCardIsShowing(attention) {
                    Text(snapshot.safeToSpendReason.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        Section {
            Button {
                navigation.openHome(.accounts)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cash").font(.subheadline.weight(.medium))
                        Text("Accounts").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    MoneyText(amount: snapshot.accountCash, size: 20, weight: .semibold)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Cash, \(snapshot.accountCash.accessibleDescription()), accounts")
                .accessibilityAddTraits(.isButton)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(RouteID.homeCash)

        } footer: {
            if let caption = freshness.caption {
                Text(caption).accessibilityIdentifier(RouteID.homeSync)
            }
        }
    }

    // MARK: - Attention

    @ViewBuilder
    private func attentionAnswer(_ attention: AttentionPresentation) -> some View {
        switch attention.home {
        case let .act(card, reviewCount):
            Button { open(card.destination) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text("NEEDS ACTION").font(.eyebrow)
                    Text(card.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    if let detail = card.detail {
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(card.actionTitle).font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(card.isTinted ? Theme.Role.caution.opacity(0.12) : Color.clear)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(RouteID.homeAttention)
            if reviewCount > 0 { reviewSummary(reviewCount) }

        case let .reviewOnly(reviewCount):
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing urgent.").font(.headline)
                if reviewCount > 0 { reviewSummary(reviewCount) }
            }
            .accessibilityIdentifier(RouteID.homeAttention)

        case let .quiet(detail):
            VStack(alignment: .leading, spacing: 5) {
                Text("Nothing needs you right now.").font(.headline)
                if let detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(RouteID.homeAttention)

        case let .indeterminate(uncertainty):
            if let destination = uncertainty.destination {
                Button { open(destination) } label: { uncertaintyRow(uncertainty.message, tappable: true) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(RouteID.homeAttention)
            } else {
                uncertaintyRow(uncertainty.message, tappable: false)
                    .accessibilityIdentifier(RouteID.homeAttention)
            }
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                HStack {
                    Text(event.date.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    Text(event.label)
                        .font(.subheadline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    MoneyText(amount: event.amount, size: 15, weight: .medium,
                              showsSign: true, colorBySign: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(RouteID.homeWeekEvent(event.id))
            }
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
