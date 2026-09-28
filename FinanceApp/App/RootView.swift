import SwiftUI

/// Four tabs, because four questions are asked: what have I got, what
/// happened, what is coming, and how did the period actually go. Everything
/// else is a destination inside one of them.
///
/// Insights is a tab now because it finally contains something: the period
/// review engine is wired to it. It was deliberately withheld while it would
/// have been empty, since an empty tab only teaches a person to ignore it.
enum AppTab: String, Hashable, CaseIterable {
    case home, activity, plan, insights
}

/// The two halves of Activity: what happened, and what the bank sent that
/// nobody has judged yet.
enum ActivitySection: String, Hashable, CaseIterable, Identifiable {
    case transactions, toReview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transactions: "Transactions"
        case .toReview: "To Review"
        }
    }
}

/// Destinations pushed from Home. Settings is one of them — a gear, not a tab,
/// because configuring the app is not a daily question.
enum HomeRoute: Hashable {
    /// Why the headline is the figure it is. A drill-down, never a card: the
    /// person asks for it by tapping the number they are already looking at.
    case safeToUse
    case accounts
    case account(String)
    case settings
    case banks
    case automation
    case data
    case appSettings
}

/// Destinations pushed from the Plan hub.
enum PlanRoute: Hashable {
    case fundingNeeded
    case budget
    case safetyReserve
    case upcoming
    case goals
    case affordability
}

/// Destinations pushed onto Insights. The verification detail is the same
/// screen Insights already owns; this is only how Home asks to open it.
enum InsightsRoute: Hashable {
    case monthVerification(ReviewPeriodSelection)
}

/// Accessibility identifiers for the primary routes.
///
/// Named in one place so a navigation test asserts the route a person can
/// reach rather than the words currently printed on it.
enum RouteID {
    /// The four primary tabs, addressed by the question each one answers
    /// rather than by the word or the SF Symbol currently printed on it.
    ///
    /// Without an explicit identifier a tab has no identity of its own, and an
    /// automation synthesises one: usually the label ("Home"), which collides
    /// with the navigation title of the same name a screen away, and sometimes
    /// the icon ("house.fill"), which changes the moment the symbol does. A
    /// physical audit measured both spellings on the same tab bar.
    static func tab(_ tab: AppTab) -> String { "tab.\(tab.rawValue)" }

    static let homeSafeToUse = "home.safe"
    static let homeAttention = "home.attention"
    static let homeShortfall = "home.shortfall"
    static let homeCash = "home.cash"
    static let homeSync = "home.sync"
    static let homeBudget = "home.budget"
    static let homeUpcoming = "home.upcoming"
    static let homeReview = "home.review"
    static let homeUpcomingAll = "home.upcoming.all"
    /// Hyphenated, not `home.week.low`: `homeWeekEvent` owns the
    /// `home.week.<id>` space, and a row that could collide with an event id
    /// is a row an automation can address by accident.
    static let homeWeekLow = "home.week-low"
    static func homeWeekEvent(_ id: String) -> String { "home.week.\(id)" }
    static let homeSettings = "home.settings"

    static let activitySection = "activity.section"
    static let activityAdd = "activity.add"
    static let activityFilters = "activity.filters"
    static let activityReviewQueue = "activity.review.queue"
    static let activityArchive = "activity.archive"

    /// The Plan hub's one status block, whatever condition it is reporting.
    /// A test addresses the state, not the sentence currently printed on it.
    static let planStatus = "plan.status"
    static let planBudget = "plan.budget"
    static let planFundingNeeded = "plan.funding-needed"
    static let planReserve = "plan.reserve"
    static let planUpcoming = "plan.upcoming"
    static let planGoals = "plan.goals"
    static let planAfford = PlanningControlID.openAffordability

    static let insightsScope = "insights.scope"
    static let insightsPrevious = "insights.previous"
    static let insightsNext = "insights.next"
    static let insightsSummary = "insights.summary"
    static let insightsCoverage = "insights.coverage"

    static let accountsList = "accounts.list"
    static func account(_ id: String) -> String { "account.\(id)" }

    static let settingsBanks = "settings.banks"
    static let settingsAutomation = "settings.automation"
    static let settingsData = "settings.data"
    static let settingsApp = "settings.app"
}

