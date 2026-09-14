import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// The ended-month verify action: the first production path from a screen to a
/// stored checkpoint.
///
/// The production path is `PeriodVerificationDetailView` →
/// `EndedMonthCheckpointAction.perform` → `FinanceStore.writeEndedMonthCheckpoint`
/// → the already-closed writer, with every reading coming back through
/// `endedMonthVerification`. These drive real stores and a real in-memory
/// repository, so what is asserted here is what a person would get.
@MainActor
@Suite("Ended-month checkpoint action")
struct EndedMonthCheckpointActionTests {

    private static let asOf = Day(year: 2026, month: 9, day: 3)
    private static let selection = ReviewPeriodSelection(scope: .month, offset: -1)

    private enum Failure: Error { case noVerification, noScreen }

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
                AccountBalance(
                    accountID: "bank", balance: euro(44_747),
                    asOf: Day(year: 2026, month: 8, day: 1)
                )
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
    private static func exceptionDocument() -> FinanceDocument {
        var document = cleanDocument()
        document.transactions = []
        document.observationResolutions = [
            ExternalObservationResolution(observationID: "observation", state: .unreviewed)
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

        /// `covered: false` leaves the month with no authoritative live
        /// coverage at all, which the evaluator answers with a blocker.
        init(document: FinanceDocument, covered: Bool = true) throws {
            container = try ModelContainer(
                for: Schema(FinanceSchema.models),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            try StoredDocumentGraph.replace(
                with: document,
                in: container.mainContext,
                writtenOn: EndedMonthCheckpointActionTests.asOf,
                appMetadata: covered
                    ? EndedMonthCheckpointActionTests.coverageMetadata()
                    : .empty
            )
            store = try FinanceStore(
                context: container.mainContext,
                now: fixtureInstant(EndedMonthCheckpointActionTests.asOf)
            )
        }

        func replace(_ document: FinanceDocument) throws {
            try StoredDocumentGraph.replace(
                with: document,
                in: container.mainContext,
                writtenOn: EndedMonthCheckpointActionTests.asOf,
                appMetadata: EndedMonthCheckpointActionTests.coverageMetadata()
            )
        }

        /// A store built again over the same rows, so no reading can be carried
        /// by anything the previous instance remembered.
        func reopen() throws -> FinanceStore {
            try FinanceStore(
                context: container.mainContext,
                now: fixtureInstant(EndedMonthCheckpointActionTests.asOf)
            )
        }

        func revisionRows() throws -> [StoredPeriodCheckpointRevision] {
            try container.mainContext.fetch(FetchDescriptor<StoredPeriodCheckpointRevision>())
        }
    }

    private func state(in store: FinanceStore) throws -> CheckpointVerificationState {
        guard let verification = store.endedMonthVerification(Self.selection) else {
            Issue.record("expected an ended-month verification")
            throw Failure.noVerification
        }
        return verification.presentation.verificationState
    }

    /// Exactly what the detail screen reads to decide the action.
    private func screen(
        _ acknowledgment: EndedMonthAcknowledgmentModel, in store: FinanceStore
    ) throws -> EndedMonthVerificationScreen {
        guard let screen = acknowledgment.screen(for: Self.selection, in: store) else {
            Issue.record("expected a verification screen")
            throw Failure.noScreen
        }
        return screen
    }

    /// The existing E2 interaction, driven exactly as the screen drives it.
    private func acceptEverything(
        _ acknowledgment: EndedMonthAcknowledgmentModel, in store: FinanceStore
    ) throws {
        let rows = try screen(acknowledgment, in: store).acknowledgment?.rows ?? []
        #expect(!rows.isEmpty, "expected acknowledgeable rows")
        for row in rows { acknowledgment.toggle(row) }
        #expect(acknowledgment.confirmSelection(for: Self.selection, in: store))
    }

    private func verify(
        _ acknowledgment: EndedMonthAcknowledgmentModel, in store: FinanceStore
    ) -> EndedMonthCheckpointActionOutcome {
        EndedMonthCheckpointAction.perform(
            for: Self.selection,
            confirming: acknowledgment.confirmedAcknowledgments,
            in: store
        )
    }

    // MARK: - A1/A2/A23 the state the action is offered from

    @Test("A1: a clean, never-verified month offers an action that can be taken")
    func cleanMonthIsOfferedAndReady() throws {
        let harness = try Harness(document: Self.cleanDocument())
        let screen = try screen(EndedMonthAcknowledgmentModel(), in: harness.store)

        #expect(screen.verification.verificationState == .notVerified)
        #expect(screen.readinessState == .nothingToDecide)
        // Nothing to decide, so no section — and readiness says so independently.
        #expect(screen.acknowledgment == nil)
    }

    @Test("A2: undecided exceptions are not ready, and accepting them is what changes that")
    func needsDecisionsBecomesReadyOnlyByAccepting() throws {
        let harness = try Harness(document: Self.exceptionDocument())
        let acknowledgment = EndedMonthAcknowledgmentModel()

        #expect(try screen(acknowledgment, in: harness.store).readinessState
                == .needsDecisions(remaining: 1))

        try acceptEverything(acknowledgment, in: harness.store)

        #expect(try screen(acknowledgment, in: harness.store).readinessState
                == .readyWithAcknowledgments)
    }

