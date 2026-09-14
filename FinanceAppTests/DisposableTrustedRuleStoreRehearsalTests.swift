import Foundation
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

/// Opt-in activation rehearsal. Normal test runs return immediately because
/// the private store copy is never part of the repository or test bundle.
/// An operator may place a disposable copy at the documented app-container
/// path, run this test once, extract the sanitized report, then delete it.
@Suite("Disposable trusted-rule store rehearsal")
@MainActor
struct DisposableTrustedRuleStoreRehearsalTests {
    private let rehearsalDay = Day(year: 2026, month: 8, day: 30)
    private let evidenceDay = Day(year: 2026, month: 8, day: 29)
    private let timestamp = Date(timeIntervalSince1970: 1_777_680_000)

    private struct FinancialState: Equatable {
        let transactionCount: Int
        let evidenceLinkCount: Int
        let resolutionStates: [ExternalObservationResolution]
        let balances: [AccountBalance]
        let planning: FinanceDocument.Planning
        let providerBalances: [ProviderBalanceSnapshot]
        let observations: [ExternalObservation]
    }

    private func financialState(_ document: FinanceDocument) -> FinancialState {
        FinancialState(
            transactionCount: document.transactions.count,
            evidenceLinkCount: document.externalEvidenceLinks.count,
            resolutionStates: document.observationResolutions,
            balances: document.balances,
            planning: document.planning,
            providerBalances: document.providerBalanceSnapshots,
            observations: document.externalObservations
        )
    }

    private func load(_ container: ModelContainer) throws -> FinanceDocument {
        try #require(try StoredDocumentGraph.load(from: container.mainContext))
    }

