import Foundation
import Testing
@testable import FinanceApp

/// The identifier and copy contract a physical accessibility audit depends on.
///
/// A tab with no identifier of its own is named by the platform — sometimes
/// after its label, sometimes after its SF Symbol — and a row with no
/// identifier is named after everything it says. Both were measured on the
/// paired iPhone. These tests pin the vocabulary that replaced them.
@MainActor
@Suite("Device accessibility hygiene")
struct DeviceAccessibilityHygieneTests {

    // MARK: - Tabs

    @Test("Each primary tab has one explicit, stable identifier")
    func tabIdentifiers() {
        #expect(RouteID.tab(.home) == "tab.home")
        #expect(RouteID.tab(.activity) == "tab.activity")
        #expect(RouteID.tab(.plan) == "tab.plan")
        #expect(RouteID.tab(.insights) == "tab.insights")

        let identifiers = AppTab.allCases.map(RouteID.tab)
        #expect(identifiers.count == 4)
        #expect(Set(identifiers).count == 4)
        // Never the label and never the symbol: those are the two spellings the
        // canary saw the platform invent, and one of them collides with the
        // navigation title of the same name.
        #expect(!identifiers.contains("Home"))
        #expect(!identifiers.contains("house.fill"))
        #expect(identifiers.allSatisfy { $0.hasPrefix("tab.") })
    }

    // MARK: - Funding Needed