    @Test("A23: a blocked month carrying no exception row is still not ready")
    func blockedWithoutExceptionsIsNotReady() throws {
        let harness = try Harness(document: Self.cleanDocument(), covered: false)
        let screen = try screen(EndedMonthAcknowledgmentModel(), in: harness.store)

        // The whole point: there is no section, exactly as for a clean month,
        // and the month is nevertheless blocked. A screen reading readiness
        // from the section's absence would offer to verify this.
        #expect(screen.acknowledgment == nil)
        #expect(screen.readinessState == .blocked)
        #expect(screen.verification.verificationState == .notVerified)

        // And the writer agrees, so the disabled action is not merely cosmetic.
        guard case let .failed(message) = verify(
            EndedMonthAcknowledgmentModel(), in: harness.store
        ) else {
            Issue.record("a blocked month is not writable")
            return
        }
        #expect(message == EndedMonthCheckpointAction.Message.reviewAgain)
        #expect(try harness.revisionRows().isEmpty)
    }

    // MARK: - A4/A5 first close

    @Test("A4: a clean first close through the action reads verified from the store")
    func cleanFirstCloseReadsVerified() throws {
        let harness = try Harness(document: Self.cleanDocument())
        #expect(try state(in: harness.store) == .notVerified)

        #expect(verify(EndedMonthAcknowledgmentModel(), in: harness.store) == .written)

        #expect(try state(in: harness.store) == .verified)
        #expect(try harness.revisionRows().count == 1)
        // A14: the reading is the repository's, not this turn's.
        #expect(try state(in: try harness.reopen()) == .verified)
    }

    @Test("A5: an acknowledged first close stores, and leaves the interaction alone")
    func acknowledgedFirstCloseKeepsAcknowledgmentState() throws {
        let harness = try Harness(document: Self.exceptionDocument())
        let acknowledgment = EndedMonthAcknowledgmentModel()
        try acceptEverything(acknowledgment, in: harness.store)
        let confirmed = acknowledgment.confirmedAcknowledgments
        #expect(confirmed != .noDecisions)

        #expect(verify(acknowledgment, in: harness.store) == .written)

        #expect(try state(in: harness.store) == .verified)
        // Nothing is done to the interaction because persistence succeeded.
        #expect(acknowledgment.confirmedAcknowledgments == confirmed)
        #expect(acknowledgment.lastConfirmationWasRefused == false)
        // And the acknowledgment was not separately persisted: a new model,
        // which has decided nothing, still reads a verified month.
        let reopened = try harness.reopen()
        #expect(EndedMonthAcknowledgmentModel().confirmedAcknowledgments == .noDecisions)
        #expect(try state(in: reopened) == .verified)
    }

    // MARK: - A6/A7 reverify

    @Test("A6: a changed clean month verifies again to verified")
    func changedCleanMonthReverifies() throws {
        let harness = try Harness(document: Self.cleanDocument())
        #expect(verify(EndedMonthAcknowledgmentModel(), in: harness.store) == .written)
        try harness.replace(Self.cleanDocument(incomeMinor: 9_500))

        let changed = try harness.reopen()
        #expect(try state(in: changed) == .changedSinceVerification)

        #expect(verify(EndedMonthAcknowledgmentModel(), in: changed) == .written)

        #expect(try state(in: changed) == .verified)
        // Appended after the tip, never over it.
        #expect(try harness.revisionRows().count == 2)
    }

