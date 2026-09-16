import Testing
import Foundation
import SwiftData
import SwiftUI
import FinanceCore
@testable import FinanceApp

// MARK: - Offering a control only where it can do something

/// Trusted Automation, and the one build state where it cannot act.
///
/// The dependency is structural rather than a matter of taste. Trusted
/// Automation has exactly one effect: the tail of `importBankEvidence` asks it
/// to resolve rows that the landing evidence made newly eligible. It is the
/// only production caller of `processTrustedRules`, there is no "apply to the
/// existing queue" path anywhere — the footer has always said as much — and
/// `importBankEvidence` is reachable in production only through `syncNow` and
/// `refreshFromService`, both of which return early unless
/// `BankSyncConfiguration.baseURL()` is non-nil. `notConfigured` is exactly the
/// state in which that URL is nil, so on such a build the switch governs an
/// event that can never happen.
///
/// The gate is therefore presentation-only, and deliberately so: the store path
/// stays reachable from any pairing state, which is what lets the trusted-rules
/// suites drive it on stores that are themselves `notConfigured`.
@MainActor
@Suite("Trusted Automation is offered only where bank evidence can arrive")
struct TrustedAutomationCapabilityTests {

    private static let today = Day(year: 2026, month: 9, day: 16)

    private func realStore() throws -> (ModelContainer, FinanceStore) {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (
            container,
            try FinanceStore(context: container.mainContext, now: fixtureInstant(Self.today))
        )
    }

    // MARK: - Capability, not connection

    /// The distinction Settings established for Banks & Sync, applied to the
    /// one other control that depends on the same capability. Collapsing these
    /// two is the mutation this exists to catch.
    @Test("Only a build with no sync service lacks the capability")
    func onlyNotConfiguredLacksTheCapability() {
        #expect(BankPairingState.notConfigured.canReceiveBankEvidence == false)
        // The capability is present in all three. What differs between them is
        // whether the device is currently connected to it, which is a question
        // a pairing code answers and this predicate deliberately does not ask.
        #expect(BankPairingState.unpaired.canReceiveBankEvidence)
        #expect(BankPairingState.paired.canReceiveBankEvidence)
        #expect(BankPairingState.revoked.canReceiveBankEvidence)
    }

    // MARK: - The Settings row

    @Test("A build with no sync service says so instead of counting rules")
    func automationRowStatesUnavailabilityRatherThanARuleCount() {
        let unavailable = SettingsView.automationDetail(ruleCount: 0, pairing: .notConfigured)
        #expect(unavailable == "Not available on this build")
        // Even with rules on the store — a restored document can carry them —
        // the count is not the useful sentence here.
        #expect(SettingsView.automationDetail(ruleCount: 3, pairing: .notConfigured) == unavailable)
    }

