import XCTest
@testable import FinanceCore

final class TrustedRulesTests: XCTestCase {
    private let boundary = Day(year: 2026, month: 8, day: 20)
    private let day = Day(year: 2026, month: 8, day: 26)
    private let confirmedAt = Date(timeIntervalSince1970: 1_777_680_000)
    private let createdAt = Date(timeIntervalSince1970: 1_777_680_100)
    private let approvedAt = Date(timeIntervalSince1970: 1_777_680_200)

    private func document(
        supportCount: Int = 2,
        amount: Int64 = -1_299,
        kind: TransactionKind = .expense,
        incomeSourceID: String? = nil,
        merchantField: TrustedMerchantEvidenceField = .structuredMerchantName,
        exactMinorUnits: Int64? = nil
    ) throws -> (FinanceDocument, TrustedRule) {
        let account = Account(
            id: "bank", name: "Synthetic Bank", currency: .eur, kind: .bank,
            supportedRails: [.cardDebit, .sepaCreditTransfer]
        )
        let binding = ExternalAccountBinding(
            id: "binding-bank", provider: .bnp,
            remoteOpaqueAccountID: "acct_synthetic", localAccountID: account.id,
            syncStartBoundary: boundary, createdAt: confirmedAt
        )
        let source = IncomeSource(
            id: "income-source", name: "Explicit synthetic source",
            amount: Money(minorUnits: 0, currency: .eur), certainty: .guaranteed,
            schedule: .monthly(
                onDay: 26, from: MonthKey(year: 2026, month: 8), through: nil
            ), arrivesOnAccount: account.id
        )
        var value = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "SYNTHETIC-TEST",
            accounts: [account],
            balances: [AccountBalance(
                accountID: account.id,
                balance: Money(minorUnits: 100_000, currency: .eur),
                asOf: boundary
            )],
            incomeSources: [source],
            externalAccountBindings: [binding]
        )

