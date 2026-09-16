import Testing
import Foundation
import SwiftData
import SwiftUI
import FinanceCore
@testable import FinanceApp

// MARK: - The claims the setup and recovery surfaces make

/// What a person is told about getting their money into this app, getting it
/// back out, and whether this build can talk to a bank.
///
/// The mechanics are already proved elsewhere: `OnboardingImportTests` proves a
/// file becomes the store, `BackupExportTests` proves the store becomes a file
/// and that the file restores into an empty install. None of that was wrong.
/// What was wrong was the account of itself the app gave — onboarding denying a
/// sync subsystem that ships one screen away, Settings offering to pair a
/// device on a build with no service to pair it with, and one operation called
/// three different things depending on which screen asked.
///
/// So these tests are about sentences, and they are here because a sentence
/// that contradicts the architecture is a defect the compiler cannot see.
@MainActor
@Suite("First run, recovery and bank setup say what is true")
struct FirstRunRecoveryCoherenceTests {

    private static let today = Day(year: 2026, month: 9, day: 16)
    private static func reference() -> Date { fixtureInstant(today) }

    private func emptyStore() throws -> (ModelContainer, FinanceStore) {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return (container, try FinanceStore(context: container.mainContext, now: Self.reference()))
    }

    private func freshness(_ state: BankFreshness) -> BankFreshnessEvaluation {
        BankFreshnessEvaluation(state: state, reference: Self.reference())
    }

    // MARK: - Bank sync: four states, and two of them are not the same state

