import XCTest
@testable import FinanceCore

/// Adversarial pre-activation audit for Phase 2.6 (base 32ab5b7 → 957e953).
///
/// These tests deliberately attack the trusted-rule machinery rather than
/// exercise its happy path: stale-copy writes, duplicated economic evidence
/// behind "two confirmations", the full reversal state machine with a
/// save/reload between every transition, fingerprint component coverage, and
/// structural nulls (refunds, cash, transfers, FX, financing, cross-provider,
/// credits) pushed at the automatic path from every angle the predicate
/// machinery exposes.
///
/// All data is synthetic. No real provider payload appears here.
final class TrustedRulesAdversarialAuditTests: XCTestCase {
    private let boundary = Day(year: 2026, month: 8, day: 20)
    private let day = Day(year: 2026, month: 8, day: 26)
    private let confirmedAt = Date(timeIntervalSince1970: 1_777_680_000)
    private let createdAt = Date(timeIntervalSince1970: 1_777_680_100)
    private let approvedAt = Date(timeIntervalSince1970: 1_777_680_200)

    // MARK: - Harness

    private func makeDocument() throws -> FinanceDocument {
        let account = Account(
            id: "bank", name: "Synthetic Bank", currency: .eur, kind: .bank,
            supportedRails: [.cardDebit, .sepaCreditTransfer]
        )
        let binding = ExternalAccountBinding(
            id: "binding-bank", provider: .bnp,
            remoteOpaqueAccountID: "acct_synthetic", localAccountID: account.id,
            syncStartBoundary: boundary, createdAt: confirmedAt
        )
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "SYNTHETIC-AUDIT",
            accounts: [account],
            balances: [AccountBalance(
                accountID: account.id,
                balance: Money(minorUnits: 100_000, currency: .eur),
                asOf: boundary
            )],
            externalAccountBindings: [binding]
        )
    }

    private func observation(
        _ id: String,
        amount: Int64 = -1_299,
        code: String? = "CARD_PURCHASE",
        subCode: String? = nil,
        status: ExternalObservationStatus = .booked,
        identity: ExternalObservationIdentity = .durable,
        eligible: Bool = true,
        bookingDate: Day? = nil,
        merchant: String = "Synthetic Merchant"
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
            structuredMerchantName: merchant,
            bankTransactionCode: code,
            bankTransactionSubCode: subCode,
            eligibleForEconomicActual: eligible,
            observedAt: confirmedAt
        )
    }

    /// A document whose observation `target` is unreviewed and matched by a
    /// fully automatic-approved expense-debit rule backed by two supports.
    private func automaticDocument(
        targetCode: String? = "CARD_PURCHASE",
        targetSubCode: String? = nil
    ) throws -> (FinanceDocument, String, String) {
        var value = try makeDocument()
        let supports = (0..<2).map { observation("support-\($0)") }
        let target = observation(
            "target", code: targetCode, subCode: targetSubCode
        )
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: supports + [target]), into: &value
        )
        var confirmed: [TrustedRuleSupport] = []
        for (index, support) in supports.enumerated() {
            let transaction = Transaction(
                id: "confirmed-\(index)", date: day, kind: .expense,
                legs: [AccountLeg(accountID: "bank", amount: support.amount)],
                factivity: .observed,
                provenance: Provenance(
                    source: "AUDIT-CONFIRMATION", evidenceGrade: .userConfirmed
                )
            )
            try ExternalEvidenceReview.createTransaction(
                transaction,
                evidence: [.init(observationID: support.id, role: .accountMovement)],
                resolvedAt: confirmedAt,
                in: &value
            )
            confirmed.append(
                TrustedRuleSupport(
                    observationID: support.id,
                    transactionID: transaction.id,
                    confirmedAt: confirmedAt,
                    categoryKey: "food",
                    userLabel: "Synthetic label"
                )
            )
        }
        let rule = TrustedRule(
            id: "audit-rule",
            title: "Audit rule",
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
                transactionKind: .expense,
                categoryKey: "food",
                userLabel: "Synthetic label"
            ),
            supportingConfirmations: confirmed,
            createdAt: createdAt
        )
        try TrustedRuleEngine.addDraft(rule, auditEventID: "audit-created", in: &value)
        try TrustedRuleEngine.approve(
            ruleID: rule.id,
            trustLevel: .approvedAutomatic,
            at: approvedAt,
            auditEventID: "audit-approved",
            in: &value
        )
        return (value, rule.id, target.id)
    }

    /// The persistence proxy used between every state-machine transition:
    /// byte-deterministic interchange round-trip, i.e. save then reload.
    private func reload(_ document: FinanceDocument) throws -> FinanceDocument {
        try Interchange.decode(Interchange.encode(document))
    }

    // MARK: - 1. Concurrent / stale-copy idempotency

    func testStaleCopiesBothApplyAndDeterministicIdentityAloneDoesNotDeduplicate() throws {
        let (base, ruleID, observationID) = try automaticDocument()

        // Two writers that both read the document before either wrote.
        var writerA = base
        var writerB = base
        let fromA = try TrustedRuleEngine.applyAutomatically(
            ruleID: ruleID, observationID: observationID, at: approvedAt, in: &writerA
        )
        let fromB = try TrustedRuleEngine.applyAutomatically(
            ruleID: ruleID, observationID: observationID, at: approvedAt, in: &writerB
        )

        // Deterministic identity means both stale writes minted the SAME ids.
        XCTAssertEqual(fromA.transaction.id, fromB.transaction.id)
        XCTAssertEqual(fromA.auditEvent.id, fromB.auditEvent.id)

        // Each copy is internally valid on its own…
        XCTAssertNoThrow(try TrustedRuleEngine.validate(writerA))
        XCTAssertNoThrow(try TrustedRuleEngine.validate(writerB))

        // …so a whole-document last-writer-wins store stays consistent (one
        // application, no duplicates) whichever copy eventually persists.
        XCTAssertNoThrow(try TrustedRuleEngine.validate(try reload(writerB)))

        // But row-level persistence of both writes WOULD duplicate: merging
        // writer B's rows into writer A's graph must be rejected by validation.
        var merged = writerA
        merged.transactions.append(fromB.transaction)
        merged.trustedRuleAuditEvents.append(fromB.auditEvent)
        XCTAssertThrowsError(try TrustedRuleEngine.validate(merged)) { error in
            let description = String(describing: error)
            XCTAssertTrue(
                description.contains("duplicate"),
                "expected a duplicate-identifier refusal, got: \(description)"
            )
        }
    }

    // MARK: - 2. Supporting-confirmation integrity

    private func expenseRule(
        id: String,
        supports: [TrustedRuleSupport],
        title: String = "Audit rule"
    ) -> TrustedRule {
        TrustedRule(
            id: id,
            title: title,
            predicate: TrustedRulePredicate(
                provider: .bnp,
                bindingID: "binding-bank",
                merchantField: .structuredMerchantName,
                merchantValue: "Synthetic Merchant",
                direction: .debit,
                currencyCode: "EUR",
                currencyExponent: 2
            ),
            interpretation: TrustedRuleInterpretation(transactionKind: .expense),
            supportingConfirmations: supports,
            createdAt: createdAt
        )
    }

    func testTwoObservationsBackedByTheSameEconomicEventCountAsOneSupport() throws {
        // Independent reproduction of the confirmed defect: two confirmation
        // rows whose account-movement links resolve to ONE user-confirmed
        // transaction. Distinct observation IDs are not independence.
        var value = try makeDocument()
        let rows = [observation("dup-1"), observation("dup-2")]
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: rows), into: &value
        )
        let shared = Transaction(
            id: "shared-economic-event", date: day, kind: .expense,
            legs: [AccountLeg(accountID: "bank", amount: rows[0].amount)],
            factivity: .observed,
            provenance: Provenance(
                source: "AUDIT-CONFIRMATION", evidenceGrade: .userConfirmed
            )
        )
        try ExternalEvidenceReview.createTransaction(
            shared,
            evidence: rows.map { .init(observationID: $0.id, role: .accountMovement) },
            resolvedAt: confirmedAt,
            in: &value
        )
        XCTAssertEqual(
            Set(value.externalEvidenceLinks.map(\.transactionID)),
            [shared.id]
        )

        let supports = rows.map {
            TrustedRuleSupport(
                observationID: $0.id, transactionID: shared.id, confirmedAt: confirmedAt
            )
        }
        let rule = expenseRule(id: "audit-shared-event", supports: supports)
        XCTAssertEqual(
            TrustedRuleEngine.independentConfirmedSupportCount(for: rule, in: value), 1
        )
        XCTAssertTrue(
            TrustedRuleEngine.automaticApprovalBlockers(for: rule, in: value)
                .contains(.insufficientConfirmedSupport)
        )
        XCTAssertThrowsError(try TrustedRuleEngine.addDraft(
            rule, auditEventID: "audit-created", in: &value
        ))
    }

    func testReplayAndSameObservationSupportsCannotManufactureASecondConfirmation() throws {
        var value = try makeDocument()
        let row = observation("only-row")
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: [row]), into: &value
        )
        // Observation replay: the same backend identity re-imported is an
        // upsert, never a second observation.
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: [row]), into: &value
        )
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: [row]), into: &value
        )
        XCTAssertEqual(value.externalObservations.count { $0.id == "only-row" }, 1)

        let transaction = Transaction(
            id: "confirmed-0", date: day, kind: .expense,
            legs: [AccountLeg(accountID: "bank", amount: row.amount)],
            factivity: .observed,
            provenance: Provenance(
                source: "AUDIT-CONFIRMATION", evidenceGrade: .userConfirmed
            )
        )
        try ExternalEvidenceReview.createTransaction(
            transaction,
            evidence: [.init(observationID: row.id, role: .accountMovement)],
            resolvedAt: confirmedAt,
            in: &value
        )

        // Two supports that both point at the one observation (different
        // transactions) are structurally impossible: one observation can
        // never link to two transactions, so the second support fails.
        let phantom = Transaction(
            id: "confirmed-phantom", date: day, kind: .expense,
            legs: [AccountLeg(accountID: "bank", amount: row.amount)],
            factivity: .observed,
            provenance: Provenance(
                source: "AUDIT-CONFIRMATION", evidenceGrade: .userConfirmed
            )
        )
        value.transactions.append(phantom)
        let rule = TrustedRule(
            id: "audit-replay-rule",
            title: "Replay rule",
            predicate: TrustedRulePredicate(
                provider: .bnp,
                bindingID: "binding-bank",
                merchantField: .structuredMerchantName,
                merchantValue: "Synthetic Merchant",
                direction: .debit,
                currencyCode: "EUR",
                currencyExponent: 2
            ),
            interpretation: TrustedRuleInterpretation(transactionKind: .expense),
            supportingConfirmations: [
                TrustedRuleSupport(
                    observationID: row.id,
                    transactionID: transaction.id,
                    confirmedAt: confirmedAt
                ),
                TrustedRuleSupport(
                    observationID: row.id,
                    transactionID: phantom.id,
                    confirmedAt: confirmedAt
                )
            ],
            createdAt: createdAt
        )
        XCTAssertThrowsError(try TrustedRuleEngine.addDraft(
            rule, auditEventID: "audit-created", in: &value
        ))

        // And a single genuine confirmation never reaches the gate.
        value.transactions.removeAll { $0.id == phantom.id }
        let single = TrustedRule(
            id: "audit-single-rule",
            title: "Single-support rule",
            predicate: rule.predicate,
            interpretation: rule.interpretation,
            supportingConfirmations: [TrustedRuleSupport(
                observationID: row.id,
                transactionID: transaction.id,
                confirmedAt: confirmedAt
            )],
            createdAt: createdAt
        )
        try TrustedRuleEngine.addDraft(single, auditEventID: "audit-created", in: &value)
        XCTAssertThrowsError(try TrustedRuleEngine.approve(
            ruleID: single.id,
            trustLevel: .approvedAutomatic,
            at: approvedAt,
            auditEventID: "audit-approved",
            in: &value
        )) { error in
            XCTAssertTrue(String(describing: error).contains("insufficientConfirmedSupport"))
        }
    }

    func testGenuinelyIndependentMovementsCountAsTwoSupports() throws {
        var value = try makeDocument()
        let first = observation("independent-1", bookingDate: Day(year: 2026, month: 8, day: 21))
        let second = observation("independent-2", bookingDate: Day(year: 2026, month: 8, day: 22))
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: [first, second]), into: &value
        )
        var supports: [TrustedRuleSupport] = []
        for (index, row) in [first, second].enumerated() {
            let transaction = Transaction(
                id: "economic-\(index)", date: row.bookingDate!, kind: .expense,
                legs: [AccountLeg(accountID: "bank", amount: row.amount)],
                factivity: .observed,
                provenance: Provenance(
                    source: "AUDIT-CONFIRMATION", evidenceGrade: .userConfirmed
                )
            )
            try ExternalEvidenceReview.createTransaction(
                transaction,
                evidence: [.init(observationID: row.id, role: .accountMovement)],
                resolvedAt: confirmedAt,
                in: &value
            )
            supports.append(
                TrustedRuleSupport(
                    observationID: row.id,
                    transactionID: transaction.id,
                    confirmedAt: confirmedAt
                )
            )
        }
        let rule = expenseRule(id: "audit-independent", supports: supports)
        XCTAssertEqual(
            TrustedRuleEngine.independentConfirmedSupportCount(for: rule, in: value), 2
        )
        XCTAssertFalse(
            TrustedRuleEngine.automaticApprovalBlockers(for: rule, in: value)
                .contains(.insufficientConfirmedSupport)
        )
        XCTAssertNoThrow(try TrustedRuleEngine.addDraft(
            rule, auditEventID: "audit-created", in: &value
        ))
        XCTAssertNoThrow(try TrustedRuleEngine.approve(
            ruleID: rule.id,
            trustLevel: .approvedAutomatic,
            at: approvedAt,
            auditEventID: "audit-approved",
            in: &value
        ))
    }

    func testMerchantEnrichmentLinkDoesNotCountAsAnIndependentEconomicEvent() throws {
        var value = try makeDocument()
        let movement = observation("movement")
        let enrich = observation("enrichment")
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: [movement, enrich]), into: &value
        )
        let first = Transaction(
            id: "economic-0", date: day, kind: .expense,
            legs: [AccountLeg(accountID: "bank", amount: movement.amount)],
            factivity: .observed,
            provenance: Provenance(
                source: "AUDIT-CONFIRMATION", evidenceGrade: .userConfirmed
            )
        )
        try ExternalEvidenceReview.createTransaction(
            first,
            evidence: [.init(observationID: movement.id, role: .accountMovement)],
            resolvedAt: confirmedAt,
            in: &value
        )
        let second = Transaction(
            id: "economic-1", date: day, kind: .expense,
            legs: [AccountLeg(accountID: "bank", amount: enrich.amount)],
            factivity: .observed,
            provenance: Provenance(
                source: "AUDIT-CONFIRMATION", evidenceGrade: .userConfirmed
            )
        )
        value.transactions.append(second)
        value.externalEvidenceLinks.append(
            ExternalEvidenceLink(
                id: "enrich-link",
                observationID: enrich.id,
                transactionID: second.id,
                role: .merchantEnrichment
            )
        )
        value.observationResolutions[
            value.observationResolutions.firstIndex { $0.observationID == enrich.id }!
        ].state = .linkedToTransaction
        let rule = expenseRule(
            id: "audit-enrichment",
            supports: [
                TrustedRuleSupport(
                    observationID: movement.id, transactionID: first.id, confirmedAt: confirmedAt
                ),
                TrustedRuleSupport(
                    observationID: enrich.id, transactionID: second.id, confirmedAt: confirmedAt
                )
            ]
        )
        XCTAssertEqual(
            TrustedRuleEngine.independentConfirmedSupportCount(for: rule, in: value), 1
        )
        XCTAssertThrowsError(try TrustedRuleEngine.addDraft(
            rule, auditEventID: "audit-created", in: &value
        ))
    }

    // MARK: - 3. Reversal state machine with reload between every transition

    func testFullReversalStateMachineWithReloadBetweenEveryTransition() throws {
        var (value, ruleID, observationID) = try automaticDocument()
        let openingBalances = value.balances
        let openingTransactionIDs = Set(value.transactions.map(\.id))

        // State 1: approved, nothing applied.
        value = try reload(value)
        XCTAssertEqual(
            value.observationResolutions.first { $0.id == observationID }?.state,
            .unreviewed
        )

        // State 2: automatic application.
        let first = try TrustedRuleEngine.applyAutomatically(
            ruleID: ruleID, observationID: observationID, at: approvedAt, in: &value
        )
        value = try reload(value)
        XCTAssertTrue(first.transaction.lifecycle != .reversed)
        XCTAssertEqual(
            value.transactions.first { $0.id == first.transaction.id }?.lifecycle,
            .cleared
        )
        XCTAssertEqual(
            value.observationResolutions.first { $0.id == observationID }?.state,
            .linkedToTransaction
        )
        XCTAssertEqual(
            value.externalEvidenceLinks.filter { $0.observationID == observationID }.count,
            1
        )
        XCTAssertEqual(value.balances, openingBalances)

        // State 3: reversal.
        try TrustedRuleEngine.reverseApplication(
            auditEventID: first.auditEvent.id,
            reversalEventID: "audit-reversal",
            at: approvedAt.addingTimeInterval(60),
            in: &value
        )
        value = try reload(value)
        XCTAssertEqual(
            value.transactions.first { $0.id == first.transaction.id }?.lifecycle,
            .reversed,
            "the reversed application must remain a historical record"
        )
        XCTAssertEqual(
            value.observationResolutions.first { $0.id == observationID }?.state,
            .unreviewed
        )
        XCTAssertNil(
            value.observationResolutions.first { $0.id == observationID }?.resolvedAt,
            "no stale resolution timestamp may survive reversal"
        )
        XCTAssertTrue(
            value.externalEvidenceLinks
                .filter { $0.observationID == observationID }.isEmpty
        )
        XCTAssertEqual(value.trustedRuleObservationSuppressions.count, 1)
        XCTAssertTrue(value.trustedRuleObservationSuppressions[0].isActive)
        XCTAssertEqual(value.balances, openingBalances)
        XCTAssertEqual(
            Set(value.transactions.map(\.id)),
            openingTransactionIDs.union([first.transaction.id]),
            "reversal must neither add nor remove transactions"
        )

        // State 4: suppressed reevaluation — automatic reapplication refuses.
        let afterReversal = value
        XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
            ruleID: ruleID,
            observationID: observationID,
            at: approvedAt.addingTimeInterval(90),
            in: &value
        )) { error in
            XCTAssertTrue(
                String(describing: error).contains("userReversalSuppression"),
                "expected the suppression blocker, got: \(error)"
            )
        }
        XCTAssertEqual(value, afterReversal)

        // Reversing the same application twice is refused.
        XCTAssertThrowsError(try TrustedRuleEngine.reverseApplication(
            auditEventID: first.auditEvent.id,
            reversalEventID: "audit-reversal-2",
            at: approvedAt.addingTimeInterval(95),
            in: &value
        ))

        // State 5: explicit reapplication authorization lifts the veto only.
        try TrustedRuleEngine.clearReapplicationSuppression(
            ruleID: ruleID,
            observationID: observationID,
            at: approvedAt.addingTimeInterval(120),
            auditEventID: "audit-reauthorized",
            in: &value
        )
        value = try reload(value)
        XCTAssertFalse(value.trustedRuleObservationSuppressions[0].isActive)
        // The interchange encoder sorts audit events by id, so array position
        // is not chronological after a reload; assert membership.
        XCTAssertTrue(
            value.trustedRuleAuditEvents.contains { $0.kind == .reapplicationAuthorized }
        )
        XCTAssertEqual(
            value.transactions.first { $0.id == first.transaction.id }?.lifecycle,
            .reversed,
            "authorization must not resurrect the reversed transaction"
        )

        // State 6: a new attempt mints a NEW transaction; nothing reuses
        // stale state, and the old application stays historically inspectable.
        let second = try TrustedRuleEngine.applyAutomatically(
            ruleID: ruleID,
            observationID: observationID,
            at: approvedAt.addingTimeInterval(180),
            in: &value
        )
        value = try reload(value)
        XCTAssertNotEqual(second.transaction.id, first.transaction.id)
        XCTAssertEqual(
            value.transactions.first { $0.id == first.transaction.id }?.lifecycle,
            .reversed
        )
        XCTAssertEqual(
            value.transactions.first { $0.id == second.transaction.id }?.lifecycle,
            .cleared
        )
        XCTAssertEqual(
            value.trustedRuleAuditEvents.filter { $0.kind == .automaticallyResolved }.count,
            2
        )
        XCTAssertEqual(
            value.externalEvidenceLinks.filter { $0.observationID == observationID }.count,
            1,
            "exactly one live evidence link; the reversed one was removed"
        )
        XCTAssertEqual(
            value.externalEvidenceLinks.first {
                $0.observationID == observationID
            }?.transactionID,
            second.transaction.id
        )
        XCTAssertEqual(
            value.observationResolutions.first { $0.id == observationID }?.state,
            .linkedToTransaction
        )
        XCTAssertEqual(value.balances, openingBalances)
        XCTAssertNoThrow(try TrustedRuleEngine.validate(value))

        // State 7: the second application can also be reversed, and both
        // reversals keep exactly one suppression each.
        try TrustedRuleEngine.reverseApplication(
            auditEventID: second.auditEvent.id,
            reversalEventID: "audit-reversal-second",
            at: approvedAt.addingTimeInterval(240),
            in: &value
        )
        value = try reload(value)
        XCTAssertEqual(value.trustedRuleObservationSuppressions.count, 2)
        XCTAssertEqual(
            value.trustedRuleObservationSuppressions.filter(\.isActive).count, 1
        )
        XCTAssertNoThrow(try TrustedRuleEngine.validate(value))
    }

    func testManualResolutionAfterReversalIsPossibleAndBlocksLaterAutomaticReuse() throws {
        var (value, ruleID, observationID) = try automaticDocument()
        let application = try TrustedRuleEngine.applyAutomatically(
            ruleID: ruleID, observationID: observationID, at: approvedAt, in: &value
        )
        try TrustedRuleEngine.reverseApplication(
            auditEventID: application.auditEvent.id,
            reversalEventID: "audit-reversal",
            at: approvedAt.addingTimeInterval(60),
            in: &value
        )
        value = try reload(value)

        // Manual resolution after reversal uses the shared eligibility path.
        let manual = Transaction(
            id: "manual-after-reversal", date: day, kind: .expense,
            legs: [AccountLeg(
                accountID: "bank",
                amount: value.externalObservations.first { $0.id == observationID }!.amount
            )],
            factivity: .observed,
            provenance: Provenance(
                source: "AUDIT-CONFIRMATION", evidenceGrade: .userConfirmed
            )
        )
        XCTAssertNoThrow(try ExternalEvidenceReview.createTransaction(
            manual,
            evidence: [.init(observationID: observationID, role: .accountMovement)],
            resolvedAt: approvedAt.addingTimeInterval(90),
            in: &value
        ))
        value = try reload(value)
        XCTAssertEqual(
            value.observationResolutions.first { $0.id == observationID }?.state,
            .linkedToTransaction
        )

        // Clearing the suppression is still possible and still inert…
        XCTAssertNoThrow(try TrustedRuleEngine.clearReapplicationSuppression(
            ruleID: ruleID,
            observationID: observationID,
            at: approvedAt.addingTimeInterval(120),
            auditEventID: "audit-reauthorized",
            in: &value
        ))
        value = try reload(value)

        // …but automatic reapplication is refused because the observation is
        // resolved by a human decision, not by stale rule state.
        XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
            ruleID: ruleID,
            observationID: observationID,
            at: approvedAt.addingTimeInterval(180),
            in: &value
        )) { error in
            XCTAssertTrue(
                String(describing: error).contains("cannot resolve"),
                "expected an evidence-resolution refusal, got: \(error)"
            )
        }
        XCTAssertEqual(
            value.trustedRuleAuditEvents.filter { $0.kind == .automaticallyResolved }.count,
            1
        )
        XCTAssertNil(TrustedRuleEngine.decision(
            for: observationID, rule: value.trustedRules[0], in: value
        ))
    }

    // MARK: - 4. Semantic fingerprint stability

    func testFingerprintExcludesEveryNonSemanticComponent() throws {
        let (value, ruleID, _) = try automaticDocument()
        let rule = value.trustedRules.first { $0.id == ruleID }!
        let fingerprint = rule.semanticFingerprint

        // Non-semantic: id, title, timestamps, trust, lifecycle, support
        // count/order — and persistence round-trip.
        let regenerated = TrustedRule(
            id: "regenerated-\(UUID().uuidString)",
            title: "A different display title",
            predicate: rule.predicate,
            interpretation: rule.interpretation,
            supportingConfirmations: rule.supportingConfirmations.reversed(),
            createdAt: createdAt.addingTimeInterval(999),
            trustLevel: .approvedAutomatic,
            lifecycle: .active,
            approvedAt: approvedAt
        )
        XCTAssertEqual(regenerated.semanticFingerprint, fingerprint)

        let reloaded = try reload(value)
        XCTAssertEqual(reloaded.trustedRules[0].semanticFingerprint, fingerprint)

        // Normalization-only changes keep the fingerprint: case and interior
        // whitespace collapse in the merchant value, and currency-code case is
        // canonicalized.
        let cosmeticallyDifferent = TrustedRulePredicate(
            provider: rule.predicate.provider,
            bindingID: rule.predicate.bindingID,
            merchantField: rule.predicate.merchantField,
            merchantValue: "  SYNTHETIC   merchant ",
            direction: rule.predicate.direction,
            currencyCode: "eur",
            currencyExponent: rule.predicate.currencyExponent,
            exactMinorUnits: rule.predicate.exactMinorUnits,
            bankTransactionCode: rule.predicate.bankTransactionCode
        )
        XCTAssertEqual(
            TrustedRuleEngine.semanticFingerprint(
                predicate: cosmeticallyDifferent,
                interpretation: rule.interpretation
            ),
            fingerprint
        )

        // Provider-code normalization: two predicates whose codes differ only
        // in case and whitespace share one fingerprint.
        let codeA = TrustedRulePredicate(
            provider: rule.predicate.provider,
            bindingID: rule.predicate.bindingID,
            merchantField: rule.predicate.merchantField,
            merchantValue: rule.predicate.merchantValue,
            direction: rule.predicate.direction,
            currencyCode: rule.predicate.currencyCode,
            currencyExponent: rule.predicate.currencyExponent,
            bankTransactionCode: " CARD_purchase "
        )
        let codeB = TrustedRulePredicate(
            provider: rule.predicate.provider,
            bindingID: rule.predicate.bindingID,
            merchantField: rule.predicate.merchantField,
            merchantValue: rule.predicate.merchantValue,
            direction: rule.predicate.direction,
            currencyCode: rule.predicate.currencyCode,
            currencyExponent: rule.predicate.currencyExponent,
            bankTransactionCode: "card_purchase"
        )
        XCTAssertEqual(
            TrustedRuleEngine.semanticFingerprint(
                predicate: codeA, interpretation: rule.interpretation
            ),
            TrustedRuleEngine.semanticFingerprint(
                predicate: codeB, interpretation: rule.interpretation
            )
        )
    }

    func testPredicateAndInterpretationMutationsProduceDistinctFingerprints() throws {
        let (value, ruleID, _) = try automaticDocument()
        let rule = value.trustedRules.first { $0.id == ruleID }!
        let base = TrustedRuleEngine.semanticFingerprint(
            predicate: rule.predicate, interpretation: rule.interpretation
        )
        var distinct: Set<String> = [base]

        func differs(_ other: String, _ label: String) {
            XCTAssertNotEqual(other, base, "\(label) must change the fingerprint")
            XCTAssertTrue(distinct.insert(other).inserted, "\(label) fingerprint collides with another variant")
        }

        func withPredicate(_ predicate: TrustedRulePredicate) -> String {
            TrustedRuleEngine.semanticFingerprint(
                predicate: predicate, interpretation: rule.interpretation
            )
        }
        func withInterpretation(_ interpretation: TrustedRuleInterpretation) -> String {
            TrustedRuleEngine.semanticFingerprint(
                predicate: rule.predicate, interpretation: interpretation
            )
        }
        func predicate(
            provider: ExternalProvider? = nil,
            bindingID: String? = nil,
            merchantField: TrustedMerchantEvidenceField? = nil,
            merchantValue: String? = nil,
            direction: TrustedRuleDirection? = nil,
            currencyCode: String? = nil,
            currencyExponent: Int? = nil,
            exactMinorUnits: Int64? = nil,
            bankTransactionCode: String? = nil
        ) -> TrustedRulePredicate {
            TrustedRulePredicate(
                provider: provider ?? rule.predicate.provider,
                bindingID: bindingID ?? rule.predicate.bindingID,
                merchantField: merchantField ?? rule.predicate.merchantField,
                merchantValue: merchantValue ?? rule.predicate.merchantValue,
                direction: direction ?? rule.predicate.direction,
                currencyCode: currencyCode ?? rule.predicate.currencyCode,
                currencyExponent: currencyExponent ?? rule.predicate.currencyExponent,
                exactMinorUnits: exactMinorUnits ?? rule.predicate.exactMinorUnits,
                bankTransactionCode: bankTransactionCode ?? rule.predicate.bankTransactionCode
            )
        }
        func interpretation(
            transactionKind: TransactionKind? = nil,
            categoryKey: String? = nil,
            userLabel: String? = nil,
            recurringObligationID: String? = nil,
            incomeSourceID: String? = nil
        ) -> TrustedRuleInterpretation {
            TrustedRuleInterpretation(
                transactionKind: transactionKind ?? rule.interpretation.transactionKind,
                categoryKey: categoryKey ?? rule.interpretation.categoryKey,
                userLabel: userLabel ?? rule.interpretation.userLabel,
                recurringObligationID: recurringObligationID ?? rule.interpretation.recurringObligationID,
                incomeSourceID: incomeSourceID ?? rule.interpretation.incomeSourceID
            )
        }

        differs(withPredicate(predicate(provider: ExternalProvider(rawValue: "revolut"))), "provider")
        differs(withPredicate(predicate(bindingID: "other-binding")), "bindingID")
        differs(withPredicate(predicate(merchantField: .rawMerchantText)), "merchantField")
        differs(withPredicate(predicate(merchantValue: "Other Merchant")), "merchantValue")
        differs(withPredicate(predicate(direction: .credit)), "direction")
        differs(withPredicate(predicate(currencyCode: "USD")), "currencyCode")
        differs(withPredicate(predicate(currencyExponent: 3)), "currencyExponent")
        differs(withPredicate(predicate(exactMinorUnits: -1_299)), "exactMinorUnits nil→value")
        differs(withPredicate(predicate(exactMinorUnits: -2_500)), "exactMinorUnits value")
        differs(withPredicate(predicate(bankTransactionCode: "CARD_PURCHASE")), "bankTransactionCode nil→value")
        differs(withInterpretation(interpretation(transactionKind: .transfer)), "transactionKind")
        differs(withInterpretation(interpretation(categoryKey: "other")), "categoryKey")
        differs(withInterpretation(interpretation(userLabel: "other")), "userLabel")
        differs(withInterpretation(interpretation(recurringObligationID: "obligation")), "recurringObligationID")
        differs(withInterpretation(interpretation(incomeSourceID: "income")), "incomeSourceID")

        // Length-prefixing: adjacent free-text components cannot be shuffled
        // into a collision ("x"+"yz" vs "xy"+"z").
        let shifted = TrustedRuleEngine.semanticFingerprint(
            predicate: rule.predicate,
            interpretation: TrustedRuleInterpretation(
                transactionKind: .expense, categoryKey: "foo", userLabel: "dbar"
            )
        )
        let shiftedCollision = TrustedRuleEngine.semanticFingerprint(
            predicate: rule.predicate,
            interpretation: TrustedRuleInterpretation(
                transactionKind: .expense, categoryKey: "food", userLabel: "bar"
            )
        )
        XCTAssertNotEqual(shifted, shiftedCollision)
        _ = distinct
    }

    // MARK: - 5/6. Failure atomicity and shared eligibility

    func testFailedApplicationLeavesNoTransactionLinkResolutionOrAuditRow() throws {
        let (value, ruleID, observationID) = try automaticDocument()
        var attacked = value

        // Force the shared eligibility path to fail after the decision was
        // already computed: the observation is resolved behind the rule's back.
        try ExternalEvidenceReview.markNoEconomicEffect(
            observationID: observationID,
            resolvedAt: approvedAt,
            in: &attacked
        )
        let before = attacked
        XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
            ruleID: ruleID, observationID: observationID, at: approvedAt, in: &attacked
        ))
        XCTAssertEqual(attacked, before)

        // Same proof for a mid-mutation failure: an accountMovement link that
        // already exists makes appendLinks throw inside createTransaction,
        // after the transaction was appended to the candidate copy.
        var linkedTwice = value
        linkedTwice.externalEvidenceLinks.append(
            ExternalEvidenceLink(
                id: "preexisting-link",
                observationID: observationID,
                transactionID: "confirmed-0",
                role: .accountMovement
            )
        )
        XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
            ruleID: ruleID, observationID: observationID, at: approvedAt, in: &linkedTwice
        ))
        XCTAssertEqual(
            linkedTwice.transactions.count, value.transactions.count,
            "no orphaned generated transaction may survive a failed application"
        )
        XCTAssertEqual(
            linkedTwice.trustedRuleAuditEvents.count, value.trustedRuleAuditEvents.count,
            "no audit event may claim an application that did not complete"
        )
    }

    func testApprovalSucceedsWhileCurrentMatchesAreIneligibleAndRuntimeStaysAuthoritative() throws {
        // The domain approval gate is definition-level only; a provisional
        // current match does not (and cannot) hide approval. Runtime must
        // therefore refuse what the approval-time Inbox could not vet.
        var value = try makeDocument()
        let supports = (0..<2).map { observation("support-\($0)") }
        let pending = observation("pending-target", status: .pending)
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: supports + [pending]), into: &value
        )
        var confirmed: [TrustedRuleSupport] = []
        for (index, support) in supports.enumerated() {
            let transaction = Transaction(
                id: "confirmed-\(index)", date: day, kind: .expense,
                legs: [AccountLeg(accountID: "bank", amount: support.amount)],
                factivity: .observed,
                provenance: Provenance(
                    source: "AUDIT-CONFIRMATION", evidenceGrade: .userConfirmed
                )
            )
            try ExternalEvidenceReview.createTransaction(
                transaction,
                evidence: [.init(observationID: support.id, role: .accountMovement)],
                resolvedAt: confirmedAt,
                in: &value
            )
            confirmed.append(
                TrustedRuleSupport(
                    observationID: support.id,
                    transactionID: transaction.id,
                    confirmedAt: confirmedAt
                )
            )
        }
        let rule = TrustedRule(
            id: "audit-rule",
            title: "Audit rule",
            predicate: TrustedRulePredicate(
                provider: .bnp,
                bindingID: "binding-bank",
                merchantField: .structuredMerchantName,
                merchantValue: "Synthetic Merchant",
                direction: .debit,
                currencyCode: "EUR",
                currencyExponent: 2
            ),
            interpretation: TrustedRuleInterpretation(transactionKind: .expense),
            supportingConfirmations: confirmed,
            createdAt: createdAt
        )
        try TrustedRuleEngine.addDraft(rule, auditEventID: "audit-created", in: &value)
        XCTAssertNoThrow(try TrustedRuleEngine.approve(
            ruleID: rule.id,
            trustLevel: .approvedAutomatic,
            at: approvedAt,
            auditEventID: "audit-approved",
            in: &value
        ))

        // The pending match never reaches a decision at all (it is not in the
        // unreviewed queue), and the preview reports it blocked regardless of
        // the approval that was already granted.
        XCTAssertNil(TrustedRuleEngine.decisions(for: pending.id, in: value).first)
        let preview = try TrustedRuleEngine.preview(ruleID: rule.id, in: value)
        XCTAssertEqual(preview.automaticallyEligibleObservations, [])
        XCTAssertEqual(preview.blockedObservations.map(\.observationID), [pending.id])

        // And runtime application of that same match refuses.
        let before = value
        XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
            ruleID: rule.id, observationID: pending.id, at: approvedAt, in: &value
        ))
        XCTAssertEqual(value, before)
    }

    // MARK: - 9. Structural nulls against the automatic path

    func testStructurallyUnsafeObservationsCannotBeAppliedAutomatically() throws {
        let attacks: [(String, ExternalObservation)] = [
            ("refund in sub-code", observation("target", code: "CARD_PURCHASE", subCode: "REFUND")),
            ("provisional identity", observation("target", identity: .provisionalSnapshot)),
            ("pending status", observation("target", status: .pending)),
            ("provider-ineligible", observation("target", eligible: false)),
            ("missing provider code", observation("target", code: nil)),
            ("non-purchase code", observation("target", code: "CARD_DEBIT")),
            ("atm code", observation("target", code: "ATM_WITHDRAWAL")),
            ("top-up code", observation("target", code: "ACCOUNT_TOPUP")),
            ("financing code", observation("target", code: "FINANCING_PAYMENT")),
            ("fx code", observation("target", code: "FX_EXCHANGE")),
            ("credit sign with debit indicator", observation("target", amount: 1_299))
        ]

        for (label, row) in attacks {
            var (value, ruleID, _) = try automaticDocument()
            // Replace the target observation while keeping a valid resolution
            // record state, so the attack reaches the decision machinery.
            let index = try XCTUnwrap(value.externalObservations.firstIndex { $0.id == "target" })
            value.externalObservations[index] = row
            let resolution = try XCTUnwrap(value.observationResolutions.firstIndex {
                $0.observationID == row.id
            })
            value.observationResolutions[resolution].state =
                row.eligibleForEconomicActual ? .unreviewed : .economicallyIneligible

            let decision = TrustedRuleEngine.decisions(for: row.id, in: value).first
            if let decision {
                XCTAssertNotEqual(
                    decision.mode,
                    .automaticResolution,
                    "\(label): must never resolve automatically"
                )
            }
            let before = value
            XCTAssertThrowsError(
                try TrustedRuleEngine.applyAutomatically(
                    ruleID: ruleID, observationID: row.id, at: approvedAt, in: &value
                ),
                "\(label): application must refuse"
            )
            XCTAssertEqual(
                value, before, "\(label): refusal must not mutate the document"
            )
            XCTAssertFalse(
                value.trustedRuleAuditEvents.contains { $0.kind == .automaticallyResolved },
                "\(label): no audit event may appear"
            )
        }
    }

    func testCrossProviderPairingOfAnyStateBlocksAutomaticApplication() throws {
        for state in [
            CrossProviderCandidateState.unique,
            .ambiguous,
            .unresolved,
            .other("synthetic")
        ] {
            let (value, ruleID, observationID) = try automaticDocument()
            var attacked = value
            attacked.crossProviderCandidates = [
                CrossProviderCandidate(
                    id: "candidate-\(state.token)",
                    bankObservationID: observationID,
                    walletObservationID: nil,
                    state: state,
                    candidateCount: 1,
                    amount: Money(minorUnits: -1_299, currency: .eur),
                    rule: "synthetic",
                    computedAt: confirmedAt
                )
            ]
            let decision = TrustedRuleEngine.decisions(
                for: observationID, in: attacked
            ).first
            XCTAssertEqual(decision?.mode, .suggestion, state.token)
            XCTAssertTrue(
                decision?.automaticBlockers.contains(
                    .crossProviderEvidenceRequiresJudgment
                ) == true,
                state.token
            )
            XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
                ruleID: ruleID, observationID: observationID, at: approvedAt, in: &attacked
            ))
        }
    }

    func testSecondRuleOnTheSameObservationCannotAlsoApply() throws {
        var (value, firstRuleID, observationID) = try automaticDocument()
        // A second, semantically distinct rule matching the same observation.
        let second = TrustedRule(
            id: "audit-rule-second",
            title: "Second overlapping rule",
            predicate: TrustedRulePredicate(
                provider: .bnp,
                bindingID: "binding-bank",
                merchantField: .structuredMerchantName,
                merchantValue: "synthetic merchant",
                direction: .debit,
                currencyCode: "EUR",
                currencyExponent: 2,
                exactMinorUnits: -1_299
            ),
            interpretation: TrustedRuleInterpretation(
                transactionKind: .expense,
                categoryKey: "food",
                userLabel: "Synthetic label"
            ),
            supportingConfirmations: value.trustedRules[0].supportingConfirmations,
            createdAt: createdAt
        )
        try TrustedRuleEngine.addDraft(second, auditEventID: "audit-created-2", in: &value)
        try TrustedRuleEngine.approve(
            ruleID: second.id,
            trustLevel: .approvedAutomatic,
            at: approvedAt,
            auditEventID: "audit-approved-2",
            in: &value
        )

        _ = try TrustedRuleEngine.applyAutomatically(
            ruleID: firstRuleID, observationID: observationID, at: approvedAt, in: &value
        )
        let before = value
        XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
            ruleID: second.id, observationID: observationID, at: approvedAt, in: &value
        ))
        XCTAssertEqual(value, before)
        XCTAssertEqual(
            value.trustedRuleAuditEvents.filter { $0.kind == .automaticallyResolved }.count, 1
        )
    }

    func testDefinitionLevelAttacksOnAutomaticApproval() throws {
        // exactMinorUnits >= 0 is refused for an expense-debit rule even
        // though everything else is clean.
        do {
            var (value, ruleID, _) = try automaticDocument()
            var predicate = value.trustedRules[0].predicate
            predicate = TrustedRulePredicate(
                provider: predicate.provider,
                bindingID: predicate.bindingID,
                merchantField: predicate.merchantField,
                merchantValue: predicate.merchantValue,
                direction: predicate.direction,
                currencyCode: predicate.currencyCode,
                currencyExponent: predicate.currencyExponent,
                exactMinorUnits: 1_299,
                bankTransactionCode: predicate.bankTransactionCode
            )
            value.trustedRules[0] = TrustedRule(
                id: ruleID,
                title: value.trustedRules[0].title,
                predicate: predicate,
                interpretation: value.trustedRules[0].interpretation,
                supportingConfirmations: value.trustedRules[0].supportingConfirmations,
                createdAt: value.trustedRules[0].createdAt
            )
            XCTAssertThrowsError(try ExternalEvidenceReview.validate(value))
        }

        // A rule predicate carrying a transfer/ATM code cannot be approved,
        // even when two genuine user confirmations of rows with that same
        // code support it.
        for code in ["ACCOUNT_TRANSFER", "ATM_WITHDRAWAL"] {
            var document = try makeDocument()
            let supports = (0..<2).map {
                observation("support-\($0)", code: code)
            }
            try ExternalEvidenceReview.importBatch(
                ExternalEvidenceBatch(observations: supports), into: &document
            )
            var confirmed: [TrustedRuleSupport] = []
            for (index, support) in supports.enumerated() {
                let transaction = Transaction(
                    id: "confirmed-\(index)", date: day, kind: .expense,
                    legs: [AccountLeg(accountID: "bank", amount: support.amount)],
                    factivity: .observed,
                    provenance: Provenance(
                        source: "AUDIT-CONFIRMATION", evidenceGrade: .userConfirmed
                    )
                )
                try ExternalEvidenceReview.createTransaction(
                    transaction,
                    evidence: [.init(observationID: support.id, role: .accountMovement)],
                    resolvedAt: confirmedAt,
                    in: &document
                )
                confirmed.append(
                    TrustedRuleSupport(
                        observationID: support.id,
                        transactionID: transaction.id,
                        confirmedAt: confirmedAt
                    )
                )
            }
            let attacked = TrustedRule(
                id: "attacked-\(code)",
                title: "Attacked definition",
                predicate: TrustedRulePredicate(
                    provider: .bnp,
                    bindingID: "binding-bank",
                    merchantField: .structuredMerchantName,
                    merchantValue: "Synthetic Merchant",
                    direction: .debit,
                    currencyCode: "EUR",
                    currencyExponent: 2,
                    bankTransactionCode: code
                ),
                interpretation: TrustedRuleInterpretation(transactionKind: .expense),
                supportingConfirmations: confirmed,
                createdAt: createdAt
            )
            try TrustedRuleEngine.addDraft(
                attacked, auditEventID: "audit-created", in: &document
            )
            XCTAssertThrowsError(
                try TrustedRuleEngine.approve(
                    ruleID: attacked.id,
                    trustLevel: .approvedAutomatic,
                    at: approvedAt,
                    auditEventID: "audit-approved",
                    in: &document
                ),
                code
            ) { error in
                XCTAssertTrue(
                    String(describing: error).contains("automatic trust violates")
                        || String(describing: error).contains("cannot resolve automatically"),
                    "\(code): \(error)"
                )
            }
        }
    }

    // MARK: - 6. Eligibility equivalence / TOCTOU

    func testRuntimeApplicationRechecksAuthoritativeStateAfterPreview() throws {
        let attacks: [(String, (inout FinanceDocument, String, String) throws -> Void)] = [
            ("already resolved", { document, _, observationID in
                try ExternalEvidenceReview.markNoEconomicEffect(
                    observationID: observationID, resolvedAt: self.approvedAt, in: &document
                )
            }),
            ("rule disabled", { document, ruleID, _ in
                try TrustedRuleEngine.disable(
                    ruleID: ruleID, at: self.approvedAt, auditEventID: "audit-disabled",
                    in: &document
                )
            }),
            ("inactive binding", { document, _, _ in
                document.externalAccountBindings[0].isActive = false
            }),
            ("suppression", { document, ruleID, observationID in
                document.trustedRuleObservationSuppressions.append(
                    TrustedRuleObservationSuppression(
                        id: "manual-suppression",
                        ruleID: ruleID,
                        observationID: observationID,
                        applicationAuditEventID: "audit-approved",
                        reversalAuditEventID: "audit-approved",
                        createdAt: self.approvedAt
                    )
                )
            }),
            ("provisional identity", { document, _, observationID in
                let index = document.externalObservations.firstIndex { $0.id == observationID }!
                document.externalObservations[index] = self.observation(
                    observationID, identity: .provisionalSnapshot
                )
            }),
            ("rejected status", { document, _, observationID in
                let index = document.externalObservations.firstIndex { $0.id == observationID }!
                document.externalObservations[index] = self.observation(
                    observationID, status: .rejected
                )
            })
        ]

        for (label, mutate) in attacks {
            var (value, ruleID, observationID) = try automaticDocument()
            let preview = try TrustedRuleEngine.preview(ruleID: ruleID, in: value)
            XCTAssertEqual(
                preview.automaticallyEligibleObservations, [observationID], label
            )
            try mutate(&value, ruleID, observationID)
            let before = value
            XCTAssertThrowsError(
                try TrustedRuleEngine.applyAutomatically(
                    ruleID: ruleID, observationID: observationID, at: approvedAt, in: &value
                ),
                "\(label): stale preview must not apply"
            )
            if label != "already resolved" && label != "rule disabled" {
                XCTAssertEqual(
                    value.trustedRuleAuditEvents.filter { $0.kind == .automaticallyResolved }.count,
                    0,
                    "\(label): no application audit"
                )
            }
            XCTAssertEqual(
                value.transactions.count, before.transactions.count,
                "\(label): no extra transaction"
            )
        }
    }

    func testOutsideSyncBoundaryAndCurrencyMismatchRefuseApplication() throws {
        do {
            var (value, ruleID, _) = try automaticDocument()
            let outside = observation(
                "target", bookingDate: Day(year: 2026, month: 8, day: 19)
            )
            let index = try XCTUnwrap(value.externalObservations.firstIndex { $0.id == "target" })
            value.externalObservations[index] = outside
            value.observationResolutions[
                value.observationResolutions.firstIndex { $0.observationID == "target" }!
            ].state = .outsideSyncBoundary
            let before = value
            XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
                ruleID: ruleID, observationID: "target", at: approvedAt, in: &value
            ))
            XCTAssertEqual(value, before)
        }
        do {
            var (value, ruleID, observationID) = try automaticDocument()
            value.accounts = [
                Account(
                    id: "bank", name: "Synthetic Bank",
                    currency: Currency(code: "USD"), kind: .bank,
                    supportedRails: [.cardDebit, .sepaCreditTransfer]
                )
            ]
            let before = value
            XCTAssertThrowsError(try TrustedRuleEngine.applyAutomatically(
                ruleID: ruleID, observationID: observationID, at: approvedAt, in: &value
            ))
            XCTAssertEqual(value.transactions.count, before.transactions.count)
        }
    }

    // MARK: - 7. Approval is inert; UI current-match hiding is not a domain invariant

    func testApprovalDoesNotMutateObservationsTransactionsOrLinks() throws {
        var (value, ruleID, observationID) = try automaticDocument()
        // automaticDocument already approved. Rebuild a draft-only copy.
        value = try makeDocument()
        let supports = (0..<2).map { observation("support-\($0)") }
        let target = observation("target")
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: supports + [target]), into: &value
        )
        var confirmed: [TrustedRuleSupport] = []
        for (index, support) in supports.enumerated() {
            let transaction = Transaction(
                id: "confirmed-\(index)", date: day, kind: .expense,
                legs: [AccountLeg(accountID: "bank", amount: support.amount)],
                factivity: .observed,
                provenance: Provenance(
                    source: "AUDIT-CONFIRMATION", evidenceGrade: .userConfirmed
                )
            )
            try ExternalEvidenceReview.createTransaction(
                transaction,
                evidence: [.init(observationID: support.id, role: .accountMovement)],
                resolvedAt: confirmedAt,
                in: &value
            )
            confirmed.append(
                TrustedRuleSupport(
                    observationID: support.id, transactionID: transaction.id,
                    confirmedAt: confirmedAt
                )
            )
        }
        let rule = expenseRule(id: ruleID, supports: confirmed)
        try TrustedRuleEngine.addDraft(rule, auditEventID: "audit-created", in: &value)
        let transactions = value.transactions
        let links = value.externalEvidenceLinks
        let resolutions = value.observationResolutions
        let observations = value.externalObservations
        try TrustedRuleEngine.approve(
            ruleID: rule.id, trustLevel: .approvedAutomatic, at: approvedAt,
            auditEventID: "audit-approved", in: &value
        )
        XCTAssertEqual(value.transactions, transactions)
        XCTAssertEqual(value.externalEvidenceLinks, links)
        XCTAssertEqual(value.observationResolutions, resolutions)
        XCTAssertEqual(value.externalObservations, observations)
        XCTAssertEqual(
            value.observationResolutions.first { $0.observationID == observationID }?.state,
            .unreviewed
        )
    }

    // MARK: - 8. Pre-1.5 interchange

    func testPre15DocumentDecodeLeavesRulesInertAndEconomicsUnchanged() throws {
        var value = try makeDocument()
        let row = observation("historical")
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: [row]), into: &value
        )
        let historical = Transaction(
            id: "historical-tx", date: day, kind: .expense,
            legs: [AccountLeg(accountID: "bank", amount: row.amount)],
            factivity: .observed,
            provenance: Provenance(
                source: "AUDIT-CONFIRMATION", evidenceGrade: .userConfirmed
            )
        )
        try ExternalEvidenceReview.createTransaction(
            historical,
            evidence: [.init(observationID: row.id, role: .accountMovement)],
            resolvedAt: confirmedAt,
            in: &value
        )
        value.schemaVersion = "1.4.0"
        var encoded = try JSONSerialization.jsonObject(
            with: Interchange.encode(value)
        ) as! [String: Any]
        encoded["schemaVersion"] = "1.4.0"
        encoded.removeValue(forKey: "trustedRules")
        encoded.removeValue(forKey: "trustedRuleAuditEvents")
        encoded.removeValue(forKey: "trustedRuleObservationSuppressions")
        let data = try JSONSerialization.data(withJSONObject: encoded)
        let decoded = try Interchange.decode(data)

        XCTAssertEqual(decoded.schemaVersion, "1.4.0")
        XCTAssertTrue(decoded.trustedRules.isEmpty)
        XCTAssertTrue(decoded.trustedRuleAuditEvents.isEmpty)
        XCTAssertTrue(decoded.trustedRuleObservationSuppressions.isEmpty)
        XCTAssertEqual(decoded.accounts, value.accounts)
        XCTAssertEqual(decoded.balances, value.balances)
        XCTAssertEqual(decoded.transactions, value.transactions)
        XCTAssertEqual(decoded.externalObservations, value.externalObservations)
        XCTAssertEqual(decoded.externalEvidenceLinks, value.externalEvidenceLinks)
        XCTAssertEqual(decoded.observationResolutions, value.observationResolutions)

        var migrated = decoded
        migrated.schemaVersion = Interchange.currentSchemaVersion
        let (automatic, ruleID, observationID) = try automaticDocument()
        migrated.externalObservations.append(contentsOf: automatic.externalObservations)
        migrated.observationResolutions.append(contentsOf: automatic.observationResolutions)
        migrated.externalEvidenceLinks.append(contentsOf: automatic.externalEvidenceLinks)
        migrated.transactions.append(contentsOf: automatic.transactions)
        migrated.trustedRules = automatic.trustedRules
        migrated.trustedRuleAuditEvents = automatic.trustedRuleAuditEvents
        let historicalIDs = Set(decoded.transactions.map(\.id))
        _ = try TrustedRuleEngine.applyAutomatically(
            ruleID: ruleID, observationID: observationID, at: approvedAt, in: &migrated
        )
        migrated = try reload(migrated)
        XCTAssertEqual(
            migrated.transactions.filter { historicalIDs.contains($0.id) },
            decoded.transactions
        )
        XCTAssertEqual(migrated.accounts, decoded.accounts)
        XCTAssertEqual(migrated.balances, decoded.balances)
    }

    func testBindingIdentityIsPartOfTheFingerprintAndIsNotAPersistenceUUID() throws {
        let (value, ruleID, _) = try automaticDocument()
        let rule = value.trustedRules.first { $0.id == ruleID }!
        XCTAssertEqual(rule.predicate.bindingID, "binding-bank")
        XCTAssertTrue(rule.semanticFingerprint.hasPrefix("trfp1_"))
        // The store derives binding IDs from the opaque backend account id
        // (`binding-<remoteOpaqueAccountID>`), not from a random persistence
        // UUID. Re-pairing the same remote account therefore keeps the same
        // semantic fingerprint; a different remote identity is a different rule.
        let rebound = TrustedRulePredicate(
            provider: rule.predicate.provider,
            bindingID: "binding-acct_synthetic",
            merchantField: rule.predicate.merchantField,
            merchantValue: rule.predicate.merchantValue,
            direction: rule.predicate.direction,
            currencyCode: rule.predicate.currencyCode,
            currencyExponent: rule.predicate.currencyExponent
        )
        XCTAssertNotEqual(
            TrustedRuleEngine.semanticFingerprint(
                predicate: rebound, interpretation: rule.interpretation
            ),
            rule.semanticFingerprint
        )
        let reloaded = try reload(value)
        XCTAssertEqual(reloaded.trustedRules[0].semanticFingerprint, rule.semanticFingerprint)
        XCTAssertEqual(reloaded.trustedRules[0].predicate.bindingID, rule.predicate.bindingID)
    }

    // MARK: - 9. Additional structural nulls

    func testPassThroughCashRejectedAndRawIdentityCannotApplyAutomatically() throws {
        let extra: [(String, ExternalObservation)] = [
            ("transfer", observation("target", code: "ACCOUNT_TRANSFER")),
            ("reversal", observation("target", code: "CARD_REVERSAL")),
            ("cash", observation("target", code: "CASH_WITHDRAWAL")),
            ("rejected", observation("target", status: .rejected, eligible: false)),
            ("already linked sibling", observation("target"))
        ]
        for (label, row) in extra {
            var (value, ruleID, _) = try automaticDocument()
            let index = try XCTUnwrap(value.externalObservations.firstIndex { $0.id == "target" })
            value.externalObservations[index] = row
            if label == "already linked sibling" {
                try ExternalEvidenceReview.markNoEconomicEffect(
                    observationID: "target", resolvedAt: approvedAt, in: &value
                )
            } else if row.eligibleForEconomicActual == false {
                value.observationResolutions[
                    value.observationResolutions.firstIndex { $0.observationID == row.id }!
                ].state = row.status == .rejected ? .economicallyIneligible : .unreviewed
            }
            let before = value
            XCTAssertThrowsError(
                try TrustedRuleEngine.applyAutomatically(
                    ruleID: ruleID, observationID: row.id, at: approvedAt, in: &value
                ),
                "\(label): application must refuse"
            )
            XCTAssertEqual(value.transactions.count, before.transactions.count, label)
        }
    }
}
