import Foundation
import SwiftData
import Testing
import FinanceCore
@testable import FinanceApp

@Suite("External evidence persistence and app boundary")
@MainActor
struct ExternalEvidencePersistenceTests {
    private let timestamp = Date(timeIntervalSince1970: 1_777_680_000)
    private let boundary = Day(year: 2026, month: 8, day: 22)

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func evidenceDocument(linked: Bool = true) throws -> FinanceDocument {
        let account = Account(
            id: "local-bank", name: "Synthetic Bank", currency: .eur, kind: .bank,
            supportedRails: [.cardDebit]
        )
        let binding = ExternalAccountBinding(
            id: "binding", provider: .bnp,
            remoteOpaqueAccountID: "acct_00000000000000000000000000000001",
            localAccountID: account.id, syncStartBoundary: boundary, createdAt: timestamp
        )
        let observation = ExternalObservation(
            id: "obs_00000000000000000000000000000001",
            bindingID: binding.id,
            provider: .bnp,
            status: .booked,
            creditDebitIndicator: .debit,
            amount: Money(minorUnits: -349, currency: .eur),
            bookingDate: Day(year: 2026, month: 8, day: 23),
            derivedTransactionDate: Day(year: 2026, month: 8, day: 21),
            derivedDateProvenance: .parsedFromProviderRemittance,
            rawMerchantText: "SYNTHETIC PROVIDER TEXT",
            merchantEmail: "billing@example.invalid",
            remittance: "SYNTHETIC PROVIDER TEXT",
            eligibleForEconomicActual: true,
            observedAt: timestamp
        )
        var document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [account],
            balances: [
                AccountBalance(
                    accountID: account.id,
                    balance: Money(minorUnits: 10_000, currency: .eur),
                    asOf: boundary
                )
            ],
            externalAccountBindings: [binding]
        )
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(
                observations: [observation],
                balances: [
                    ProviderBalanceSnapshot(
                        id: "balance", bindingID: binding.id, provider: .bnp,
                        balanceType: "CLBD", amount: Money(minorUnits: 9_900, currency: .eur),
                        referenceDate: Day(year: 2026, month: 8, day: 23), observedAt: timestamp
                    )
                ],
                candidates: [
                    CrossProviderCandidate(
                        id: "candidate", bankObservationID: observation.id,
                        walletObservationID: nil, state: .unresolved, candidateCount: 0,
                        amount: observation.amount.magnitude, rule: "synthetic-test",
                        computedAt: timestamp
                    )
                ]
            ),
            into: &document
        )
        if linked {
            let transaction = Transaction(
                id: "economic", date: Day(year: 2026, month: 8, day: 23), kind: .expense,
                legs: [AccountLeg(accountID: account.id, amount: observation.amount)],
                factivity: .observed,
                provenance: Provenance(source: "TEST", evidenceGrade: .userConfirmed)
            )
            try ExternalEvidenceReview.createTransaction(
                transaction,
                evidence: [.init(observationID: observation.id, role: .accountMovement)],
                resolvedAt: timestamp,
                in: &document
            )
            let rule = TrustedRule(
                id: "rule",
                title: "Synthetic suggestion rule",
                predicate: TrustedRulePredicate(
                    provider: .bnp,
                    bindingID: binding.id,
                    merchantField: .rawMerchantText,
                    merchantValue: "SYNTHETIC PROVIDER TEXT",
                    direction: .debit,
                    currencyCode: "EUR",
                    currencyExponent: 2,
                    exactMinorUnits: -349
                ),
                interpretation: TrustedRuleInterpretation(transactionKind: .expense),
                supportingConfirmations: [TrustedRuleSupport(
                    observationID: observation.id,
                    transactionID: transaction.id,
                    confirmedAt: timestamp
                )],
                createdAt: timestamp.addingTimeInterval(1)
            )
            try TrustedRuleEngine.addDraft(
                rule, auditEventID: "rule-created", in: &document
            )
            try TrustedRuleEngine.approve(
                ruleID: rule.id,
                trustLevel: .suggestionOnly,
                at: timestamp.addingTimeInterval(2),
                auditEventID: "rule-approved",
                in: &document
            )
        }
        return document
    }

    private func automaticCandidateDocument() throws -> FinanceDocument {
        var document = try evidenceDocument()
        document.trustedRules = []
        document.trustedRuleAuditEvents = []
        document.trustedRuleObservationSuppressions = []
        let bindingID = try #require(document.externalAccountBindings.first?.id)
        let accountID = try #require(document.accounts.first?.id)

        func row(_ id: String) -> ExternalObservation {
            ExternalObservation(
                id: id,
                bindingID: bindingID,
                provider: .bnp,
                status: .booked,
                creditDebitIndicator: .debit,
                amount: Money(minorUnits: -349, currency: .eur),
                bookingDate: Day(year: 2026, month: 8, day: 24),
                structuredMerchantName: "Synthetic Merchant",
                bankTransactionCode: "CARD_PURCHASE",
                eligibleForEconomicActual: true,
                observedAt: timestamp.addingTimeInterval(10)
            )
        }
        let firstSupport = row("support-automatic-1")
        let secondSupport = row("support-automatic-2")
        let target = row("current-automatic-target")
        try ExternalEvidenceReview.importBatch(
            .init(observations: [firstSupport, secondSupport, target]), into: &document
        )
        for (index, support) in [firstSupport, secondSupport].enumerated() {
            let confirmed = Transaction(
                id: "economic-automatic-\(index + 1)",
                date: Day(year: 2026, month: 8, day: 24),
                kind: .expense,
                legs: [AccountLeg(accountID: accountID, amount: support.amount)],
                factivity: .observed,
                provenance: Provenance(source: "TEST", evidenceGrade: .userConfirmed)
            )
            try ExternalEvidenceReview.createTransaction(
                confirmed,
                evidence: [.init(observationID: support.id, role: .accountMovement)],
                resolvedAt: timestamp,
                in: &document
            )
        }
        let rule = TrustedRule(
            id: "automatic-candidate-rule",
            title: "Synthetic structured merchant expense",
            predicate: TrustedRulePredicate(
                provider: .bnp,
                bindingID: bindingID,
                merchantField: .structuredMerchantName,
                merchantValue: "Synthetic Merchant",
                direction: .debit,
                currencyCode: "EUR",
                currencyExponent: 2
            ),
            interpretation: TrustedRuleInterpretation(
                transactionKind: .expense,
                categoryKey: nil,
                userLabel: nil
            ),
            supportingConfirmations: [
                TrustedRuleSupport(
                    observationID: firstSupport.id,
                    transactionID: "economic-automatic-1",
                    confirmedAt: timestamp
                ),
                TrustedRuleSupport(
                    observationID: secondSupport.id,
                    transactionID: "economic-automatic-2",
                    confirmedAt: timestamp
                )
            ],
            createdAt: timestamp.addingTimeInterval(20)
        )
        try TrustedRuleEngine.addDraft(
            rule, auditEventID: "automatic-rule-created", in: &document
        )
        return document
    }

    @Test("SwiftData round-trip preserves normalized evidence and stable ids")
    func roundTrip() throws {
        let container = try container()
        let input = try evidenceDocument()
        try StoredDocumentGraph.replace(
            with: input, in: container.mainContext,
            writtenOn: Day(year: 2026, month: 8, day: 23)
        )
        let loaded = try StoredDocumentGraph.load(from: container.mainContext)
        let output = try #require(loaded)
        #expect(output.externalAccountBindings == input.externalAccountBindings)
        #expect(output.externalObservations == input.externalObservations)
        #expect(output.providerBalanceSnapshots == input.providerBalanceSnapshots)
        #expect(output.externalEvidenceLinks == input.externalEvidenceLinks)
        #expect(output.observationResolutions == input.observationResolutions)
        #expect(output.crossProviderCandidates == input.crossProviderCandidates)
        #expect(output.trustedRules == input.trustedRules)
        #expect(output.trustedRuleAuditEvents == input.trustedRuleAuditEvents)
        #expect(output.trustedRuleObservationSuppressions == input.trustedRuleObservationSuppressions)
    }

    @Test("Observation review state and transaction link survive store restart")
    func restart() throws {
        let container = try container()
        try StoredDocumentGraph.replace(
            with: evidenceDocument(), in: container.mainContext,
            writtenOn: Day(year: 2026, month: 8, day: 23)
        )
        let restarted = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 23))
        )
        let item = try #require(restarted.snapshot.syncedObservations.first)
        #expect(item.resolution == .linked)
        #expect(restarted.snapshot.unreviewedSyncedObservations.isEmpty)
        #expect(try restarted.exportDocument().externalEvidenceLinks.first?.transactionID == "economic")
    }

    @Test("Provider balance remains separate from ledger balance")
    func providerBalanceSeparate() throws {
        let container = try container()
        let input = try evidenceDocument(linked: false)
        try StoredDocumentGraph.replace(
            with: input, in: container.mainContext,
            writtenOn: Day(year: 2026, month: 8, day: 23)
        )
        let loaded = try StoredDocumentGraph.load(from: container.mainContext)
        let output = try #require(loaded)
        #expect(output.balances[0].balance.minorUnits == 10_000)
        #expect(output.providerBalanceSnapshots[0].amount.minorUnits == 9_900)
        let mapper = DomainMapper().bankingSurface(document: output, transactionPresentation: [:],
            asOf: Day(year: 2026, month: 8, day: 23))
        #expect(mapper.balances[0].difference?.minorUnits == -100)
    }

    @Test("Surface binding omits backend account identity")
    func surfaceOmitsRemoteIdentity() throws {
        let input = try evidenceDocument(linked: false)
        let surface = DomainMapper().bankingSurface(document: input, transactionPresentation: [:])
        let rendered = String(reflecting: surface.bindings[0])
        #expect(!rendered.contains("acct_"))
        #expect(!rendered.contains("remoteOpaque"))
        #expect(surface.bindings[0].localAccountID == "local-bank")

        let linked = try evidenceDocument()
        let labeled = DomainMapper().bankingSurface(
            document: linked,
            transactionPresentation: [
                "economic": .init(categoryKey: nil, merchant: "User-confirmed label")
            ]
        )
        #expect(labeled.observations[0].displayMerchant == "User-confirmed label")
        #expect(labeled.observations[0].observedMerchant == "SYNTHETIC PROVIDER TEXT")
    }

    @Test("Evidence ingestion does not change transactions or ledger balance")
    func ingestionIsEvidenceOnly() async throws {
        let container = try container()
        var input = try evidenceDocument(linked: false)
        input.externalObservations = []
        input.providerBalanceSnapshots = []
        input.observationResolutions = []
        input.crossProviderCandidates = []
        try StoredDocumentGraph.replace(
            with: input, in: container.mainContext,
            writtenOn: Day(year: 2026, month: 8, day: 23)
        )
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 23))
        )
        let batch = try evidenceDocument(linked: false)
        try await store.importBankEvidence(
            from: LocalBankSyncProvider(
                batch: .init(
                    observations: batch.externalObservations,
                    balances: batch.providerBalanceSnapshots
                )
            )
        )
        let output = try store.exportDocument()
        #expect(output.transactions.isEmpty)
        #expect(output.balances[0].balance.minorUnits == 10_000)
        #expect(output.externalObservations.count == 1)
    }

    @Test("Smart Inbox prioritizes risk, then high-confidence rule suggestions")
    func smartInboxPriority() throws {
        var input = try evidenceDocument()
        input.trustedRules = []
        input.trustedRuleAuditEvents = []
        let bindingID = try #require(input.externalAccountBindings.first?.id)
        let accountID = try #require(input.accounts.first?.id)

        func row(_ id: String, code: String) -> ExternalObservation {
            ExternalObservation(
                id: id,
                bindingID: bindingID,
                provider: .bnp,
                status: .booked,
                creditDebitIndicator: .debit,
                amount: Money(minorUnits: -349, currency: .eur),
                bookingDate: Day(year: 2026, month: 8, day: 23),
                rawMerchantText: "SEPARATE PROVIDER DESCRIPTION",
                structuredMerchantName: "Synthetic Merchant",
                merchantEmail: "billing@example.invalid",
                bankTransactionCode: code,
                eligibleForEconomicActual: true,
                observedAt: timestamp.addingTimeInterval(10)
            )
        }
        let firstSupport = row("support-1", code: "CARD_PURCHASE")
        let secondSupport = row("support-2", code: "CARD_PURCHASE")
        let high = row("target-high", code: "CARD_PURCHASE")
        let risky = row("target-risky", code: "ATM_WITHDRAWAL")
        try ExternalEvidenceReview.importBatch(
            .init(observations: [firstSupport, secondSupport, high, risky]), into: &input
        )
        for (index, support) in [firstSupport, secondSupport].enumerated() {
            let confirmed = Transaction(
                id: "economic-smart-\(index + 1)",
                date: Day(year: 2026, month: 8, day: 23),
                kind: .expense,
                legs: [AccountLeg(accountID: accountID, amount: support.amount)],
                factivity: .observed,
                provenance: Provenance(source: "TEST", evidenceGrade: .userConfirmed)
            )
            try ExternalEvidenceReview.createTransaction(
                confirmed,
                evidence: [.init(observationID: support.id, role: .accountMovement)],
                resolvedAt: timestamp,
                in: &input
            )
        }
        let rule = TrustedRule(
            id: "rule-high-confidence",
            title: "Synthetic structured-merchant expense",
            predicate: TrustedRulePredicate(
                provider: .bnp,
                bindingID: bindingID,
                merchantField: .structuredMerchantName,
                merchantValue: "Synthetic Merchant",
                direction: .debit,
                currencyCode: "EUR",
                currencyExponent: 2
            ),
            interpretation: TrustedRuleInterpretation(
                transactionKind: .expense,
                categoryKey: nil,
                userLabel: nil
            ),
            supportingConfirmations: [
                TrustedRuleSupport(
                    observationID: firstSupport.id,
                    transactionID: "economic-smart-1",
                    confirmedAt: timestamp
                ),
                TrustedRuleSupport(
                    observationID: secondSupport.id,
                    transactionID: "economic-smart-2",
                    confirmedAt: timestamp
                )
            ],
            createdAt: timestamp.addingTimeInterval(20)
        )
        try TrustedRuleEngine.addDraft(rule, auditEventID: "rule-created", in: &input)
        try TrustedRuleEngine.approve(
            ruleID: rule.id,
            trustLevel: .approvedAutomatic,
            at: timestamp.addingTimeInterval(21),
            auditEventID: "rule-approved",
            in: &input
        )

        let surface = DomainMapper().bankingSurface(
            document: input,
            transactionPresentation: [:]
        )
        #expect(surface.observations[0].id == risky.id)
        #expect(surface.observations[0].inboxPriority == .risky)
        #expect(surface.observations[1].id == high.id)
        #expect(surface.observations[1].inboxPriority == .highConfidenceSuggestion)
        let suggestion = try #require(surface.observations[1].primarySuggestion)
        #expect(suggestion.kind == .trustedRule)
        #expect(suggestion.confidence == .high)
        #expect(suggestion.automaticResolutionEligible)
        #expect(suggestion.explanation?.contains("2 prior explicit confirmation") == true)
    }

    @Test("Proposed-rule surface exposes approval evidence, safety, and dry-run counts")
    func proposedRuleApprovalSurface() throws {
        let input = try automaticCandidateDocument()
        let surface = DomainMapper().bankingSurface(
            document: input,
            transactionPresentation: [:]
        )
        let rule = try #require(surface.trustedRules.first)

        #expect(rule.lifecycle == "Draft")
        #expect(rule.trust == "Suggestion only")
        #expect(rule.canApproveSuggestionOnly)
        #expect(rule.canApproveAutomatic)
        #expect(rule.automaticSafetyReasons.isEmpty)
        #expect(rule.supportingConfirmations.count == 2)
        #expect(rule.supportingConfirmations.allSatisfy { $0.amount != nil })
        #expect(rule.currentMatchCount == 1)
        #expect(rule.currentAutomaticallyEligibleCount == 1)
        #expect(rule.currentSuggestionOnlyCount == 0)
        #expect(rule.currentBlockedMatches.isEmpty)
        #expect(rule.semanticFingerprint.hasPrefix("trfp1_"))

        let unsafe = try #require(DomainMapper().bankingSurface(
            document: evidenceDocument(),
            transactionPresentation: [:]
        ).trustedRules.first)
        #expect(!unsafe.canApproveAutomatic)
        #expect(unsafe.automaticSafetyReasons.contains {
            $0.contains("structured merchant identity")
        })
    }

    @Test("Suggestion approval activates no current Inbox match")
    func suggestionApprovalDoesNotApplyCurrentMatches() throws {
        let container = try container()
        let input = try automaticCandidateDocument()
        try StoredDocumentGraph.replace(
            with: input,
            in: container.mainContext,
            writtenOn: Day(year: 2026, month: 8, day: 24)
        )
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )
        let before = try store.exportDocument()

        try store.approveTrustedRuleForSuggestions("automatic-candidate-rule")
        let after = try store.exportDocument()

        #expect(after.trustedRules.first?.lifecycle == .active)
        #expect(after.trustedRules.first?.trustLevel == .suggestionOnly)
        #expect(after.transactions == before.transactions)
        #expect(after.externalEvidenceLinks == before.externalEvidenceLinks)
        #expect(after.observationResolutions == before.observationResolutions)
        #expect(after.balances == before.balances)
        #expect(after.trustedRuleAuditEvents.count == before.trustedRuleAuditEvents.count + 1)
    }

    @Test("Automatic approval grants future trust without applying current matches")
    func automaticApprovalDoesNotApplyCurrentMatches() throws {
        let container = try container()
        let input = try automaticCandidateDocument()
        try StoredDocumentGraph.replace(
            with: input,
            in: container.mainContext,
            writtenOn: Day(year: 2026, month: 8, day: 24)
        )
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )
        let before = try store.exportDocument()

        try store.approveTrustedRuleForAutomaticHandling("automatic-candidate-rule")
        let after = try store.exportDocument()

        #expect(after.trustedRules.first?.lifecycle == .active)
        #expect(after.trustedRules.first?.trustLevel == .approvedAutomatic)
        #expect(after.transactions == before.transactions)
        #expect(after.externalEvidenceLinks == before.externalEvidenceLinks)
        #expect(after.observationResolutions == before.observationResolutions)
        #expect(after.balances == before.balances)
        #expect(after.trustedRuleAuditEvents.last?.kind == .approvedForAutomaticResolution)
        #expect(store.snapshot.trustedRules.first?.currentAutomaticallyEligibleCount == 1)
    }

    @Test("Reversal suppression and audit survive store restart")
    func reversalSuppressionPersists() throws {
        var input = try automaticCandidateDocument()
        try TrustedRuleEngine.approve(
            ruleID: "automatic-candidate-rule",
            trustLevel: .approvedAutomatic,
            at: timestamp.addingTimeInterval(30),
            auditEventID: "automatic-rule-approved",
            in: &input
        )
        let application = try TrustedRuleEngine.applyAutomatically(
            ruleID: "automatic-candidate-rule",
            observationID: "current-automatic-target",
            at: timestamp.addingTimeInterval(40),
            in: &input
        )
        try TrustedRuleEngine.reverseApplication(
            auditEventID: application.auditEvent.id,
            reversalEventID: "automatic-rule-reversed",
            at: timestamp.addingTimeInterval(50),
            in: &input
        )
        let container = try container()
        try StoredDocumentGraph.replace(
            with: input,
            in: container.mainContext,
            writtenOn: Day(year: 2026, month: 8, day: 24)
        )

        let restarted = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )
        let output = try restarted.exportDocument()
        let rule = try #require(restarted.snapshot.trustedRules.first)

        #expect(output.trustedRuleObservationSuppressions.count == 1)
        #expect(output.trustedRuleObservationSuppressions[0].isActive)
        #expect(output.trustedRuleAuditEvents.last?.kind == .reversed)
        #expect(rule.currentBlockedMatches.count == 1)
        #expect(rule.currentAutomaticallyEligibleCount == 0)
    }

    @Test("Disabling a rule persists audit without rewriting reviewed history")
    func disableRule() throws {
        let container = try container()
        let input = try evidenceDocument()
        try StoredDocumentGraph.replace(
            with: input,
            in: container.mainContext,
            writtenOn: Day(year: 2026, month: 8, day: 23)
        )
        let store = try FinanceStore(
            context: container.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 24))
        )
        let before = try store.exportDocument()
        try store.disableTrustedRule("rule")
        let after = try store.exportDocument()

        #expect(after.trustedRules.first?.lifecycle == .disabled)
        #expect(after.trustedRuleAuditEvents.last?.kind == .disabled)
        #expect(after.transactions == before.transactions)
        #expect(after.externalEvidenceLinks == before.externalEvidenceLinks)
        #expect(after.observationResolutions == before.observationResolutions)
        #expect(store.snapshot.trustedRules.first?.lifecycle == "Disabled")
    }

    @Test("A pre-1.5 SwiftData store opens with empty inert rule tables")
    func additiveStoreMigration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trusted-rules-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("FinanceCore-1.1.store")

        let excluded = Set([
            ObjectIdentifier(StoredTrustedRule.self),
            ObjectIdentifier(StoredTrustedRuleAuditEvent.self),
            ObjectIdentifier(StoredTrustedRuleObservationSuppression.self),
            ObjectIdentifier(StoredPlannedPurchase.self),
            ObjectIdentifier(StoredSinkingFund.self)
        ])
        let legacyModels = FinanceSchema.models.filter {
            !excluded.contains(ObjectIdentifier($0))
        }
        do {
            let legacy = try ModelContainer(
                for: Schema(legacyModels),
                configurations: ModelConfiguration(url: url)
            )
            var old = try evidenceDocument(linked: false)
            old.schemaVersion = "1.4.0"
            legacy.mainContext.insert(
                try StoredDocumentMeta(document: old, writtenOn: boundary)
            )
            old.accounts.enumerated().forEach {
                legacy.mainContext.insert(StoredAccount($0.element, sequence: $0.offset))
            }
            for (index, balance) in old.balances.enumerated() {
                legacy.mainContext.insert(try StoredAccountBalance(balance, sequence: index))
            }
            for (index, binding) in old.externalAccountBindings.enumerated() {
                legacy.mainContext.insert(try StoredExternalAccountBinding(binding, sequence: index))
            }
            for (index, observation) in old.externalObservations.enumerated() {
                legacy.mainContext.insert(try StoredExternalObservation(observation, sequence: index))
            }
            for (index, snapshot) in old.providerBalanceSnapshots.enumerated() {
                legacy.mainContext.insert(try StoredProviderBalanceSnapshot(snapshot, sequence: index))
            }
            old.observationResolutions.enumerated().forEach {
                legacy.mainContext.insert(StoredObservationResolution($0.element, sequence: $0.offset))
            }
            old.crossProviderCandidates.enumerated().forEach {
                legacy.mainContext.insert(StoredCrossProviderCandidate($0.element, sequence: $0.offset))
            }
            try legacy.mainContext.save()
        }

        let current = try ModelContainer(
            for: Schema(FinanceSchema.models),
            configurations: ModelConfiguration(url: url)
        )
        let loaded = try #require(try StoredDocumentGraph.load(from: current.mainContext))
        #expect(loaded.schemaVersion == "1.4.0")
        #expect(loaded.trustedRules.isEmpty)
        #expect(loaded.trustedRuleAuditEvents.isEmpty)
        #expect(loaded.trustedRuleObservationSuppressions.isEmpty)
        #expect(loaded.externalObservations.count == 1)
        let migratedStore = try FinanceStore(
            context: current.mainContext,
            now: fixtureInstant(Day(year: 2026, month: 8, day: 25))
        )
        #expect(!migratedStore.trustedAutomationEnabled)
    }

    @Test("App sources contain no backend admin credential")
    func noAdminCredential() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "FinanceApp")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var combined = ""
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            combined += try String(contentsOf: url, encoding: .utf8)
        }
        #expect(!combined.contains("ADMIN_API_TOKEN"))
        #expect(!combined.contains("Bearer "))
        #expect(!combined.contains("identification_hash"))
        #expect(!combined.contains("entry_reference"))
    }
}
