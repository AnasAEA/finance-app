import Foundation
import SwiftUI
import Testing
@testable import FinanceApp

@MainActor
@Suite("Production information architecture")
struct ProductionIATests {
    @Test("Production exposes exactly Home, Activity, Plan and Insights")
    func canonicalTabs() {
        #expect(AppTab.allCases == [.home, .activity, .plan, .insights])
        #expect(AppTab.allCases.map(\.rawValue) == ["home", "activity", "plan", "insights"])
    }

    @Test("Activity has transactions and a separate evidence review surface")
    func activitySections() {
        #expect(ActivitySection.allCases == [.transactions, .toReview])
        #expect(ActivitySection.allCases.map(\.title) == ["Transactions", "To Review"])
    }

    @Test("Cross-tab navigation changes location without changing money")
    func navigationHasNoEconomicSideEffects() {
        let store = FinanceStore.preview()
        let before = store.snapshot
        let navigation = AppNavigation()

        navigation.openPlan(.budget)
        #expect(navigation.selectedTab == .plan)
        #expect(navigation.planPath.count == 1)

        navigation.openToReview()
        #expect(navigation.selectedTab == .activity)
        #expect(navigation.activitySection == .toReview)

        navigation.showHome([.settings, .automation])
        #expect(navigation.selectedTab == .home)
        #expect(navigation.homePath.count == 2)
        #expect(store.snapshot == before)
        #expect(store.snapshot.safeToSpend == before.safeToSpend)
    }

    @Test("Home upcoming density follows the approved shortfall rule")
    func homeUpcomingDensity() {
        #expect(PlanningTotals.homeUpcomingLimit(hasShortfall: true) == 2)
        #expect(PlanningTotals.homeUpcomingLimit(hasShortfall: false) == 3)
    }

    @Test("Home list keeps extra scroll room under the floating tab bar")
    func homeClearsFloatingTabBar() {
        #expect(Theme.Metric.floatingTabBarClearance >= 24)
    }

