import Foundation
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

/// Store-level adversarial audit for Phase 2.6 (base 32ab5b7 → 957e953).
///
/// Everything here runs against a real (in-memory) SwiftData container with a
/// store restart between every lifecycle transition, because the domain-level
/// guarantees only matter if they survive `replace` → `load` at each step.
/// The lifecycle driver mirrors exactly what activation wiring will have to
/// do: engine operation on the document, then whole-document persistence.
///
/// All data is synthetic. No real provider payload appears here.
@Suite("Trusted rules adversarial persistence audit")
@MainActor
struct TrustedRulesAdversarialAuditTests {
    private let timestamp = Date(timeIntervalSince1970: 1_777_680_000)
    private let boundary = Day(year: 2026, month: 8, day: 22)

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func row(
        _ id: String,
        bindingID: String,
        code: String? = "CARD_PURCHASE",
        status: ExternalObservationStatus = .booked,
        identity: ExternalObservationIdentity = .durable,
        eligible: Bool = true,
        observedAt: Date? = nil
    ) -> ExternalObservation {
        ExternalObservation(
            id: id,
            bindingID: bindingID,
            provider: .bnp,
            identity: identity,
            status: status,
            creditDebitIndicator: .debit,
            amount: Money(minorUnits: -349, currency: .eur),
            bookingDate: Day(year: 2026, month: 8, day: 24),
            structuredMerchantName: "Synthetic Merchant",
            bankTransactionCode: code,
            eligibleForEconomicActual: eligible,
            observedAt: observedAt ?? timestamp
        )
    }

