import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// Read-only checkpoint verification presentation.
///
/// The production path is `FinanceStore.endedMonthVerification` →
/// `AttentionComposition.readiness` → `PeriodVerificationMapper` →
/// `PeriodVerificationPresentation.verificationState`. These tests drive real
/// stores, a real in-memory repository and the already-closed writer, so the
/// transitions below are the ones a person would see. Nothing here exposes a
/// checkpoint action.
@MainActor
@Suite("Checkpoint verification state presentation")
struct CheckpointVerificationPresentationTests {

    private static let asOf = Day(year: 2026, month: 9, day: 3)
    private static let august = ReviewInterval.month(MonthKey(year: 2026, month: 8))
    private static let selection = ReviewPeriodSelection(scope: .month, offset: -1)

    private enum Failure: Error { case noVerification }

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

        init(document: FinanceDocument) throws {
            container = try ModelContainer(
                for: Schema(FinanceSchema.models),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            try StoredDocumentGraph.replace(
                with: document,
                in: container.mainContext,
                writtenOn: CheckpointVerificationPresentationTests.asOf,
                appMetadata: CheckpointVerificationPresentationTests.coverageMetadata()
            )
            store = try FinanceStore(
                context: container.mainContext,
                now: fixtureInstant(CheckpointVerificationPresentationTests.asOf)
            )
        }

        func replace(_ document: FinanceDocument) throws {
            try StoredDocumentGraph.replace(
                with: document,
                in: container.mainContext,
                writtenOn: CheckpointVerificationPresentationTests.asOf,
                appMetadata: CheckpointVerificationPresentationTests.coverageMetadata()
            )
        }

        /// A store built again over the same persisted rows, so a reading can
        /// never be carried by anything the previous instance remembered.
        func reopen() throws -> FinanceStore {
            try FinanceStore(
                context: container.mainContext,
                now: fixtureInstant(CheckpointVerificationPresentationTests.asOf)
            )
        }
    }

    /// The presentation a screen would render, read fresh through production.
    private func presentation(
        in store: FinanceStore
    ) throws -> PeriodVerificationPresentation {
        guard let verification = store.endedMonthVerification(Self.selection) else {
            Issue.record("expected an ended-month verification")
            throw Failure.noVerification
        }
        return verification.presentation
    }

    private func state(
        in store: FinanceStore
    ) throws -> CheckpointVerificationState {
        try presentation(in: store).verificationState
    }

    private func acceptEverything(
        _ acknowledgment: EndedMonthAcknowledgmentModel,
        in store: FinanceStore
    ) throws {
        guard let screen = acknowledgment.screen(for: Self.selection, in: store),
              let section = screen.acknowledgment, !section.rows.isEmpty else {
            Issue.record("expected acknowledgeable rows")
            throw Failure.noVerification
        }
        for row in section.rows { acknowledgment.toggle(row) }
        #expect(acknowledgment.confirmSelection(for: Self.selection, in: store))
    }

    private func revisionRows(_ harness: Harness) throws -> [StoredPeriodCheckpointRevision] {
        try harness.container.mainContext.fetch(
            FetchDescriptor<StoredPeriodCheckpointRevision>()
        )
    }

    // MARK: - P1 never closed

    @Test("P1: a month with no stored checkpoint is not verified")
    func neverClosedReadsNotVerified() throws {
        let harness = try Harness(document: Self.cleanDocument())
        #expect(try state(in: harness.store) == .notVerified)
        #expect(CheckpointVerificationState.notVerified.headline == "Not verified yet.")
        #expect(try presentation(in: harness.store).changeSummary == nil)
        #expect(try revisionRows(harness).isEmpty)
    }

    // MARK: - P2 first close transition

    @Test("P2: a real first close makes the next fresh read say verified")
    func firstCloseTransitionsToVerified() throws {
        let harness = try Harness(document: Self.cleanDocument())
        #expect(try state(in: harness.store) == .notVerified)

        guard case .storedFirstClose = harness.store.writeEndedMonthCheckpoint(Self.selection) else {
            Issue.record("expected a first close")
            return
        }

        #expect(try state(in: harness.store) == .verified)
        #expect(CheckpointVerificationState.verified.headline == "Verified.")
        #expect(try presentation(in: harness.store).changeSummary == nil)
        #expect(try revisionRows(harness).count == 1)
    }

    // MARK: - P4 changed since verification