    @Test("Activity composes actionable and current-pending evidence independently")
    func activityReviewSections() {
        let needsReview = observation(id: "needs-review", resolution: .unreviewed, status: .booked)
        let currentZeroA = observation(
            id: "pending-current",
            amount: .eur(0),
            resolution: .provisional,
            status: .pending
        )
        let currentZeroB = observation(
            id: "pending-zero",
            amount: .eur(0),
            resolution: .provisional,
            status: .pending
        )
        let currentZeroC = observation(
            id: "pending-third",
            amount: .eur(0),
            resolution: .provisional,
            status: .pending
        )
        let historical = observation(
            id: "pending-stale",
            resolution: .provisional,
            status: .pending
        )

        let observedInstant = Date(timeIntervalSince1970: 1_777_680_000)
        var neither = FinanceAppSnapshot.empty(asOf: CalendarDay(year: 2026, month: 5, day: 2))
        #expect(ActivityReviewSections(snapshot: neither).isEmpty)

        neither.syncedObservations = [needsReview]
        var sections = ActivityReviewSections(snapshot: neither)
        #expect(sections.needsReview.map(\.id) == ["needs-review"])
        #expect(sections.pending.isEmpty)

        var pendingOnly = FinanceAppSnapshot.empty(asOf: neither.asOf)
        pendingOnly.syncedObservations = [currentZeroA, currentZeroB, currentZeroC, historical]
        pendingOnly.currentPendingProviderSnapshots = [
            CurrentPendingProviderSnapshot(
                id: "bnp",
                providerName: "BNP",
                authoritativeAt: observedInstant,
                observationIDs: ["pending-current", "pending-zero", "pending-third"]
            )
        ]
        sections = ActivityReviewSections(snapshot: pendingOnly)
        #expect(sections.needsReview.isEmpty)
        #expect(Set(sections.pending.map(\.id)) == [
            "pending-current", "pending-zero", "pending-third",
        ])
        #expect(sections.pending.allSatisfy { $0.amount.isZero })
        #expect(!sections.isEmpty)
        #expect(!sections.pending.contains { $0.id == "pending-stale" })
        #expect(PendingObservationPresentation.sectionExplanation
            == "No action needed · Waiting for your bank to complete these payments.")
        #expect(PendingObservationPresentation.rowStatus == "Pending")
        #expect(!PendingObservationPresentation.showsAmountSign(.eur(0)))
        #expect(PendingObservationPresentation.showsAmountSign(.eur(-3.99)))

        pendingOnly.syncedObservations.append(needsReview)
        sections = ActivityReviewSections(snapshot: pendingOnly)
        #expect(sections.needsReview.map(\.id) == ["needs-review"])
        #expect(Set(sections.pending.map(\.id)) == [
            "pending-current", "pending-zero", "pending-third",
        ])

        // Home remains actionable-only and the transaction/search source is
        // still the canonical economic activity collection.
        #expect(PlanningTotals.reviewCount(from: pendingOnly) == 1)
        #expect(pendingOnly.activity.flatMap(\.rows).isEmpty)
    }

    @Test("Plan hub stacks the trailing figure at accessibility sizes")
    func planHubStacksAtAccessibilitySize() {
        #expect(Theme.Layout.planHubStacksValueBelowTitle(.medium) == false)
        #expect(Theme.Layout.planHubStacksValueBelowTitle(.xxxLarge) == false)
        #expect(Theme.Layout.planHubStacksValueBelowTitle(.accessibility1))
        #expect(Theme.Layout.planHubStacksValueBelowTitle(.accessibility3))
        #expect(Theme.Layout.planHubStacksValueBelowTitle(.accessibility5))
    }

    @Test("Healthy sync is quiet and precise")
    func healthyFreshness() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let synced = now.addingTimeInterval(-12 * 60)
        let result = BankFreshness.evaluate(
            connections: [connection(state: .connected, lastSync: synced)],
            activity: .idle,
            pairing: .paired,
            reference: now
        )
        #expect(result == .updated(synced))
        #expect(result.requiresAction == false)
        #expect(result.caption(relativeTo: now) == "Last sync 12 min ago")
        #expect(BankFreshness.evaluate(
            connections: [connection(state: .connected, lastSync: now)],
            activity: .idle, pairing: .paired, reference: now
        ).caption(relativeTo: now) == "Synced just now")
    }

    @Test("Healthy freshness is the oldest successful provider stamp, not a local HTTP clock")
    func freshnessUsesOldestProviderStamp() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let oldest = now.addingTimeInterval(-45 * 60)
        let newest = now.addingTimeInterval(-60)
        let result = BankFreshness.evaluate(
            connections: [
                connection(id: "bnp", state: .connected, lastSync: oldest),
                connection(id: "paypal", state: .connected, lastSync: newest),
            ],
            activity: .succeeded(at: now),
            pairing: .paired,
            reference: now
        )
        #expect(result == .updated(oldest))
        #expect(result.caption(relativeTo: now) == "Last sync 45 min ago")
    }

    @Test("A connection that has never completed a provider fetch is not healthy")
    func missingProviderStampIsNeverSynced() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        #expect(BankFreshness.evaluate(
            connections: [
                connection(id: "bnp", state: .connected, lastSync: now),
                connection(id: "paypal", state: .connected, lastSync: nil),
            ],
            activity: .succeeded(at: now),
            pairing: .paired,
            reference: now
        ) == .neverSynced)
    }

    @Test("Stale, failed, revoked and expiring connections need attention")
    func actionableFreshness() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let stale = now.addingTimeInterval(-(BankFreshness.staleAfter + 60))

        let staleResult = BankFreshness.evaluate(
            connections: [connection(state: .connected, lastSync: stale)],
            activity: .idle,
            pairing: .paired,
            reference: now
        )
        #expect(staleResult == .stale(stale))
        #expect(staleResult.requiresAction)
        #expect(staleResult.caption(relativeTo: now) == "Last sync 2 days ago · check sync")

        #expect(BankFreshness.evaluate(
            connections: [connection(state: .connected, lastSync: now)],
            activity: .failed("sanitized"), pairing: .paired, reference: now
        ) == .needsAttention)
        #expect(BankFreshness.evaluate(
            connections: [], activity: .idle, pairing: .revoked, reference: now
        ) == .needsAttention)
        #expect(BankFreshness.evaluate(
            connections: [connection(state: .expiringSoon, lastSync: now)],
            activity: .idle, pairing: .paired, reference: now
        ) == .needsAttention)
        #expect(BankFreshness.evaluate(
            connections: [connection(state: .connected, lastSync: now, error: "sanitized")],
            activity: .idle, pairing: .paired, reference: now
        ) == .needsAttention)
    }

    @Test("Manual use is not a sync fault, but a paired device with no sync is actionable")
    func noConnectionVersusNeverSynced() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let manual = BankFreshness.evaluate(
            connections: [], activity: .idle, pairing: .notConfigured, reference: now
        )
        #expect(manual == .notConnected)
        #expect(manual.requiresAction == false)
        #expect(manual.caption(relativeTo: now) == nil)

        let pending = BankFreshness.evaluate(
            connections: [], activity: .idle, pairing: .paired, reference: now
        )
        #expect(pending == .neverSynced)
        #expect(pending.requiresAction)
        #expect(pending.caption(relativeTo: now) == "Not synced yet")
    }

    @Test("Relaunch freshness uses persisted provider success, not balance observation time")
    func relaunchFreshnessUsesProviderSuccess() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let oldest = now.addingTimeInterval(-30 * 60)
        var snapshot = FinanceAppSnapshot.empty(asOf: CalendarDay(year: 1970, month: 1, day: 24))
        snapshot.providerAccountBindings = [
            binding(id: "bnp", provider: "BNP"),
            binding(id: "paypal", provider: "PayPal"),
        ]
        snapshot.providerBalanceStatuses = [providerBalance(observedAt: now)]
        snapshot.currentPendingProviderSnapshots = [
            CurrentPendingProviderSnapshot(
                id: "bnp", providerName: "BNP", authoritativeAt: oldest,
                observationIDs: []
            ),
            CurrentPendingProviderSnapshot(
                id: "paypal", providerName: "PayPal",
                authoritativeAt: now.addingTimeInterval(-5 * 60), observationIDs: []
            ),
        ]

        let result = BankFreshness.evaluate(
            snapshot: snapshot,
            activity: .idle,
            pairing: .paired,
            reference: now
        )
        #expect(result == .updated(oldest))
        #expect(result.caption(relativeTo: now) == "Last sync 30 min ago")
        #expect(result.caption(relativeTo: now) != "Not synced yet")
    }

    @Test("A provider balance alone never fabricates freshness")
    func balanceDoesNotFabricateFreshness() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var snapshot = FinanceAppSnapshot.empty(asOf: CalendarDay(year: 1970, month: 1, day: 24))
        snapshot.providerAccountBindings = [binding(id: "bnp", provider: "BNP")]
        snapshot.providerBalanceStatuses = [providerBalance(observedAt: now)]

        #expect(BankFreshness.evaluate(
            snapshot: snapshot,
            activity: .succeeded(at: now),
            pairing: .paired,
            reference: now
        ) == .neverSynced)
    }

    @Test("A missing successful timestamp for one relevant provider stays never synced")
    func missingRelevantProviderSuccess() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var snapshot = FinanceAppSnapshot.empty(asOf: CalendarDay(year: 1970, month: 1, day: 24))
        snapshot.providerAccountBindings = [
            binding(id: "bnp", provider: "BNP"),
            binding(id: "paypal", provider: "PayPal"),
        ]
        snapshot.currentPendingProviderSnapshots = [
            CurrentPendingProviderSnapshot(
                id: "bnp", providerName: "BNP", authoritativeAt: now,
                observationIDs: []
            ),
        ]

        #expect(BankFreshness.evaluate(
            snapshot: snapshot,
            activity: .idle,
            pairing: .paired,
            reference: now
        ) == .neverSynced)
    }

    private func connection(
        id: String = "synthetic-connection",
        providerName: String = "Synthetic provider",
        state: ProviderConnectionState,
        lastSync: Date?,
        error: String? = nil
    ) -> ProviderConnectionStatus {
        ProviderConnectionStatus(
            id: id,
            providerName: providerName,
            institution: nil,
            state: state,
            consentExpires: nil,
            lastSyncedAt: lastSync,
            lastErrorMessage: error
        )
    }

    private func binding(id: String, provider: String) -> ProviderAccountBinding {
        ProviderAccountBinding(
            id: id,
            providerName: provider,
            localAccountID: "account-\(id)",
            localAccountName: "Account",
            syncStartBoundary: CalendarDay(year: 2026, month: 1, day: 1),
            isActive: true
        )
    }

    private func providerBalance(observedAt: Date) -> ProviderBalanceStatus {
        ProviderBalanceStatus(
            id: "provider-balance",
            providerName: "BNP",
            accountName: "Account",
            balanceType: "CLBD",
            ledgerBalance: .eur(10),
            providerBalance: .eur(10),
            difference: .eur(0),
            referenceDate: CalendarDay(year: 2026, month: 1, day: 1),
            observedAt: observedAt
        )
    }
    private func observation(
        id: String,
        amount: Amount = .eur(-5),
        resolution: SyncedObservationResolution,
        status: SyncedObservationStatus
    ) -> SyncedObservationItem {
        SyncedObservationItem(
            id: id,
            providerName: "Synthetic Bank",
            providerAccountName: "Current account",
            isAccountBindingActive: true,
            amount: amount,
            status: status,
            resolution: resolution,
            displayMerchant: "Bank activity",
            observedMerchant: nil,
            rawMerchantText: nil,
            remittance: nil,
            merchantEmail: nil,
            bankTransactionCode: nil,
            dates: ObservationDates(
                booking: CalendarDay(year: 2026, month: 8, day: 31),
                transaction: nil,
                value: nil,
                derivedTransaction: nil,
                derivedProvenanceLabel: nil,
                economicPeriod: CalendarDay(year: 2026, month: 8, day: 31)
            ),
            observedAt: Date(timeIntervalSince1970: 1_777_680_000),
            suggestions: [],
            duplicateConflict: nil,
            hasProviderStatusWarning: false
        )
    }
}
