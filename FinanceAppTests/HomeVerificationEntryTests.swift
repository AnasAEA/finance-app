import Testing
import Foundation
import SwiftData
import FinanceCore
@testable import FinanceApp

/// Home routes into the canonical Insights verification detail. It does not
/// write a checkpoint, confirm a subject, or own verification truth.
@MainActor
@Suite("Home verification entry")
struct HomeVerificationEntryTests {

    private static let asOf = Day(year: 2026, month: 9, day: 3)
    private static let selection = ReviewPeriodSelection(scope: .month, offset: -1)

    private static func euro(_ minor: Int64) -> Money {
        Money(minorUnits: minor, currency: .eur)
    }

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
                writtenOn: HomeVerificationEntryTests.asOf,
                appMetadata: HomeVerificationEntryTests.coverageMetadata()
            )
            store = try FinanceStore(
                context: container.mainContext,
                now: fixtureInstant(HomeVerificationEntryTests.asOf)
            )
        }

        func replace(_ document: FinanceDocument) throws {
            try StoredDocumentGraph.replace(
                with: document,
                in: container.mainContext,
                writtenOn: HomeVerificationEntryTests.asOf,
                appMetadata: HomeVerificationEntryTests.coverageMetadata()
            )
        }

        func reopen() throws -> FinanceStore {
            try FinanceStore(
                context: container.mainContext,
                now: fixtureInstant(HomeVerificationEntryTests.asOf)
            )
        }
    }

    private func home(in store: FinanceStore) -> HomeAttentionPresentation {
        store.currentPresentation().attention.home
    }

    private func monthCard(in store: FinanceStore) throws -> HomeAttentionCard {
        guard case let .act(card, _) = home(in: store),
              case .insightsMonthVerification = card.destination
        else {
            Issue.record("expected a Home month-verification action")
            throw Failure.noCard
        }
        return card
    }

    private enum Failure: Error { case noCard }

    @Test("A never-verified ended month offers Review month for that period")
    func neverVerifiedOffersReviewMonth() throws {
        let harness = try Harness(document: Self.cleanDocument())
        let card = try monthCard(in: harness.store)
        #expect(card.actionTitle == "Review month")
        #expect(card.title.contains("isn't verified yet."))
        #expect(
            card.destination
                == .insightsMonthVerification(Self.selection)
        )
        #expect(try harness.store.endedMonthVerification(Self.selection)?.presentation.verificationState
                == .notVerified)
    }

    @Test("A verified unchanged month stays quiet on Home")
    func verifiedUnchangedIsQuiet() throws {
        let harness = try Harness(document: Self.cleanDocument())
        guard case .storedFirstClose = harness.store.writeEndedMonthCheckpoint(Self.selection) else {
            Issue.record("expected a first close")
            return
        }
        let reopened = try harness.reopen()
        if case let .act(card, _) = home(in: reopened) {
            #expect(card.destination != .insightsMonthVerification(Self.selection))
        }
    }

    @Test("A changed month offers Review changes for the same period")
    func changedMonthOffersReviewChanges() throws {
        let harness = try Harness(document: Self.cleanDocument())
        guard case .storedFirstClose = harness.store.writeEndedMonthCheckpoint(Self.selection) else {
            Issue.record("expected a first close")
            return
        }
        try harness.replace(Self.cleanDocument(incomeMinor: 9_500))
        let changed = try harness.reopen()
        let card = try monthCard(in: changed)
        #expect(card.actionTitle == "Review changes")
        #expect(card.title.contains("changed since verification."))
        #expect(card.destination == .insightsMonthVerification(Self.selection))
        #expect(
            try changed.endedMonthVerification(Self.selection)?.presentation.verificationState
                == .changedSinceVerification
        )
    }

    @Test("Successful verification removes the Home action; a later change restores it")
    func verificationClearsAndChangeRestoresHomeAction() throws {
        let harness = try Harness(document: Self.cleanDocument())
        _ = try monthCard(in: harness.store)

        guard case .storedFirstClose = harness.store.writeEndedMonthCheckpoint(Self.selection) else {
            Issue.record("expected a first close")
            return
        }
        let verified = try harness.reopen()
        if case let .act(card, _) = home(in: verified) {
            #expect(card.destination != .insightsMonthVerification(Self.selection))
        }

        try harness.replace(Self.cleanDocument(incomeMinor: 9_500))
        let changed = try harness.reopen()
        #expect(try monthCard(in: changed).actionTitle == "Review changes")

        guard case .storedReverify = changed.writeEndedMonthCheckpoint(Self.selection) else {
            Issue.record("expected a reverify")
            return
        }
        let current = try harness.reopen()
        if case let .act(card, _) = home(in: current) {
            #expect(card.destination != .insightsMonthVerification(Self.selection))
        }
    }

    @Test("Home routing opens Insights on the canonical month, and does not confirm")
    func routingTargetsInsightsWithoutAuthority() throws {
        let harness = try Harness(document: Self.cleanDocument())
        let card = try monthCard(in: harness.store)
        let navigation = AppNavigation()
        guard case let .insightsMonthVerification(selection) = card.destination else {
            Issue.record("expected Insights routing")
            return
        }
        navigation.openInsightsVerification(selection)
        #expect(navigation.selectedTab == .insights)
        #expect(navigation.insightsSelection == Self.selection)
        #expect(EndedMonthAcknowledgmentModel().confirmedAcknowledgments == .noDecisions)
    }

    @Test("Home never writes a checkpoint or confirms a subject")
    func homeOwnsNoCheckpointAuthority() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("FinanceApp")
        let home = try String(
            contentsOf: root.appendingPathComponent("Features/Home/HomeView.swift"),
            encoding: .utf8
        )
        for forbidden in [
            "writeEndedMonthCheckpoint",
            "EndedMonthCheckpointAction",
            "EndedMonthCheckpointWriter",
            "PeriodCheckpointAcknowledgmentMatcher",
            "PeriodCheckpointConfirmedAcknowledgments",
            "repository.store",
        ] {
            #expect(!home.contains(forbidden), "Home reached \(forbidden)")
        }
        #expect(home.contains("openInsightsVerification"))
    }
}