    /// A document with two confirmed supports, one pending target row, and a
    /// drafted-but-unapproved automatic candidate rule.
    private func proposalSeedDocument() throws -> FinanceDocument {
        var document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "SYNTHETIC-AUDIT",
            accounts: [
                Account(
                    id: "local-bank", name: "Synthetic Bank", currency: .eur,
                    kind: .bank, supportedRails: [.cardDebit]
                )
            ],
            balances: [
                AccountBalance(
                    accountID: "local-bank",
                    balance: Money(minorUnits: 50_000, currency: .eur),
                    asOf: boundary
                )
            ],
            externalAccountBindings: [
                ExternalAccountBinding(
                    id: "binding", provider: .bnp,
                    remoteOpaqueAccountID: "acct_audit_synthetic",
                    localAccountID: "local-bank",
                    syncStartBoundary: boundary, createdAt: timestamp
                )
            ]
        )
        let supports = [
            row("support-1", bindingID: "binding"),
            row("support-2", bindingID: "binding")
        ]
        let target = row("target", bindingID: "binding")
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: supports + [target]), into: &document
        )
        return document
    }

    /// A document with two confirmed supports, one pending target row, and a
    /// drafted-but-unapproved automatic candidate rule.
    private func candidateDocument() throws -> FinanceDocument {
        var document = try proposalSeedDocument()
        let supports = [
            row("support-1", bindingID: "binding"),
            row("support-2", bindingID: "binding")
        ]
        var confirmed: [TrustedRuleSupport] = []
        for (index, support) in supports.enumerated() {
            let transaction = Transaction(
                id: "confirmed-\(index + 1)",
                date: Day(year: 2026, month: 8, day: 24),
                kind: .expense,
                legs: [AccountLeg(accountID: "local-bank", amount: support.amount)],
                factivity: .observed,
                provenance: Provenance(source: "AUDIT", evidenceGrade: .userConfirmed)
            )
            try ExternalEvidenceReview.createTransaction(
                transaction,
                evidence: [.init(observationID: support.id, role: .accountMovement)],
                resolvedAt: timestamp,
                in: &document
            )
            confirmed.append(
                TrustedRuleSupport(
                    observationID: support.id,
                    transactionID: transaction.id,
                    confirmedAt: timestamp
                )
            )
        }
        let rule = TrustedRule(
            id: "audit-rule",
            title: "Audit candidate",
            predicate: TrustedRulePredicate(
                provider: .bnp,
                bindingID: "binding",
                merchantField: .structuredMerchantName,
                merchantValue: "Synthetic Merchant",
                direction: .debit,
                currencyCode: "EUR",
                currencyExponent: 2
            ),
            interpretation: TrustedRuleInterpretation(transactionKind: .expense),
            supportingConfirmations: confirmed,
            createdAt: timestamp.addingTimeInterval(10)
        )
        try TrustedRuleEngine.addDraft(rule, auditEventID: "audit-created", in: &document)
        return document
    }

    private func activatedDocument(
        trust: TrustedRuleTrustLevel = .approvedAutomatic,
        includeTarget: Bool = false
    ) throws -> FinanceDocument {
        var document = try candidateDocument()
        if !includeTarget {
            document.externalObservations.removeAll { $0.id == "target" }
            document.observationResolutions.removeAll { $0.id == "target" }
        }
        try TrustedRuleEngine.approve(
            ruleID: "audit-rule",
            trustLevel: trust,
            at: timestamp.addingTimeInterval(20),
            auditEventID: "audit-approved",
            in: &document
        )
        return document
    }

    @Test("Approved automation cannot duplicate a transaction that names the incoming evidence")
    func recordedEvidenceBlocksAutomaticDuplicate() throws {
        let db = try container()
        var document = try activatedDocument(includeTarget: true)
        let target = try #require(document.externalObservations.first { $0.id == "target" })
        document.transactions.append(Transaction(id: "already-recorded-target", date: try #require(target.suggestedEconomicDate),
            kind: .expense, legs: [.init(accountID: "local-bank", amount: target.amount)], factivity: .observed,
            provenance: Provenance(source: "AUDIT", evidenceGrade: .userConfirmed, reference: target.id)))
        try persist(document, in: db.mainContext)
        let store = try FinanceStore(context: db.mainContext, now: fixtureInstant(Day(year: 2026, month: 8, day: 25)))
        try store.setTrustedAutomationEnabled(true)
        let before = try load(from: db)
        let result = try store.processTrustedRules(observationIDs: [target.id])
        #expect(result.appliedObservationIDs.isEmpty)
        #expect(result.ambiguousObservationIDs == [target.id])
        #expect(try load(from: db) == before)
    }

    @Test func evidenceAndAutomaticRuleUseAdvancingOperationTime() throws {
        let db = try container()
        var document = try activatedDocument(includeTarget: true)
        let manual = row("manual-clock-evidence", bindingID: "binding")
        try ExternalEvidenceReview.importBatch(.init(observations: [manual]), into: &document)
        document.transactions.append(Transaction(
            id: "manual-clock-transaction", date: try #require(manual.bookingDate), kind: .expense,
            legs: [.init(accountID: "local-bank", amount: manual.amount)], factivity: .observed,
            provenance: Provenance(source: "AUDIT", evidenceGrade: .userConfirmed)
        ))
        try persist(document, in: db.mainContext)
        let launch = timestamp.addingTimeInterval(3600)
        var current = launch
        let store = try FinanceStore(context: db.mainContext, clock: { current })
        current = launch.addingTimeInterval(3600)
        try store.matchObservation("manual-clock-evidence", toTransaction: "manual-clock-transaction")
        let resolved = try load(from: db)
        #expect(resolved.observationResolutions.first { $0.observationID == "manual-clock-evidence" }?.resolvedAt == current)

        try store.setTrustedAutomationEnabled(true)
        current = launch.addingTimeInterval(7200)
        let result = try store.processTrustedRules(observationIDs: ["target"])
        #expect(result.appliedObservationIDs == ["target"])
        let applied = try load(from: db)
        let audit = try #require(applied.trustedRuleAuditEvents.first { $0.kind == .automaticallyResolved })
        #expect(audit.occurredAt == current)
        #expect(applied.observationResolutions.first { $0.observationID == "target" }?.resolvedAt == current)
    }

    private func documentWithTwoAutomaticRules() throws -> FinanceDocument {
        var document = try activatedDocument()
        let first = try #require(document.trustedRules.first)
        let second = TrustedRule(
            id: "audit-rule-exact",
            title: "Exact synthetic amount",
            predicate: TrustedRulePredicate(
                provider: first.predicate.provider,
                bindingID: first.predicate.bindingID,
                merchantField: first.predicate.merchantField,
                merchantValue: first.predicate.merchantValue,
                direction: first.predicate.direction,
                currencyCode: first.predicate.currencyCode,
                currencyExponent: first.predicate.currencyExponent,
                exactMinorUnits: -349,
                bankTransactionCode: first.predicate.bankTransactionCode
            ),
            interpretation: first.interpretation,
            supportingConfirmations: first.supportingConfirmations,
            createdAt: timestamp.addingTimeInterval(30)
        )
        try TrustedRuleEngine.addDraft(
            second,
            auditEventID: "audit-created-exact",
            in: &document
        )
        try TrustedRuleEngine.approve(
            ruleID: second.id,
            trustLevel: .approvedAutomatic,
            at: timestamp.addingTimeInterval(40),
            auditEventID: "audit-approved-exact",
            in: &document
        )
        return document
    }

    private final class SelectiveWriteFailure {
        var writeCount = 0
    }

    private static func failFirstAutomaticWrite(
        _ state: SelectiveWriteFailure
    ) -> DocumentWriter {
        DocumentWriter { document, context, writtenOn, presentation, metadata in
            state.writeCount += 1
            if state.writeCount == 2 {
                try context.fetch(FetchDescriptor<StoredAccount>()).forEach(context.delete)
                try context.fetch(FetchDescriptor<StoredTrustedRule>()).forEach(context.delete)
                throw CocoaError(.fileWriteNoPermission)
            }
            try StoredDocumentGraph.replace(
                with: document,
                in: context,
                writtenOn: writtenOn,
                presentation: presentation,
                appMetadata: metadata
            )
        }
    }

    /// The whole-document persistence step activation wiring must use.
    private func persist(
        _ document: FinanceDocument,
        in context: ModelContext,
        appMetadata: AppPersistenceMetadata = .empty
    ) throws {
        try StoredDocumentGraph.replace(
            with: document,
            in: context,
            writtenOn: Day(year: 2026, month: 8, day: 24),
            appMetadata: appMetadata
        )
    }

    private func load(from container: ModelContainer) throws -> FinanceDocument {
        try #require(try StoredDocumentGraph.load(from: container.mainContext))
    }

    private struct FinancialFingerprint: Hashable {
        let accounts: [Account]
        let balances: [AccountBalance]
        let transactions: [Transaction]
        let evidence: [ExternalEvidenceLink]
        let resolutions: [ExternalObservationResolution]
        let observations: [ExternalObservation]
    }

    private func fingerprint(_ document: FinanceDocument) -> FinancialFingerprint {
        FinancialFingerprint(
            accounts: document.accounts,
            balances: document.balances,
            transactions: document.transactions,
            evidence: document.externalEvidenceLinks,
            resolutions: document.observationResolutions,
            observations: document.externalObservations
        )
    }

    // MARK: - Full lifecycle against SwiftData with restart between transitions

    @Test("Manual confirmations create one inspectable inactive proposal")
    func manualConfirmationsCreateProposalAndApprovalIsInert() throws {
        let container = try container()
        try persist(try proposalSeedDocument(), in: container.mainContext)
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )

        try store.createExpense(from: "support-1", userLabel: "Synthetic label")
        #expect(try load(from: container).trustedRules.isEmpty)
        // Distinct durable provider payments do not become duplicate warnings
        // merely because their amount, merchant and nearby dates coincide.
        try store.createExpense(
            from: "support-2",
            userLabel: "Synthetic label"
        )
        let proposed = try load(from: container)
        let rule = try #require(proposed.trustedRules.first)
        #expect(proposed.trustedRules.count == 1)
        #expect(rule.lifecycle == .draft)
        #expect(rule.trustLevel == .suggestionOnly)
        #expect(rule.predicate.merchantField == .structuredMerchantName)
        #expect(rule.predicate.bankTransactionCode == "CARD_PURCHASE")
        #expect(rule.predicate.exactMinorUnits == nil)
        #expect(rule.interpretation.transactionKind == .expense)
        #expect(rule.interpretation.userLabel == "Synthetic label")
        #expect(rule.supportingConfirmations.count == 2)
        #expect(Set(rule.supportingConfirmations.map(\.transactionID)).count == 2)
        #expect(Set(rule.supportingConfirmations.map(\.observationID)).count == 2)
        let summary = try #require(store.snapshot.trustedRules.first)
        #expect(summary.lifecycle == "Draft")
        #expect(summary.canApproveAutomatic)
        #expect(summary.currentAutomaticallyEligibleCount == 1)

        let beforeApproval = fingerprint(proposed)
        try store.approveTrustedRuleForAutomaticHandling(rule.id)
        let approved = try load(from: container)
        #expect(approved.trustedRules[0].lifecycle == .active)
        #expect(approved.trustedRules[0].trustLevel == .approvedAutomatic)
        #expect(fingerprint(approved) == beforeApproval)
        #expect(
            approved.trustedRuleAuditEvents.filter {
                $0.kind == .approvedForAutomaticResolution
            }.count == 1
        )

        try store.setTrustedAutomationEnabled(true)
        let result = try store.processTrustedRules(observationIDs: ["target"])
        #expect(result.appliedObservationIDs == ["target"])
        let applied = try load(from: container)
        let application = try #require(applied.trustedRuleAuditEvents.first {
            $0.kind == .automaticallyResolved
        })
        let transactionID = try #require(application.transactionID)
        let stored = try #require(
            container.mainContext.fetch(FetchDescriptor<StoredTransaction>()).first {
                $0.identifier == transactionID
            }
        )
        #expect(stored.appCategoryKey == rule.interpretation.categoryKey)
        #expect(stored.appMerchant == rule.interpretation.userLabel)
    }

    // MARK: - Controlled production activation

    @Test("Trusted Automation is persisted locally and defaults safely off")
    func trustedAutomationSettingDefaultsOffAndPersists() throws {
        let container = try container()
        let input = try activatedDocument(includeTarget: true)
        try persist(input, in: container.mainContext)

        var store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )
        #expect(!store.trustedAutomationEnabled)
        #expect(try load(from: container).transactions == input.transactions)

        try store.setTrustedAutomationEnabled(true)
        #expect(store.trustedAutomationEnabled)
        // Enabling never scans or processes the existing Inbox.
        #expect(try load(from: container).transactions == input.transactions)

        store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )
        #expect(store.trustedAutomationEnabled)
        try store.setTrustedAutomationEnabled(false)
        store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )
        #expect(!store.trustedAutomationEnabled)
    }

    @Test("Master off persists evidence but creates no automatic economics")
    func masterOffImportsEvidenceWithoutApplication() throws {
        let container = try container()
        let input = try activatedDocument()
        try persist(input, in: container.mainContext)
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )

        let result = try store.importBankEvidence(
            ExternalEvidenceBatch(observations: [row("target", bindingID: "binding")])
        )
        let after = try load(from: container)
        #expect(result == .empty)
        #expect(after.externalObservations.contains { $0.id == "target" })
        #expect(after.observationResolutions.first { $0.id == "target" }?.state == .unreviewed)
        #expect(after.transactions == input.transactions)
        #expect(after.externalEvidenceLinks == input.externalEvidenceLinks)
        #expect(after.trustedRuleAuditEvents.filter {
            $0.kind == .automaticallyResolved
        }.isEmpty)

        // Turning on later still does not process historical Inbox or a plain
        // replay of the same already-reachable booked row.
        try store.setTrustedAutomationEnabled(true)
        let replay = try store.importBankEvidence(
            ExternalEvidenceBatch(observations: [row("target", bindingID: "binding")])
        )
        #expect(replay.appliedObservationIDs.isEmpty)
        #expect(try load(from: container).transactions == input.transactions)
    }

    @Test("Master on respects suggestion-only trust")
    func masterOnSuggestionOnlyDoesNotApply() throws {
        let container = try container()
        let input = try activatedDocument(trust: .suggestionOnly)
        try persist(
            input,
            in: container.mainContext,
            appMetadata: AppPersistenceMetadata(trustedAutomationEnabled: true)
        )
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )

        let result = try store.importBankEvidence(
            ExternalEvidenceBatch(observations: [row("target", bindingID: "binding")])
        )
        #expect(result.evaluatedObservationCount == 1)
        #expect(result.appliedObservationIDs.isEmpty)
        #expect(try load(from: container).transactions == input.transactions)
    }

    @Test("Master on applies one approved safe new observation and ignores replay")
    func masterOnApprovedRuleAppliesNewObservationOnce() throws {
        let container = try container()
        let input = try activatedDocument()
        try persist(
            input,
            in: container.mainContext,
            appMetadata: AppPersistenceMetadata(trustedAutomationEnabled: true)
        )
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )
        let batch = ExternalEvidenceBatch(
            observations: [row("target", bindingID: "binding")]
        )

        let first = try store.importBankEvidence(batch)
        let afterFirst = try load(from: container)
        #expect(first.appliedObservationIDs == ["target"])
        #expect(first.failedObservationIDs.isEmpty)
        #expect(afterFirst.transactions.count == input.transactions.count + 1)
        #expect(afterFirst.externalEvidenceLinks.count == input.externalEvidenceLinks.count + 1)
        #expect(afterFirst.trustedRuleAuditEvents.filter {
            $0.kind == .automaticallyResolved
        }.count == 1)

        // A later fetch timestamp alone is not economic newness.
        let replay = try store.importBankEvidence(
            ExternalEvidenceBatch(observations: [
                row(
                    "target",
                    bindingID: "binding",
                    observedAt: timestamp.addingTimeInterval(60)
                )
            ])
        )
        #expect(replay.evaluatedObservationCount == 0)
        let afterReplay = try load(from: container)
        #expect(afterReplay.transactions == afterFirst.transactions)
        #expect(afterReplay.externalEvidenceLinks == afterFirst.externalEvidenceLinks)
        #expect(afterReplay.observationResolutions == afterFirst.observationResolutions)
        #expect(afterReplay.trustedRuleAuditEvents == afterFirst.trustedRuleAuditEvents)
        #expect(afterReplay.balances == afterFirst.balances)
    }

    @Test("Pending to durable booked transition becomes newly eligible exactly once")
    func pendingToBookedTransitionTriggersOnce() throws {
        let container = try container()
        let input = try activatedDocument()
        try persist(
            input,
            in: container.mainContext,
            appMetadata: AppPersistenceMetadata(trustedAutomationEnabled: true)
        )
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )
        let pending = row(
            "transition",
            bindingID: "binding",
            status: .pending,
            identity: .provisionalSnapshot,
            eligible: false
        )

        let first = try store.importBankEvidence(
            ExternalEvidenceBatch(observations: [pending])
        )
        #expect(first.evaluatedObservationCount == 0)
        #expect(try load(from: container).observationResolutions.first {
            $0.id == "transition"
        }?.state == .provisional)

        let promoted = try store.importBankEvidence(
            ExternalEvidenceBatch(observations: [row("transition", bindingID: "binding")])
        )
        #expect(promoted.appliedObservationIDs == ["transition"])
        let after = try load(from: container)
        #expect(after.transactions.count == input.transactions.count + 1)

        let replay = try store.importBankEvidence(
            ExternalEvidenceBatch(observations: [row("transition", bindingID: "binding")])
        )
        #expect(replay.evaluatedObservationCount == 0)
        #expect(try load(from: container) == after)
    }

    @Test("Multiple automatic rules fail closed with an Inbox explanation")
    func multipleAutomaticRulesFailClosed() throws {
        let container = try container()
        let input = try documentWithTwoAutomaticRules()
        try persist(
            input,
            in: container.mainContext,
            appMetadata: AppPersistenceMetadata(trustedAutomationEnabled: true)
        )
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )

        let result = try store.importBankEvidence(
            ExternalEvidenceBatch(observations: [row("target", bindingID: "binding")])
        )
        let after = try load(from: container)
        #expect(result.ambiguousObservationIDs == ["target"])
        #expect(result.appliedObservationIDs.isEmpty)
        #expect(after.transactions == input.transactions)
        #expect(after.trustedRuleAuditEvents.filter {
            $0.kind == .automaticallyResolved
        }.isEmpty)
        #expect(store.trustedAutomationDiagnostic?.contains("multiple trusted rules") == true)
        #expect(store.snapshot.syncedObservations.first {
            $0.id == "target"
        }?.trustedAutomationReviewReason == "Multiple trusted rules match")
    }

    @Test("Per-observation writes preserve evidence and continue after one failure")
    func perObservationFailureDoesNotBlockNextAndCanRetry() throws {
        let container = try container()
        let input = try activatedDocument()
        try persist(
            input,
            in: container.mainContext,
            appMetadata: AppPersistenceMetadata(trustedAutomationEnabled: true)
        )
        let state = SelectiveWriteFailure()
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25)),
            writer: Self.failFirstAutomaticWrite(state)
        )
        let batch = ExternalEvidenceBatch(observations: [
            row("a-fail", bindingID: "binding"),
            row("b-safe", bindingID: "binding")
        ])

        let first = try store.importBankEvidence(batch)
        let afterFirst = try load(from: container)
        #expect(first.failedObservationIDs == ["a-fail"])
        #expect(first.appliedObservationIDs == ["b-safe"])
        #expect(afterFirst.externalObservations.contains { $0.id == "a-fail" })
        #expect(afterFirst.externalObservations.contains { $0.id == "b-safe" })
        #expect(afterFirst.observationResolutions.first {
            $0.id == "a-fail"
        }?.state == .unreviewed)
        #expect(afterFirst.observationResolutions.first {
            $0.id == "b-safe"
        }?.state == .linkedToTransaction)
        #expect(afterFirst.transactions.count == input.transactions.count + 1)
        #expect(afterFirst.trustedRuleAuditEvents.filter {
            $0.kind == .automaticallyResolved
        }.count == 1)
        #expect(store.trustedAutomationDiagnostic != nil)

        // The plain provider replay is not "new", but the explicit persisted
        // retry marker makes the failed item eligible for one safe retry.
        let retry = try store.importBankEvidence(batch)
        let afterRetry = try load(from: container)
        #expect(retry.appliedObservationIDs == ["a-fail"])
        #expect(retry.failedObservationIDs.isEmpty)
        #expect(afterRetry.transactions.count == input.transactions.count + 2)
        #expect(afterRetry.trustedRuleAuditEvents.filter {
            $0.kind == .automaticallyResolved
        }.count == 2)
        #expect(store.trustedAutomationDiagnostic == nil)
    }

    @Test("Global and rule state are rechecked after preview before sync")
    func previewDoesNotOverrideGlobalOffOrDisabledRuleDuringSync() throws {
        do {
            let container = try container()
            let input = try activatedDocument(includeTarget: true)
            #expect(TrustedRuleEngine.decisions(
                for: "target", in: input
            ).first?.mode == .automaticResolution)
            var withoutTarget = input
            withoutTarget.externalObservations.removeAll { $0.id == "target" }
            withoutTarget.observationResolutions.removeAll { $0.id == "target" }
            try persist(
                withoutTarget,
                in: container.mainContext,
                appMetadata: AppPersistenceMetadata(trustedAutomationEnabled: true)
            )
            let store = try FinanceStore(
                context: container.mainContext,
                now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
            )
            try store.setTrustedAutomationEnabled(false)
            let result = try store.importBankEvidence(
                ExternalEvidenceBatch(observations: [row("target", bindingID: "binding")])
            )
            #expect(result == .empty)
            #expect(try load(from: container).transactions == withoutTarget.transactions)
        }

        do {
            let container = try container()
            var input = try activatedDocument(includeTarget: true)
            #expect(TrustedRuleEngine.decisions(
                for: "target", in: input
            ).first?.mode == .automaticResolution)
            input.externalObservations.removeAll { $0.id == "target" }
            input.observationResolutions.removeAll { $0.id == "target" }
            try TrustedRuleEngine.disable(
                ruleID: "audit-rule",
                at: timestamp.addingTimeInterval(50),
                auditEventID: "audit-disabled",
                in: &input
            )
            try persist(
                input,
                in: container.mainContext,
                appMetadata: AppPersistenceMetadata(trustedAutomationEnabled: true)
            )
            let store = try FinanceStore(
                context: container.mainContext,
                now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
            )
            let result = try store.importBankEvidence(
                ExternalEvidenceBatch(observations: [row("target", bindingID: "binding")])
            )
            #expect(result.appliedObservationIDs.isEmpty)
            #expect(try load(from: container).transactions == input.transactions)
        }
    }

    @Test("A disabled rule is superseded only by a current approved replacement")
    func replacementRuleUsesOnlyCurrentActiveState() throws {
        var input = try activatedDocument()
        try TrustedRuleEngine.disable(
            ruleID: "audit-rule",
            at: timestamp.addingTimeInterval(50),
            auditEventID: "audit-disabled",
            in: &input
        )
        let old = try #require(input.trustedRules.first)
        let replacement = TrustedRule(
            id: "replacement-rule",
            title: "Replacement",
            predicate: TrustedRulePredicate(
                provider: old.predicate.provider,
                bindingID: old.predicate.bindingID,
                merchantField: old.predicate.merchantField,
                merchantValue: old.predicate.merchantValue,
                direction: old.predicate.direction,
                currencyCode: old.predicate.currencyCode,
                currencyExponent: old.predicate.currencyExponent,
                exactMinorUnits: -349,
                bankTransactionCode: old.predicate.bankTransactionCode
            ),
            interpretation: old.interpretation,
            supportingConfirmations: old.supportingConfirmations,
            createdAt: timestamp.addingTimeInterval(60)
        )
        try TrustedRuleEngine.addDraft(
            replacement,
            auditEventID: "replacement-created",
            in: &input
        )
        try TrustedRuleEngine.approve(
            ruleID: replacement.id,
            trustLevel: .approvedAutomatic,
            at: timestamp.addingTimeInterval(70),
            auditEventID: "replacement-approved",
            in: &input
        )
        let container = try container()
        try persist(
            input,
            in: container.mainContext,
            appMetadata: AppPersistenceMetadata(trustedAutomationEnabled: true)
        )
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )

        let result = try store.importBankEvidence(
            ExternalEvidenceBatch(observations: [row("target", bindingID: "binding")])
        )
        #expect(result.appliedObservationIDs == ["target"])
        let output = try load(from: container)
        let event = try #require(output.trustedRuleAuditEvents.first {
            $0.kind == .automaticallyResolved
        })
        #expect(event.ruleID == replacement.id)
    }

    @Test("Full rule lifecycle survives store restart between every transition")
    func fullLifecycleWithRestartBetweenEveryTransition() throws {
        let container = try container()
        let input = try candidateDocument()

        // Transition 1: automatic approval changes only rule/audit state.
        try persist(input, in: container.mainContext)
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )
        let beforeApproval = try load(from: container)
        let beforeApprovalFinancial = fingerprint(beforeApproval)
        try store.approveTrustedRuleForAutomaticHandling("audit-rule")
        var document = try load(from: container)
        #expect(document.trustedRules[0].trustLevel == .approvedAutomatic)
        #expect(document.trustedRules[0].lifecycle == .active)
        #expect(fingerprint(document) == beforeApprovalFinancial)
        try store.setTrustedAutomationEnabled(true)

        // Transition 2: the canonical store boundary applies and persists one
        // exact economic event.
        let beforeApply = document
        let result = try store.processTrustedRules(observationIDs: ["target"])
        #expect(result.evaluatedObservationCount == 1)
        #expect(result.appliedObservationIDs == ["target"])
        #expect(result.ambiguousObservationIDs.isEmpty)
        document = try load(from: container)
        #expect(document.transactions.count == beforeApply.transactions.count + 1)
        #expect(document.externalEvidenceLinks.count == beforeApply.externalEvidenceLinks.count + 1)
        #expect(
            document.trustedRuleAuditEvents.filter { $0.kind == .automaticallyResolved }.count
                == beforeApply.trustedRuleAuditEvents.filter { $0.kind == .automaticallyResolved }.count + 1
        )
        let application = try #require(document.trustedRuleAuditEvents.first {
            $0.kind == .automaticallyResolved
        })
        let transactionID = try #require(application.transactionID)
        let transaction = try #require(document.transactions.first { $0.id == transactionID })
        let target = try #require(document.externalObservations.first { $0.id == "target" })
        #expect(transaction.lifecycle == .cleared)
        #expect(transaction.kind == .expense)
        #expect(transaction.date == target.suggestedEconomicDate)
        #expect(transaction.bookedDate == target.bookingDate)
        #expect(transaction.legs == [
            AccountLeg(accountID: "local-bank", amount: target.amount)
        ])
        #expect(transaction.ownership == nil)
        #expect(transaction.provenance.source == "TRUSTED-RULE")
        #expect(transaction.provenance.evidenceGrade == .derived)
        #expect(transaction.provenance.reference == "audit-rule")
        #expect(
            document.observationResolutions.first { $0.id == "target" }?.state
                == .linkedToTransaction
        )
        #expect(document.externalObservations == beforeApply.externalObservations)
        #expect(
            document.externalEvidenceLinks.filter {
                $0.observationID == "target"
                    && $0.transactionID == transactionID
                    && $0.role == .accountMovement
            }.count == 1
        )
        #expect(document.balances[0].balance.minorUnits == 50_000)

        // Repeated processing, including two store reloads, is a strict no-op.
        let afterFirst = document
        #expect(try store.processTrustedRules(observationIDs: ["target"]).appliedObservationIDs.isEmpty)
        var reloaded = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )
        #expect(try reloaded.processTrustedRules(observationIDs: ["target"]).appliedObservationIDs.isEmpty)
        reloaded = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )
        #expect(try reloaded.processTrustedRules(observationIDs: ["target"]).appliedObservationIDs.isEmpty)
        #expect(try load(from: container) == afterFirst)

        // Transition 3: reversal, persisted, then restarted.
        try reloaded.reverseTrustedRuleApplication(application.id)
        document = try load(from: container)
        #expect(
            document.transactions.first { $0.id == transactionID }?.lifecycle
                == .reversed
        )
        #expect(document.trustedRuleObservationSuppressions.count == 1)
        #expect(document.trustedRuleObservationSuppressions[0].isActive)
        #expect(document.observationResolutions.first { $0.id == "target" }?.state == .unreviewed)
        #expect(document.externalEvidenceLinks.filter { $0.observationID == "target" }.isEmpty)
        #expect(document.balances[0].balance.minorUnits == 50_000)

        // Transition 4: persisted suppression makes processing a no-op.
        reloaded = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )
        #expect(try reloaded.processTrustedRules(observationIDs: ["target"]).appliedObservationIDs.isEmpty)
        #expect(try load(from: container) == document)

        // Transition 5: explicit authorization, persisted, then restarted.
        try reloaded.authorizeTrustedRuleReapplication(
            ruleID: "audit-rule", observationID: "target"
        )
        document = try load(from: container)
        #expect(!document.trustedRuleObservationSuppressions[0].isActive)

        // Transition 6: reapplication creates a second attempt with a new
        // transaction id; the reversed one stays historically inspectable.
        reloaded = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )
        let secondResult = try reloaded.processTrustedRules(observationIDs: ["target"])
        #expect(secondResult.appliedObservationIDs == ["target"])
        document = try load(from: container)
        let attempts = document.trustedRuleAuditEvents.filter { $0.kind == .automaticallyResolved }
        let secondTransactionID = try #require(attempts.last?.transactionID)
        #expect(secondTransactionID != transactionID)
        #expect(
            document.transactions.first { $0.id == transactionID }?.lifecycle
                == .reversed
        )
        #expect(attempts.count == 2)
        #expect(
            document.externalEvidenceLinks.filter { $0.observationID == "target" }.count == 1
        )
        #expect(document.balances[0].balance.minorUnits == 50_000)
        #expect(throws: Never.self) { try TrustedRuleEngine.validate(document) }

        // The rule surface after the full cycle reports the live match again.
        let surface = DomainMapper().bankingSurface(
            document: document, transactionPresentation: [:]
        )
        #expect(surface.trustedRules[0].currentBlockedMatches.isEmpty)
    }

    @Test("Pre-1.5 financial rows stay identical through migrate/apply/reverse")
    func pre15FinancialRowsRemainIdentical() throws {
        let container = try container()
        var document = try candidateDocument()
        let confirmed = document.transactions
        let observations = document.externalObservations
        document.schemaVersion = "1.4.0"
        document.trustedRules = []
        document.trustedRuleAuditEvents = []
        document.trustedRuleObservationSuppressions = []

        try persist(document, in: container.mainContext)
        let baseline = try load(from: container)
        #expect(baseline.schemaVersion == "1.4.0")
        #expect(baseline.trustedRules.isEmpty)
        let openingFinancial = fingerprint(baseline)

        document = baseline
        document.schemaVersion = Interchange.currentSchemaVersion
        let rule = TrustedRule(
            id: "audit-rule",
            title: "Audit candidate",
            predicate: TrustedRulePredicate(
                provider: .bnp,
                bindingID: "binding",
                merchantField: .structuredMerchantName,
                merchantValue: "Synthetic Merchant",
                direction: .debit,
                currencyCode: "EUR",
                currencyExponent: 2
            ),
            interpretation: TrustedRuleInterpretation(transactionKind: .expense),
            supportingConfirmations: [
                TrustedRuleSupport(
                    observationID: "support-1", transactionID: "confirmed-1",
                    confirmedAt: timestamp
                ),
                TrustedRuleSupport(
                    observationID: "support-2", transactionID: "confirmed-2",
                    confirmedAt: timestamp
                )
            ],
            createdAt: timestamp.addingTimeInterval(10)
        )
        try TrustedRuleEngine.addDraft(rule, auditEventID: "audit-created", in: &document)
        try TrustedRuleEngine.approve(
            ruleID: rule.id, trustLevel: .approvedAutomatic,
            at: timestamp.addingTimeInterval(30), auditEventID: "audit-approved",
            in: &document
        )
        let application = try TrustedRuleEngine.applyAutomatically(
            ruleID: rule.id, observationID: "target",
            at: timestamp.addingTimeInterval(40), in: &document
        )
        try TrustedRuleEngine.reverseApplication(
            auditEventID: application.auditEvent.id,
            reversalEventID: "audit-reversed",
            at: timestamp.addingTimeInterval(50), in: &document
        )
        try persist(document, in: container.mainContext)
        let migrated = try load(from: container)

        #expect(migrated.accounts == openingFinancial.accounts)
        #expect(migrated.balances == openingFinancial.balances)
        #expect(
            migrated.transactions.filter { $0.provenance.evidenceGrade == .userConfirmed }
                == confirmed
        )
        #expect(migrated.externalObservations == observations)
        #expect(migrated.trustedRuleObservationSuppressions.count == 1)
        #expect(throws: Never.self) { try TrustedRuleEngine.validate(migrated) }
    }

    // MARK: - Failure atomicity at the store boundary

    private static func failingWriter() -> DocumentWriter {
        DocumentWriter { _, context, _, _, _ in
            // Tear down part of the graph, then fail: the nastiest durable
            // state a partial write could leave.
            try context.fetch(FetchDescriptor<StoredAccount>()).forEach(context.delete)
            try context.fetch(FetchDescriptor<StoredTrustedRule>()).forEach(context.delete)
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    @Test("A failing rule-approval write leaves document and disk untouched")
    func failingApprovalWriteIsAtomic() throws {
        let container = try container()
        let input = try candidateDocument()
        try persist(input, in: container.mainContext)

        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25)),
            writer: Self.failingWriter()
        )
        let before = try load(from: container)
        let beforeFinancial = fingerprint(before)

        #expect(throws: (any Error).self) {
            try store.approveTrustedRuleForAutomaticHandling("audit-rule")
        }

        // The in-memory document was restored…
        #expect(store.snapshot.trustedRules[0].lifecycle == "Draft")
        // …and the rolled-back graph on disk still has its rows.
        let after = try load(from: container)
        #expect(after.accounts == beforeFinancial.accounts)
        #expect(after.trustedRules.map(\.id) == before.trustedRules.map(\.id))
        #expect(after.trustedRules[0].lifecycle == .draft)
        #expect(
            after.trustedRuleAuditEvents.count == before.trustedRuleAuditEvents.count
        )
    }

    @Test("A failing automatic-processing item rolls back and reports retry")
    func failingAutomaticProcessingWriteIsAtomic() throws {
        let container = try container()
        var input = try candidateDocument()
        try TrustedRuleEngine.approve(
            ruleID: "audit-rule",
            trustLevel: .approvedAutomatic,
            at: timestamp,
            auditEventID: "audit-approved",
            in: &input
        )
        try persist(
            input,
            in: container.mainContext,
            appMetadata: AppPersistenceMetadata(trustedAutomationEnabled: true)
        )
        let before = try load(from: container)
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25)),
            writer: Self.failingWriter()
        )

        let result = try store.processTrustedRules(observationIDs: ["target"])
        #expect(result.appliedObservationIDs.isEmpty)
        #expect(result.failedObservationIDs == ["target"])
        #expect(try store.exportDocument() == before)
        #expect(try load(from: container) == before)
    }

    @Test("Preview never overrides later rule disablement or manual resolution")
    func previewIsNotProcessingAuthority() throws {
        do {
            let container = try container()
            var input = try candidateDocument()
            try TrustedRuleEngine.approve(
                ruleID: "audit-rule", trustLevel: .approvedAutomatic,
                at: timestamp, auditEventID: "audit-approved", in: &input
            )
            try persist(input, in: container.mainContext)
            let store = try FinanceStore(
                context: container.mainContext,
                now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
            )
            try store.setTrustedAutomationEnabled(true)
            #expect(TrustedRuleEngine.decisions(for: "target", in: input).first?.mode == .automaticResolution)
            try store.disableTrustedRule("audit-rule")
            let before = try load(from: container)
            #expect(try store.processTrustedRules(observationIDs: ["target"]).appliedObservationIDs.isEmpty)
            #expect(try load(from: container) == before)
        }

        do {
            let container = try container()
            var input = try candidateDocument()
            try TrustedRuleEngine.approve(
                ruleID: "audit-rule", trustLevel: .approvedAutomatic,
                at: timestamp, auditEventID: "audit-approved", in: &input
            )
            try persist(input, in: container.mainContext)
            let store = try FinanceStore(
                context: container.mainContext,
                now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
            )
            try store.setTrustedAutomationEnabled(true)
            #expect(TrustedRuleEngine.decisions(for: "target", in: input).first?.mode == .automaticResolution)
            try store.createExpense(
                from: "target",
                userLabel: "Manual review",
                allowingPotentialDuplicate: true
            )
            let before = try load(from: container)
            #expect(try store.processTrustedRules(observationIDs: ["target"]).appliedObservationIDs.isEmpty)
            #expect(try load(from: container) == before)
        }
    }

    @Test("UI current-match hiding does not become a domain approval invariant")
    func currentInboxHidingIsNotASemanticGate() throws {
        var document = try candidateDocument()
        let pending = row("pending-current", bindingID: "binding", code: "CARD_PURCHASE")
        // A booked identity with pending status is not economically eligible.
        let unsafe = ExternalObservation(
            id: pending.id,
            bindingID: pending.bindingID,
            provider: .bnp,
            status: .pending,
            creditDebitIndicator: .debit,
            amount: pending.amount,
            bookingDate: pending.bookingDate,
            structuredMerchantName: "Synthetic Merchant",
            bankTransactionCode: "CARD_PURCHASE",
            eligibleForEconomicActual: true,
            observedAt: timestamp
        )
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: [unsafe]), into: &document
        )
        let surface = DomainMapper().bankingSurface(
            document: document, transactionPresentation: [:]
        )
        let summary = try #require(surface.trustedRules.first)
        #expect(summary.automaticSafetyReasons.isEmpty)
        #expect(!summary.canApproveAutomatic)
        #expect(summary.canApproveSuggestionOnly)

        let container = try container()
        try persist(document, in: container.mainContext)
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )
        let before = try load(from: container)
        try store.approveTrustedRuleForAutomaticHandling("audit-rule")
        let after = try load(from: container)
        #expect(after.trustedRules[0].trustLevel == .approvedAutomatic)
        #expect(after.transactions == before.transactions)
        #expect(after.externalEvidenceLinks == before.externalEvidenceLinks)
        #expect(after.observationResolutions == before.observationResolutions)
        #expect(after.externalObservations == before.externalObservations)
    }

    @Test("Only the serialized FinanceStore boundary calls applyAutomatically")
    func onlyFinanceStoreInvokesAutomaticApplication() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "FinanceApp")
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        )
        var hits: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("applyAutomatically") {
                hits.append(url.lastPathComponent)
            }
        }
        #expect(hits == ["FinanceStore.swift"])
    }

    @Test("Binding IDs are derived from the remote opaque account, not a random UUID")
    func storeBindingIdentityIsRemoteDerived() throws {
        let source = try String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appending(path: "FinanceApp/Persistence/FinanceStore.swift")
                .path,
            encoding: .utf8
        )
        #expect(source.contains("id: \"binding-\\(remoteAccountID)\""))
    }
}
