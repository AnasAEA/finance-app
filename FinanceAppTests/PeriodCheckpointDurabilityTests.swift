import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// Phase 2.9C-C — checkpoint history outlives the document, and stays outside
/// everything it is not part of.
///
/// The load-bearing claim of this phase is that an accepted close is *durable*:
/// every ordinary document write purges and re-inserts the whole
/// `StoredDocumentGraph`, and checkpoint rows must not be in that purge. The
/// proof here uses the real write path — `FinanceStore` → `DocumentWriter.live`
/// → `StoredDocumentGraph.replace` — rather than a stand-in that would only
/// prove a helper does nothing.
///
/// Every store is temporary and synthetic. No real store is opened, copied or
/// written.
@MainActor
@Suite("Checkpoint history survives the document it was closed against")
struct PeriodCheckpointDurabilityTests {

    private typealias Fixture = CheckpointFixtures

    private static let today = Day(year: 2026, month: 9, day: 16)

    /// A directory that does not exist yet, so each store is genuinely new.
    private static func storeURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-durability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("FinanceCore-1.1.store")
    }

    private static func document(
        balanceMinor: Int64 = 38_409,
        accountName: String = "Bank"
    ) -> FinanceDocument {
        let bank = Account(
            id: "bank", name: accountName, currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 0
        )
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [bank],
            balances: [
                AccountBalance(
                    accountID: bank.id,
                    balance: Money(minorUnits: balanceMinor, currency: .eur),
                    asOf: today
                )
            ]
        )
    }

    /// Everything about a stored revision that a lossy or replaced row would
    /// change, captured as plain values so the comparison is not against a
    /// live object the store could have mutated underneath it.
    private struct Snapshot: Equatable {
        let id: UUID
        let periodStart: Day
        let periodEnd: Day
        let kind: ReviewPeriodKind
        let revisionNumber: Int64
        let predecessorID: UUID?
        let closedAt: Date
        let quality: PeriodCheckpointQuality
        let formatToken: String
        let digest: [UInt8]
        let canonicalBytes: [UInt8]
        let safeClaims: PeriodCheckpointSafeClaims
        let exceptions: [PeriodCheckpointException]

        init(_ revision: PeriodCheckpointRevision) {
            id = revision.id
            periodStart = revision.period.start
            periodEnd = revision.period.end
            kind = revision.periodKind
            revisionNumber = revision.revisionNumber
            predecessorID = revision.predecessorID
            closedAt = revision.closedAt
            quality = revision.quality
            formatToken = revision.projectionFormatVersion.token
            digest = revision.projectionDigest.bytes
            canonicalBytes = revision.canonicalProjection.bytes
            safeClaims = revision.safeClaims
            exceptions = revision.acknowledgedExceptions.map(\.exception)
        }
    }

    private static func snapshot(
        _ repository: PeriodCheckpointRepository
    ) throws -> Snapshot {
        let read = repository.latestRevision(inPeriod: Fixture.august, kind: .monthly)
        guard case let .supported(revision) = read else {
            Issue.record("the stored revision should still be readable, got \(read)")
            throw Failure.checkpointLost
        }
        return Snapshot(revision)
    }

    private enum Failure: Error { case checkpointLost }

    @Test("Repository beforeSave failure rolls back dataset, revision and whole acknowledgment rows")
    func repositoryFailureRollsBackTheWholeCheckpoint() throws {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = PeriodCheckpointRepository(context: container.mainContext)
        let revision = try Fixture.revision(exceptions: Fixture.exceptions)
        #expect(!revision.acknowledgedExceptions.isEmpty)
        enum Probe: Error { case beforeSave }
        do {
            try repository.store(revision, beforeSave: { throw Probe.beforeSave })
            Issue.record("expected repository persistence failure")
        } catch let error as PeriodCheckpointStoreError {
            guard case let .persistenceFailed(reason) = error else {
                Issue.record("expected persistenceFailed, got \(error)")
                return
            }
            #expect(reason.contains("Probe"))
        }
        let reopened = ModelContext(container)
        #expect(try reopened.fetchCount(FetchDescriptor<StoredPeriodCheckpointDataset>()) == 0)
        #expect(try reopened.fetchCount(FetchDescriptor<StoredPeriodCheckpointRevision>()) == 0)
        #expect(try reopened.fetchCount(FetchDescriptor<StoredPeriodCheckpointAcknowledgment>()) == 0)
        // A failed first append leaves no hidden dataset or chain occupancy.
        #expect(try repository.store(revision) == .stored)
        #expect(try reopened.fetchCount(FetchDescriptor<StoredPeriodCheckpointDataset>()) == 1)
        #expect(try reopened.fetchCount(FetchDescriptor<StoredPeriodCheckpointRevision>()) == 1)
        #expect(try reopened.fetchCount(FetchDescriptor<StoredPeriodCheckpointAcknowledgment>())
            == revision.acknowledgedExceptions.count)
    }

    // MARK: - The purge

    @Test("Two ordinary document saves leave the stored revision byte-identical")
    func checkpointHistorySurvivesOrdinaryDocumentWrites() throws {
        let url = try Self.storeURL()
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(url: url)
        )
        let store = try FinanceStore(
            context: container.mainContext, now: fixtureInstant(Self.today)
        )

        // 1. An ordinary document, written the way the app writes one.
        try store.importDocument(Self.document())
        #expect(try store.exportDocument().accounts.count == 1)

        // 2. A closed period beside it.
        let revisionID = UUID()
        try store.checkpoints.store(
            try Fixture.revision(id: revisionID, exceptions: Fixture.exceptions)
        )
        let original = try Self.snapshot(store.checkpoints)
        #expect(original.id == revisionID)
        #expect(original.exceptions == Fixture.exceptions)

        // 3. An unrelated ordinary mutation — a real entry through the real
        //    writer, which purges and re-inserts the whole document graph.
        try store.add(
            TransactionDraft(
                day: CalendarDay(year: 2026, month: 9, day: 16),
                kind: .expense,
                amount: .eur(12.34),
                accountID: "bank",
                categoryKey: "food",
                merchant: "Synthetic"
            )
        )
        #expect(try store.exportDocument().transactions.count == 1)
        #expect(try Self.snapshot(store.checkpoints) == original)

        // 4. A second unrelated ordinary save, this one a wholesale replace.
        try store.importDocument(Self.document(balanceMinor: 11_111, accountName: "Renamed"))
        #expect(try store.exportDocument().transactions.isEmpty)
        #expect(try Self.snapshot(store.checkpoints) == original)

        // 5. And it is on disk, not only in a context that remembers it: a
        //    fresh repository on a fresh context reads the same bytes.
        let reread = try Self.snapshot(
            PeriodCheckpointRepository(context: ModelContext(container))
        )
        #expect(reread == original)
        #expect(reread.canonicalBytes == original.canonicalBytes)
        #expect(reread.digest == original.digest)
    }

    @Test("The checkpoint models are absent from the document purge")
    func checkpointModelsAreNotPurged() throws {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let repository = PeriodCheckpointRepository(context: context)
        try repository.store(try Fixture.revision(exceptions: Fixture.exceptions))

        let before = try context.fetch(FetchDescriptor<StoredPeriodCheckpointRevision>()).count
        let acknowledgmentsBefore = try context
            .fetch(FetchDescriptor<StoredPeriodCheckpointAcknowledgment>()).count

        // The production purge, called directly, twice.
        try StoredDocumentGraph.replace(with: Self.document(), in: context, writtenOn: Self.today)
        try StoredDocumentGraph.replace(
            with: Self.document(balanceMinor: 1), in: context, writtenOn: Self.today
        )

        #expect(try context.fetch(FetchDescriptor<StoredPeriodCheckpointDataset>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<StoredPeriodCheckpointRevision>()).count == before)
        #expect(
            try context.fetch(FetchDescriptor<StoredPeriodCheckpointAcknowledgment>()).count
                == acknowledgmentsBefore
        )
    }

    // MARK: - Coexistence with the private archive

    @Test("Document, archive and checkpoint history coexist without touching each other")
    func documentArchiveAndCheckpointCoexist() throws {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = try FinanceStore(
            context: container.mainContext, now: fixtureInstant(Self.today)
        )
        try store.importDocument(Self.document())
        _ = try store.history.prepareImport(data: try HistoryArchiveFixture.data())
        guard case .imported = try store.history.confirmImport() else {
            Issue.record("the archive fixture should install")
            return
        }
        let archiveBefore = try #require(try store.history.metadata())

        // A checkpoint write erases neither the archive nor the document.
        try store.checkpoints.store(try Fixture.revision())
        #expect(try store.history.metadata()?.contentSHA256 == archiveBefore.contentSHA256)
        #expect(try store.history.metadata()?.transactionCount == archiveBefore.transactionCount)
        #expect(try store.exportDocument().balances.first?.balance == Money(minorUnits: 38_409, currency: .eur))

        // An ordinary document replace erases neither the archive nor the
        // checkpoint.
        try store.importDocument(Self.document(balanceMinor: 22_222))
        #expect(try store.history.metadata()?.contentSHA256 == archiveBefore.contentSHA256)
        #expect(try store.history.metadata()?.transactionCount == archiveBefore.transactionCount)
        #expect(store.checkpoints.occupancy() == .holdsCheckpointHistory)
        guard case .supported = store.checkpoints.latestRevision(
            inPeriod: Fixture.august, kind: .monthly
        ) else {
            Issue.record("the stored revision should survive a document replace")
            return
        }
        #expect(try store.exportDocument().balances.first?.balance == Money(minorUnits: 22_222, currency: .eur))
    }

    // MARK: - Emptiness and import safety

    @Test("A fresh store is empty and importable")
    func freshStoreIsImportable() throws {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = try FinanceStore(
            context: container.mainContext, now: fixtureInstant(Self.today)
        )
        #expect(store.isEmpty)
        #expect(store.importBlocker == nil)
        #expect(store.canImportCurrentState)
    }

    @Test("A store holding a document is non-empty, exactly as before")
    func documentBearingStoreIsUnchanged() throws {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = try FinanceStore(
            context: container.mainContext, now: fixtureInstant(Self.today)
        )
        try store.importDocument(Self.document())
        #expect(!store.isEmpty)
        #expect(store.importBlocker == .storeNotEmpty)
    }

    @Test("Checkpoint history in an emptied store blocks an import of other money")
    func checkpointHistoryBlocksImport() throws {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let store = try FinanceStore(
            context: container.mainContext, now: fixtureInstant(Self.today)
        )
        #expect(store.isEmpty)

        try store.checkpoints.store(try Fixture.revision())

        // The document is still empty; the closes of the dataset it belonged
        // to are not. Importing somebody else's export here would attach one
        // dataset's accepted closes to another dataset's money.
        #expect(!store.isEmpty)
        #expect(store.importBlocker == .storeNotEmpty)
        #expect(!store.canImportCurrentState)
        #expect(throws: AppImportError.storeNotEmpty) {
            _ = try store.prepareImport(from: Data("{}".utf8))
        }
    }

    @Test("Checkpoint metadata that cannot be read fails closed, and is not emptiness")
    func corruptCheckpointMetadataFailsClosed() throws {
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        // An orphan revision with no dataset identity, written before the store
        // opens so its repository reads the corrupt state from scratch.
        let revision = try Fixture.revision()
        container.mainContext.insert(
            try StoredPeriodCheckpointRevision(revision, datasetIdentifier: UUID().uuidString)
        )
        try container.mainContext.save()

        let store = try FinanceStore(
            context: container.mainContext, now: fixtureInstant(Self.today)
        )
        #expect(!store.isEmpty)
        #expect(store.importBlocker == .storeUnreadable)
        #expect(throws: AppImportError.storeUnreadable) {
            _ = try store.prepareImport(from: Data("{}".utf8))
        }
    }

    // MARK: - Opening a store written before this phase

    @Test("A store written without the checkpoint models opens, and reads empty")
    func preCheckpointStoreOpens() throws {
        let url = try Self.storeURL()
        let checkpointModels = Set([
            ObjectIdentifier(StoredPeriodCheckpointDataset.self),
            ObjectIdentifier(StoredPeriodCheckpointRevision.self),
            ObjectIdentifier(StoredPeriodCheckpointAcknowledgment.self)
        ])
        // The schema exactly as it stood before this phase: everything the app
        // already had, and none of what it gained.
        let legacyModels = FinanceSchema.models.filter {
            !checkpointModels.contains(ObjectIdentifier($0))
        }
        #expect(legacyModels.count == FinanceSchema.models.count - 3)

        // Written and closed under the old schema. The container is released
        // with the scope so the reopen below is a genuine second open.
        do {
            let legacy = try ModelContainer(
                for: Schema(legacyModels),
                configurations: ModelConfiguration(url: url)
            )
            try StoredDocumentGraph.replace(
                with: Self.document(), in: legacy.mainContext, writtenOn: Self.today
            )
        }

        let current = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(url: url)
        )

        // The ledger still reads.
        let loaded = try #require(try StoredDocumentGraph.load(from: current.mainContext))
        #expect(loaded.accounts.map(\.id) == ["bank"])
        #expect(loaded.balances.first?.balance == Money(minorUnits: 38_409, currency: .eur))

        // The new subgraph is empty rather than absent, unreadable or corrupt.
        let repository = PeriodCheckpointRepository(context: current.mainContext)
        #expect(repository.occupancy() == .empty)
        guard case .empty = repository.latestRevision(inPeriod: Fixture.august, kind: .monthly)
        else { Issue.record("a pre-checkpoint store has no revisions"); return }

        let store = try FinanceStore(
            context: current.mainContext, now: fixtureInstant(Self.today)
        )
        #expect(!store.isEmpty)
        #expect(store.importBlocker == .storeNotEmpty)

        // And the migrated store can then take its first close.
        #expect(try repository.store(try Fixture.revision()) == .stored)
        guard case .supported = repository.latestRevision(inPeriod: Fixture.august, kind: .monthly)
        else { Issue.record("the first close should read back"); return }
    }

    @Test("A fresh install has no checkpoint rows at all")
    func freshInstallHasNoCheckpointRows() throws {
        let url = try Self.storeURL()
        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(url: url)
        )
        let context = container.mainContext
        #expect(try context.fetch(FetchDescriptor<StoredPeriodCheckpointDataset>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<StoredPeriodCheckpointRevision>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<StoredPeriodCheckpointAcknowledgment>()).isEmpty)

        let store = try FinanceStore(context: context, now: fixtureInstant(Self.today))
        #expect(store.isEmpty)
        #expect(store.checkpoints.occupancy() == .empty)
    }
}