    @Test("A configured build still counts its rules, paired or not")
    func automationRowCountsRulesWhenTheCapabilityExists() {
        for pairing in [BankPairingState.unpaired, .paired, .revoked] {
            #expect(SettingsView.automationDetail(ruleCount: 0, pairing: pairing)
                    == "0 trusted rules")
            #expect(SettingsView.automationDetail(ruleCount: 1, pairing: pairing)
                    == "1 trusted rule")
            #expect(SettingsView.automationDetail(ruleCount: 4, pairing: pairing)
                    == "4 trusted rules")
        }
    }

    /// Banks & Sync and Automation describe the same fact about the same build.
    /// They were allowed to disagree before this slice: one said the build had
    /// no service, the other offered a switch over evidence from it.
    @Test("The two Settings rows never contradict each other")
    func settingsRowsAgree() {
        let reference = fixtureInstant(Self.today)
        func evaluation(_ state: BankFreshness) -> BankFreshnessEvaluation {
            BankFreshnessEvaluation(state: state, reference: reference)
        }

        let banks = SettingsView.banksDetail(evaluation(.notConnected), pairing: .notConfigured)
        let automation = SettingsView.automationDetail(ruleCount: 0, pairing: .notConfigured)
        #expect(banks == automation)
        #expect(banks == "Not available on this build")

        // And where the capability exists, neither row claims it is missing.
        for pairing in [BankPairingState.unpaired, .paired, .revoked] {
            let detail = SettingsView.automationDetail(ruleCount: 2, pairing: pairing)
            #expect(!detail.contains("Not available"))
            #expect(!SettingsView.banksDetail(evaluation(.neverSynced), pairing: pairing)
                .contains("Not available"))
        }
    }

    // MARK: - The explanation

    /// Capability-oriented, and free of anything a person cannot act on. The
    /// build setting, the xcconfig and the service address are this project's
    /// vocabulary, not theirs.
    @Test("The unavailable explanation names the capability, not the plumbing")
    func unavailableReasonAvoidsDeveloperTerms() {
        for wasEnabled in [true, false] {
            let reason = AutomationView.unavailableReason(wasEnabled: wasEnabled)
            #expect(reason.contains("Trusted Automation"))
            #expect(reason.contains("not configured for this build"))
            for jargon in [
                "BANK_SYNC", "xcconfig", "endpoint", "base URL", "baseURL",
                "Info.plist", "host", "URL"
            ] {
                #expect(!reason.contains(jargon), "leaked \(jargon)")
            }
            // It must not suggest a fix the person cannot perform from here.
            #expect(!reason.lowercased().contains("settings to"))
        }
    }

    /// "Unavailable" must not read as "we turned your setting off". It says so
    /// only to somebody who had actually turned it on.
    @Test("Someone who had enabled it is told their choice is kept")
    func unavailableReasonPromisesThePreferenceSurvives() {
        let kept = AutomationView.unavailableReason(wasEnabled: true)
        #expect(kept.contains("kept"))
        #expect(kept.contains("applies again"))

        let never = AutomationView.unavailableReason(wasEnabled: false)
        #expect(!never.contains("kept"))
        #expect(kept.hasPrefix(never))
    }

    // MARK: - The screens

    @Test("Automation renders in every pairing state, light and dark, at any size")
    func automationRendersInEveryState() {
        for pairing in [BankPairingState.notConfigured, .unpaired, .paired, .revoked] {
            let store = FinanceStore.bankSyncPreview(pairing: pairing)
            for scheme in [ColorScheme.light, .dark] {
                for size in [DynamicTypeSize.large, .accessibility3] {
                    #expect(RenderCheck.image(
                        NavigationStack { AutomationView() },
                        store: store, scheme: scheme, typeSize: size
                    ) != nil)
                }
            }
        }
    }

    @Test("Banks & Sync renders in every pairing state with the section gated")
    func bankSyncRendersInEveryState() {
        for pairing in [BankPairingState.notConfigured, .unpaired, .paired, .revoked] {
            let store = FinanceStore.bankSyncPreview(pairing: pairing)
            #expect(RenderCheck.image(NavigationStack { BankSyncView() }, store: store) != nil)
        }
    }

    // MARK: - The switch itself, where it is offered

    /// `.paired` is untouched: the control works exactly as before.
    @Test("A paired build can still turn Trusted Automation on and off")
    func pairedBuildKeepsAWorkingSwitch() throws {
        let store = FinanceStore.bankSyncPreview(pairing: .paired)
        #expect(store.pairingState.canReceiveBankEvidence)
        #expect(store.trustedAutomationEnabled == false)

        try store.setTrustedAutomationEnabled(true)
        #expect(store.trustedAutomationEnabled)
        try store.setTrustedAutomationEnabled(false)
        #expect(store.trustedAutomationEnabled == false)
    }

    /// `.unpaired` and `.revoked` are *not* treated like `.notConfigured`. The
    /// capability exists; the device is not connected to it. Setting the
    /// preference ahead of pairing is meaningful — the first sync after pairing
    /// honours it — and the store has never required pairing to set it.
    @Test("An unpaired or revoked build may still configure automation in advance")
    func unpairedAndRevokedKeepTheSwitch() throws {
        for pairing in [BankPairingState.unpaired, .revoked] {
            let store = FinanceStore.bankSyncPreview(pairing: pairing)
            #expect(store.pairingState.canReceiveBankEvidence)
            try store.setTrustedAutomationEnabled(true)
            #expect(store.trustedAutomationEnabled)
        }
    }

    // MARK: - The persisted preference

    /// The preference is a device-local `StoredEntryPreferences` value, not part
    /// of `FinanceDocument`. It survives a relaunch on its own terms.
    @Test("The preference persists across reopening the store")
    func preferencePersistsAcrossReopen() throws {
        let (container, store) = try realStore()
        try store.setTrustedAutomationEnabled(true)
        #expect(store.trustedAutomationEnabled)

        let reopened = try FinanceStore(
            context: container.mainContext, now: fixtureInstant(Self.today)
        )
        #expect(reopened.trustedAutomationEnabled)
    }

    /// The edge case the gate must not get wrong: a store with the preference
    /// already on, running where the capability is absent. Making the control
    /// unavailable is a presentation decision and writes nothing, so the
    /// person's answer is still there when the capability returns.
    @Test("Making the control unavailable never erases an enabled preference")
    func unavailabilityDoesNotEraseTheStoredPreference() throws {
        let store = FinanceStore.bankSyncPreview(pairing: .notConfigured)
        try store.setTrustedAutomationEnabled(true)
        #expect(store.trustedAutomationEnabled)
        #expect(store.pairingState.canReceiveBankEvidence == false)

        // Rendering the screen that reports the control as unavailable, at both
        // schemes and sizes, is the whole of what this slice does to it.
        for scheme in [ColorScheme.light, .dark] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                #expect(RenderCheck.image(
                    NavigationStack { AutomationView() },
                    store: store, scheme: scheme, typeSize: size
                ) != nil)
            }
        }
        #expect(store.trustedAutomationEnabled, "the stored answer was destroyed")
        // And the person is told it was kept rather than left to assume.
        #expect(AutomationView.unavailableReason(wasEnabled: store.trustedAutomationEnabled)
            .contains("kept"))
    }

    /// The other half: when the capability comes back, the stored answer is the
    /// one that is honoured — nothing had to be re-enabled.
    @Test("A restored capability finds the preference as it was left")
    func restoredCapabilityHonoursTheStoredPreference() throws {
        let (container, store) = try realStore()
        try store.setTrustedAutomationEnabled(true)

        // The same persisted store read by a build that does have the
        // capability. Pairing lives in the Keychain and the service address in
        // the bundle; neither is part of what was written above, so the
        // preference is simply found again.
        let reopened = try FinanceStore(
            context: container.mainContext, now: fixtureInstant(Self.today)
        )
        #expect(reopened.trustedAutomationEnabled)
        #expect(try reopened.exportDocument() == (try store.exportDocument()))
    }

    // MARK: - Nothing about bank sync changed

    /// This slice gates a control. It must not touch pairing, the sync client,
    /// the stored document, or the automation engine's own reachability.
    @Test("Gating mutates no bank-sync state and no document")
    func gatingMutatesNothing() throws {
        let (container, store) = try realStore()
        _ = container
        let pairingBefore = store.pairingState
        let documentBefore = try store.exportDocument()
        let activityBefore = store.bankSyncActivity

        for scheme in [ColorScheme.light, .dark] {
            #expect(RenderCheck.image(
                NavigationStack { AutomationView() }, store: store, scheme: scheme
            ) != nil)
            #expect(RenderCheck.image(
                NavigationStack { SettingsView() }, store: store, scheme: scheme
            ) != nil)
        }

        #expect(store.pairingState == pairingBefore)
        #expect(store.bankSyncActivity == activityBefore)
        #expect(try store.exportDocument() == documentBefore)
        #expect(store.trustedAutomationEnabled == false)
        #expect(store.trustedAutomationDiagnostic == nil)
    }

    /// The execution path stays independent of pairing, which is why the gate
    /// had to be presentational. A store-level refusal would change automation
    /// semantics and break every trusted-rules suite, all of which drive this
    /// on stores whose own pairing state is `notConfigured`.
    @Test("The engine remains reachable regardless of pairing state")
    func engineRemainsReachableFromAnyPairingState() throws {
        let (container, store) = try realStore()
        _ = container

        // Whatever this checkout's pairing state happens to be — a developer
        // with a local service address gets `unpaired` here rather than
        // `notConfigured` — the engine answers the same way. That invariance is
        // the point: the gate never reached this far down.
        try store.setTrustedAutomationEnabled(true)
        #expect(store.trustedAutomationEnabled)
        // Reachable, and correctly finds nothing to do rather than refusing.
        #expect(try store.processTrustedRules(observationIDs: []) == .empty)
    }
}