enum VisualValidationScreen: String {
    case accountCreation, incomeSources, onboarding, importCurrentState
    case budgetEditor, historyArchiveImport
    /// The bank screens address rows of the synthetic Bank Inbox state by id.
    /// Those ids are fixture identity, so they are compiled out of Release
    /// along with the fixture itself rather than left as string literals in
    /// the shipped binary.
    #if DEBUG
    case bankInbox, bankReview, bankRecurring, bankAmbiguous, bankATM, bankResolved, bankBalance
    case bankSyncPairing, bankSyncConnected, bankSyncMapping
    case bankSyncSyncing, bankSyncSucceeded, bankSyncFailed
    /// Banks & Sync on a build that *does* have a service address, with this
    /// device not yet paired. Distinct from `bankSyncPairing`, which is the
    /// code sheet on its own: the state worth pinning is that this screen
    /// still offers a way to pair, which the not-configured state must not.
    case bankSyncUnpaired
    #endif
}

/// Where the person is, and the only way for one screen to send them somewhere
/// owned by another.
///
/// Home's "To review" row and the Plan hub both need to hand navigation to a
/// destination they do not own. Holding the tab, the Activity segment and both
/// navigation paths here keeps that a single assignment instead of a chain of
/// bindings — and keeps deep state alive across a tab switch, because the paths
/// outlive the views.
@Observable
@MainActor
final class AppNavigation {
    var selectedTab: AppTab
    var activitySection: ActivitySection = .transactions
    /// Exact actionable bank observations named by an Insight. Nil restores
    /// the normal complete review queue.
    var activityReviewIDs: Set<String>?
    var homePath = NavigationPath()
    var planPath = NavigationPath()
    var insightsPath = NavigationPath()
    /// When Home (or a launch argument) asks Insights to show a period, that
    /// selection is applied once the tab is visible. Nil means Insights keeps
    /// the period the person last chose.
    var insightsSelection: ReviewPeriodSelection?
    /// Add lives in the Activity toolbar; the sheet itself is presented once, at
    /// the root, so it survives a tab switch underneath it.
    var isAddingTransaction = false

    init(selectedTab: AppTab = .home) {
        self.selectedTab = selectedTab
    }

    func openPlan(_ route: PlanRoute) {
        selectedTab = .plan
        var next = NavigationPath()
        next.append(route)
        planPath = next
    }

    func openHome(_ route: HomeRoute) {
        selectedTab = .home
        homePath.append(route)
    }

    /// Replaces the Home path rather than appending, so a deep link cannot
    /// stack two copies of Settings.
    func showHome(_ routes: [HomeRoute]) {
        selectedTab = .home
        var next = NavigationPath()
        for route in routes { next.append(route) }
        homePath = next
    }

    func openToReview() {
        activityReviewIDs = nil
        activitySection = .toReview
        selectedTab = .activity
    }

    func openReviewItems(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        activityReviewIDs = Set(ids)
        activitySection = .toReview
        selectedTab = .activity
    }

    /// Switch to Insights on the given month and push the canonical
    /// verification detail. Replaces any Insights path so a second Home tap
    /// cannot stack two copies of the same month.
    func openInsightsVerification(_ selection: ReviewPeriodSelection) {
        selectedTab = .insights
        insightsSelection = selection
        var next = NavigationPath()
        next.append(InsightsRoute.monthVerification(selection))
        insightsPath = next
    }