// MARK: - The boundaries this phase must not cross

/// Source-level audits of what Phase 2.9C-C is *not*.
///
/// Each one holds a boundary the phase brief names. They read the shipped
/// source rather than a summary of it, because the failure they guard against
/// is somebody wiring the repository into a screen or a close action and the
/// behavioural tests still passing.
@Suite("Checkpoint persistence stays a storage primitive")
struct PeriodCheckpointBoundaryTests {

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)   // …/FinanceAppTests/PeriodCheckpointDurabilityTests.swift
            .deletingLastPathComponent()  // …/FinanceAppTests
            .deletingLastPathComponent()  // …/finance-app
            .appendingPathComponent("FinanceApp")
    }

    private static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Source with its line comments removed.
    ///
    /// These audits ask what the code *does*, and this file explains at length
    /// what it deliberately does not call. Matching prose would make the
    /// explanation the violation.
    private static func code(_ relativePath: String) throws -> String {
        try source(relativePath)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    private static func swiftSources(under layers: [String]) throws -> [(path: String, text: String)] {
        let manager = FileManager.default
        var found: [(String, String)] = []
        for layer in layers {
            let directory = sourceRoot.appendingPathComponent(layer)
            guard let enumerator = manager.enumerator(atPath: directory.path) else { continue }
            for case let relative as String in enumerator where relative.hasSuffix(".swift") {
                found.append((
                    "\(layer)/\(relative)",
                    try String(
                        contentsOf: directory.appendingPathComponent(relative), encoding: .utf8
                    )
                ))
            }
        }
        return found
    }

    @Test("The writer takes a revision and never constructs one")
    func theWriterNeverConstructsARevision() throws {
        let repository = try Self.code("Persistence/PeriodCheckpointRepository.swift")

        // The rehydration initializer is a read path. Between the start of the
        // write primitive and the first read primitive there must be no call to
        // it: the writer stores what it is given.
        let writeStart = try #require(repository.range(of: "func store("))
        let writeEnd = try #require(repository.range(of: "func revisions("))
        let writePath = repository[writeStart.lowerBound..<writeEnd.lowerBound]
        #expect(!writePath.contains("rehydratingStoredSnapshot"))

        // And it is used exactly once in the whole file, on the read side.
        #expect(repository.components(separatedBy: "rehydratingStoredSnapshot(").count - 1 <= 1)

        // Storage never replays the engine, the evaluator or a review.
        for forbidden in [
            "PeriodCheckpointEvaluator", "ReviewEngine", "ReviewTotals",
            "ReviewResult", "PeriodCheckpointReadiness", "PeriodCheckpointBaselineComparator"
        ] {
            #expect(!repository.contains(forbidden), "\(forbidden) has no business in storage")
        }
        let models = try Self.code("Persistence/CheckpointPersistedModels.swift")
        for forbidden in ["ReviewEngine", "ReviewTotals", "ReviewResult", "PeriodCheckpointEvaluator"] {
            #expect(!models.contains(forbidden))
        }
    }

    /// Phase 2.9C-D wires baseline *reads*. Storage types stay below the
    /// boundary it wires them through.
    @Test("Checkpoint storage stays below the mapper boundary")
    func checkpointStorageStaysBelowTheMapperBoundary() throws {
        // Screens and surface code see a comparison, never a stored row, a
        // repository or a canonical payload.
        var offenders: [String] = []
        for file in try Self.swiftSources(under: ["App", "Components", "Features", "Surface"]) {
            for forbidden in [
                "PeriodCheckpointRepository", "StoredPeriodCheckpoint",
                "PeriodCheckpointStoredRead", "PeriodCheckpointStoredHeader",
                "CanonicalSemanticPeriodProjection", "PeriodCheckpointRevision"
            ] where file.text.contains(forbidden) {
                offenders.append("\(file.path): \(forbidden)")
            }
        }
        #expect(offenders.isEmpty, "these files consume checkpoint storage: \(offenders)")

        // The attention layer is pure and owns no store: it receives an
        // already-read baseline source and never reaches for persistence.
        // Read comment-free, because these files explain at length what they
        // deliberately do not touch.
        for file in try Self.swiftSources(under: ["Attention"]) {
            let code = try Self.code(file.path)
            for forbidden in [
                "PeriodCheckpointRepository", "StoredPeriodCheckpoint",
                "PeriodCheckpointStoredRead", "PeriodCheckpointStoredHeader",
                "ModelContext", "SwiftData"
            ] where code.contains(forbidden) {
                offenders.append("\(file.path): \(forbidden)")
            }
        }
        #expect(offenders.isEmpty, "the attention layer reached into storage: \(offenders)")

        // The presentation mappers read readiness, never rows.
        for mapper in [
            "Persistence/AttentionPresentationMapper.swift",
            "Persistence/PeriodVerificationMapper.swift",
            "Persistence/ReviewPresentationMapper.swift",
            "Persistence/ReviewRequestBuilder.swift"
        ] {
            let text = try Self.code(mapper)
            #expect(!text.contains("PeriodCheckpointRepository"))
            #expect(!text.contains("StoredPeriodCheckpoint"))
            #expect(!text.contains("PeriodCheckpointStoredRead"))
        }
    }

    /// The D read path is observational. The one production checkpoint store
    /// caller is the named writer; the storage primitive itself is still the
    /// only other file that may mention `store`.
    @Test("No production path rehydrates or compare-and-appends checkpoint history")
    func noProductionPathWritesACheckpoint() throws {
        let approvedStoreCaller = "Persistence/EndedMonthCheckpointWriter.swift"
        let storagePrimitive = "Persistence/PeriodCheckpointRepository.swift"
        let neverInProduction = ["rehydratingStoredSnapshot", "compareAndAppend"]
        var offenders: [String] = []
        for file in try Self.swiftSources(under: [
            "App", "Components", "Features", "Surface", "Attention", "Persistence"
        ]) where file.path != storagePrimitive {
            let code = try Self.code(file.path)
            for forbidden in neverInProduction where code.contains(forbidden) {
                offenders.append("\(file.path): \(forbidden)")
            }
        }
        #expect(offenders.isEmpty, "a production path writes checkpoint history: \(offenders)")
        // The single-authorized-writer guard itself lives once, in
        // EndedMonthCheckpointWriteTests ("W22"); this case owns the scan above.
    }

    /// The B guardrail, held from outside the type that states it.
    ///
    /// `PeriodCheckpointCurrentState(_ payload:)` trusts the caller's claim
    /// that a projection is comparable. Production must reach it only through
    /// the readiness initializer, where blockers win — otherwise insufficient
    /// current coverage would read as `changedSinceClose` instead of
    /// `indeterminate`.
    @Test("The current side of a comparison comes from readiness")
    func currentComparisonStateComesFromReadiness() throws {
        let reader = try Self.code("Persistence/PeriodCheckpointBaselineReader.swift")
        #expect(reader.contains("PeriodCheckpointCurrentState(readiness)"))
        #expect(reader.components(separatedBy: "PeriodCheckpointCurrentState(").count - 1 == 1)

        // And nowhere else in the product constructs one at all.
        var offenders: [String] = []
        for file in try Self.swiftSources(under: [
            "App", "Components", "Features", "Surface", "Attention", "Persistence"
        ]) where file.path != "Persistence/PeriodCheckpointBaselineReader.swift" {
            if try Self.code(file.path).contains("PeriodCheckpointCurrentState(") {
                offenders.append(file.path)
            }
        }
        #expect(offenders.isEmpty, "a second current-state construction exists: \(offenders)")

        // Comparison rules are B's. The product transports the answer.
        for forbidden in [
            "ReviewTotals", "ReviewEngine", ".totals",
            "coverageChanged", "economicsChanged", "evidenceChanged",
            "unchangedSinceClose", "changedSinceClose"
        ] {
            #expect(!reader.contains(forbidden), "\(forbidden) has no business in the reader")
        }
    }

    /// The placeholder the phase replaced.
    ///
    /// `notImplementedInThisBuild` remains a term in the source-failure
    /// vocabulary; what must not remain is a production source injecting it,
    /// because checkpoint persistence *is* implemented in this build.
    @Test("No production source claims the checkpoint baseline is unimplemented")
    func noBaselinePlaceholderRemainsInProduction() throws {
        var offenders: [String] = []
        for file in try Self.swiftSources(under: [
            "App", "Components", "Features", "Surface", "Attention", "Persistence"
        ]) where file.path != "Attention/AttentionModel.swift" {
            if try Self.code(file.path).contains("notImplementedInThisBuild") {
                offenders.append(file.path)
            }
        }
        #expect(offenders.isEmpty, "a production placeholder baseline survives: \(offenders)")

        // The one permitted occurrence is the vocabulary case itself.
        let model = try Self.code("Attention/AttentionModel.swift")
        #expect(model.contains("case notImplementedInThisBuild"))
        #expect(model.components(separatedBy: "notImplementedInThisBuild").count - 1 == 1)
    }

    @Test("No layer grows its own close, re-verify or compare-and-append API")
    func noCloseOrReverifyAction() throws {
        var offenders: [String] = []
        for file in try Self.swiftSources(under: [
            "App", "Components", "Features", "Surface", "Attention", "Persistence"
        ]) {
            for forbidden in [
                "func closePeriod", "func closeCheckpoint", "func closeMonth",
                "func reverify", "func reVerify", "func compareAndAppend",
                "func acknowledgeAndClose"
            ] where file.text.contains(forbidden) {
                offenders.append("\(file.path): \(forbidden)")
            }
        }
        #expect(offenders.isEmpty, "a close/re-verify action exists: \(offenders)")
    }

    @Test("No checkpoint field enters the document or the interchange")
    func checkpointHistoryIsLocalOnly() throws {
        // The persistence boundary's document side.
        let mapper = try Self.code("Persistence/DomainMapper.swift")
        #expect(!mapper.contains("Checkpoint"))
        let importer = try Self.code("Persistence/DocumentImporter.swift")
        #expect(!importer.contains("Checkpoint"))

        // The document graph knows the models exist only to register them, and
        // its purge does not name them.
        let models = try Self.code("Persistence/PersistedModels.swift")
        let purgeStart = try #require(models.range(of: "private static func purge(from context"))
        let purgeEnd = try #require(models.range(of: "enum FinanceSchema"))
        let purge = models[purgeStart.lowerBound..<purgeEnd.lowerBound]
        for model in [
            "StoredPeriodCheckpointDataset",
            "StoredPeriodCheckpointRevision",
            "StoredPeriodCheckpointAcknowledgment"
        ] {
            #expect(!purge.contains(model), "\(model) must not be purged with the document")
            #expect(models.contains("\(model).self"), "\(model) must be registered in the schema")
        }

        // No interchange version moved.
        #expect(Interchange.currentSchemaVersion == "1.6.0")
        #expect(PersistedSchema.supported == Interchange.readableSchemaVersions.sorted())
    }

    /// The complete, ordered inventory of what a checkpoint row holds.
    ///
    /// Pinned exhaustively rather than by forbidden-substring search, because
    /// the interesting failure is a field nobody meant to persist arriving
    /// quietly. Adding one is then a deliberate act with a diff here beside it.
    /// Absent by construction and by this list: disposition, `ReviewResult`,
    /// `ReviewTotals`, findings, blockers, sync and transport timestamps,
    /// merchant, counterparty, IBAN and remittance text, and formatted money.
    private static let storedFields = [
        // StoredPeriodCheckpointDataset
        "identifier", "establishedAt",
        // StoredPeriodCheckpointRevision
        "identifier", "datasetIdentifier",
        "periodStartDay", "periodEndDay", "periodKindRaw",
        "revisionNumber", "predecessorIdentifier", "closedAt",
        "qualityRaw", "projectionFormatToken", "projectionDigest", "canonicalProjection",
        "safeClaimMayShowCalculatedTotals", "safeClaimUnquestionablyCompleteTotals",
        "safeClaimCompleteCategoryAttribution", "safeClaimCompleteEvidenceAudit",
        "acknowledgmentCount", "acknowledgmentDigest",
        // StoredPeriodCheckpointAcknowledgment
        "revisionIdentifier", "exceptionIdentifier", "kindRaw", "aggregateBasisRaw",
        "day", "amountMinor", "amountCurrencyCode", "amountCurrencyExponent", "sequence"
    ]

    @Test("Checkpoint rows hold exactly the snapshot, and nothing else")
    func storedRowsCarryOnlySemantics() throws {
        let models = try Self.code("Persistence/CheckpointPersistedModels.swift")
        let declared = models
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("var ") else { return nil }
                return String(
                    trimmed.dropFirst(4).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                )
            }
        #expect(declared == Self.storedFields)

        // Money is stored as its parts. No formatted string, and no synthesized
        // Codable blob hiding a domain schema inside an opaque column.
        #expect(!models.contains("Codable"))
        #expect(!models.contains("PersistenceCoding.encode"))
    }
}
