import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// Phase 2.5 — the first write on a freshly installed app must land.
///
/// On a real fresh install the container has `Library` but not
/// `Library/Application Support`. SwiftData opens a store there without
/// complaint, and only fails at the first `save()`, which rolls back. The
/// person sees an import that validated, previewed, reported its counts and
/// then kept nothing; a relaunch "fixes" it because by then the directory
/// exists. These tests hold the line that the *first* attempt works.
@MainActor
@Suite("A first install keeps what it is given, first time")
struct FreshInstallPersistenceTests {

    /// A directory path that does not exist yet — the fresh-install shape.
    private static func unusedDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("fresh-install-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    private static let account = Account(
        id: "bank", name: "Bank", currency: .eur, kind: .bank,
        supportedRails: [.cardDebit, .sepaCreditTransfer], drawOrder: 0
    )

    private static func document() -> FinanceDocument {
        FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account],
            balances: [
                AccountBalance(
                    accountID: "bank",
                    balance: Money(exactDecimal: "384.09", currency: .eur)!,
                    asOf: Day(year: 2026, month: 8, day: 22)
                )
            ]
        )
    }

    private static func container(at directory: URL) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(url: directory.appendingPathComponent("FinanceCore-1.1.store"))
        )
    }

    // MARK: - The fix

    @Test("Preparing the location creates a directory that was not there")
    func prepareCreatesTheDirectory() throws {
        let directory = Self.unusedDirectory()
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        try PersistenceLocation.prepare(directory)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    @Test("Preparing a location that already exists is not an error")
    func prepareIsIdempotent() throws {
        let directory = Self.unusedDirectory()
        try PersistenceLocation.prepare(directory)
        #expect(throws: Never.self) { try PersistenceLocation.prepare(directory) }
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    @Test("A file where the directory should be is refused, not written through")
    func aFileInTheWayIsRefused() throws {
        let directory = Self.unusedDirectory()
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: directory.path, contents: Data("x".utf8))

        #expect(throws: PersistenceLocation.Failure.self) {
            try PersistenceLocation.prepare(directory)
        }
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    // MARK: - The regression

    @Test("The first import into a never-used location is saved without a relaunch")
    func firstImportSurvivesOnAFreshLocation() throws {
        // Left in the temporary directory on purpose: removing a store while
        // its container is still open faults the process, and the container
        // outlives this scope.
        let directory = Self.unusedDirectory()

        // Exactly what launch does, before the container is opened.
        try PersistenceLocation.prepare(directory)

        let container = try Self.container(at: directory)
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 29))
        )
        #expect(store.isEmpty)

        try store.importDocument(Self.document())

        // Read it back through a *second* context on the same store, so this
        // is proving the write reached disk rather than that it is still
        // sitting in the context it was made in.
        let reopened = try FinanceStore(context: ModelContext(container))
        #expect(!reopened.isEmpty)
        #expect(reopened.snapshot.accounts.count == 1)
        #expect(reopened.snapshot.accounts.first?.balance == .eur(384.09))
    }

    @Test("A store that could not be opened refuses imports instead of losing them")
    func anUnavailableStoreSaysSoRatherThanSwallowingAnImport() throws {
        // A container that never opened is the shape a location failure leaves
        // behind. Silently accepting an import here is the failure this whole
        // file exists to prevent.
        let store = try FinanceStore(
            context: nil,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 29)),
            unavailableReason: "Application Support could not be created."
        )

        #expect(store.storeIsUnreadable)
        #expect(!store.canImportCurrentState)
        #expect(store.importBlocker == .storeUnreadable)
        #expect(throws: AppImportError.storeUnreadable) {
            _ = try store.prepareImport(from: Data("{}".utf8))
        }
    }

    @Test("A store that opened normally reports no problem")
    func anOpenedStoreIsNotMarkedUnreadable() throws {
        let directory = Self.unusedDirectory()
        try PersistenceLocation.prepare(directory)

        // The container has to be held: a context whose container has been
        // released faults the moment anything touches it.
        let container = try Self.container(at: directory)
        let store = try FinanceStore(context: container.mainContext)
        #expect(!store.storeIsUnreadable)
        #expect(store.canImportCurrentState)
    }

    // MARK: - The historical archive takes the same path

    @Test("A historical archive imported on a fresh location is saved first time")
    func historicalArchiveSurvivesOnAFreshLocation() throws {
        let directory = Self.unusedDirectory()
        try PersistenceLocation.prepare(directory)

        let container = try Self.container(at: directory)
        let store = try FinanceStore(context: container.mainContext)

        _ = try store.history.prepareImport(data: try HistoryArchiveFixture.data())
        let outcome = try store.history.confirmImport()
        guard case .imported = outcome else {
            Issue.record("the first archive import should install the archive")
            return
        }

        let reopened = try FinanceStore(context: ModelContext(container))
        let metadata = try #require(try reopened.history.metadata())
        #expect(metadata.transactionCount == HistoryArchiveFixture.recordCount)
    }
}