    @Test("Funding Needed names semantic roles, and only roles")
    func fundingIdentifiers() {
        #expect(FundingID.all == [
            "funding.trigger", "funding.date", "funding.due", "funding.covered",
            "funding.still-needed", "funding.payment-account", "funding.explanation",
        ])
        #expect(Set(FundingID.all).count == FundingID.all.count)
        // A role, not a reading of the role. No amount, day, account name or
        // masked fragment may be spelled into an identifier.
        for identifier in FundingID.all {
            #expect(identifier.allSatisfy { $0.isLowercase || $0 == "." || $0 == "-" })
        }
    }

    // MARK: - Insights

    @Test("Insights controls that a navigation must reach are named")
    func insightsIdentifiers() {
        #expect(InsightsID.scope(.week) == "insights.scope.week")
        #expect(InsightsID.scope(.month) == "insights.scope.month")
        #expect(InsightsID.showDetails == "insights.show-details")
        #expect(InsightsID.verification == "insights.verification")
        #expect(InsightsID.unresolved == "insights.unresolved")
        #expect(InsightsID.acknowledge == "insights.acknowledge")
        #expect(InsightsID.acknowledgmentState == "insights.acknowledgment-state")
        // The period controls already existed and keep their names.
        #expect(RouteID.insightsScope == "insights.scope")
        #expect(RouteID.insightsPrevious == "insights.previous")
        #expect(RouteID.insightsNext == "insights.next")
    }

    // MARK: - Activity row identity

    @Test("A row's identity is derived, never borrowed from what it says")
    func activityRowIdentityCarriesNoContent() {
        // The *shapes* the physical audit measured, invented here rather than
        // copied: a row named after everything it says, a pending row named
        // after a sync run and a provider account, a backend observation
        // handle, and a plan reference with a date. No real value from the
        // phone belongs in a repository.
        let leaky = [
            "Synthetic Merchant, Other · Synthetic bank account (masked 0000), 1 Jan 2026, -€1,23",
            "pend_run_00000000000000000000000000000000_acct_11111111111111111111111111111111_0",
            "obs_22222222222222222222222222222222",
            "ob-synthetic-plan@2026-01-01",
        ]
        let builders: [(String) -> String] = [
            ActivityID.decision, ActivityID.payment, ActivityID.pending,
            ActivityID.limitation, ActivityID.transaction,
        ]

        for identity in leaky {
            for build in builders {
                let identifier = build(identity)
                let prefix = ActivityID.rowPrefixes.first { identifier.hasPrefix($0) }
                #expect(prefix != nil)
                let token = String(identifier.dropFirst(prefix?.count ?? 0))
                #expect(token.count == 16)
                #expect(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
                // Nothing of the identity survives into the identifier.
                #expect(!identifier.contains(identity))
                #expect(!identifier.contains("€"))
                #expect(!identifier.contains("masked"))
                #expect(!identifier.contains("Synthetic"))
                #expect(!identifier.contains("acct_"))
                #expect(!identifier.contains("obs_"))
                #expect(!identifier.contains("2026"))
            }
        }
    }

    @Test("The five row roles are separate, unambiguous identifier spaces")
    func activityRowNamespacesDoNotOverlap() {
        #expect(Set(ActivityID.rowPrefixes).count == 5)
        for prefix in ActivityID.rowPrefixes {
            let others = ActivityID.rowPrefixes.filter { $0 != prefix }
            #expect(!others.contains { $0.hasPrefix(prefix) })
        }
        // A section header must not answer a search for a row in that section.
        #expect(!ActivityID.rowPrefixes.contains { ActivityID.pendingSection.hasPrefix($0) })
        #expect(ActivityID.pendingSection == "activity.pending-section")

        let sameIdentity = builtIdentifiers(for: "obs-streaming")
        #expect(Set(sameIdentity).count == sameIdentity.count)
    }

    @Test("The same row keeps the same identity; different rows do not share one")
    func tokenIsStableAndDistinct() {
        #expect(ActivityID.decision("obs-streaming") == ActivityID.decision("obs-streaming"))
        #expect(ActivityID.decision("obs-streaming") != ActivityID.decision("obs-streamins"))

        let ids = [
            "obs-streaming", "obs-paypal-unresolved", "pending-snapshot", "pending-third",
            "needs-review", "pending-current", "pending-zero", "live:tx-1", "archive:arc-1",
        ]
        #expect(Set(ids.map(ActivityID.transaction)).count == ids.count)
    }

    @Test("Both copies of the token agree, character for character")
    func tokenVectors() {
        // Mirrored in FinanceAppUITests/AutomationTokenMirror.swift, which a UI
        // test process needs because it cannot import the app.
        let vectors: [(String, String)] = [
            ("", "cbf29ce484222325"),
            ("a", "af63dc4c8601ec8c"),
            ("obs-streaming", "9ac03f209deb1760"),
            ("obs-paypal-unresolved", "01a3eb4e5c2bef45"),
            ("pending-snapshot", "63eb36fd26467a43"),
            ("pending-third", "ec863c759cf2b224"),
            ("live:tx-1", "0800a431d0655ce9"),
            ("archive:arc-1", "7f054a8284db4711"),
        ]
        for (identity, token) in vectors {
            #expect(AutomationToken.opaque(identity) == token)
        }
    }

    // MARK: - High-value identifier uniqueness

    @Test("No two high-value identifiers collide, and none is a prefix of another")
    func highValueIdentifiersAreDistinct() {
        let identifiers = AppTab.allCases.map(RouteID.tab) + FundingID.all + [
            InsightsID.scopeWeek, InsightsID.scopeMonth, InsightsID.showDetails,
            InsightsID.verification, InsightsID.unresolved,
            InsightsID.acknowledge, InsightsID.acknowledgmentState,
            RouteID.insightsScope, RouteID.insightsPrevious, RouteID.insightsNext,
            RouteID.insightsSummary, RouteID.insightsCoverage,
            RouteID.homeSafeToUse, RouteID.homeAttention, RouteID.homeCash,
            RouteID.homeSync, RouteID.homeReview, RouteID.homeUpcomingAll,
            RouteID.homeSettings,
            RouteID.activitySection, RouteID.activityAdd, RouteID.activityFilters,
            RouteID.activityReviewQueue, ActivityID.pendingSection,
            RouteID.planBudget, RouteID.planFundingNeeded, RouteID.planUpcoming,
            RouteID.planGoals, RouteID.planAfford,
            RouteID.settingsBanks, RouteID.settingsAutomation,
            RouteID.settingsData, RouteID.settingsApp,
        ]
        #expect(Set(identifiers).count == identifiers.count)

        // `insights.scope` legitimately prefixes `insights.scope.week`: the
        // control and its two options are different things and both are
        // addressed. Everything else must be unambiguous under exact match,
        // which the set check above establishes.
        #expect(InsightsID.scopeWeek.hasPrefix(RouteID.insightsScope))
        #expect(InsightsID.scopeMonth.hasPrefix(RouteID.insightsScope))
    }

    // MARK: - Diagnostic vocabulary must not reach a row

    @Test("Analysis vocabulary never becomes the words on a row")
    func diagnosticDescriptorsAreReplaced() {
        // The exact vocabulary a forensic reconstruction writes when the
        // evidence names no purchase. True of the evidence; wrong as a title.
        let raw = "UNKNOWN — not present in available primary descriptors"
        #expect(DisplayDescriptor.isDiagnostic(raw))
        let title = DisplayDescriptor.instalmentTitle(
            purchaseDescription: raw, provider: "Synthetic Finance"
        )
        #expect(title == "Synthetic Finance instalment")
        #expect(!title.contains("UNKNOWN"))
        #expect(!title.contains("descriptors"))
        // Nothing financial is invented to fill the gap.
        #expect(!title.contains("€"))
        #expect(!title.contains("purchase"))

        #expect(DisplayDescriptor.instalmentTitle(
            purchaseDescription: "   ", provider: ""
        ) == "Instalment")
        #expect(DisplayDescriptor.instalmentTitle(
            purchaseDescription: "NOT_COMPUTABLE", provider: "Synthetic Finance"
        ) == "Synthetic Finance instalment")
        // A provider that is itself diagnostic cannot rescue the title.
        #expect(DisplayDescriptor.instalmentTitle(
            purchaseDescription: "UNKNOWN", provider: "N/A"
        ) == "Instalment")
    }

    @Test("A descriptor a person could have written survives untouched")
    func humanDescriptorsSurvive() {
        // The shapes a real document carries — a named counterparty, a partly
        // known purchase, a raw statement descriptor — written synthetically.
        let kept = [
            "Example Ltd / handset",
            "Airline ticket",
            "4x CARD PURCHASE (item not visible)",
            "Marketplace purchase (item not visible)",
            // A statement descriptor's shape: all caps, and deliberately kept
            // as written rather than tidied into something friendlier.
            "FACTURE CARTE DU 010126 EXAMPLE.COM/BILL CARTE 0000XXXXXXXX0000 IRL 1,23EUR",
            // Screaming vocabulary only counts as diagnostic when it opens the
            // string; a person writing about an unknown charge means it.
            "Unknown charge, disputing with the bank",
        ]
        for descriptor in kept {
            #expect(!DisplayDescriptor.isDiagnostic(descriptor))
            #expect(DisplayDescriptor.instalmentTitle(
                purchaseDescription: descriptor, provider: "Synthetic Finance"
            ) == descriptor)
        }
    }

    @Test("Every diagnostic token is caught with or without a trailing clause")
    func diagnosticTokensAreCaught() {
        for token in DisplayDescriptor.diagnosticTokens {
            #expect(DisplayDescriptor.isDiagnostic(token))
            #expect(DisplayDescriptor.isDiagnostic("\(token) — reason withheld"))
            #expect(DisplayDescriptor.isDiagnostic("  \(token)  "))
        }
        #expect(DisplayDescriptor.isDiagnostic(""))
    }

    private func builtIdentifiers(for identity: String) -> [String] {
        [
            ActivityID.decision(identity), ActivityID.payment(identity),
            ActivityID.pending(identity), ActivityID.limitation(identity),
            ActivityID.transaction(identity),
        ]
    }
}