    static func make(from launch: LaunchOptions) -> AppNavigation {
        let navigation = AppNavigation(selectedTab: launch.startTab ?? .home)
        if let section = launch.startSection { navigation.activitySection = section }
        navigation.isAddingTransaction = launch.opensAddSheet
        switch launch.startRoute {
        // Funding Needed is only reached by acting on Home's attention card,
        // which is the right product shape and a poor automation entry: which
        // card is primary depends on the day. The launch route opens the same
        // screen deterministically, and navigates only.
        case "fundingNeeded": navigation.openPlan(.fundingNeeded)
        case "budget": navigation.openPlan(.budget)
        case "reserve": navigation.openPlan(.safetyReserve)
        case "upcoming": navigation.openPlan(.upcoming)
        case "goals": navigation.openPlan(.goals)
        case "affordability": navigation.openPlan(.affordability)
        case "safeToUse": navigation.showHome([.safeToUse])
        case "accounts": navigation.showHome([.accounts])
        case "settings": navigation.showHome([.settings])
        case "banks": navigation.showHome([.settings, .banks])
        case "automation": navigation.showHome([.settings, .automation])
        case "data": navigation.showHome([.settings, .data])
        default: break
        }
        return navigation
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(FinanceStore.self) private var store
    @State private var navigation: AppNavigation

    init() {
        _navigation = State(initialValue: AppNavigation.make(from: LaunchOptions.current))
    }

    var body: some View {
        @Bindable var navigation = navigation
        return Group {
            switch LaunchOptions.current.visualValidationScreen {
            case .accountCreation:
                NavigationStack { AccountEditorView() }
            case .incomeSources:
                NavigationStack { IncomeSourcesView() }
            case .onboarding:
                NavigationStack {
                    ScrollView { OnboardingView().padding(Theme.Metric.screenPadding) }
                        .background(Theme.Surface.background)
                }
            case .importCurrentState:
                ImportCurrentStateView()
            case .budgetEditor:
                BudgetEditView()
            case .historyArchiveImport:
                ImportHistoricalArchiveView()
            #if DEBUG
            case .bankInbox:
                NavigationStack { BankInboxView() }
            case .bankReview:
                NavigationStack { ObservationReviewView(observationID: "obs-bank-merchant") }
            case .bankRecurring:
                NavigationStack { ObservationReviewView(observationID: "obs-streaming") }
            case .bankAmbiguous:
                NavigationStack { ObservationReviewView(observationID: "obs-paypal-unresolved") }
            case .bankATM:
                NavigationStack { ObservationReviewView(observationID: "obs-atm") }
            case .bankResolved:
                NavigationStack { ObservationReviewView(observationID: "obs-resolved") }
            case .bankBalance:
                NavigationStack { ProviderBalanceDetailView(balanceID: "balance-bank-clbd") }
            case .bankSyncPairing:
                NavigationStack { PairDeviceSheet() }
            case .bankSyncConnected, .bankSyncSyncing, .bankSyncSucceeded, .bankSyncFailed,
                 .bankSyncUnpaired:
                NavigationStack { BankSyncView() }
            case .bankSyncMapping:
                NavigationStack {
                    MapAccountSheet(
                        remote: MappableRemoteAccount(
                            id: "acct_neobank_mad", providerName: "Revolut",
                            displayName: "Neobank MAD", currencyCode: "MAD",
                            mappedLocalAccountID: nil, mappedLocalAccountName: nil,
                            syncStartBoundary: nil
                        )
                    )
                }
            #endif
            case nil:
                tabContent
            }
        }
        .tint(Theme.Role.accent)
        .environment(navigation)
        .sheet(isPresented: $navigation.isAddingTransaction) {
            AddTransactionSheet()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active,
                  !ProcessInfo.processInfo.arguments.contains("-disableForegroundSync"),
                  LaunchOptions.current.visualValidationScreen == nil,
                  !LaunchOptions.current.usesHCIPrototype,
                  !LaunchOptions.current.usesBankInboxPreview,
                  !LaunchOptions.current.usesDailyUsePreview,
                  !LaunchOptions.current.usesPlanningPreview,
                  !LaunchOptions.current.usesEmptyPreview,
                  !LaunchOptions.current.usesDevelopmentFixture,
                  store.pairingState == .paired else { return }
            // Cron may already have fresh evidence. Foreground reads that
            // snapshot without asking the banks to run again.
            await store.refreshFromService()
            guard !Task.isCancelled else { return }
            await store.resumeSyncIfNeeded()
        }
    }

    private var tabContent: some View {
        @Bindable var navigation = navigation
        return TabView(selection: $navigation.selectedTab) {
            NavigationStack(path: $navigation.homePath) {
                HomeView()
                    .navigationDestination(for: HomeRoute.self) { route in
                        HomeRouteDestination(route: route)
                    }
            }
            .tabItem {
                Label("Home", systemImage: "house.fill")
                    .accessibilityIdentifier(RouteID.tab(.home))
            }
            .tag(AppTab.home)

            NavigationStack {
                ActivityView()
            }
            .tabItem {
                Label("Activity", systemImage: "list.bullet")
                    .accessibilityIdentifier(RouteID.tab(.activity))
            }
            .tag(AppTab.activity)

            NavigationStack(path: $navigation.planPath) {
                PlanView()
                    .navigationDestination(for: PlanRoute.self) { route in
                        PlanRouteDestination(route: route)
                    }
            }
            .tabItem {
                Label("Plan", systemImage: "calendar")
                    .accessibilityIdentifier(RouteID.tab(.plan))
            }
            .tag(AppTab.plan)

            NavigationStack(path: $navigation.insightsPath) {
                InsightsView()
            }
            // A record being examined, not a dashboard chart: the tab set is
            // literal nouns (house, list, calendar) and this keeps that.
            .tabItem {
                Label("Insights", systemImage: "doc.text.magnifyingglass")
                    .accessibilityIdentifier(RouteID.tab(.insights))
            }
            .tag(AppTab.insights)
        }
        // Both halves are load-bearing, and each was measured on the phone.
        //
        // The identifier on a `.tabItem` label does not reach the bar on its
        // own — the buttons stay anonymous. But SwiftUI does eventually push
        // *something* from that label onto the `UITabBarItem`, and with no
        // identifier declared what it pushes is the SF Symbol's name: drop
        // these four modifiers and the bar reverts to `house.fill`,
        // `list.bullet`, `calendar`, overwriting whatever was there.
        //
        // `TabBarIdentity` names the items directly, which is what makes them
        // addressable at all and what covers the window before SwiftUI gets
        // there. The two agree on the value, so whichever writes last is right.
        .background { TabBarIdentity().frame(width: 0, height: 0) }
    }
}

/// Home's pushed destinations. Financial browsing and configuration both hang
/// off Home, and stay separate screens: Accounts is where money is, Banks &
/// Sync is where connections are managed.
struct HomeRouteDestination: View {
    let route: HomeRoute

