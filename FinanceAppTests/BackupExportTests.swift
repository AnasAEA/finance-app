import Testing
import Foundation
import SwiftData
import SwiftUI
import FinanceCore
@testable import FinanceApp

// MARK: - Producing a backup

/// The export half of the interchange spine.
///
/// Import already proves a chosen file becomes the store. These prove the
/// other direction, and one thing more: that the file produced here is one the
/// import path can actually read. A backup nobody has read back is a file, not
/// a backup, and the difference only shows on the day it matters.
@MainActor
@Suite("Export backup")
struct BackupExportTests {

    private static let today = Day(year: 2026, month: 9, day: 16)

    private func harness() throws -> EntryFixtures.Harness {
        try EntryFixtures.Harness(CurrentStateExport.document())
    }

    private func emptyStore() throws -> (ModelContainer, FinanceStore) {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(CurrentStateExport.today)
        )
        return (container, store)
    }

    // MARK: - The happy path

    @Test("A stored document becomes a dated, verified file")
    func storedDocumentBecomesAVerifiedFile() throws {
        let harness = try harness()
        #expect(harness.store.canExportBackup)
        #expect(harness.store.backupBlocker == nil)

        let backup = try harness.store.exportBackup()

        #expect(backup.fileName == "Finance Backup \(EntryFixtures.today.isoString).json")
        #expect(backup.data.isEmpty == false)
        #expect(backup.summary.byteCount == backup.data.count)

        // The counts describe the real document, not a placeholder.
        let stored = try harness.store.exportDocument()
        #expect(backup.summary.accountCount == stored.accounts.count)
        #expect(backup.summary.accountCount == 5)
        #expect(backup.summary.transactionCount == stored.transactions.count)
        #expect(backup.summary.incomeSourceCount == stored.incomeSources.count)
        #expect(backup.summary.debtCount == stored.debts.count)
        #expect(backup.summary.instalmentCount == stored.installments.count)
        #expect(
            backup.summary.recurringCommitmentCount == stored.planning.recurringObligations.count
        )
    }

    /// The whole point. A backup that cannot be restored is not one, so this
    /// walks the file back through the import path a person would actually
    /// use and requires the restored store to produce the identical file.
    @Test("The file restores into an empty install and exports identically")
    func theFileRestoresAndReproducesItself() throws {
        let harness = try harness()
        let backup = try harness.store.exportBackup()

        let (container, restored) = try emptyStore()
        _ = container
        #expect(restored.canImportCurrentState)

        let preview = try restored.prepareImport(from: backup.data)
        #expect(preview.accounts.count == backup.summary.accountCount)
        let summary = try restored.confirmImport()
        #expect(summary.accountCount == backup.summary.accountCount)

        // Same money, same plan, same evidence — proved by the file the
        // restored store writes rather than by a field-by-field comparison
        // that could miss whatever it forgot to look at.
        let again = try restored.exportBackup()
        #expect(again.data == backup.data)
        #expect(again.summary == backup.summary)
    }

    // MARK: - Refusals

    /// The refusal this feature exists for. An unreadable store serves an
    /// empty plan, and an empty plan encodes perfectly well — so without this
    /// gate the app would hand back a well-formed backup of nothing and look
    /// like it had worked.
    @Test("A store that could not be read refuses rather than backing up nothing")
    func unreadableStoreRefusesRatherThanExportingNothing() throws {
        let store = try FinanceStore(
            context: nil,
            now: fixtureInstant(Self.today),
            unavailableReason: "Application Support could not be created."
        )

        #expect(store.storeIsUnreadable)
        #expect(store.canExportBackup == false)
        #expect(store.backupBlocker == .storeUnreadable)
        #expect(throws: AppExportError.storeUnreadable) {
            _ = try store.exportBackup()
        }
    }

    @Test("A fresh install has nothing to back up and says so")
    func emptyStoreHasNothingToBackUp() throws {
        let (container, store) = try emptyStore()
        _ = container

        #expect(store.isEmpty)
        #expect(store.canExportBackup == false)
        #expect(store.backupBlocker == .nothingToExport)
        #expect(throws: AppExportError.nothingToExport) {
            _ = try store.exportBackup()
        }
    }

    /// A goal can be planned before an account exists, and `documentIsEmpty`
    /// does not count goals — so the refusal must not be worded as "there is
    /// nothing here". It is worded as what is actually missing, which is also
    /// exactly what a restore would refuse the file for.
    @Test("A store holding only a goal is refused for the reason that is true")
    func aGoalWithoutAnAccountIsRefusedAccurately() throws {
        let (container, store) = try emptyStore()
        _ = container

        try store.savePlannedPurchase(
            PlannedPurchaseDraft(name: "Camera", amountText: "400.00", status: .wishlist)
        )
        #expect(store.snapshot.plannedPurchases.isEmpty == false)

        let blocker = try #require(store.backupBlocker)
        #expect(blocker == .nothingToExport)
        #expect(blocker.message.contains("account"))
        // The one sentence this state must never be given.
        #expect(!blocker.message.contains("nothing to back up"))
    }

    @Test("A preview store has no stored document to export")
    func fixedStoreRefuses() throws {
        let store = FinanceStore.preview()
        #expect(store.canExportBackup == false)
        #expect(store.backupBlocker == .storeIsReadOnly)
        #expect(throws: AppExportError.storeIsReadOnly) {
            _ = try store.exportBackup()
        }
    }

    /// Gate 2 is not decoration. A document that encodes but that the import
    /// path would refuse is refused here, on the day the backup is taken,
    /// rather than on the day somebody needs it.
    @Test("A document the import path would refuse is not offered as a backup")
    func aDocumentImportWouldRefuseIsNotOffered() throws {
        // Decodes cleanly; fails semantic validation, because an account with
        // no balance imports and is then invisible on every screen.
        let unimportable = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [
                Account(
                    id: "bank", name: "Bank", currency: .eur, kind: .bank,
                    supportedRails: PaymentRail.euroBankRails
                )
            ],
            balances: [],
            planning: FinanceDocument.Planning(defaultScenario: .base)
        )

        #expect(
            throws: AppExportError.verificationFailed(
                .inconsistentDocument(.accountWithoutBalance(accountID: "bank"))
            )
        ) {
            _ = try DocumentExporter.backup(of: unimportable, on: Self.today)
        }
    }

    // MARK: - The summary describes the file

    /// Counted from the bytes, not from the store. The discriminant is a
    /// currency the legacy wire cannot state: the stored document and the file
    /// it produces then disagree about the schema, and the summary has to
    /// follow the file.
    @Test("The summary states the schema the file was actually written to")
    func summaryFollowsTheFileNotTheStore() throws {
        let zeroExponentEUR = Currency(code: "EUR", minorUnitDigits: 0)
        let document = FinanceDocument(
            schemaVersion: "1.6.0",
            documentKind: "TEST",
            accounts: [
                Account(
                    id: "bank", name: "Bank", currency: zeroExponentEUR, kind: .bank,
                    supportedRails: PaymentRail.euroBankRails
                )
            ],
            balances: [
                AccountBalance(
                    accountID: "bank",
                    balance: Money(minorUnits: 1_234, currency: zeroExponentEUR),
                    asOf: Self.today
                )
            ],
            planning: FinanceDocument.Planning(defaultScenario: .base)
        )

        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = try FinanceStore(
            context: container.mainContext, now: fixtureInstant(Self.today)
        )
        try store.importDocument(document)

        let backup = try store.exportBackup()
        // The data says something only the explicit-monetary wire can carry,
        // so the file is 2.0.0 whatever the stored document calls itself.
        #expect(Interchange.documentRequiresV2(try store.exportDocument()))
        #expect(backup.summary.schemaVersion == "2.0.0")
        #expect(try Interchange.decode(backup.data).schemaVersion == "2.0.0")

        // And the exponent survived, which is the reason the file said 2.0.0.
        let reread = try Interchange.decode(backup.data)
        #expect(reread.accounts[0].currency == zeroExponentEUR)
    }

    // MARK: - Privacy

    /// The same rule the import path follows: a refusal names what is wrong,
    /// never what was in the document. A backup holds the whole of a person's
    /// finances, so this is the one direction the app is most trusted not to
    /// leak in.
    @Test("No error message this path can produce quotes the document")
    func noExportErrorLeaksDocumentContent() {
        let errors: [AppExportError] = [
            .storeIsReadOnly, .storeUnreadable, .nothingToExport,
            .currentDayUnavailable, .documentUnencodable, .incompleteBackup,
            .verificationFailed(.fileUnreadable),
            .verificationFailed(.inconsistentDocument(.duplicateBalance(accountID: "bank-main"))),
            .verificationFailed(
                .notAFinanceDocument(field: "balances[0].balance", reason: .unreadableValue)
            )
        ]
        for error in errors {
            #expect(!error.message.contains(CurrentStateExport.privateMarker))
            #expect(!error.message.contains("960.00"))
            #expect(!error.message.contains("300.00"))
            #expect(!(error.recoverySuggestion ?? "").contains(CurrentStateExport.privateMarker))
        }
    }

    /// The backup itself is the one thing that *does* hold the document, and
    /// it is handed to the caller rather than kept. Nothing here retains it.
    @Test("Producing a backup writes nothing and changes nothing")
    func producingABackupChangesNothing() throws {
        let harness = try harness()
        let before = try harness.store.exportDocument()

        _ = try harness.store.exportBackup()
        _ = try harness.store.exportBackup()

        #expect(try harness.store.exportDocument() == before)
        #expect(harness.store.isEmpty == false)
        #expect(harness.store.storeIsUnreadable == false)
    }

    // MARK: - The file the system writes

    @Test("The written file is exactly the verified bytes")
    func theWrittenFileIsTheVerifiedBytes() throws {
        let harness = try harness()
        let backup = try harness.store.exportBackup()

        let file = FinanceBackupFile(data: backup.data)
        #expect(file.wrapper.regularFileContents == backup.data)
        #expect(FinanceBackupFile.readableContentTypes == [.json])
    }
}