    @Test("A7: a changed exception month verifies again after explicit reconfirmation")
    func changedExceptionMonthNeedsReconfirmation() throws {
        let harness = try Harness(document: Self.exceptionDocument())
        let first = EndedMonthAcknowledgmentModel()
        try acceptEverything(first, in: harness.store)
        #expect(verify(first, in: harness.store) == .written)

        // The same month, moved. A brand-new screen, as leaving and returning
        // gives: nothing is carried forward, because E1 is not wired.
        var moved = Self.exceptionDocument()
        moved.transactions = [
            Transaction(
                id: "tx-extra",
                date: Day(year: 2026, month: 8, day: 20),
                kind: .income,
                legs: [AccountLeg(accountID: "bank", amount: Self.euro(3_300))],
                factivity: .observed
            )
        ]
        try harness.replace(moved)
        let changed = try harness.reopen()
        let second = EndedMonthAcknowledgmentModel()
        #expect(second.confirmedAcknowledgments == .noDecisions)
        #expect(try state(in: changed) == .changedSinceVerification)

        // Undecided until this person decides, even though a previous revision
        // carried an acknowledgment for the very same exception.
        #expect(try screen(second, in: changed).readinessState == .needsDecisions(remaining: 1))
        guard case .failed = verify(second, in: changed) else {
            Issue.record("an undecided month is not writable")
            return
        }

        try acceptEverything(second, in: changed)
        #expect(verify(second, in: changed) == .written)
        #expect(try state(in: changed) == .verified)
        #expect(try harness.revisionRows().count == 2)
    }

    // MARK: - A8 already current

    @Test("A8: verifying an already-current month is not an error and stores nothing new")
    func alreadyCurrentIsNotAnError() throws {
        let harness = try Harness(document: Self.cleanDocument())
        #expect(verify(EndedMonthAcknowledgmentModel(), in: harness.store) == .written)
        #expect(try harness.revisionRows().count == 1)

        // The race a stale screen produces: the action is taken again against
        // a month that is already current.
        guard case .alreadyCurrent = harness.store.writeEndedMonthCheckpoint(Self.selection)
        else {
            Issue.record("expected already current")
            return
        }
        #expect(verify(EndedMonthAcknowledgmentModel(), in: harness.store) == .written)

        // A22: no second semantic checkpoint.
        #expect(try harness.revisionRows().count == 1)
        #expect(try state(in: harness.store) == .verified)
    }

    // MARK: - A9/A27 refusal

    @Test("A9/A27: a refusal is no success, and keeps every decision that was made")
    func refusalKeepsDecisions() throws {
        let harness = try Harness(document: Self.exceptionDocument())
        let acknowledgment = EndedMonthAcknowledgmentModel()
        try acceptEverything(acknowledgment, in: harness.store)
        let confirmed = acknowledgment.confirmedAcknowledgments

        // The month moves out from under the decision: the accepted subject is
        // no longer the one carried, which the evaluator answers with a blocker.
        var resolved = Self.exceptionDocument()
        resolved.observationResolutions = [
            ExternalObservationResolution(observationID: "observation", state: .noEconomicEffect)
        ]
        try harness.replace(resolved)
        let moved = try harness.reopen()

        guard case let .failed(message) = verify(acknowledgment, in: moved) else {
            Issue.record("a stale decision is not writable")
            return
        }
        #expect(message == EndedMonthCheckpointAction.Message.reviewAgain)
        // A13/A27: nothing was repaired by identifier and nothing was dropped.
        #expect(acknowledgment.confirmedAcknowledgments == confirmed)
        #expect(moved.endedMonthVerification(Self.selection) != nil)
        #expect(try state(in: moved) == .notVerified)
        #expect(try harness.revisionRows().isEmpty)
    }

    // MARK: - A10 not writable

    @Test("A10: a read-only store is unavailable, not a save failure")
    func readOnlyStoreIsUnavailable() throws {
        let store = FinanceStore(
            snapshot: .empty(asOf: DomainMapper.civilDay(Self.asOf)),
            now: fixtureInstant(Self.asOf)
        )
        guard case let .failed(message) = verify(EndedMonthAcknowledgmentModel(), in: store) else {
            Issue.record("a fixed store is not writable")
            return
        }
        #expect(message == EndedMonthCheckpointAction.Message.unavailable)
    }

    // MARK: - A24 unavailable verification

    @Test("A24: a history this build cannot compare is unavailable, and offers nothing")
    func unsupportedHistoryReadsUnavailable() throws {
        let harness = try Harness(document: Self.cleanDocument())
        #expect(verify(EndedMonthAcknowledgmentModel(), in: harness.store) == .written)

        // A revision written by a later build: readable as a header, and not
        // this build's bytes to parse.
        let row = try #require(harness.revisionRows().first)
        row.projectionFormatToken = "finance-app/semantic-period-projection/v99"
        row.canonicalProjection = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try harness.container.mainContext.save()

        let reopened = try harness.reopen()
        #expect(try state(in: reopened) == .unavailable)

        // The action is not offered for this state; were it taken anyway, the
        // writer refuses it as unavailable rather than restarting the chain.
        guard case let .failed(message) = verify(EndedMonthAcknowledgmentModel(), in: reopened)
        else {
            Issue.record("an uncomparable history is not writable")
            return
        }
        #expect(message == EndedMonthCheckpointAction.Message.unavailable)
        #expect(try harness.revisionRows().count == 1)
    }