    /// The mutation this exists to kill: mapping an unconfigured service onto
    /// "Not paired".
    ///
    /// Both reach Settings as `BankFreshness.notConnected`, and that is correct
    /// for `BankFreshness` — Home has nothing to say in either case. It is not
    /// correct for a row a person taps in order to act, because only one of the
    /// two has an action behind it.
    @Test("A build with no sync service is never labelled merely not paired")
    func unconfiguredBuildIsNotCalledUnpaired() {
        let unconfigured = SettingsView.banksDetail(
            freshness(.notConnected), pairing: .notConfigured
        )
        #expect(unconfigured == "Not available on this build")
        #expect(!unconfigured.lowercased().contains("paired"))

        // Same freshness, configured build, device simply has not paired yet.
        // This one *is* "Not paired", and pressing it leads somewhere useful.
        #expect(SettingsView.banksDetail(freshness(.notConnected), pairing: .unpaired)
                == "Not paired")
    }

    /// Configuration is asked before freshness, not after. A build with no
    /// service address cannot have synced, so no freshness state may talk it
    /// back into a sentence about syncing.
    @Test("No freshness state turns an unconfigured build into a sync report")
    func unconfiguredOutranksEveryFreshnessState() {
        let states: [BankFreshness] = [
            .notConnected,
            .neverSynced,
            .updated(Self.reference().addingTimeInterval(-600)),
            .stale(Self.reference().addingTimeInterval(-5 * 24 * 60 * 60)),
            .needsAttention
        ]
        for state in states {
            #expect(SettingsView.banksDetail(freshness(state), pairing: .notConfigured)
                    == "Not available on this build")
        }
    }

    /// The states that *are* about pairing keep their own sentences, and none
    /// of them collides with the unconfigured one.
    @Test("Configured builds still report pairing, sync age and faults distinctly")
    func configuredStatesRemainDistinct() {
        let synced = Self.reference().addingTimeInterval(-3_600)
        let details = [
            SettingsView.banksDetail(freshness(.notConnected), pairing: .unpaired),
            SettingsView.banksDetail(freshness(.neverSynced), pairing: .paired),
            SettingsView.banksDetail(freshness(.updated(synced)), pairing: .paired),
            SettingsView.banksDetail(freshness(.stale(synced)), pairing: .paired),
            SettingsView.banksDetail(freshness(.needsAttention), pairing: .revoked),
            SettingsView.banksDetail(freshness(.notConnected), pairing: .notConfigured)
        ]
        #expect(Set(details).count == details.count)
    }

    /// The detail screen behind the row has always been honest. This pins that
    /// it renders in every pairing state, including the one that offers no
    /// action at all — the state a person reaches from the row above.
    @Test("Banks & Sync renders in every pairing state")
    func bankSyncScreenRendersInEveryState() {
        for pairing in [BankPairingState.notConfigured, .unpaired, .paired, .revoked] {
            let store = FinanceStore.bankSyncPreview(pairing: pairing)
            #expect(store.pairingState == pairing)
            #expect(RenderCheck.image(NavigationStack { BankSyncView() }, store: store) != nil)
        }
    }

    // MARK: - Onboarding says what this build is

    /// The sentence this replaced was "There is no server, no sync and no
    /// sample data", on a product with a bank-sync service, a pairing flow and
    /// a Banks & Sync screen one tap away in Settings.
    @Test("Onboarding never denies that this app has bank sync")
    func onboardingDoesNotDenySync() {
        for pairing in [BankPairingState.notConfigured, .unpaired, .paired, .revoked] {
            let line = OnboardingView.privacyLine(pairing: pairing)
            #expect(!line.contains("no server"))
            #expect(!line.contains("no sync"))
            // The two claims that are true whatever the build is, and are the
            // reason a person trusts the figures they are about to enter.
            #expect(line.contains("never uploaded"))
            #expect(line.contains("No sample data"))
        }
    }

    /// Conditional, and only where it is true. A build with no service address
    /// says so; a build with one does not pretend it is absent.
    @Test("Onboarding states sync availability per build, not per product")
    func onboardingStatesSyncPerBuild() {
        let unconfigured = OnboardingView.privacyLine(pairing: .notConfigured)
        #expect(unconfigured.contains("This build has no bank sync."))

        for pairing in [BankPairingState.unpaired, .paired, .revoked] {
            let line = OnboardingView.privacyLine(pairing: pairing)
            #expect(!line.contains("This build has no bank sync."))
            #expect(line.contains("Bank sync is optional"))
            // Evidence, never conclusions — the invariant the whole sync layer
            // is built on, stated where a person first meets the idea.
            #expect(line.contains("evidence"))
        }
    }

    /// A fresh install offers two ways in and no third. Bank pairing is not one
    /// of them: `MapAccountSheet` has nothing to map a remote account onto
    /// until local accounts exist, so a "Connect bank" button here would open a
    /// step that cannot complete.
    @Test("Onboarding renders both ways in, on a store that can take either")
    func onboardingOffersBothPathsOnAnEmptyStore() throws {
        let (container, store) = try emptyStore()
        _ = container

        #expect(store.isEmpty)
        #expect(store.canImportCurrentState)
        for scheme in [ColorScheme.light, .dark] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                #expect(RenderCheck.image(
                    NavigationStack { ScrollView { OnboardingView().padding() } },
                    store: store, scheme: scheme, typeSize: size
                ) != nil)
            }
        }
    }

    // MARK: - A populated store is refused, and told what to do instead

    /// The guard itself is proved in `OnboardingImportTests`. What is proved
    /// here is that the person on the other side of it learns the supported
    /// recovery, which `DataAndBackupView` used to drop: the row is disabled,
    /// so the sheet that shows `recoverySuggestion` is unreachable, and the
    /// footer showed `message` alone.
    @Test("A populated store is refused with the recovery that is supported")
    func populatedStoreRefusalNamesTheSupportedRecovery() throws {
        let harness = try EntryFixtures.Harness(CurrentStateExport.document())
        let blocker = try #require(harness.store.importBlocker)
        #expect(blocker == .storeNotEmpty)
        #expect(harness.store.canImportCurrentState == false)

        let shown = DataAndBackupView.refusal(blocker.message, blocker.recoverySuggestion)
        // Why it is refused …
        #expect(shown.contains("already exists"))
        #expect(shown.contains("duplicate money"))
        // … and the one procedure that does work.
        #expect(shown.contains("fresh install"))
        // The refusal answers in the words of the button it refused.
        #expect(shown.contains("Restor"))
        #expect(!shown.contains("Import"))
    }

    /// Every refusal either says what to do or has nothing to add. None of them
    /// silently drops a suggestion that exists.
    @Test("The refusal line carries the suggestion whenever there is one")
    func refusalLineNeverDropsASuggestion() {
        let blockers: [AppImportError] = [
            .storeNotEmpty, .storeUnreadable, .storeIsReadOnly,
            .inconsistentDocument(.noAccounts)
        ]
        for blocker in blockers {
            let shown = DataAndBackupView.refusal(blocker.message, blocker.recoverySuggestion)
            #expect(shown.hasPrefix(blocker.message))
            if let suggestion = blocker.recoverySuggestion {
                #expect(shown.contains(suggestion))
            } else {
                #expect(shown == blocker.message)
            }
        }
        // The export side of the same screen, through the same helper.
        let export = AppExportError.nothingToExport
        let shown = DataAndBackupView.refusal(export.message, export.recoverySuggestion)
        #expect(shown.contains("restore a backup"))
    }

    @Test("Data & Privacy renders refused and offered, light and dark, at any size")
    func dataAndPrivacyRendersBothRestoreStates() throws {
        let (container, empty) = try emptyStore()
        _ = container
        let populated = try EntryFixtures.Harness(CurrentStateExport.document())
        #expect(empty.canImportCurrentState)
        #expect(populated.store.canImportCurrentState == false)

        for store in [empty, populated.store] {
            for scheme in [ColorScheme.light, .dark] {
                for size in [DynamicTypeSize.large, .accessibility3] {
                    #expect(RenderCheck.image(
                        NavigationStack { DataAndBackupView() },
                        store: store, scheme: scheme, typeSize: size
                    ) != nil)
                }
            }
        }
    }

    // MARK: - What a restore does not bring back

    /// The export screen lists the exclusions before the file is written. The
    /// restore result now lists the same ones after it is read, because that is
    /// where a person goes looking for the verified months that did not come
    /// back — and the alternative to telling them is letting it read as loss.
    @Test("What a backup leaves out is stated where a restore lands")
    func restoreResultStatesTheExclusions() throws {
        // One list, used by both screens: a backup that started carrying one of
        // these could not go on being described as not carrying it on one
        // screen out of two.
        #expect(BackupSummary.exclusions.count == 3)
        let all = BackupSummary.exclusions.joined(separator: " ")
        #expect(all.contains("historical archive"))
        #expect(all.contains("Verified-month history"))
        #expect(all.contains("Bank pairing"))

        let harness = try EntryFixtures.Harness(CurrentStateExport.document())
        for scheme in [ColorScheme.light, .dark] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                #expect(RenderCheck.image(
                    NavigationStack { ScrollView { ExclusionsCard().padding() } },
                    store: harness.store, scheme: scheme, typeSize: size
                ) != nil)
            }
        }
    }

    /// The mutation: claiming bank pairing, checkpoint history or the archive
    /// comes back with a restore. Nothing on either screen may say so, and the
    /// restore path must not quietly start carrying them either.
    @Test("Nothing claims pairing or verified months are restored")
    func restoreClaimsNothingItDoesNotCarry() throws {
        let harness = try EntryFixtures.Harness(CurrentStateExport.document())
        let backup = try harness.store.exportBackup()

        // The file is the document and nothing beside it. Decoding it back
        // yields a `FinanceDocument`, which has no checkpoint and no pairing to
        // carry in the first place — the exclusions are structural, not a
        // filter somebody has to remember to apply.
        let reread = try Interchange.decode(backup.data)
        #expect(reread.accounts.count == backup.summary.accountCount)

        for line in BackupSummary.exclusions {
            #expect(line.contains("which"))
            // Each line says the thing is *absent*, never that it is included.
            #expect(!line.lowercased().contains("included"))
        }
    }

    // MARK: - The whole round trip, in product terms

    /// Export a populated document, restore it into a fresh install, and get
    /// the same financial state — asserted on the money rather than on the
    /// bytes, which `BackupExportTests` already pins.
    ///
    /// The claim deliberately stops at the document. Verified months and bank
    /// pairing are not compared, because they are not in the file, and a test
    /// that compared them would have to be wrong in one direction or the other.
    @Test("Export, fresh install, restore — the financial document is unchanged")
    func roundTripPreservesFinancialSemantics() throws {
        let harness = try EntryFixtures.Harness(CurrentStateExport.document())
        let before = try harness.store.exportDocument()
        let backup = try harness.store.exportBackup()

        let (container, restored) = try emptyStore()
        _ = container
        #expect(restored.isEmpty)
        #expect(restored.canImportCurrentState)

        _ = try restored.prepareImport(from: backup.data)
        let summary = try restored.confirmImport()
        let after = try restored.exportDocument()

        // Integer cents decide equality, and the whole graph is compared.
        #expect(after == before)
        #expect(summary.accountCount == before.accounts.count)
        #expect(restored.isEmpty == false)

        // Checkpoint history is not carried, and the restored store says so by
        // having none rather than by inheriting the source store's.
        #expect(restored.checkpoints.occupancy() == .empty)
        // Nor is pairing: a restore is a document, not a device identity, so
        // the restored store's pairing is whatever a store that had never been
        // restored into would have had. Compared against a fresh one rather
        // than against a literal, because a checkout carrying a local service
        // address legitimately starts `unpaired` instead of `notConfigured`.
        let (untouchedContainer, untouched) = try emptyStore()
        _ = untouchedContainer
        #expect(restored.pairingState == untouched.pairingState)
        #expect(restored.pairingState != .paired)
    }

    /// The other half of the guard: once a store has been restored into, it is
    /// no longer a store that may be restored into.
    @Test("A restored store refuses the next restore")
    func aRestoredStoreIsNoLongerEmpty() throws {
        let harness = try EntryFixtures.Harness(CurrentStateExport.document())
        let backup = try harness.store.exportBackup()

        let (container, restored) = try emptyStore()
        _ = container
        _ = try restored.prepareImport(from: backup.data)
        _ = try restored.confirmImport()

        #expect(restored.importBlocker == .storeNotEmpty)
        #expect(throws: AppImportError.storeNotEmpty) {
            _ = try restored.prepareImport(from: backup.data)
        }
    }

    // MARK: - One vocabulary

    /// Three words, three different things. "Import" survives in exactly one
    /// place, and it is the place where a person really is importing something
    /// this app cannot produce.
    @Test("Restore, export and import name three different operations")
    func vocabularyIsCoherent() {
        // A refusal from the restore path never calls itself an import.
        let restoreSentences = [AppImportError.storeNotEmpty, .storeUnreadable, .storeIsReadOnly]
            .flatMap { [$0.message, $0.recoverySuggestion ?? ""] }
            .joined(separator: " ")
        #expect(!restoreSentences.contains("Import"))
        #expect(!restoreSentences.contains("import"))

        // The archive is the genuine import — a `FinanceHistoryDocument`, a
        // type this app cannot produce and does not back up — and keeps the
        // word for exactly that reason.
        #expect(HistoryArchiveImportError.invalidArchive.description.contains("archive"))
        #expect(HistoryArchiveImportError.nothingPrepared.description.contains("historical"))
    }
}