// MARK: - What the person sees

@MainActor
@Suite("The export screens render")
struct BackupExportPresentationTests {

    @Test("Every export state renders, light and dark, at ordinary and accessibility sizes")
    func everyExportStateRenders() throws {
        let harness = try EntryFixtures.Harness(CurrentStateExport.document())
        let backup = try harness.store.exportBackup()

        for scheme in [ColorScheme.light, .dark] {
            for size in [DynamicTypeSize.large, .accessibility3] {
                func renders(_ view: some View) -> Bool {
                    RenderCheck.image(
                        NavigationStack { view },
                        store: harness.store, scheme: scheme, typeSize: size
                    ) != nil
                }
                #expect(renders(ExportReadyStep(backup: backup) {}))
                #expect(renders(ExportSavedStep(fileName: backup.fileName) {}))
                #expect(renders(ExportBlockedStep(problem: .storeUnreadable)))
                #expect(renders(ExportBlockedStep(problem: .nothingToExport)))
                #expect(renders(DataAndBackupView()))
            }
        }
    }

    /// The export flow's identifiers name roles, and no two of them resolve to
    /// the same element. `data.export` legitimately prefixes the four inside
    /// the sheet: the row that opens the flow and the controls within it are
    /// different things, and no two of them are ever on screen together.
    @Test("The export identifiers are distinct and name roles only")
    func exportIdentifiersAreDistinct() {
        #expect(Set(DataID.all).count == DataID.all.count)
        for identifier in DataID.all {
            #expect(identifier.hasPrefix("data.export"))
            // Roles, not contents: nothing here is derived from a document.
            #expect(identifier.lowercased() == identifier)
            #expect(!identifier.contains(CurrentStateExport.privateMarker))
        }
    }

    /// The row is offered on a store that has something to save, and refuses
    /// in place — with the reason — on one that does not.
    @Test("Data & Privacy renders the export row in both states")
    func dataAndPrivacyRendersBothExportStates() throws {
        let harness = try EntryFixtures.Harness(CurrentStateExport.document())
        #expect(harness.store.canExportBackup)
        #expect(RenderCheck.image(DataAndBackupView(), store: harness.store) != nil)

        let unreadable = try FinanceStore(
            context: nil,
            now: fixtureInstant(Day(year: 2026, month: 9, day: 16)),
            unavailableReason: "Application Support could not be created."
        )
        #expect(unreadable.canExportBackup == false)
        #expect(unreadable.backupBlocker?.message.isEmpty == false)
        #expect(RenderCheck.image(DataAndBackupView(), store: unreadable) != nil)
    }
}