    @Test("P4: moving the month away from its checkpoint reads as changed")
    func changedSinceVerification() throws {
        let harness = try Harness(document: Self.cleanDocument())
        guard case .storedFirstClose = harness.store.writeEndedMonthCheckpoint(Self.selection) else {
            Issue.record("expected a first close")
            return
        }
        #expect(try state(in: harness.store) == .verified)

        // The same covered month, carrying a different economic amount.
        try harness.replace(Self.cleanDocument(incomeMinor: 9_500))
        let reopened = try harness.reopen()

        #expect(try state(in: reopened) == .changedSinceVerification)
        #expect(
            CheckpointVerificationState.changedSinceVerification.headline
                == "Changes since verification."
        )
        let summary = try #require(try presentation(in: reopened).changeSummary)
        #expect(summary.dimensions.contains(.economics))
        #expect(summary.occupancyStatements.isEmpty)
        #expect(
            summary.statements.contains("The month's recorded spending or income is different.")
        )
        assertNoCheckpointMetadata(summary)
        // Reading never appends.
        #expect(try revisionRows(harness).count == 1)
    }

    // MARK: - P6 reverify transition

    @Test("P6: a real reverify returns the reading to verified")
    func reverifyReturnsToVerified() throws {
        let harness = try Harness(document: Self.cleanDocument())
        guard case .storedFirstClose = harness.store.writeEndedMonthCheckpoint(Self.selection) else {
            Issue.record("expected a first close")
            return
        }
        try harness.replace(Self.cleanDocument(incomeMinor: 9_500))

        let changed = try harness.reopen()
        #expect(try state(in: changed) == .changedSinceVerification)

        guard case .storedReverify = changed.writeEndedMonthCheckpoint(Self.selection) else {
            Issue.record("expected a reverify")
            return
        }

        #expect(try state(in: changed) == .verified)
        #expect(try presentation(in: changed).changeSummary == nil)
        // The reading follows the newest checkpoint, and the old one is kept.
        #expect(try revisionRows(harness).count == 2)
    }

    // MARK: - P7 acknowledged first close

    @Test("P7: an acknowledged first close reads verified without touching acknowledgment state")
    func acknowledgedFirstCloseReadsVerified() throws {
        let harness = try Harness(document: Self.exceptionDocument())
        #expect(try state(in: harness.store) == .notVerified)

        // The existing E2 interaction, unchanged: select, then confirm.
        let acknowledgment = EndedMonthAcknowledgmentModel()
        guard let screen = acknowledgment.screen(for: Self.selection, in: harness.store),
              let section = screen.acknowledgment, !section.rows.isEmpty else {
            Issue.record("expected acknowledgeable rows")
            return
        }
        for row in section.rows { acknowledgment.toggle(row) }
        #expect(acknowledgment.confirmSelection(for: Self.selection, in: harness.store))

        guard case .storedFirstClose = harness.store.writeEndedMonthCheckpoint(
            Self.selection,
            confirmedAcknowledgments: acknowledgment.confirmedAcknowledgments
        ) else {
            Issue.record("expected a first close")
            return
        }

        // The reading is the repository's, not the interaction's: a brand-new
        // model that has decided nothing still sees a verified month.
        #expect(try state(in: harness.store) == .verified)
        let fresh = EndedMonthAcknowledgmentModel()
        #expect(fresh.confirmedAcknowledgments == .noDecisions)
        #expect(try state(in: try harness.reopen()) == .verified)
    }

    // MARK: - P8 persisted truth, no local flag

    @Test("P8: the reading survives a store rebuilt over the same rows")
    func readingComesFromPersistedTruth() throws {
        let harness = try Harness(document: Self.cleanDocument())
        guard case .storedFirstClose = harness.store.writeEndedMonthCheckpoint(Self.selection) else {
            Issue.record("expected a first close")
            return
        }
        #expect(try state(in: harness.store) == .verified)

        // Nothing in the first store carries the answer forward.
        for _ in 0..<3 {
            #expect(try state(in: try harness.reopen()) == .verified)
        }
    }

    // MARK: - P13 / P14 no write caller, no matcher

    @Test("P13/P14: the read presentation stores nothing and reaches no matcher")
    func presentationLayerNeitherWritesNorMatches() throws {
        for path in [
            "Persistence/PeriodVerificationMapper.swift",
            "Surface/Insights.swift",
            "Features/Insights/InsightsView.swift",
            "Attention/AttentionFactAdapters.swift",
        ] {
            let code = try CheckpointWriteSource.read(path)
            #expect(try CheckpointWriteSource.count(".store(", in: code) == 0, "\(path) stores")
            for forbidden in [
                "writeEndedMonthCheckpoint",
                "EndedMonthCheckpointWriter",
                "PeriodCheckpointAcknowledgmentMatcher",
                "carryForwardCandidate",
                "carryForwardCandidates",
                "CheckpointClosePolicy",
                "PeriodCheckpointRevision",
            ] {
                #expect(!code.contains(forbidden), "\(path) reached \(forbidden)")
            }
        }
    }

    // MARK: - P9 no unconditional headline

    @Test("P9: Insights renders the mapped state, not one hardcoded headline")
    func insightsDoesNotHardcodeTheHeadline() throws {
        let view = try CheckpointWriteSource.read("Features/Insights/InsightsView.swift")
        // Two readings now: the period row, and the verification detail, which
        // owns the checkpoint action and has to show what it achieved. Both
        // read the same mapped presentation, which is the point of counting
        // them — a second headline built any other way would not be here.
        #expect(try CheckpointWriteSource.count("verificationState.headline", in: view) >= 1)
        #expect(try CheckpointWriteSource.count("changeSummary", in: view) >= 1)
        // Every headline lives on the presentation state, and none of them is
        // spelled out in the view.
        for state in CheckpointVerificationState.allCases {
            #expect(
                try CheckpointWriteSource.count("<string> \(state.headline) </string>", in: view) == 0,
                "the view spells out \(state.headline)"
            )
        }
        for forbidden in [
            "PeriodCheckpointChangeClass", "economicsChanged", "coverageChanged",
            "PeriodCheckpointRevision", "baselineComparison",
        ] {
            #expect(!view.contains(forbidden), "the view classifies \(forbidden)")
        }
    }

    // MARK: - P8 no local verification authority

    @Test("P8: no screen holds verification state of its own")
    func viewHoldsNoVerificationAuthority() throws {
        let view = try CheckpointWriteSource.read("Features/Insights/InsightsView.swift")
        // The view never names the type: it reads one headline off the
        // presentation. A local flag, a cached answer or a hand-rolled
        // decision would all have to name it here.
        #expect(try CheckpointWriteSource.count("CheckpointVerificationState", in: view) == 0)
        for forbidden in ["didVerify", "isVerified", "hasVerified", "wasVerified"] {
            #expect(!view.contains(forbidden), "the view holds \(forbidden)")
        }
    }

    @Test("P5: only a proven-unchanged comparison may say verified")
    func onlyUnchangedEarnsVerified() {
        // The mapper is total over the comparison, and exactly one case earns
        // the verified claim.
        let verified: [PeriodCheckpointBaselineComparison] = [
            .unchangedSinceClose(previousQuality: .clean)
        ]
        for comparison in verified {
            #expect(PeriodVerificationMapper.verificationState(for: comparison) == .verified)
        }
        let notVerified: [PeriodCheckpointBaselineComparison] = [
            .unavailable(.noBaselinePersistence),
            .unavailable(.baselineProjectionUnreadable),
            .notPreviouslyClosed,
            .changedSinceClose(previousQuality: .clean, changes: .init(.economicsChanged)),
            .indeterminate(previousQuality: .clean, blockers: .init(.sourceGap)),
            .requiresReverification(
                previousQuality: .clean,
                storedFormatToken: "v0",
                comparisonFormat: .v1
            ),
        ]
        for comparison in notVerified {
            #expect(
                PeriodVerificationMapper.verificationState(for: comparison) != .verified,
                "\(comparison) claimed verified"
            )
        }
    }

    // MARK: - Change summary through the production read path

    @Test("A new unreviewed movement after a clean close is named as new")
    func newExceptionAfterCleanClose() throws {
        let harness = try Harness(document: Self.cleanDocument())
        guard case .storedFirstClose = harness.store.writeEndedMonthCheckpoint(Self.selection) else {
            Issue.record("expected a first close")
            return
        }
        try harness.replace(Self.exceptionDocument())
        let changed = try harness.reopen()

        let shown = try presentation(in: changed)
        #expect(shown.verificationState == .changedSinceVerification)
        let summary = try #require(shown.changeSummary)
        #expect(summary.occupancyStatements == ["1 bank movement now needs review."])
        #expect(shown.decisions.contains { $0.destination != nil })
        assertNoCheckpointMetadata(summary)
    }

    @Test("Resolving a previously acknowledged exception is named as gone")
    func disappearedExceptionAfterAcknowledgedClose() throws {
        let harness = try Harness(document: Self.exceptionDocument())
        let acknowledgment = EndedMonthAcknowledgmentModel()
        try acceptEverything(acknowledgment, in: harness.store)
        guard case .storedFirstClose = harness.store.writeEndedMonthCheckpoint(
            Self.selection,
            confirmedAcknowledgments: acknowledgment.confirmedAcknowledgments
        ) else {
            Issue.record("expected a first close")
            return
        }
        try harness.replace(Self.cleanDocument())
        let changed = try harness.reopen()

        let shown = try presentation(in: changed)
        #expect(shown.verificationState == .changedSinceVerification)
        let summary = try #require(shown.changeSummary)
        #expect(summary.occupancyStatements == [
            "Previously acknowledged items are no longer present."
        ])
        assertNoCheckpointMetadata(summary)
    }

    @Test("A still-present exception plus new economics does not claim the exception is new")
    func mixedOccupancyThroughProductionRead() throws {
        let harness = try Harness(document: Self.exceptionDocument())
        let acknowledgment = EndedMonthAcknowledgmentModel()
        try acceptEverything(acknowledgment, in: harness.store)
        guard case .storedFirstClose = harness.store.writeEndedMonthCheckpoint(
            Self.selection,
            confirmedAcknowledgments: acknowledgment.confirmedAcknowledgments
        ) else {
            Issue.record("expected a first close")
            return
        }

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

        let shown = try presentation(in: changed)
        #expect(shown.verificationState == .changedSinceVerification)
        let summary = try #require(shown.changeSummary)
        #expect(summary.occupancyStatements.isEmpty)
        #expect(summary.dimensions.contains(.economics))
        let visible = summary.statements.joined(separator: " ").lowercased()
        #expect(!visible.contains("now needs review"))
        #expect(!visible.contains("no longer present"))
        #expect(!visible.contains("observation"))
        assertNoCheckpointMetadata(summary)
    }

    @Test("Changing an exception's subject under the same identifier is not identity")
    func sameIdentifierChangedSubjectIsNotIdentical() throws {
        let harness = try Harness(document: Self.exceptionDocument())
        let acknowledgment = EndedMonthAcknowledgmentModel()
        try acceptEverything(acknowledgment, in: harness.store)
        guard case .storedFirstClose = harness.store.writeEndedMonthCheckpoint(
            Self.selection,
            confirmedAcknowledgments: acknowledgment.confirmedAcknowledgments
        ) else {
            Issue.record("expected a first close")
            return
        }

        var moved = Self.exceptionDocument()
        moved.externalObservations = [
            ExternalObservation(
                id: "observation", bindingID: "binding", provider: .bnp,
                identity: .durable, status: .booked, creditDebitIndicator: .debit,
                amount: Self.euro(-9_500), bookingDate: Day(year: 2026, month: 8, day: 15),
                eligibleForEconomicActual: true,
                observedAt: Date(timeIntervalSince1970: 1_000)
            )
        ]
        try harness.replace(moved)
        let changed = try harness.reopen()

        let shown = try presentation(in: changed)
        #expect(shown.verificationState == .changedSinceVerification)
        let summary = try #require(shown.changeSummary)
        #expect(summary.occupancyStatements.isEmpty)
        let visible = summary.statements.joined(separator: " ")
        #expect(!visible.contains("observation"))
        #expect(!visible.lowercased().contains("now needs review"))
        #expect(!visible.lowercased().contains("identical"))
        assertNoCheckpointMetadata(summary)
    }

    @Test("Successful reverify clears the change summary through fresh repository state")
    func reverifyClearsTheChangeSummary() throws {
        let harness = try Harness(document: Self.cleanDocument())
        guard case .storedFirstClose = harness.store.writeEndedMonthCheckpoint(Self.selection) else {
            Issue.record("expected a first close")
            return
        }
        try harness.replace(Self.cleanDocument(incomeMinor: 9_500))
        let changed = try harness.reopen()
        #expect(try presentation(in: changed).changeSummary != nil)

        guard case .storedReverify = changed.writeEndedMonthCheckpoint(Self.selection) else {
            Issue.record("expected a reverify")
            return
        }
        #expect(try state(in: changed) == .verified)
        #expect(try presentation(in: changed).changeSummary == nil)
        #expect(try presentation(in: try harness.reopen()).changeSummary == nil)
    }

    private func assertNoCheckpointMetadata(_ summary: VerificationChangeSummary) {
        let visible = summary.statements.joined(separator: " ").lowercased()
        for forbidden in [
            "revision", "predecessor", "digest", "canonical", "checkpoint",
            "baseline", "uuid", "changedsinceclose", "economicschanged",
            "coveragechanged", "evidencechanged", "withexceptions",
            "previousquality", "periodcheckpoint",
        ] {
            #expect(!visible.contains(forbidden), "leaked \(forbidden)")
        }
    }

    // MARK: - P15-P18 freeze
}