    // MARK: - A11/A12 result mapping

    @Test("A11/A12: every writer result maps to exactly one thing a person is told")
    func resultMappingIsTotal() throws {
        let unavailable = EndedMonthCheckpointAction.Message.unavailable
        let reviewAgain = EndedMonthCheckpointAction.Message.reviewAgain
        let saveFailed = EndedMonthCheckpointAction.Message.saveFailed

        // Accepted: an append, or a checkpoint that already says this.
        #expect(EndedMonthCheckpointAction.outcome(for: .alreadyCurrent) == .written)

        // A12: a fresh-UUID append the store said it already had is an
        // invariant failure. It is never success, and never "already current".
        #expect(
            EndedMonthCheckpointAction.outcome(for: .storeUnexpectedAlreadyStored)
                == .failed(saveFailed)
        )
        for error: PeriodCheckpointStoreError in [
            .storeUnavailable, .persistenceFailed("SyntheticError"),
        ] {
            #expect(
                EndedMonthCheckpointAction.outcome(for: .storeRefused(error))
                    == .failed(saveFailed)
            )
        }

        // Every not-writable reason is availability: nothing was attempted.
        for reason in EndedMonthCheckpointNotWritableReason.allCases {
            #expect(
                EndedMonthCheckpointAction.outcome(for: .notWritable(reason))
                    == .failed(unavailable),
                "\(reason)"
            )
        }

        // And the policy's refusals, walked whole so a new one cannot be added
        // without deciding what a person is told about it.
        let expected: [CheckpointClosePolicyRefusal: String] = [
            .readinessNotReady: reviewAgain,
            .inconsistentPreviousObservation: reviewAgain,
            .unsupportedWriteScope: unavailable,
            .periodNotEnded: unavailable,
            .semanticProjectionUnavailable: unavailable,
            .previousRevisionFormatUnsupported: unavailable,
            .previousRevisionCorrupt: unavailable,
            .previousRevisionPeriodMismatch: unavailable,
            .previousRevisionKindMismatch: unavailable,
            .comparisonIndeterminate: unavailable,
            .comparisonUnavailable: unavailable,
            .revisionNumberUnrepresentable: saveFailed,
            .revisionConstructionRefused: saveFailed,
        ]
        #expect(expected.count == CheckpointClosePolicyRefusal.allCases.count)
        for refusal in CheckpointClosePolicyRefusal.allCases {
            #expect(
                EndedMonthCheckpointAction.outcome(for: .refused(refusal))
                    == .failed(try #require(expected[refusal])),
                "\(refusal)"
            )
        }

        // No engine vocabulary reaches a person.
        for message in [unavailable, reviewAgain, saveFailed] {
            for leak in ["checkpoint", "revision", "predecessor", "digest", "hash", "store"] {
                #expect(!message.lowercased().contains(leak), "\(message) leaks \(leak)")
            }
        }
    }

    // MARK: - Source pins

    /// Comment-free source, so prose cannot satisfy or break a pin.
    private static func code(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FinanceApp")
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let comment = line.range(of: "//") else { return line }
                return line[line.startIndex..<comment.lowerBound]
            }
            .joined(separator: "\n")
    }

    private static let actionPath = "Persistence/EndedMonthCheckpointAction.swift"
    private static let viewPath = "Features/Insights/InsightsView.swift"

    @Test("The screen asks the presentation whether to offer and enable the action")
    func ctaVisibilityAndEnablementAreAsked() throws {
        let view = try CheckpointWriteSource.read(Self.viewPath)

        // What matters is that the screen *asks*, and asks with readiness —
        // a predicate that is correct but uncalled, with the section's mere
        // presence enabling the button instead, has to fail here. The
        // per-state answers themselves are behavioural and are covered by
        // A1/A2/A23 against the real presentation, not pinned as source text.
        let enabled = try CheckpointWriteSource.function("canVerify", in: view)
        #expect(try CheckpointWriteSource.count(
            "EndedMonthAcknowledgmentReadinessState", in: enabled.signature
        ) == 1)
        #expect(try CheckpointWriteSource.count("acknowledgment", in: enabled.body) == 0,
                "readiness is read as readiness, never re-derived from acknowledgment state")
        #expect(try CheckpointWriteSource.count(
            ".disabled(!canVerify(readiness))", in: view
        ) == 1)
        #expect(try CheckpointWriteSource.count(
            "verificationStatusSection(shown, readiness: screen?.readinessState)", in: view
        ) == 1)
        #expect(try CheckpointWriteSource.count("if offersVerification(shown)", in: view) == 1)
    }

    @Test("The action is taken once, synchronously, and always forces a re-read")
    func actionIsSynchronousAndAlwaysRefreshes() throws {
        let view = try CheckpointWriteSource.read(Self.viewPath)
        let action = try CheckpointWriteSource.function("verifyMonth", in: view)

        // One call, through the adapter, with the typed authority and nothing
        // else the screen could have made up.
        #expect(try CheckpointWriteSource.count(
            "EndedMonthCheckpointAction.perform(", in: action.body
        ) == 1)
        #expect(try CheckpointWriteSource.count(
            "confirming: acknowledgment.confirmedAcknowledgments", in: action.body
        ) == 1)

        // A16: no suspension point, so nothing to interleave and no spinner.
        for forbidden in ["Task", "await", "async", "isSubmitting"] {
            #expect(try CheckpointWriteSource.count(forbidden, in: action.body) == 0, "\(forbidden)")
        }

        // A28/AF18: one bump, on both paths, so a refusal re-reads too.
        // One bump, outside the switch, so neither outcome can skip it.
        #expect(try CheckpointWriteSource.count("refreshGeneration += 1", in: action.body) == 1)
    }

    @Test("The screen holds no verification answer of its own")
    func screenHoldsNoLocalAuthority() throws {
        let view = try CheckpointWriteSource.read(Self.viewPath)
        let source = try Self.code(Self.viewPath)

        // AF4/AF19: the existing guard, restated for the action. Success is
        // never a flag, and the type that names the answer is never held here.
        #expect(try CheckpointWriteSource.count("CheckpointVerificationState", in: view) == 0)
        for forbidden in ["didVerify", "isVerified", "hasVerified", "wasVerified"] {
            #expect(!source.contains(forbidden), "\(forbidden)")
        }
        // Every reading comes from the same mapped presentation.
        #expect(try CheckpointWriteSource.count("verificationState.headline", in: view) >= 1)

        // AF11/AF12/AF14: no store, no policy, no revision, no matcher.
        #expect(try CheckpointWriteSource.count(".store(", in: view) == 0)
        for forbidden in [
            "writeEndedMonthCheckpoint", "EndedMonthCheckpointWriter", "CheckpointClosePolicy",
            "PeriodCheckpointRevision", "PeriodCheckpointAcknowledgmentMatcher",
            "carryForwardCandidate", "PeriodCheckpointRepository",
        ] {
            #expect(!source.contains(forbidden), "\(forbidden)")
        }
    }

    @Test("The adapter is the only production caller, and it only calls the store")
    func exactlyOneProductionWriterCaller() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FinanceApp")
        let files = try #require(FileManager.default.enumerator(atPath: root.path))

        var callers: [String] = []
        for case let path as String in files where path.hasSuffix(".swift") {
            // FinanceStore.swift declares it; every other mention is a call.
            guard path != "Persistence/FinanceStore.swift" else { continue }
            let count = try CheckpointWriteSource.count(
                "writeEndedMonthCheckpoint", in: CheckpointWriteSource.read(path)
            )
            callers.append(contentsOf: repeatElement(path, count: count))
        }
        // A18/A19/A20: one caller, and it is the adapter — so no view, no Home
        // adapter and no second feature reaches the writer.
        #expect(callers == [Self.actionPath])

        // AF11/AF14: the adapter stores nothing itself and restates no policy.
        let adapter = try CheckpointWriteSource.read(Self.actionPath)
        #expect(try CheckpointWriteSource.count(".store(", in: adapter) == 0)
        #expect(try CheckpointWriteSource.count("PeriodCheckpointRevision(", in: adapter) == 0)
        for forbidden in [
            "Task", "await", "async", "CheckpointClosePolicy", "PeriodCheckpointRepository",
            "PeriodCheckpointAcknowledgmentMatcher", "carryForwardCandidate", "latestRevision",
        ] {
            #expect(try CheckpointWriteSource.count(forbidden, in: adapter) == 0, "\(forbidden)")
        }
    }
}
