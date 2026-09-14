import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// Ended-month checkpoint write action.
///
/// The production path is `FinanceStore.writeEndedMonthCheckpoint` →
/// `EndedMonthCheckpointWriter` → `PeriodCheckpointRepository.store`. These
/// tests pin that sequence, the single-tip observation, and the fail-closed
/// cases around it. Fixtures are synthetic; no real store is opened.
@MainActor
@Suite("Ended-month checkpoint write action")
struct EndedMonthCheckpointWriteTests {

    private static let asOf = Day(year: 2026, month: 9, day: 3)
    private static let august = ReviewInterval.month(MonthKey(year: 2026, month: 8))
    private static let selection = ReviewPeriodSelection(scope: .month, offset: -1)
    private static let closedAt = Date(timeIntervalSinceReferenceDate: 820_000_000)

    /// SHA-256 of `FinanceApp/Persistence/PeriodCheckpointRepository.swift` at
    /// authorization `6fb626c`. W20 fails if that file moves.

    // MARK: - Documents

    private static func euro(_ minor: Int64) -> Money {
        Money(minorUnits: minor, currency: .eur)
    }

    /// Clean ended August: covered, no checkpoint exceptions.
    private static func cleanDocument(incomeMinor: Int64 = 2_000) -> FinanceDocument {
        let bank = Account(
            id: "bank", name: "Current", currency: .eur, kind: .bank,
            supportedRails: PaymentRail.euroBankRails, drawOrder: 0
        )
        var document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [bank],
            balances: [
                AccountBalance(accountID: "bank", balance: euro(44_747), asOf: Day(year: 2026, month: 8, day: 1))
            ]
        )
        document.transactions = [
            Transaction(
                id: "tx-august",
                date: Day(year: 2026, month: 8, day: 5),
                kind: .income,
                legs: [AccountLeg(accountID: "bank", amount: euro(incomeMinor))],
                factivity: .observed
            )
        ]
        document.externalAccountBindings = [
            ExternalAccountBinding(
                id: "binding", provider: .bnp,
                remoteOpaqueAccountID: "synthetic-remote", localAccountID: "bank",
                syncStartBoundary: Day(year: 2026, month: 1, day: 1),
                createdAt: Date(timeIntervalSince1970: 0)
            )
        ]
        document.externalObservations = [
            ExternalObservation(
                id: "observation", bindingID: "binding", provider: .bnp,
                identity: .durable, status: .booked, creditDebitIndicator: .debit,
                amount: euro(-2_000), bookingDate: Day(year: 2026, month: 8, day: 15),
                eligibleForEconomicActual: true,
                observedAt: Date(timeIntervalSince1970: 1_000)
            )
        ]
        document.observationResolutions = [
            ExternalObservationResolution(observationID: "observation", state: .noEconomicEffect)
        ]
        return document
    }

    /// Exception-bearing ended August: one unreviewed booked observation.
    private static func exceptionDocument(
        amountMinor: Int64 = -2_000,
        resolution: ObservationResolutionState = .unreviewed
    ) -> FinanceDocument {
        var document = cleanDocument()
        document.transactions = []
        document.externalObservations = [
            ExternalObservation(
                id: "observation", bindingID: "binding", provider: .bnp,
                identity: .durable, status: .booked, creditDebitIndicator: .debit,
                amount: euro(amountMinor), bookingDate: Day(year: 2026, month: 8, day: 15),
                eligibleForEconomicActual: true,
                observedAt: Date(timeIntervalSince1970: 1_000)
            )
        ]
        document.observationResolutions = [
            ExternalObservationResolution(observationID: "observation", state: resolution)
        ]
        return document
    }

    private static func coverageMetadata() -> AppPersistenceMetadata {
        var metadata = AppPersistenceMetadata.empty
        metadata.authoritativeLiveCoverage = [
            "synthetic-remote": AuthoritativeLiveCoverage(
                provider: .bnp,
                remoteOpaqueAccountID: "synthetic-remote",
                localAccountID: "bank",
                syncedFrom: Day(year: 2026, month: 8, day: 1),
                syncedThrough: asOf,
                authoritativeAt: Date(timeIntervalSince1970: 1_788_000_000)
            )
        ]
        return metadata
    }

    // MARK: - Harness

    @MainActor
    private struct Harness {
        let container: ModelContainer
        let store: FinanceStore
        let coverage: Bool

        init(
            document: FinanceDocument,
            coverage: Bool = true,
            unavailableReason: String? = nil
        ) throws {
            container = try ModelContainer(
                for: Schema(FinanceSchema.models),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            self.coverage = coverage
            try StoredDocumentGraph.replace(
                with: document,
                in: container.mainContext,
                writtenOn: asOf,
                appMetadata: coverage ? coverageMetadata() : .empty
            )
            store = try FinanceStore(
                context: container.mainContext,
                now: fixtureInstant(asOf),
                unavailableReason: unavailableReason
            )
        }

        var selection: ReviewPeriodSelection { EndedMonthCheckpointWriteTests.selection }

        func reopen() throws -> FinanceStore {
            try FinanceStore(context: container.mainContext, now: fixtureInstant(asOf))
        }

        func replace(_ document: FinanceDocument) throws {
            try StoredDocumentGraph.replace(
                with: document,
                in: container.mainContext,
                writtenOn: asOf,
                appMetadata: coverage ? coverageMetadata() : .empty
            )
        }

        func revisionRows() throws -> [StoredPeriodCheckpointRevision] {
            try container.mainContext.fetch(FetchDescriptor<StoredPeriodCheckpointRevision>())
        }

        func acknowledgmentRows() throws -> [StoredPeriodCheckpointAcknowledgment] {
            try container.mainContext.fetch(FetchDescriptor<StoredPeriodCheckpointAcknowledgment>())
        }

        func latestSupported() throws -> PeriodCheckpointRevision {
            let read = store.checkpoints.latestRevision(
                inPeriod: SemanticInterval(august), kind: .monthly
            )
            guard case let .supported(revision) = read else {
                Issue.record("expected a supported tip, got \(read)")
                throw Failure.expectedSupportedTip
            }
            return revision
        }
    }

    private enum Failure: Error {
        case expectedSupportedTip
    }

    private final class CallCounter {
        private(set) var count = 0
        func uuid() -> UUID {
            count += 1
            return UUID()
        }
        func instant() -> Date {
            count += 1
            return Date(timeIntervalSinceReferenceDate: 820_000_000)
        }
    }

    private func confirmAll(_ store: FinanceStore) throws -> PeriodCheckpointConfirmedAcknowledgments {
        let verification = try #require(store.endedMonthVerification(Self.selection))
        return try PeriodCheckpointAcknowledgmentConfirmation.confirm(
            decisions: verification.readiness.exceptions,
            carriedExceptions: verification.readiness.exceptions
        )
    }

    private func readyCleanReadiness(
        tip: PeriodCheckpointStoredRead = .empty
    ) throws -> PeriodCheckpointReadiness {
        let document = Self.cleanDocument()
        let review = try ReviewEngine.review(
            ReviewRequest(
                document: document,
                kind: .monthly,
                interval: Self.august,
                asOf: Self.asOf,
                coverage: .liveCovered([Self.august])
            )
        )
        return AttentionComposition.readiness(
            for: AttentionComposition.Input(
                document: document,
                asOf: Self.asOf,
                review: review,
                occurrences: [],
                observations: [],
                categoryKeys: [:],
                checkpointBaseline: PeriodCheckpointBaselineReader.source(for: tip),
                period: Self.august,
                periodKind: .monthly,
                periodLabel: "August 2026"
            )
        )
    }

    // MARK: - W1 clean first close

    @Test("W1: a clean ended month with an empty tip stores revision 1")
    func cleanFirstClose() throws {
        let harness = try Harness(document: Self.cleanDocument())
        let identities = CallCounter()
        let clock = CallCounter()

        let result = harness.store.writeEndedMonthCheckpoint(
            harness.selection,
            makeCandidateIdentity: { identities.uuid() },
            sampleClosedAt: { clock.instant() }
        )

        guard case let .storedFirstClose(revision) = result else {
            Issue.record("expected storedFirstClose, got \(result)")
            return
        }
        #expect(revision.revisionNumber == 1)
        #expect(revision.predecessorID == nil)
        #expect(revision.quality == .clean)
        #expect(revision.acknowledgedExceptions.isEmpty)
        #expect(revision.closedAt == Self.closedAt)
        #expect(identities.count == 1)
        #expect(clock.count == 1)
        #expect(try harness.revisionRows().count == 1)
        #expect(try harness.acknowledgmentRows().isEmpty)
        #expect(try harness.latestSupported().id == revision.id)
    }

    // MARK: - W2 acknowledged first close

    @Test("W2: acknowledged exceptions persist only as the stored revision's rows")
    func acknowledgedFirstClose() throws {
        let harness = try Harness(document: Self.exceptionDocument())
        let confirmed = try confirmAll(harness.store)
        #expect(!confirmed.confirmedAcknowledgmentIDs.isEmpty)

        let result = harness.store.writeEndedMonthCheckpoint(
            harness.selection,
            confirmedAcknowledgments: confirmed
        )

        guard case let .storedFirstClose(revision) = result else {
            Issue.record("expected storedFirstClose, got \(result)")
            return
        }
        let storedSubjects = Set(revision.acknowledgedExceptions.map(\.exception))
        let verification = try #require(harness.store.endedMonthVerification(harness.selection))
        #expect(storedSubjects == Set(verification.readiness.exceptions))
        #expect(storedSubjects.count == confirmed.confirmedAcknowledgmentIDs.count)

        let rows = try harness.acknowledgmentRows()
        #expect(rows.count == storedSubjects.count)
        #expect(Set(rows.map(\.exceptionIdentifier)) == Set(storedSubjects.map(\.id)))
        #expect(try harness.revisionRows().count == 1)
        // No second acknowledgment table besides the repository's own rows.
        #expect(try harness.acknowledgmentRows().count == rows.count)
    }

    // MARK: - W3 reverify

    @Test("W3: a changed supported tip appends n+1 naming the tip")
    func reverifyAppendsAfterTheTip() throws {
        let harness = try Harness(document: Self.cleanDocument(incomeMinor: 2_000))
        guard case let .storedFirstClose(first) = harness.store.writeEndedMonthCheckpoint(harness.selection)
        else {
            Issue.record("first close failed")
            return
        }

        try harness.replace(Self.cleanDocument(incomeMinor: 7_777))
        let reopened = try harness.reopen()
        let result = reopened.writeEndedMonthCheckpoint(Self.selection)

        guard case let .storedReverify(second) = result else {
            Issue.record("expected storedReverify, got \(result)")
            return
        }
        #expect(second.revisionNumber == first.revisionNumber + 1)
        #expect(second.predecessorID == first.id)
        #expect(second.id != first.id)
        #expect(try harness.revisionRows().count == 2)
    }

    // MARK: - W4 already current

    @Test("W4: an unchanged supported tip mints nothing and stores nothing")
    func alreadyCurrentIsANoOp() throws {
        let harness = try Harness(document: Self.cleanDocument())
        guard case .storedFirstClose = harness.store.writeEndedMonthCheckpoint(harness.selection) else {
            Issue.record("first close failed")
            return
        }
        let rowsBefore = try harness.revisionRows().count
        let identities = CallCounter()
        let clock = CallCounter()

        let result = harness.store.writeEndedMonthCheckpoint(
            harness.selection,
            makeCandidateIdentity: { identities.uuid() },
            sampleClosedAt: { clock.instant() }
        )

        #expect(isAlreadyCurrent(result))
        #expect(identities.count == 0)
        #expect(clock.count == 0)
        #expect(try harness.revisionRows().count == rowsBefore)
    }

    // MARK: - W5 blocked

    @Test("W5: blocked readiness is a policy refusal with no identity")
    func blockedIsRefused() throws {
        let harness = try Harness(document: Self.exceptionDocument(), coverage: false)
        let identities = CallCounter()
        let clock = CallCounter()

        let result = harness.store.writeEndedMonthCheckpoint(
            harness.selection,
            makeCandidateIdentity: { identities.uuid() },
            sampleClosedAt: { clock.instant() }
        )

        #expect(refusal(result) == .readinessNotReady)
        #expect(identities.count == 0)
        #expect(clock.count == 0)
        #expect(try harness.revisionRows().isEmpty)
    }

    // MARK: - W6 needs decisions

    @Test("W6: undecided exceptions are refused with no identity")
    func needsDecisionsIsRefused() throws {
        let harness = try Harness(document: Self.exceptionDocument())
        let identities = CallCounter()

        let result = harness.store.writeEndedMonthCheckpoint(
            harness.selection,
            makeCandidateIdentity: { identities.uuid() }
        )

        #expect(refusal(result) == .readinessNotReady)
        #expect(identities.count == 0)
        #expect(try harness.revisionRows().isEmpty)
    }

    // MARK: - W7 stale same-id subject

    @Test("W7: a same-id different subject fails closed before store")
    func staleSameIDSubjectIsRefused() throws {
        let harness = try Harness(document: Self.exceptionDocument(amountMinor: -2_000))
        let confirmed = try confirmAll(harness.store)
        try harness.replace(Self.exceptionDocument(amountMinor: -2_500))
        let reopened = try harness.reopen()
        let identities = CallCounter()

        let result = reopened.writeEndedMonthCheckpoint(
            Self.selection,
            confirmedAcknowledgments: confirmed,
            makeCandidateIdentity: { identities.uuid() }
        )

        #expect(refusal(result) == .readinessNotReady)
        #expect(identities.count == 0)
        #expect(try harness.revisionRows().isEmpty)
    }

    // MARK: - W8 disappeared subject

    @Test("W8: a disappeared confirmed subject fails closed before store")
    func disappearedSubjectIsRefused() throws {
        let harness = try Harness(document: Self.exceptionDocument())
        let confirmed = try confirmAll(harness.store)
        try harness.replace(Self.exceptionDocument(resolution: .noEconomicEffect))
        let reopened = try harness.reopen()
        let identities = CallCounter()

        let result = reopened.writeEndedMonthCheckpoint(
            Self.selection,
            confirmedAcknowledgments: confirmed,
            makeCandidateIdentity: { identities.uuid() }
        )

        #expect(refusal(result) == .readinessNotReady)
        #expect(identities.count == 0)
        #expect(try harness.revisionRows().isEmpty)
    }

    // MARK: - W9 unsupported tip

    @Test("W9: an unsupported tip is refused, never a revision-1 fallback")
    func unsupportedTipIsRefused() throws {
        let harness = try Harness(document: Self.cleanDocument())
        let planted = UUID()
        try harness.store.checkpoints.store(try CheckpointFixtures.revision(id: planted))
        let identifier = planted.uuidString
        let row = try #require(
            try harness.container.mainContext.fetch(
                FetchDescriptor<StoredPeriodCheckpointRevision>(
                    predicate: #Predicate { $0.identifier == identifier }
                )
            ).first
        )
        row.projectionFormatToken = "v2"
        row.canonicalProjection = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try harness.container.mainContext.save()

        let reopened = try harness.reopen()
        let identities = CallCounter()
        let result = reopened.writeEndedMonthCheckpoint(
            Self.selection,
            makeCandidateIdentity: { identities.uuid() }
        )

        #expect(refusal(result) == .previousRevisionFormatUnsupported)
        #expect(identities.count == 0)
        #expect(try harness.revisionRows().count == 1)
        #expect(try harness.revisionRows()[0].revisionNumber == 1)
    }

    // MARK: - W10 corrupt tip

    @Test("W10: a corrupt tip is refused, never treated as absence")
    func corruptTipIsRefused() throws {
        let harness = try Harness(document: Self.cleanDocument())
        let planted = UUID()
        try harness.store.checkpoints.store(try CheckpointFixtures.revision(id: planted))
        let identifier = planted.uuidString
        let row = try #require(
            try harness.container.mainContext.fetch(
                FetchDescriptor<StoredPeriodCheckpointRevision>(
                    predicate: #Predicate { $0.identifier == identifier }
                )
            ).first
        )
        var digest = Array(row.projectionDigest)
        digest[0] ^= 0xFF
        row.projectionDigest = Data(digest)
        try harness.container.mainContext.save()

        let reopened = try harness.reopen()
        let identities = CallCounter()
        let result = reopened.writeEndedMonthCheckpoint(
            Self.selection,
            makeCandidateIdentity: { identities.uuid() }
        )

        #expect(refusal(result) == .previousRevisionCorrupt)
        #expect(identities.count == 0)
        #expect(try harness.revisionRows().count == 1)
    }

    // MARK: - W11 weekly

    @Test("W11: a weekly selection is notWritable and never reaches the writer")
    func weeklySelectionIsNotWritable() throws {
        let harness = try Harness(document: Self.cleanDocument())
        let identities = CallCounter()
        let clock = CallCounter()

        let result = harness.store.writeEndedMonthCheckpoint(
            ReviewPeriodSelection(scope: .week, offset: -1),
            makeCandidateIdentity: { identities.uuid() },
            sampleClosedAt: { clock.instant() }
        )

        #expect(notWritable(result) == .weeklySelection)
        #expect(identities.count == 0)
        #expect(clock.count == 0)
        #expect(try harness.revisionRows().isEmpty)
    }

    // MARK: - W12 current / unended month

    @Test("W12: the current unended month is notWritable")
    func currentMonthIsNotWritable() throws {
        let harness = try Harness(document: Self.cleanDocument())
        let identities = CallCounter()

        let result = harness.store.writeEndedMonthCheckpoint(
            ReviewPeriodSelection(scope: .month, offset: 0),
            makeCandidateIdentity: { identities.uuid() }
        )

        #expect(notWritable(result) == .periodNotEnded)
        #expect(identities.count == 0)
        #expect(try harness.revisionRows().isEmpty)
    }

    // MARK: - W13 double invocation

    @Test("W13: a second immediate call is alreadyCurrent and leaves one revision")
    func doubleInvocationIsIdempotent() throws {
        let harness = try Harness(document: Self.cleanDocument())
        guard case .storedFirstClose = harness.store.writeEndedMonthCheckpoint(harness.selection) else {
            Issue.record("first close failed")
            return
        }
        let second = harness.store.writeEndedMonthCheckpoint(harness.selection)
        #expect(isAlreadyCurrent(second))
        #expect(try harness.revisionRows().count == 1)
    }

    // MARK: - W14 crash retry

    @Test("W14: reopening after a successful store retries to alreadyCurrent")
    func crashRetryIsAlreadyCurrent() throws {
        let harness = try Harness(document: Self.cleanDocument())
        guard case let .storedFirstClose(first) = harness.store.writeEndedMonthCheckpoint(harness.selection)
        else {
            Issue.record("first close failed")
            return
        }
        let reopened = try harness.reopen()
        let retry = reopened.writeEndedMonthCheckpoint(Self.selection)
        #expect(isAlreadyCurrent(retry))
        #expect(try harness.revisionRows().count == 1)
        #expect(try harness.latestSupported().id == first.id)
    }

    // MARK: - W15 materialization failure

    @Test("W15: invalid append metadata refuses construction and stores nothing")
    func materializationFailureStoresNothing() throws {
        let harness = try Harness(document: Self.cleanDocument())
        let identities = CallCounter()
        let result = harness.store.writeEndedMonthCheckpoint(
            harness.selection,
            makeCandidateIdentity: { identities.uuid() },
            sampleClosedAt: { Date(timeIntervalSinceReferenceDate: .nan) }
        )
        #expect(refusal(result) == .revisionConstructionRefused)
        #expect(identities.count == 1)
        #expect(try harness.revisionRows().isEmpty)
    }

    // MARK: - W16 store failures

    @Test("W16: every typed repository error is returned without flattening")
    func typedRepositoryErrorsArePreserved() throws {
        // Persistence failures need no application callback: the same typed
        // catch returns every PeriodCheckpointStoreError unchanged. Behavioral
        // duplicate/predecessor probes below exercise that catch through store.
        let writer = try CheckpointWriteSource.read(CheckpointWriteSource.writerPath)
        #expect(try CheckpointWriteSource.count("""
            catch let error as PeriodCheckpointStoreError { return .storeRefused(error) }
            """, in: writer) == 1)
    }

    @Test("W16: a planted duplicate revision number is a typed refusal, not a retry")
    func plantedDuplicateIsTypedRefusal() throws {
        let harness = try Harness(document: Self.cleanDocument())
        guard case .storedFirstClose = harness.store.writeEndedMonthCheckpoint(harness.selection) else {
            Issue.record("first close failed")
            return
        }
        let ready = try readyCleanReadiness(tip: .empty)
        let identities = CallCounter()
        let result = EndedMonthCheckpointWriter.write(
            readiness: ready,
            chainTip: .empty,
            repository: harness.store.checkpoints,
            makeCandidateIdentity: { identities.uuid() },
            closedAt: { Self.closedAt }
        )
        guard case let .storeRefused(.rejected(rejection)) = result else {
            Issue.record("expected duplicateRevisionNumber, got \(result)")
            return
        }
        #expect(rejection == .duplicateRevisionNumber)
        #expect(identities.count == 1)
        #expect(try harness.revisionRows().count == 1)
    }

    @Test("W16: a planted missing predecessor is a typed refusal, not a retry")
    func plantedMissingPredecessorIsTypedRefusal() throws {
        let harness = try Harness(document: Self.cleanDocument())
        let phantom = try CheckpointFixtures.revision(
            id: UUID(),
            projection: try CheckpointFixtures.projection(spendingMinor: 99)
        )
        let ready = try readyCleanReadiness(tip: .supported(phantom))
        #expect(ready.disposition == .readyClean)

        let result = EndedMonthCheckpointWriter.write(
            readiness: ready,
            chainTip: .supported(phantom),
            repository: harness.store.checkpoints,
            closedAt: { Self.closedAt }
        )
        guard case let .storeRefused(.rejected(rejection)) = result else {
            Issue.record("expected predecessorNotFound, got \(result)")
            return
        }
        #expect(rejection == .predecessorNotFound)
        #expect(try harness.revisionRows().isEmpty)
    }

    // MARK: - W17 same-turn structural pin

    @Test("W17: the writer and FinanceStore action declare no suspension")
    func sameTurnStructuralPin() throws {
        let writer = try CheckpointWriteSource.read(CheckpointWriteSource.writerPath)
        let action = try CheckpointWriteSource.function(
            "writeEndedMonthCheckpoint", in: CheckpointWriteSource.read("Persistence/FinanceStore.swift")
        ).complete
        for source in [writer, action] {
            for forbidden in [
                "await", "async", "Task", "DispatchQueue",
                "withCheckedContinuation", "withUnsafeContinuation",
            ] {
                #expect(!source.contains(forbidden), "same-turn contract contains \(forbidden)")
            }
        }
    }

    // MARK: - W18 zero UI caller

    @Test("W18: Features, Components, Surface and App do not call the writer")
    func zeroUICaller() throws {
        var offenders: [String] = []
        for file in try Self.swiftSources(under: ["App", "Components", "Features", "Surface"]) {
            let code = try Self.code(file.path)
            for forbidden in [
                "EndedMonthCheckpointWriter",
                "EndedMonthCheckpointWriteResult",
                "writeEndedMonthCheckpoint",
            ] where code.contains(forbidden) {
                offenders.append("\(file.path): \(forbidden)")
            }
        }
        #expect(offenders.isEmpty, "UI layers reached the write action: \(offenders)")
    }

    // MARK: - W19 zero E1 caller

    @Test("W19: the writer contains no matcher or carry-forward")
    func zeroE1Caller() throws {
        let writer = try Self.code("Persistence/EndedMonthCheckpointWriter.swift")
        for forbidden in [
            "PeriodCheckpointAcknowledgmentMatcher",
            "carryForwardCandidate",
            "carryForwardCandidates",
        ] {
            #expect(!writer.contains(forbidden), "writer reached \(forbidden)")
        }
    }

    // MARK: - W20 repository blob

    @Test("W20: the repository offers storage only — no close, re-verify or append API")
    func repositoryOffersStorageOnly() throws {
        let repository = try Self.code("Persistence/PeriodCheckpointRepository.swift")
        for forbidden in [
            "func closePeriod", "func reverify", "func reVerify", "func compareAndAppend",
            "func acknowledgeAndClose", "func append(", "func replace(",
        ] {
            #expect(!repository.contains(forbidden), "the repository grew \(forbidden)")
        }
    }

    // MARK: - W21 read-only facade

    @Test("W21: loadFailure refuses before any repository store")
    func loadFailureRefusesBeforeStore() throws {
        let harness = try Harness(
            document: Self.cleanDocument(),
            unavailableReason: "synthetic load failure"
        )
        #expect(harness.store.loadFailure != nil)
        let identities = CallCounter()
        let result = harness.store.writeEndedMonthCheckpoint(
            harness.selection,
            makeCandidateIdentity: { identities.uuid() }
        )
        #expect(notWritable(result) == .storeFailedToLoad)
        #expect(identities.count == 0)
        #expect(try harness.revisionRows().isEmpty)
    }

    @Test("W21: a fixed facade refuses before any repository store")
    func fixedFacadeRefusesBeforeStore() throws {
        let store = FinanceStore(
            snapshot: .empty(asOf: DomainMapper.civilDay(Self.asOf)),
            now: fixtureInstant(Self.asOf)
        )
        let identities = CallCounter()
        let result = store.writeEndedMonthCheckpoint(
            Self.selection,
            makeCandidateIdentity: { identities.uuid() }
        )
        #expect(notWritable(result) == .storeIsReadOnly)
        #expect(identities.count == 0)
    }

    // MARK: - W22 exactly one production store caller

    @Test("W22: only EndedMonthCheckpointWriter.swift is a production checkpoint store caller")
    func exactlyOneProductionStoreCaller() throws {
        let approved = CheckpointWriteSource.writerPath
        #expect(try CheckpointWriteSource.productionStoreCallSites() == [approved])
        let writer = try CheckpointWriteSource.read(approved)
        #expect(try CheckpointWriteSource.count(".store(", in: writer) == 1)
        #expect(try CheckpointWriteSource.count("repository.store(revision)", in: writer) == 1)
        #expect(try CheckpointWriteSource.count("PeriodCheckpointRevision(", in: writer) == 0)
        #expect(!writer.contains("compareAndAppend"))
    }

    // MARK: - W23 unavailable fresh review

    @Test("W23: unavailable fresh review refuses before append metadata or persistence")
    func unavailableReviewRefusesBeforeMetadataOrStore() throws {
        let harness = try Harness(document: Self.cleanDocument())
        var instant = fixtureInstant(Self.asOf)
        let store = try FinanceStore(context: harness.container.mainContext, clock: { instant })
        // Initialization has a valid civil day. The next real operation cannot
        // derive one, so computeReview returns nil for the normal ended month.
        instant = Date(timeIntervalSinceReferenceDate: .nan)
        #expect(store.endedMonthVerification(Self.selection) == nil)
        let identities = CallCounter()
        let appendClock = CallCounter()
        let result = store.writeEndedMonthCheckpoint(
            Self.selection,
            makeCandidateIdentity: { identities.uuid() },
            sampleClosedAt: { appendClock.instant() }
        )
        #expect(notWritable(result) == .reviewUnavailable)
        #expect(identities.count == 0)
        #expect(appendClock.count == 0)
        #expect(try harness.revisionRows().isEmpty)
        #expect(try harness.acknowledgmentRows().isEmpty)
        #expect(try harness.container.mainContext.fetchCount(
            FetchDescriptor<StoredPeriodCheckpointDataset>()
        ) == 0)
    }

    // MARK: - Independent-review regression boundaries

    @Test("B1/F1: the complete application signature has only semantic inputs and metadata providers")
    func applicationSignatureIsPinned() throws {
        let action = try CheckpointWriteSource.function(
            "writeEndedMonthCheckpoint", in: CheckpointWriteSource.read("Persistence/FinanceStore.swift")
        )
        #expect(action.signature == (try CheckpointWriteSource.tokens("""
            func writeEndedMonthCheckpoint(
                _ selection: ReviewPeriodSelection,
                confirmedAcknowledgments: PeriodCheckpointConfirmedAcknowledgments = .noDecisions,
                makeCandidateIdentity: @escaping () -> UUID = UUID.init,
                sampleClosedAt: (() -> Date)? = nil
            ) -> EndedMonthCheckpointWriteResult
            """)))
        for forbidden in ["beforeSave", "preSave", "willSave", "saveHook"] {
            #expect(!action.complete.contains(forbidden))
        }
    }

    @Test("B1: writer APIs admit metadata providers and no pre-save callback")
    func writerSignaturesExcludePreSaveCallbacks() throws {
        let writer = try CheckpointWriteSource.read(CheckpointWriteSource.writerPath)
        let write = try CheckpointWriteSource.function("write", in: writer)
        let persist = try CheckpointWriteSource.function("persist", in: writer)
        #expect(write.signature == (try CheckpointWriteSource.tokens("""
            func write(
                readiness: PeriodCheckpointReadiness,
                chainTip: PeriodCheckpointStoredRead,
                repository: PeriodCheckpointRepository,
                makeCandidateIdentity: () -> UUID = UUID.init,
                closedAt: () -> Date
            ) -> EndedMonthCheckpointWriteResult
            """)))
        #expect(persist.signature == (try CheckpointWriteSource.tokens("""
            func persist(
                _ plan: CheckpointClosePolicy.AppendPlan,
                as operation: PersistAs,
                repository: PeriodCheckpointRepository,
                makeCandidateIdentity: () -> UUID,
                closedAt: () -> Date
            ) -> EndedMonthCheckpointWriteResult
            """)))
        #expect(writer.filter { $0 == "func" }.count == 2)
        for forbidden in ["beforeSave", "preSave", "willSave", "saveHook"] {
            #expect(!writer.contains(forbidden))
        }
        #expect(try CheckpointWriteSource.count("repository.store(revision)", in: persist.body) == 1)
    }

    @Test("F2: one exact tip feeds fresh readiness and the writer, which performs no reads")
    func singleTipObservationIsPinned() throws {
        let action = try CheckpointWriteSource.function(
            "writeEndedMonthCheckpoint", in: CheckpointWriteSource.read("Persistence/FinanceStore.swift")
        ).complete
        #expect(try CheckpointWriteSource.count("latestRevision(", in: action) == 1)
        for required in [
            "let tip = checkpoints.latestRevision(inPeriod: period, kind: kind)",
            "checkpointBaseline: PeriodCheckpointBaselineReader.source(for: tip)",
            "EndedMonthCheckpointWriter.write(readiness: readiness, chainTip: tip, repository: checkpoints,",
        ] {
            #expect(try CheckpointWriteSource.count(required, in: action) == 1)
        }
        #expect(try CheckpointWriteSource.count("PeriodCheckpointBaselineReader.source(from:", in: action) == 0)
        let writer = try CheckpointWriteSource.read(CheckpointWriteSource.writerPath)
        for forbidden in ["latestRevision", "revisions", "occupancy", "PeriodCheckpointBaselineReader"] {
            #expect(!writer.contains(forbidden))
        }
        #expect(try CheckpointWriteSource.count("""
            CheckpointClosePolicy.classify(currentReadiness: readiness, currentChainTip: chainTip)
            """, in: writer) == 1)
    }

    @Test("F4: only a materialized candidate reaches the writer's single ordinary store call")
    func writerStoresOnlyTheMaterializedCandidate() throws {
        let writer = try CheckpointWriteSource.read(CheckpointWriteSource.writerPath)
        let write = try CheckpointWriteSource.function("write", in: writer)
        let persist = try CheckpointWriteSource.function("persist", in: writer)
        #expect(try CheckpointWriteSource.count(".store(", in: writer) == 1)
        #expect(try CheckpointWriteSource.count(".store(", in: write.body) == 0)
        #expect(try CheckpointWriteSource.count("""
            case .alreadyCurrent: return .alreadyCurrent
            case let .refused(reason): return .refused(reason)
            case let .firstClose(plan):
            """, in: write.body) == 1)
        #expect(try CheckpointWriteSource.count("""
            case let .refused(reason): return .refused(reason)
            case let .candidate(revision): do {
                let outcome = try repository.store(revision)
                switch outcome {
            """, in: persist.body) == 1)
        // These are APPEND metadata providers, not FinanceStore's operation
        // clock, which can already have supplied review/asOf at action entry.
        for provider in ["makeCandidateIdentity()", "closedAt()"] {
            #expect(try CheckpointWriteSource.count(provider, in: write.body) == 0)
            #expect(try CheckpointWriteSource.count(provider, in: persist.body) == 1)
        }
    }

    @Test("Source scan ignores comments and literal text but retains aliased and interpolated calls")
    func sourceScanRecognizesRealMemberCalls() throws {
        let source = #####"""
            // repository.store(comment)
            /* nested /* checkpoints.store(comment) */ sink.store(comment) */
            let ordinary = "foo.store(text) and an escaped quote \""
            let raw = #"sink.store(text)"#
            let multiline = """
                checkpoints.store(text)
                """
            sink /* receiver */ .
                `store`
                (candidate)
            let rendered = "value \(try other.store(candidate))"
            """#####
        #expect(try CheckpointWriteSource.count(".store(", in: CheckpointWriteSource.tokens(source)) == 2)
    }

    @Test("Source declarations include closure defaults and the complete function body")
    func sourceDeclarationIncludesDefaultsAndBody() throws {
        let declaration = try CheckpointWriteSource.function("probe", in: CheckpointWriteSource.tokens("""
            func probe(callback: () -> Void = {}) -> Int {
                if ready { callback() }
                sink.store(candidate)
                return 1
            }
            func later() { other.store(candidate) }
            """))
        #expect(declaration.signature == (try CheckpointWriteSource.tokens(
            "func probe(callback: () -> Void = {}) -> Int"
        )))
        #expect(try CheckpointWriteSource.count(".store(", in: declaration.body) == 1)
        #expect(try CheckpointWriteSource.count("return 1", in: declaration.body) == 1)
    }

    // MARK: - Result helpers

    private func isAlreadyCurrent(_ result: EndedMonthCheckpointWriteResult) -> Bool {
        if case .alreadyCurrent = result { return true }
        return false
    }

    private func refusal(_ result: EndedMonthCheckpointWriteResult) -> CheckpointClosePolicyRefusal? {
        if case let .refused(reason) = result { return reason }
        return nil
    }

    private func notWritable(
        _ result: EndedMonthCheckpointWriteResult
    ) -> EndedMonthCheckpointNotWritableReason? {
        if case let .notWritable(reason) = result { return reason }
        return nil
    }

    // MARK: - Source

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FinanceApp")
    }

    private static func code(_ relativePath: String) throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent(relativePath), encoding: .utf8)
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
}