    @Test("Complete lifecycle on an opt-in disposable real-store copy")
    func completeLifecycleOnDisposableCopy() throws {
        let documents = try #require(
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        )
        let directory = documents.appendingPathComponent(
            "Phase26ActivationRehearsal", isDirectory: true
        )
        let storeURL = directory.appendingPathComponent("FinanceCore-1.1.store")
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }

        let container = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(url: storeURL)
        )
        let original = try load(container)
        #expect(original.trustedRules.isEmpty)
        #expect(original.externalEvidenceLinks.isEmpty)
        let originalInboxCount = DomainMapper().bankingSurface(
            document: original,
            transactionPresentation: [:]
        ).observations.count

        let binding = try #require(original.externalAccountBindings.first { candidate in
            candidate.isActive
                && candidate.syncStartBoundary < evidenceDay
                && original.accounts.contains(where: { account in
                    account.id == candidate.localAccountID
                        && original.balances.contains(where: { balance in
                            balance.accountID == account.id
                        })
                })
        })
        let account = try #require(original.accounts.first {
            $0.id == binding.localAccountID
        })
        #expect(original.balances.contains { $0.accountID == account.id })

        func observation(_ suffix: String) -> ExternalObservation {
            ExternalObservation(
                id: "phase26-rehearsal-\(suffix)",
                bindingID: binding.id,
                provider: binding.provider,
                status: .booked,
                creditDebitIndicator: .debit,
                amount: Money(minorUnits: -349, currency: account.currency),
                bookingDate: evidenceDay,
                transactionDate: evidenceDay,
                rawMerchantText: "Synthetic rehearsal evidence",
                structuredMerchantName: "Synthetic Rehearsal Merchant",
                bankTransactionCode: "CARD_PURCHASE",
                eligibleForEconomicActual: true,
                observedAt: timestamp
            )
        }
        var seeded = original
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: [
                observation("support-1"),
                observation("support-2"),
                observation("target")
            ]),
            into: &seeded
        )
        let presentation = try Dictionary(
            uniqueKeysWithValues: container.mainContext.fetch(
                FetchDescriptor<StoredTransaction>()
            ).map {
                (
                    $0.identifier,
                    DomainMapper.TransactionPresentation(
                        categoryKey: $0.appCategoryKey,
                        merchant: $0.appMerchant
                    )
                )
            }
        )
        let appMetadata = try StoredDocumentGraph.loadAppMetadata(
            from: container.mainContext
        )
        try StoredDocumentGraph.replace(
            with: seeded,
            in: container.mainContext,
            writtenOn: rehearsalDay,
            presentation: presentation,
            appMetadata: appMetadata
        )

        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(rehearsalDay)
        )
        try store.createExpense(
            from: "phase26-rehearsal-support-1",
            userLabel: "Synthetic rehearsal expense"
        )
        #expect(try load(container).trustedRules.isEmpty)
        try store.createExpense(
            from: "phase26-rehearsal-support-2",
            userLabel: "Synthetic rehearsal expense"
        )
        var document = try load(container)
        let rule = try #require(document.trustedRules.first)
        #expect(document.trustedRules.count == 1)
        #expect(rule.lifecycle == .draft)
        #expect(rule.supportingConfirmations.count == 2)
        #expect(rule.predicate.merchantField == .structuredMerchantName)
        #expect(rule.predicate.bankTransactionCode == "CARD_PURCHASE")
        #expect(rule.interpretation.transactionKind == .expense)

        let preview = try TrustedRuleEngine.preview(ruleID: rule.id, in: document)
        #expect(preview.matchedObservations == ["phase26-rehearsal-target"])
        #expect(preview.automaticallyEligibleObservations == ["phase26-rehearsal-target"])
        let summary = try #require(store.snapshot.trustedRules.first)
        #expect(summary.canApproveAutomatic)
        let beforeApproval = financialState(document)
        try store.approveTrustedRuleForAutomaticHandling(rule.id)
        document = try load(container)
        #expect(financialState(document) == beforeApproval)
        try store.setTrustedAutomationEnabled(true)

        let beforeApply = document
        let targetBefore = try #require(beforeApply.externalObservations.first {
            $0.id == "phase26-rehearsal-target"
        })
        let targetResolutionBefore = try #require(beforeApply.observationResolutions.first {
            $0.id == targetBefore.id
        })
        let beforeBalance = try #require(beforeApply.balances.first {
            $0.accountID == account.id
        })
        let first = try store.processTrustedRules(observationIDs: [targetBefore.id])
        #expect(first.appliedObservationIDs == [targetBefore.id])
        document = try load(container)
        #expect(document.transactions.count == beforeApply.transactions.count + 1)
        #expect(document.externalEvidenceLinks.count == beforeApply.externalEvidenceLinks.count + 1)
        let attemptsAfterFirst = document.trustedRuleAuditEvents.filter {
            $0.kind == .automaticallyResolved
        }
        #expect(attemptsAfterFirst.count == 1)
        let firstEvent = try #require(attemptsAfterFirst.first)
        let firstTransactionID = try #require(firstEvent.transactionID)
        let firstTransaction = try #require(document.transactions.first {
            $0.id == firstTransactionID
        })
        #expect(firstTransaction.kind == .expense)
        #expect(firstTransaction.date == targetBefore.suggestedEconomicDate)
        #expect(firstTransaction.bookedDate == targetBefore.bookingDate)
        #expect(firstTransaction.legs == [
            AccountLeg(accountID: account.id, amount: targetBefore.amount)
        ])
        #expect(firstTransaction.ownership == nil)
        #expect(firstTransaction.provenance.source == "TRUSTED-RULE")
        #expect(firstTransaction.provenance.evidenceGrade == .derived)
        let storedFirst = try #require(
            container.mainContext.fetch(FetchDescriptor<StoredTransaction>()).first {
                $0.identifier == firstTransactionID
            }
        )
        #expect(storedFirst.appCategoryKey == rule.interpretation.categoryKey)
        #expect(storedFirst.appMerchant == rule.interpretation.userLabel)
        #expect(document.externalObservations.first { $0.id == targetBefore.id } == targetBefore)
        #expect(document.providerBalanceSnapshots == beforeApply.providerBalanceSnapshots)
        #expect(document.planning == beforeApply.planning)
        #expect(
            document.observationResolutions.first { $0.id == targetBefore.id }?.state
                == .linkedToTransaction
        )
        #expect(targetResolutionBefore.state == .unreviewed)
        #expect(document.externalEvidenceLinks.filter {
            $0.observationID == targetBefore.id
                && $0.transactionID == firstTransactionID
                && $0.role == .accountMovement
        }.count == 1)
        #expect(
            document.balances.first { $0.accountID == account.id }?.balance.minorUnits
                == beforeBalance.balance.minorUnits
        )

        let afterFirst = document
        #expect(try store.processTrustedRules(
            observationIDs: [targetBefore.id]
        ).appliedObservationIDs.isEmpty)
        var reloaded = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(rehearsalDay)
        )
        #expect(try reloaded.processTrustedRules(
            observationIDs: [targetBefore.id]
        ).appliedObservationIDs.isEmpty)
        reloaded = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(rehearsalDay)
        )
        #expect(try reloaded.processTrustedRules(
            observationIDs: [targetBefore.id]
        ).appliedObservationIDs.isEmpty)
        #expect(try load(container) == afterFirst)

        try reloaded.reverseTrustedRuleApplication(firstEvent.id)
        let reversed = try load(container)
        #expect(reversed.transactions.first { $0.id == firstTransactionID }?.lifecycle == .reversed)
        #expect(reversed.observationResolutions.first { $0.id == targetBefore.id }?.state == .unreviewed)
        #expect(reversed.externalEvidenceLinks.filter { $0.observationID == targetBefore.id }.isEmpty)
        #expect(reversed.trustedRuleObservationSuppressions.filter(\.isActive).count == 1)
        #expect(
            reversed.balances.first { $0.accountID == account.id }?.balance
                == beforeBalance.balance
        )

        reloaded = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(rehearsalDay)
        )
        #expect(try reloaded.processTrustedRules(
            observationIDs: [targetBefore.id]
        ).appliedObservationIDs.isEmpty)
        #expect(try load(container) == reversed)

        try reloaded.authorizeTrustedRuleReapplication(
            ruleID: rule.id,
            observationID: targetBefore.id
        )
        reloaded = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(rehearsalDay)
        )
        let second = try reloaded.processTrustedRules(observationIDs: [targetBefore.id])
        #expect(second.appliedObservationIDs == [targetBefore.id])
        let reapplied = try load(container)
        let attempts = reapplied.trustedRuleAuditEvents.filter {
            $0.kind == .automaticallyResolved
        }
        #expect(attempts.count == 2)
        let secondTransactionID = try #require(attempts.last?.transactionID)
        #expect(secondTransactionID != firstTransactionID)
        #expect(reapplied.transactions.first { $0.id == firstTransactionID }?.lifecycle == .reversed)
        #expect(reapplied.externalEvidenceLinks.filter {
            $0.observationID == targetBefore.id && $0.role == .accountMovement
        }.count == 1)
        #expect(
            reapplied.balances.first { $0.accountID == account.id }?.balance.minorUnits
                == beforeBalance.balance.minorUnits - 349
        )
        #expect(throws: Never.self) { try TrustedRuleEngine.validate(reapplied) }

        let report: [String: Any] = [
            "source": "disposable-copy-of-real-device-store",
            "matchedObservation": "synthetic",
            "storedObservationsBeforeSyntheticFixtures": original.externalObservations.count,
            "visibleInboxObservationsBeforeSyntheticFixtures": originalInboxCount,
            "rulesBeforeSyntheticFixtures": original.trustedRules.count,
            "evidenceLinksBeforeSyntheticFixtures": original.externalEvidenceLinks.count,
            "proposalSupportCount": rule.supportingConfirmations.count,
            "approvalEconomicDelta": 0,
            "firstApplicationTransactionDelta": 1,
            "firstApplicationEvidenceLinkDelta": 1,
            "firstApplicationSuccessfulAuditDelta": 1,
            "repeatedApplicationTransactionDelta": 0,
            "repeatedApplicationEvidenceLinkDelta": 0,
            "repeatedApplicationSuccessfulAuditDelta": 0,
            "suppressedApplicationDelta": 0,
            "authorizedReapplicationTransactionDelta": 1,
            "currentAccountMovementLinks": 1,
            "automaticAttempts": 2,
            "oldAttemptRemainsReversed": true,
            "providerEvidenceMutatedByApplication": false,
            "budgetStateMutatedByApplication": false,
            "automaticProvenance": "derived",
            "accountingDateSource": "observation.suggestedEconomicDate",
            "passed": true
        ]
        let reportData = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys]
        )
        try reportData.write(
            to: directory.appendingPathComponent("sanitized-report.json"),
            options: .atomic
        )
    }
}