        let observations = (0...supportCount).map { index in
            observation(
                "observation-\(index)", amount: amount,
                merchantField: merchantField
            )
        }
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: observations), into: &value
        )

        var supports: [TrustedRuleSupport] = []
        for index in 0..<supportCount {
            let observation = observations[index]
            let transaction = Transaction(
                id: "confirmed-\(index)", date: day, kind: kind,
                legs: [AccountLeg(accountID: account.id, amount: observation.amount)],
                incomeSourceID: incomeSourceID,
                factivity: .observed,
                provenance: Provenance(
                    source: "EXPLICIT-TEST-CONFIRMATION", evidenceGrade: .userConfirmed
                )
            )
            try ExternalEvidenceReview.createTransaction(
                transaction,
                evidence: [.init(observationID: observation.id, role: .accountMovement)],
                resolvedAt: confirmedAt,
                in: &value
            )
            supports.append(
                TrustedRuleSupport(
                    observationID: observation.id,
                    transactionID: transaction.id,
                    confirmedAt: confirmedAt,
                    categoryKey: kind == .expense ? "food" : "income",
                    userLabel: "Synthetic label"
                )
            )
        }

        let predicate = TrustedRulePredicate(
            provider: .bnp,
            bindingID: binding.id,
            merchantField: merchantField,
            merchantValue: merchantField == .merchantEmail
                ? "billing@example.invalid" : "Synthetic Merchant",
            direction: amount < 0 ? .debit : .credit,
            currencyCode: "EUR",
            currencyExponent: 2,
            exactMinorUnits: exactMinorUnits
        )
        let rule = TrustedRule(
            id: "trusted-rule",
            title: "Synthetic merchant rule",
            predicate: predicate,
            interpretation: TrustedRuleInterpretation(
                transactionKind: kind,
                categoryKey: kind == .expense ? "food" : "income",
                userLabel: "Synthetic label",
                incomeSourceID: incomeSourceID
            ),
            supportingConfirmations: supports,
            createdAt: createdAt
        )
        return (value, rule)
    }

    private func observation(
        _ id: String,
        amount: Int64 = -1_299,
        merchantField: TrustedMerchantEvidenceField = .structuredMerchantName,
        code: String? = "CARD_PURCHASE",
        status: ExternalObservationStatus = .booked,
        identity: ExternalObservationIdentity = .durable,
        eligible: Bool = true,
        bookingDate: Day? = nil,
        observedAt: Date? = nil
    ) -> ExternalObservation {
        ExternalObservation(
            id: id,
            bindingID: "binding-bank",
            provider: .bnp,
            identity: identity,
            status: status,
            creditDebitIndicator: amount < 0 ? .debit : .credit,
            amount: Money(minorUnits: amount, currency: .eur),
            bookingDate: bookingDate ?? day,
            rawMerchantText: merchantField == .rawMerchantText ? "Synthetic Merchant" : "Provider words stay evidence",
            structuredMerchantName: merchantField == .structuredMerchantName ? "Synthetic Merchant" : nil,
            merchantEmail: merchantField == .merchantEmail ? "billing@example.invalid" : nil,
            remittance: merchantField == .remittance ? "Synthetic Merchant" : nil,
            bankTransactionCode: code,
            eligibleForEconomicActual: eligible,
            observedAt: observedAt ?? confirmedAt
        )
    }

    private func addAndApprove(
        _ rule: TrustedRule,
        trust: TrustedRuleTrustLevel,
        in document: inout FinanceDocument
    ) throws {
        try TrustedRuleEngine.addDraft(rule, auditEventID: "audit-created", in: &document)
        try TrustedRuleEngine.approve(
            ruleID: rule.id,
            trustLevel: trust,
            at: approvedAt,
            auditEventID: "audit-approved",
            in: &document
        )
    }

    func testRuleBeginsInactiveAndSuggestionOnly() throws {
        var (value, rule) = try document()
        try TrustedRuleEngine.addDraft(rule, auditEventID: "audit-created", in: &value)

        XCTAssertEqual(value.trustedRules[0].lifecycle, .draft)
        XCTAssertEqual(value.trustedRules[0].trustLevel, .suggestionOnly)
        XCTAssertNil(TrustedRuleEngine.decision(
            for: "observation-2", rule: value.trustedRules[0], in: value
        ))
        XCTAssertEqual(value.trustedRuleAuditEvents.map(\.kind), [.created])
    }

    func testSuggestionApprovalNeverBecomesAutomatic() throws {
        var (value, rule) = try document()
        try addAndApprove(rule, trust: .suggestionOnly, in: &value)

        let decision = try XCTUnwrap(TrustedRuleEngine.decisions(
            for: "observation-2", in: value
        ).first)
        XCTAssertEqual(decision.mode, .suggestion)
        XCTAssertEqual(decision.confidence, .high)
        XCTAssertTrue(decision.explanation.contains("2 prior explicit confirmation"))
        XCTAssertTrue(decision.automaticBlockers.contains(.automaticTrustNotApproved))
    }

    func testExplicitAutomaticApprovalCanResolveNarrowExpense() throws {
        var (value, rule) = try document()
        try addAndApprove(rule, trust: .approvedAutomatic, in: &value)

        let decision = try XCTUnwrap(TrustedRuleEngine.decisions(
            for: "observation-2", in: value
        ).first)
        XCTAssertEqual(decision.mode, .automaticResolution)
        XCTAssertTrue(decision.automaticBlockers.isEmpty)
        XCTAssertEqual(decision.interpretation.categoryKey, "food")
        XCTAssertEqual(decision.interpretation.userLabel, "Synthetic label")
        XCTAssertNil(decision.interpretation.incomeSourceID)
    }

    func testAutomaticApprovalRequiresTwoPriorConfirmations() throws {
        var (value, rule) = try document(supportCount: 1)
        try TrustedRuleEngine.addDraft(rule, auditEventID: "audit-created", in: &value)

        XCTAssertThrowsError(try TrustedRuleEngine.approve(
            ruleID: rule.id,
            trustLevel: .approvedAutomatic,
            at: approvedAt,
            auditEventID: "audit-approved",
            in: &value
        )) { error in
            XCTAssertTrue(String(describing: error).contains("insufficientConfirmedSupport"))
        }
        XCTAssertEqual(value.trustedRules[0].lifecycle, .draft)
        XCTAssertEqual(value.trustedRuleAuditEvents.map(\.kind), [.created])
    }

    func testTwoConfirmationsOfOneEconomicEventCannotOpenTheAutomaticGate() throws {
        var value = try document(supportCount: 0).0
        let first = observation("movement-a")
        let second = observation("movement-b")
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: [first, second]), into: &value
        )
        let shared = Transaction(
            id: "shared-economic-event", date: day, kind: .expense,
            legs: [AccountLeg(accountID: "bank", amount: first.amount)],
            factivity: .observed,
            provenance: Provenance(
                source: "EXPLICIT-TEST-CONFIRMATION", evidenceGrade: .userConfirmed
            )
        )
        try ExternalEvidenceReview.createTransaction(
            shared,
            evidence: [
                .init(observationID: first.id, role: .accountMovement),
                .init(observationID: second.id, role: .accountMovement)
            ],
            resolvedAt: confirmedAt,
            in: &value
        )
        XCTAssertEqual(
            value.externalEvidenceLinks.filter { $0.transactionID == shared.id }.count, 2
        )

        let rule = TrustedRule(
            id: "shared-event-rule",
            title: "Shared economic event",
            predicate: TrustedRulePredicate(
                provider: .bnp,
                bindingID: "binding-bank",
                merchantField: .structuredMerchantName,
                merchantValue: "Synthetic Merchant",
                direction: .debit,
                currencyCode: "EUR",
                currencyExponent: 2
            ),
            interpretation: TrustedRuleInterpretation(
                transactionKind: .expense, categoryKey: "food", userLabel: "Synthetic label"
            ),
            supportingConfirmations: [
                TrustedRuleSupport(
                    observationID: first.id, transactionID: shared.id, confirmedAt: confirmedAt,
                    categoryKey: "food", userLabel: "Synthetic label"
                ),
                TrustedRuleSupport(
                    observationID: second.id, transactionID: shared.id, confirmedAt: confirmedAt,
                    categoryKey: "food", userLabel: "Synthetic label"
                )
            ],
            createdAt: createdAt
        )
        XCTAssertEqual(
            TrustedRuleEngine.independentConfirmedSupportCount(for: rule, in: value), 1
        )
        XCTAssertThrowsError(try TrustedRuleEngine.addDraft(
            rule, auditEventID: "audit-created", in: &value
        ))
    }

    func testNonStructuredMerchantEvidenceCanSuggestButNeverResolveAutomatically() throws {
        for field in [
            TrustedMerchantEvidenceField.merchantEmail, .rawMerchantText, .remittance
        ] {
            var (value, rule) = try document(merchantField: field)
            try TrustedRuleEngine.addDraft(rule, auditEventID: "audit-created", in: &value)
            XCTAssertThrowsError(try TrustedRuleEngine.approve(
                ruleID: rule.id,
                trustLevel: .approvedAutomatic,
                at: approvedAt,
                auditEventID: "audit-auto-denied",
                in: &value
            ), field.rawValue)
            try TrustedRuleEngine.approve(
                ruleID: rule.id,
                trustLevel: .suggestionOnly,
                at: approvedAt,
                auditEventID: "audit-approved",
                in: &value
            )

            let decision = try XCTUnwrap(TrustedRuleEngine.decisions(
                for: "observation-2", in: value
            ).first, field.rawValue)
            XCTAssertEqual(decision.mode, .suggestion, field.rawValue)
            XCTAssertTrue(
                decision.automaticBlockers.contains(.structuredMerchantIdentityRequired),
                field.rawValue
            )
        }
    }

    func testAmbiguousCrossProviderEvidenceNeverResolvesAutomatically() throws {
        var (value, rule) = try document()
        value.crossProviderCandidates = [CrossProviderCandidate(
            id: "candidate",
            bankObservationID: "observation-2",
            walletObservationID: nil,
            state: .ambiguous,
            candidateCount: 2,
            amount: Money(minorUnits: 1_299, currency: .eur),
            rule: "synthetic ambiguous candidate",
            computedAt: confirmedAt
        )]
        try addAndApprove(rule, trust: .approvedAutomatic, in: &value)

        let decision = try XCTUnwrap(TrustedRuleEngine.decisions(
            for: "observation-2", in: value
        ).first)
        XCTAssertEqual(decision.mode, .suggestion)
        XCTAssertTrue(decision.automaticBlockers.contains(.crossProviderEvidenceRequiresJudgment))
    }

    func testRiskyProviderCodesRemainSuggestionOnly() throws {
        let cases: [(String, TrustedRuleAutomaticBlocker)] = [
            ("ATM_WITHDRAWAL", .atmOrCashRequiresJudgment),
            ("INTERNAL_TRANSFER", .transferRequiresJudgment),
            ("INSTALLMENT_PAYMENT", .financingRequiresJudgment),
            ("FX_EXCHANGE", .foreignExchangeRequiresJudgment),
            ("CARD_REFUND", .refundOrReversalRequiresJudgment),
            ("CARD_DEBIT", .unresolvedEconomicsRequiresJudgment)
        ]
        for (code, expected) in cases {
            var (value, rule) = try document()
            value.externalObservations.removeAll { $0.id == "observation-2" }
            value.observationResolutions.removeAll { $0.observationID == "observation-2" }
            try ExternalEvidenceReview.importBatch(
                ExternalEvidenceBatch(observations: [observation("observation-2", code: code)]),
                into: &value
            )
            try addAndApprove(rule, trust: .approvedAutomatic, in: &value)

            let decision = try XCTUnwrap(TrustedRuleEngine.decisions(
                for: "observation-2", in: value
            ).first, code)
            XCTAssertEqual(decision.mode, .suggestion, code)
            XCTAssertTrue(decision.automaticBlockers.contains(expected), code)
        }
    }

    func testPassThroughAndOtherUnsafeEconomicKindsNeverResolveAutomatically() throws {
        for kind in [
            TransactionKind.passThrough, .transfer, .refund, .financingRepayment,
            .cashWithdrawal, .currencyConversion
        ] {
            var (value, rule) = try document(kind: kind)
            try TrustedRuleEngine.addDraft(rule, auditEventID: "audit-created", in: &value)
            XCTAssertThrowsError(try TrustedRuleEngine.approve(
                ruleID: rule.id,
                trustLevel: .approvedAutomatic,
                at: approvedAt,
                auditEventID: "audit-auto-denied",
                in: &value
            ), kind.rawValue)
            try TrustedRuleEngine.approve(
                ruleID: rule.id,
                trustLevel: .suggestionOnly,
                at: approvedAt,
                auditEventID: "audit-approved",
                in: &value
            )
            let decision = try XCTUnwrap(TrustedRuleEngine.decisions(
                for: "observation-2", in: value
            ).first, kind.rawValue)
            XCTAssertEqual(decision.mode, .suggestion, kind.rawValue)
            XCTAssertFalse(decision.automaticBlockers.isEmpty, kind.rawValue)
        }
    }

    func testRecurringObligationSettlementRemainsSuggestionOnly() throws {
        var (value, baseRule) = try document()
        value.planning.recurringObligations = [
            RecurringObligation(
                id: "obligation",
                name: "Synthetic obligation",
                amount: Money(minorUnits: 1_299, currency: .eur),
                spec: .monthly(
                    onDay: 26,
                    from: MonthKey(year: 2026, month: 8),
                    through: nil
                ),
                requirement: .euroBankPayment(rails: [.cardDebit]),
                spendingClass: .essential
            )
        ]
        let rule = TrustedRule(
            id: baseRule.id,
            title: baseRule.title,
            predicate: baseRule.predicate,
            interpretation: TrustedRuleInterpretation(
                transactionKind: .expense,
                categoryKey: "food",
                userLabel: "Synthetic label",
                recurringObligationID: "obligation"
            ),
            supportingConfirmations: baseRule.supportingConfirmations,
            createdAt: baseRule.createdAt
        )
        try TrustedRuleEngine.addDraft(rule, auditEventID: "audit-created", in: &value)
        XCTAssertThrowsError(try TrustedRuleEngine.approve(
            ruleID: rule.id,
            trustLevel: .approvedAutomatic,
            at: approvedAt,
            auditEventID: "audit-auto-denied",
            in: &value
        ))
        try TrustedRuleEngine.approve(
            ruleID: rule.id,
            trustLevel: .suggestionOnly,
            at: approvedAt,
            auditEventID: "audit-approved",
            in: &value
        )
        let decision = try XCTUnwrap(TrustedRuleEngine.decisions(
            for: "observation-2", in: value
        ).first)
        XCTAssertEqual(decision.mode, .suggestion)
        XCTAssertTrue(decision.automaticBlockers.contains(.recurringSettlementRequiresJudgment))
    }

    func testAllIncomingCreditsRemainSuggestionOnlyInFirstRelease() throws {
        var (safe, safeRule) = try document(
            supportCount: 3,
            amount: 75_000,
            kind: .income,
            incomeSourceID: "income-source",
            merchantField: .merchantEmail,
            exactMinorUnits: 75_000
        )
        try TrustedRuleEngine.addDraft(safeRule, auditEventID: "audit-created", in: &safe)
        XCTAssertThrowsError(try TrustedRuleEngine.approve(
            ruleID: safeRule.id,
            trustLevel: .approvedAutomatic,
            at: approvedAt,
            auditEventID: "audit-auto-denied",
            in: &safe
        ))
        try TrustedRuleEngine.approve(
            ruleID: safeRule.id,
            trustLevel: .suggestionOnly,
            at: approvedAt,
            auditEventID: "audit-approved",
            in: &safe
        )
        XCTAssertEqual(TrustedRuleEngine.decisions(
            for: "observation-3", in: safe
        ).first?.mode, .suggestion)

        var (unusual, unusualRule) = try document(
            supportCount: 3,
            amount: 75_000,
            kind: .income,
            incomeSourceID: "income-source",
            merchantField: .merchantEmail
        )
        try addAndApprove(unusualRule, trust: .suggestionOnly, in: &unusual)
        let decision = try XCTUnwrap(TrustedRuleEngine.decisions(
            for: "observation-3", in: unusual
        ).first)
        XCTAssertEqual(decision.mode, .suggestion)
        XCTAssertTrue(decision.automaticBlockers.contains(.unusualCreditRequiresJudgment))
        XCTAssertEqual(decision.interpretation.incomeSourceID, "income-source")
        XCTAssertEqual(decision.interpretation.categoryKey, "income")
    }

    func testAutomaticApplicationUsesDerivedProvenanceAndAppendOnlyAudit() throws {
        var (value, rule) = try document()
        try addAndApprove(rule, trust: .approvedAutomatic, in: &value)
        let balanceBefore = value.balances

        let result = try TrustedRuleEngine.applyAutomatically(
            ruleID: rule.id,
            observationID: "observation-2",
            at: approvedAt,
            in: &value
        )

        XCTAssertEqual(result.transaction.provenance.evidenceGrade, .derived)
        XCTAssertEqual(result.transaction.provenance.reference, rule.id)
        XCTAssertEqual(result.categoryKey, "food")
        XCTAssertEqual(result.userLabel, "Synthetic label")
        XCTAssertEqual(value.balances, balanceBefore, "core application never rewrites provider or ledger balance evidence")
        XCTAssertEqual(
            value.observationResolutions.first { $0.id == "observation-2" }?.state,
            .linkedToTransaction
        )
        XCTAssertEqual(value.trustedRuleAuditEvents.last?.kind, .automaticallyResolved)
    }

    func testDisableStopsFutureMatchesWithoutRewritingPastApplication() throws {
        var (value, rule) = try document(supportCount: 3)
        try addAndApprove(rule, trust: .approvedAutomatic, in: &value)
        let application = try TrustedRuleEngine.applyAutomatically(
            ruleID: rule.id,
            observationID: "observation-3",
            at: approvedAt,
            in: &value
        )
        try TrustedRuleEngine.disable(
            ruleID: rule.id,
            at: approvedAt.addingTimeInterval(60),
            auditEventID: "audit-disabled",
            in: &value
        )

        XCTAssertTrue(TrustedRuleEngine.decisions(for: "observation-3", in: value).isEmpty)
        XCTAssertNotNil(value.transactions.first { $0.id == application.transaction.id })
        XCTAssertEqual(value.trustedRuleAuditEvents.map(\.kind), [
            .created, .approvedForAutomaticResolution, .automaticallyResolved, .disabled
        ])
    }

    func testExplicitReversalPreservesHistoryAndReturnsObservationToReview() throws {
        var (value, rule) = try document()
        try addAndApprove(rule, trust: .approvedAutomatic, in: &value)
        let application = try TrustedRuleEngine.applyAutomatically(
            ruleID: rule.id,
            observationID: "observation-2",
            at: approvedAt,
            in: &value
        )
        _ = try TrustedRuleEngine.reverseApplication(
            auditEventID: application.auditEvent.id,
            reversalEventID: "audit-reversal",
            at: approvedAt.addingTimeInterval(60),
            in: &value
        )

        XCTAssertEqual(
            value.transactions.first { $0.id == application.transaction.id }?.lifecycle,
            .reversed
        )
        XCTAssertFalse(value.externalEvidenceLinks.contains {
            $0.transactionID == application.transaction.id
        })
        XCTAssertEqual(
            value.observationResolutions.first { $0.id == "observation-2" }?.state,
            .unreviewed
        )
        XCTAssertEqual(value.trustedRuleAuditEvents.last?.kind, .reversed)
        XCTAssertEqual(value.trustedRuleAuditEvents.last?.sourceAuditEventID, application.auditEvent.id)
        XCTAssertEqual(value.trustedRuleObservationSuppressions.count, 1)

        let transactionCount = value.transactions.count
        let linkCount = value.externalEvidenceLinks.count
        let auditCount = value.trustedRuleAuditEvents.count
        let decision = try XCTUnwrap(TrustedRuleEngine.decisions(
            for: "observation-2", in: value
        ).first)
        XCTAssertEqual(decision.mode, .blocked)
        XCTAssertTrue(decision.automaticBlockers.contains(.userReversalSuppression))
        XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
            ruleID: rule.id,
            observationID: "observation-2",
            at: approvedAt.addingTimeInterval(120),
            in: &value
        ))
        XCTAssertEqual(value.transactions.count, transactionCount)
        XCTAssertEqual(value.externalEvidenceLinks.count, linkCount)
        XCTAssertEqual(value.trustedRuleAuditEvents.count, auditCount)
    }

    func testAutomaticApplicationIsIdempotentAcrossRepeatedEvaluation() throws {
        var (value, rule) = try document()
        try addAndApprove(rule, trust: .approvedAutomatic, in: &value)

        let first = try TrustedRuleEngine.applyAutomatically(
            ruleID: rule.id,
            observationID: "observation-2",
            at: approvedAt,
            in: &value
        )
        let transactionCount = value.transactions.count
        let linkCount = value.externalEvidenceLinks.count
        let auditCount = value.trustedRuleAuditEvents.count
        let second = try TrustedRuleEngine.applyAutomatically(
            ruleID: rule.id,
            observationID: "observation-2",
            at: approvedAt.addingTimeInterval(60),
            in: &value
        )

        XCTAssertEqual(second, first)
        XCTAssertEqual(value.transactions.count, transactionCount)
        XCTAssertEqual(value.externalEvidenceLinks.count, linkCount)
        XCTAssertEqual(value.trustedRuleAuditEvents.count, auditCount)
        XCTAssertEqual(value.trustedRuleAuditEvents.filter {
            $0.kind == .automaticallyResolved
        }.count, 1)
    }

    func testRepeatedImportAndReloadCannotDuplicateApplication() throws {
        var (value, rule) = try document()
        try addAndApprove(rule, trust: .approvedAutomatic, in: &value)
        let target = try XCTUnwrap(value.externalObservations.first {
            $0.id == "observation-2"
        })
        let first = try TrustedRuleEngine.applyAutomatically(
            ruleID: rule.id,
            observationID: target.id,
            at: approvedAt,
            in: &value
        )
        let counts = (
            value.transactions.count,
            value.externalEvidenceLinks.count,
            value.trustedRuleAuditEvents.count
        )

        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: [target]), into: &value
        )
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: [target]), into: &value
        )
        let reloaded = try Interchange.decode(Interchange.encode(value))
        var afterRestart = reloaded
        let second = try TrustedRuleEngine.applyAutomatically(
            ruleID: rule.id,
            observationID: target.id,
            at: approvedAt.addingTimeInterval(60),
            in: &afterRestart
        )

        XCTAssertEqual(second.auditEvent.id, first.auditEvent.id)
        XCTAssertEqual(second.transaction.id, first.transaction.id)
        XCTAssertEqual(afterRestart.transactions.count, counts.0)
        XCTAssertEqual(afterRestart.externalEvidenceLinks.count, counts.1)
        XCTAssertEqual(afterRestart.trustedRuleAuditEvents.count, counts.2)
    }

    func testImportAndRepeatedSnapshotsRemainEvidenceOnlyBeforeActivation() throws {
        var (value, rule) = try document()
        value.externalObservations.removeAll { $0.id == "observation-2" }
        value.observationResolutions.removeAll { $0.observationID == "observation-2" }
        try addAndApprove(rule, trust: .approvedAutomatic, in: &value)
        let target = observation("observation-2", observedAt: approvedAt)
        let transactionCount = value.transactions.count
        let auditCount = value.trustedRuleAuditEvents.count

        for _ in 0..<3 {
            try ExternalEvidenceReview.importBatch(
                ExternalEvidenceBatch(observations: [target]), into: &value
            )
        }

        XCTAssertEqual(value.transactions.count, transactionCount)
        XCTAssertEqual(value.externalEvidenceLinks.count, 2)
        XCTAssertEqual(value.trustedRuleAuditEvents.count, auditCount)
        XCTAssertEqual(
            try TrustedRuleEngine.preview(ruleID: rule.id, in: value)
                .automaticallyEligibleObservations,
            [target.id]
        )
    }

    func testDryRunIsPureAndClassifiesCurrentInbox() throws {
        var (value, rule) = try document()
        try addAndApprove(rule, trust: .approvedAutomatic, in: &value)
        let before = value

        let preview = try TrustedRuleEngine.preview(ruleID: rule.id, in: value)

        XCTAssertEqual(preview.matchedObservations, ["observation-2"])
        XCTAssertEqual(preview.automaticallyEligibleObservations, ["observation-2"])
        XCTAssertTrue(preview.suggestionOnlyObservations.isEmpty)
        XCTAssertTrue(preview.blockedObservations.isEmpty)
        XCTAssertEqual(value, before)
    }

    func testReversalSuppressionRequiresExplicitAuditedClear() throws {
        var (value, rule) = try document()
        try addAndApprove(rule, trust: .approvedAutomatic, in: &value)
        let application = try TrustedRuleEngine.applyAutomatically(
            ruleID: rule.id,
            observationID: "observation-2",
            at: approvedAt,
            in: &value
        )
        try TrustedRuleEngine.reverseApplication(
            auditEventID: application.auditEvent.id,
            reversalEventID: "audit-reversal",
            at: approvedAt.addingTimeInterval(60),
            in: &value
        )
        XCTAssertEqual(
            try TrustedRuleEngine.preview(ruleID: rule.id, in: value)
                .blockedObservations.map(\.observationID),
            ["observation-2"]
        )

        let transactionCount = value.transactions.count
        try TrustedRuleEngine.clearReapplicationSuppression(
            ruleID: rule.id,
            observationID: "observation-2",
            at: approvedAt.addingTimeInterval(120),
            auditEventID: "audit-reauthorized",
            in: &value
        )

        XCTAssertEqual(value.transactions.count, transactionCount)
        XCTAssertFalse(value.trustedRuleObservationSuppressions[0].isActive)
        XCTAssertEqual(value.trustedRuleAuditEvents.last?.kind, .reapplicationAuthorized)
        XCTAssertEqual(
            try TrustedRuleEngine.preview(ruleID: rule.id, in: value)
                .automaticallyEligibleObservations,
            ["observation-2"]
        )
    }

    func testSemanticFingerprintIsCanonicalAndCandidateGenerationConverges() throws {
        var (value, rule) = try document()
        let reordered = TrustedRule(
            id: "different-generated-id",
            title: "Different display title",
            predicate: TrustedRulePredicate(
                provider: rule.predicate.provider,
                bindingID: rule.predicate.bindingID,
                merchantField: rule.predicate.merchantField,
                merchantValue: "  SYNTHETIC   MERCHANT ",
                direction: rule.predicate.direction,
                currencyCode: "eur",
                currencyExponent: rule.predicate.currencyExponent,
                exactMinorUnits: rule.predicate.exactMinorUnits,
                bankTransactionCode: rule.predicate.bankTransactionCode
            ),
            interpretation: rule.interpretation,
            supportingConfirmations: Array(rule.supportingConfirmations.reversed()),
            createdAt: rule.createdAt.addingTimeInterval(10)
        )
        XCTAssertEqual(rule.semanticFingerprint, reordered.semanticFingerprint)
        XCTAssertEqual(rule.semanticFingerprint, rule.semanticFingerprint)

        let first = try TrustedRuleEngine.addDraft(
            rule, auditEventID: "audit-created", in: &value
        )
        let second = try TrustedRuleEngine.addDraft(
            reordered, auditEventID: "audit-duplicate-must-not-appear", in: &value
        )
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(value.trustedRules.count, 1)
        XCTAssertEqual(value.trustedRuleAuditEvents.count, 1)

        let differentAction = TrustedRuleInterpretation(
            transactionKind: .expense,
            categoryKey: "different-category",
            userLabel: rule.interpretation.userLabel
        )
        XCTAssertNotEqual(
            rule.semanticFingerprint,
            TrustedRuleEngine.semanticFingerprint(
                predicate: rule.predicate, interpretation: differentAction
            )
        )
    }

    func testApprovedSemanticMutationInvalidatesSnapshottedAuditMeaning() throws {
        var (value, rule) = try document()
        try addAndApprove(rule, trust: .suggestionOnly, in: &value)
        let changedInterpretation = TrustedRuleInterpretation(
            transactionKind: .expense,
            categoryKey: "food",
            userLabel: "Changed semantic label"
        )
        let changedSupports = rule.supportingConfirmations.map {
            TrustedRuleSupport(
                observationID: $0.observationID,
                transactionID: $0.transactionID,
                confirmedAt: $0.confirmedAt,
                categoryKey: $0.categoryKey,
                userLabel: "Changed semantic label"
            )
        }
        value.trustedRules[0] = TrustedRule(
            id: rule.id,
            title: rule.title,
            predicate: rule.predicate,
            interpretation: changedInterpretation,
            supportingConfirmations: changedSupports,
            createdAt: rule.createdAt,
            trustLevel: .suggestionOnly,
            lifecycle: .active,
            approvedAt: approvedAt
        )

        XCTAssertThrowsError(try TrustedRuleEngine.validate(value)) { error in
            XCTAssertTrue(String(describing: error).contains("audit event"))
        }
    }

    func testAutomaticApprovalDoesNotApplyCurrentMatches() throws {
        var (value, rule) = try document()
        try TrustedRuleEngine.addDraft(rule, auditEventID: "audit-created", in: &value)
        let transactions = value.transactions
        let links = value.externalEvidenceLinks
        let resolutions = value.observationResolutions

        try TrustedRuleEngine.approve(
            ruleID: rule.id,
            trustLevel: .approvedAutomatic,
            at: approvedAt,
            auditEventID: "audit-approved",
            in: &value
        )

        XCTAssertEqual(value.transactions, transactions)
        XCTAssertEqual(value.externalEvidenceLinks, links)
        XCTAssertEqual(value.observationResolutions, resolutions)
        XCTAssertEqual(value.trustedRuleAuditEvents.last?.kind, .approvedForAutomaticResolution)
        XCTAssertEqual(
            try TrustedRuleEngine.preview(ruleID: rule.id, in: value)
                .automaticallyEligibleObservations,
            ["observation-2"]
        )
    }

    func testAutomaticApplicationRejectsEveryNonReviewableEvidenceState() throws {
        let cases: [(String, ExternalObservation, ObservationResolutionState)] = [
            (
                "pending",
                observation("observation-2", status: .pending),
                .provisional
            ),
            (
                "rejected",
                observation("observation-2", status: .rejected),
                .economicallyIneligible
            ),
            (
                "provisional identity",
                observation("observation-2", identity: .provisionalSnapshot),
                .provisional
            ),
            (
                "provider ineligible",
                observation("observation-2", eligible: false),
                .economicallyIneligible
            ),
            (
                "outside sync boundary",
                observation("observation-2", bookingDate: boundary),
                .outsideSyncBoundary
            )
        ]

        for (label, replacement, state) in cases {
            var (value, rule) = try document()
            try addAndApprove(rule, trust: .approvedAutomatic, in: &value)
            let observationIndex = try XCTUnwrap(value.externalObservations.firstIndex {
                $0.id == replacement.id
            })
            let resolutionIndex = try XCTUnwrap(value.observationResolutions.firstIndex {
                $0.observationID == replacement.id
            })
            value.externalObservations[observationIndex] = replacement
            value.observationResolutions[resolutionIndex].state = state

            XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
                ruleID: rule.id,
                observationID: replacement.id,
                at: approvedAt,
                in: &value
            ), label) { error in
                XCTAssertTrue(
                    String(describing: error).contains("not eligible for economic review")
                        || String(describing: error).contains("already resolved"),
                    "\(label): \(error)"
                )
            }
            XCTAssertFalse(value.trustedRuleAuditEvents.contains {
                $0.kind == .automaticallyResolved
            }, label)
        }
    }

    func testAutomaticApplicationRejectsAlreadyResolvedObservation() throws {
        var (value, rule) = try document()
        try addAndApprove(rule, trust: .approvedAutomatic, in: &value)
        try ExternalEvidenceReview.markNoEconomicEffect(
            observationID: "observation-2", resolvedAt: approvedAt, in: &value
        )
        let before = value

        XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
            ruleID: rule.id,
            observationID: "observation-2",
            at: approvedAt,
            in: &value
        )) { error in
            XCTAssertTrue(String(describing: error).contains("already resolved"))
        }
        XCTAssertEqual(value, before)
    }

    func testAutomaticApplicationRejectsUnmappedAndCurrencyMismatchedAccounts() throws {
        do {
            var (value, rule) = try document()
            try addAndApprove(rule, trust: .approvedAutomatic, in: &value)
            let binding = value.externalAccountBindings[0]
            value.externalAccountBindings[0] = ExternalAccountBinding(
                id: binding.id,
                provider: binding.provider,
                remoteOpaqueAccountID: binding.remoteOpaqueAccountID,
                localAccountID: "missing-account",
                syncStartBoundary: binding.syncStartBoundary,
                isActive: binding.isActive,
                createdAt: binding.createdAt
            )
            XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
                ruleID: rule.id,
                observationID: "observation-2",
                at: approvedAt,
                in: &value
            )) { error in
                XCTAssertTrue(String(describing: error).contains("unknown local account"))
            }
        }

        do {
            var (value, rule) = try document()
            try addAndApprove(rule, trust: .approvedAutomatic, in: &value)
            value.accounts[0].currency = .usd
            XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
                ruleID: rule.id,
                observationID: "observation-2",
                at: approvedAt,
                in: &value
            )) { error in
                XCTAssertTrue(String(describing: error).contains("currency does not match"))
            }
        }

        do {
            var (value, rule) = try document()
            try addAndApprove(rule, trust: .approvedAutomatic, in: &value)
            let binding = value.externalAccountBindings[0]
            value.externalAccountBindings[0] = ExternalAccountBinding(
                id: binding.id,
                provider: binding.provider,
                remoteOpaqueAccountID: binding.remoteOpaqueAccountID,
                localAccountID: binding.localAccountID,
                syncStartBoundary: binding.syncStartBoundary,
                isActive: false,
                createdAt: binding.createdAt
            )
            XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
                ruleID: rule.id,
                observationID: "observation-2",
                at: approvedAt,
                in: &value
            )) { error in
                XCTAssertTrue(String(describing: error).contains("is inactive"))
            }
        }
    }

    func testAutomaticApplicationRejectsDuplicateAccountMovementUse() throws {
        var (value, rule) = try document()
        try addAndApprove(rule, trust: .approvedAutomatic, in: &value)
        value.externalEvidenceLinks.append(
            ExternalEvidenceLink(
                id: "malformed-duplicate-movement",
                observationID: "observation-2",
                transactionID: "confirmed-0",
                role: .accountMovement
            )
        )

        XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
            ruleID: rule.id,
            observationID: "observation-2",
            at: approvedAt,
            in: &value
        )) { error in
            XCTAssertTrue(String(describing: error).contains("account-movement evidence twice"))
        }
        XCTAssertFalse(value.trustedRuleAuditEvents.contains {
            $0.kind == .automaticallyResolved
        })
    }

    func testManualAndAutomaticResolutionShareEvidenceEligibility() throws {
        var (value, rule) = try document()
        try addAndApprove(rule, trust: .approvedAutomatic, in: &value)
        let targetIndex = try XCTUnwrap(value.externalObservations.firstIndex {
            $0.id == "observation-2"
        })
        let resolutionIndex = try XCTUnwrap(value.observationResolutions.firstIndex {
            $0.observationID == "observation-2"
        })
        value.externalObservations[targetIndex] = observation(
            "observation-2", status: .pending
        )
        value.observationResolutions[resolutionIndex].state = .provisional
        let manualTransaction = Transaction(
            id: "manual-candidate",
            date: day,
            kind: .expense,
            legs: [AccountLeg(
                accountID: "bank",
                amount: value.externalObservations[targetIndex].amount
            )],
            factivity: .observed,
            provenance: Provenance(source: "TEST", evidenceGrade: .userConfirmed)
        )
        var manual = value
        var manualReason = ""
        XCTAssertThrowsError(try ExternalEvidenceReview.createTransaction(
            manualTransaction,
            evidence: [.init(observationID: "observation-2", role: .accountMovement)],
            resolvedAt: approvedAt,
            in: &manual
        )) { manualReason = String(describing: $0) }

        XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
            ruleID: rule.id,
            observationID: "observation-2",
            at: approvedAt,
            in: &value
        )) { error in
            XCTAssertTrue(String(describing: error).contains(manualReason))
        }
        XCTAssertEqual(manual, value)
    }

    func testProposalRequiresTwoIndependentUserConfirmedMerchantExpenses() throws {
        var (value, _) = try document(supportCount: 2)
        let metadata = (0..<2).map {
            TrustedRuleConfirmationMetadata(
                transactionID: "confirmed-\($0)",
                categoryKey: "food",
                userLabel: "Synthetic label"
            )
        }

        let proposal = try XCTUnwrap(
            TrustedRuleEngine.proposalCandidates(
                in: value,
                confirmationMetadata: metadata
            ).first
        )
        XCTAssertEqual(proposal.predicate.merchantField, .structuredMerchantName)
        XCTAssertEqual(proposal.predicate.bankTransactionCode, "CARD_PURCHASE")
        XCTAssertNil(proposal.predicate.exactMinorUnits)
        XCTAssertEqual(proposal.interpretation.transactionKind, .expense)
        XCTAssertEqual(proposal.interpretation.categoryKey, "food")
        XCTAssertEqual(proposal.supportingConfirmations.count, 2)
        XCTAssertEqual(Set(proposal.supportingConfirmations.map(\.transactionID)).count, 2)
        XCTAssertEqual(Set(proposal.supportingConfirmations.map(\.observationID)).count, 2)

        var (oneSupport, _) = try document(supportCount: 1)
        XCTAssertTrue(TrustedRuleEngine.proposalCandidates(
            in: oneSupport,
            confirmationMetadata: [metadata[0]]
        ).isEmpty)

        // Merchant repetition without explicit category/label metadata is not
        // a training signal and cannot create a draft candidate.
        XCTAssertTrue(TrustedRuleEngine.proposalCandidates(
            in: value,
            confirmationMetadata: []
        ).isEmpty)
    }

    func testRuleDerivedApplicationCannotBecomeProposalSupport() throws {
        var (value, _) = try document(supportCount: 2)
        let manualMetadata = (0..<2).map {
            TrustedRuleConfirmationMetadata(
                transactionID: "confirmed-\($0)",
                categoryKey: "food",
                userLabel: "Synthetic label"
            )
        }
        let proposal = try XCTUnwrap(TrustedRuleEngine.proposalCandidates(
            in: value,
            confirmationMetadata: manualMetadata
        ).first)
        let rule = proposal.makeRule(id: "proposal-rule", createdAt: createdAt)
        try addAndApprove(rule, trust: .approvedAutomatic, in: &value)
        let application = try TrustedRuleEngine.applyAutomatically(
            ruleID: rule.id,
            observationID: "observation-2",
            at: approvedAt,
            in: &value
        )
        XCTAssertEqual(application.transaction.provenance.evidenceGrade, .derived)

        // Even if the app presentation layer supplies metadata for the new
        // transaction, Core accepts only USER CONFIRMED provenance as support.
        let candidates = TrustedRuleEngine.proposalCandidates(
            in: value,
            confirmationMetadata: manualMetadata + [
                TrustedRuleConfirmationMetadata(
                    transactionID: application.transaction.id,
                    categoryKey: "food",
                    userLabel: "Synthetic label"
                )
            ]
        )
        let after = try XCTUnwrap(candidates.first)
        XCTAssertEqual(after.supportingConfirmations.count, 2)
        XCTAssertFalse(after.supportingConfirmations.contains {
            $0.transactionID == application.transaction.id
        })
    }

    func testReversedUserConfirmationCannotSupportProposalOrApproval() throws {
        var (value, rule) = try document(supportCount: 2)
        let index = try XCTUnwrap(value.transactions.firstIndex { $0.id == "confirmed-1" })
        let original = value.transactions[index]
        value.transactions[index] = Transaction(
            id: original.id,
            date: original.date,
            kind: original.kind,
            legs: original.legs,
            ownership: original.ownership,
            linkedTransactionID: original.linkedTransactionID,
            incomeSourceID: original.incomeSourceID,
            installmentPlanID: original.installmentPlanID,
            factivity: original.factivity,
            lifecycle: .reversed,
            bookedDate: original.bookedDate,
            datePrecision: original.datePrecision,
            certainty: original.certainty,
            note: original.note,
            provenance: original.provenance
        )
        let metadata = (0..<2).map {
            TrustedRuleConfirmationMetadata(
                transactionID: "confirmed-\($0)",
                categoryKey: "food",
                userLabel: "Synthetic label"
            )
        }
        XCTAssertTrue(TrustedRuleEngine.proposalCandidates(
            in: value,
            confirmationMetadata: metadata
        ).isEmpty)
        XCTAssertThrowsError(try TrustedRuleEngine.addDraft(
            rule,
            auditEventID: "audit-created",
            in: &value
        ))
    }

    func testAutomaticTransactionInheritsManualEvidenceAccountingSemantics() throws {
        var (value, rule) = try document()
        let targetIndex = try XCTUnwrap(value.externalObservations.firstIndex {
            $0.id == "observation-2"
        })
        let economicDay = Day(year: 2026, month: 8, day: 25)
        let bookingDay = Day(year: 2026, month: 8, day: 26)
        value.externalObservations[targetIndex] = ExternalObservation(
            id: "observation-2",
            bindingID: "binding-bank",
            provider: .bnp,
            status: .booked,
            creditDebitIndicator: .debit,
            amount: Money(minorUnits: -1_299, currency: .eur),
            bookingDate: bookingDay,
            transactionDate: economicDay,
            rawMerchantText: "Provider words stay evidence",
            structuredMerchantName: "Synthetic Merchant",
            bankTransactionCode: "CARD_PURCHASE",
            eligibleForEconomicActual: true,
            observedAt: confirmedAt
        )
        try addAndApprove(rule, trust: .approvedAutomatic, in: &value)

        let application = try TrustedRuleEngine.applyAutomatically(
            ruleID: rule.id,
            observationID: "observation-2",
            at: approvedAt,
            in: &value
        )
        let transaction = application.transaction
        XCTAssertEqual(application.categoryKey, "food")
        XCTAssertEqual(application.userLabel, "Synthetic label")
        XCTAssertEqual(transaction.date, economicDay)
        XCTAssertEqual(transaction.bookedDate, bookingDay)
        XCTAssertEqual(transaction.kind, .expense)
        XCTAssertEqual(transaction.legs, [
            AccountLeg(
                accountID: "bank",
                amount: Money(minorUnits: -1_299, currency: .eur)
            )
        ])
        XCTAssertNil(transaction.ownership)
        XCTAssertEqual(transaction.provenance.source, "TRUSTED-RULE")
        XCTAssertEqual(transaction.provenance.evidenceGrade, .derived)
        XCTAssertEqual(transaction.provenance.reference, rule.id)
        XCTAssertEqual(value.externalEvidenceLinks.filter {
            $0.observationID == "observation-2"
                && $0.transactionID == transaction.id
                && $0.role == .accountMovement
        }.count, 1)
    }

    func testOlderDocumentDecodesWithNoRulesAndCurrentRoundTripPreservesDimensions() throws {
        var (value, rule) = try document()
        try addAndApprove(rule, trust: .suggestionOnly, in: &value)
        let data = try Interchange.encode(value)
        let roundTrip = try Interchange.decode(data)
        XCTAssertEqual(roundTrip.trustedRules, value.trustedRules)
        XCTAssertEqual(
            roundTrip.trustedRuleAuditEvents.sorted { $0.id < $1.id },
            value.trustedRuleAuditEvents.sorted { $0.id < $1.id }
        )
        XCTAssertEqual(roundTrip.trustedRuleObservationSuppressions, value.trustedRuleObservationSuppressions)
        XCTAssertEqual(roundTrip.trustedRules[0].predicate.merchantField, .structuredMerchantName)
        XCTAssertEqual(roundTrip.trustedRules[0].interpretation.categoryKey, "food")
        XCTAssertNil(roundTrip.trustedRules[0].interpretation.incomeSourceID)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["schemaVersion"] = "1.4.0"
        json.removeValue(forKey: "trustedRules")
        json.removeValue(forKey: "trustedRuleAuditEvents")
        json.removeValue(forKey: "trustedRuleObservationSuppressions")
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let legacy = try Interchange.decode(legacyData)
        XCTAssertTrue(legacy.trustedRules.isEmpty)
        XCTAssertTrue(legacy.trustedRuleAuditEvents.isEmpty)
        XCTAssertTrue(legacy.trustedRuleObservationSuppressions.isEmpty)
    }
}