    var body: some View {
        switch route {
        case .safeToUse:
            SafeToUseExplanationView()
        case .accounts:
            AccountsView()
        case .account(let id):
            AccountDetailView(accountID: id)
        case .settings:
            SettingsView()
        case .banks:
            BankSyncView()
        case .automation:
            AutomationView()
        case .data:
            DataAndBackupView()
        case .appSettings:
            AppSettingsView()
        }
    }
}

/// The Plan hub's destinations. Each one is a push, including the
/// affordability check: it collects input, explains itself and returns a
/// verdict, which is a task, not a glance.
struct PlanRouteDestination: View {
    let route: PlanRoute

    var body: some View {
        switch route {
        case .fundingNeeded:
            FundingNeededView()
        case .budget:
            BudgetDetailView()
        case .safetyReserve:
            SafetyReserveView()
        case .upcoming:
            UpcomingView()
        case .goals:
            GoalsAndSetAsideView()
        case .affordability:
            AffordabilityCheckView()
        }
    }
}

/// Launch arguments, for driving the app into a known state from a script.
///
/// Used by the screenshot pass and by UI tests. It reads arguments only — there
/// is no way to reach these from the running app.
struct LaunchOptions {
    var startTab: AppTab?
    var startSection: ActivitySection?
    /// Named route to open at launch. Raw string rather than an enum because
    /// the same argument reaches both Home and Plan destinations.
    var startRoute: String
    var opensAddSheet: Bool
    var usesDevelopmentFixture: Bool
    var usesDailyUsePreview: Bool
    var usesPlanningPreview: Bool
    var usesEmptyPreview: Bool
    var usesBankInboxPreview: Bool
    var usesHCIPrototype: Bool
    var hciPrototypeVariant: String
    var initialEntryKind: TransactionDraft.Kind?
    var visualValidationScreen: VisualValidationScreen?
    /// Opens Insights on a given period, so the screenshot pass can address a
    /// cross-month week or an older period without simulating taps.
    var insightsSelection: ReviewPeriodSelection?

    static var current: LaunchOptions {
        let arguments = ProcessInfo.processInfo.arguments
        var options = LaunchOptions(
            startTab: nil,
            startSection: nil,
            startRoute: "",
            opensAddSheet: arguments.contains("-openAddSheet"),
            usesDevelopmentFixture: arguments.contains("-useDevelopmentFixture"),
            usesDailyUsePreview: arguments.contains("-useDailyUsePreview"),
            usesPlanningPreview: arguments.contains("-usePlanningPreview"),
            usesEmptyPreview: arguments.contains("-useEmptyPreview"),
            usesBankInboxPreview: arguments.contains("-useBankInboxPreview"),
            usesHCIPrototype: arguments.contains("-HCIPrototype"),
            hciPrototypeVariant: "full",
            initialEntryKind: nil,
            visualValidationScreen: nil,
            insightsSelection: nil
        )
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }
        if let variant = value("-HCIPrototypeVariant") { options.hciPrototypeVariant = variant }
        // The prototype's arguments keep working and mean the same thing: the
        // Debug shell now mounts the production screens, so the deep links have
        // to arrive in the same place.
        if let tab = value("-startTab") ?? value("-HCIPrototypeTab") {
            options.startTab = AppTab(rawValue: tab)
        }
        if let section = value("-startSection") ?? value("-HCIPrototypeSection") {
            options.startSection = ActivitySection(rawValue: section)
        }
        if let route = value("-startRoute") ?? value("-HCIPrototypeRoute") {
            options.startRoute = route
        }
        if let scope = value("-insightsScope").flatMap(ReviewPeriodScope.init(rawValue:)) {
            options.insightsSelection = ReviewPeriodSelection(
                scope: scope,
                offset: value("-insightsOffset").flatMap(Int.init) ?? 0
            )
        }
        if let kind = value("-entryKind") {
            options.initialEntryKind = TransactionDraft.Kind(rawValue: kind)
        }
        if let screen = value("-visualScreen") {
            options.visualValidationScreen = VisualValidationScreen(rawValue: screen)
        }
        return options
    }
}

#Preview {
    RootView().environment(FinanceStore.preview())
}
