import XCTest
@testable import FinanceCore

/// Phase 2.3 — expected → actual reconciliation.
///
/// Every fixture here is synthetic. The rules are named for the *shapes* they
/// exercise (a monthly streaming subscription, a monthly membership) at
/// analogous amounts; no real balance, real date or real account belonging to
/// anybody is present in this file, and none should ever be added to it.
final class ReconciliationTests: XCTestCase {

    // MARK: - Fixture vocabulary

    private func euro(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .eur)! }
    private func dirham(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .mad)! }
    private func day(_ iso: String) -> Day { Day(isoString: iso)! }
    private func month(_ year: Int, _ m: Int) -> MonthKey { MonthKey(year: year, month: m) }

    /// An ordinary bank account: cards and SEPA, no wallet rail.
    private let bank = Account(
        id: "bank", name: "Bank", currency: .eur, kind: .bank,
        supportedRails: [.cardDebit, .sepaCreditTransfer, .sepaDirectDebit], drawOrder: 0
    )
    /// A wallet that only moves money electronically.
    private let wallet = Account(
        id: "wallet", name: "Wallet", currency: .eur, kind: .wallet,
        supportedRails: [.electronicPayment], drawOrder: 1
    )
    /// Foreign physical cash, for the currency wall.
    private let cashMAD = Account(
        id: "cash-mad", name: "Cash (MAD)", currency: .mad, kind: .cash,
        supportedRails: [.physicalCash], drawOrder: 2
    )

    /// A monthly subscription rule billed on day 26.
    private func streamingRule(
        amount: String = "7.99",
        requirement: PaymentRequirement = PaymentRequirement.euroBankPayment(),
        from: MonthKey? = nil,
        through: MonthKey? = nil,
        status: CommitmentStatus = .committed
    ) -> RecurringObligation {
        RecurringObligation(
            id: "ob-streaming", name: "Streaming Premium", amount: euro(amount),
            spec: .monthly(onDay: 26, from: from ?? month(2026, 9), through: through),
            requirement: requirement, spendingClass: .optional, commitmentStatus: status
        )
    }

    /// A second monthly rule, billed on day 27.
    private func membershipRule(amount: String = "3.49") -> RecurringObligation {
        RecurringObligation(
            id: "ob-membership", name: "Retail Membership", amount: euro(amount),
            spec: .monthly(onDay: 27, from: month(2026, 9), through: nil),
            requirement: PaymentRequirement.euroBankPayment(), spendingClass: .optional
        )
    }

    /// An observed expense paid out of one account.
    private func actual(
        id: String, on iso: String, amount: Money, account: String = "bank",
        lifecycle: TransactionLifecycle = .cleared, note: String? = nil
    ) -> Transaction {
        Transaction(
            id: id, date: day(iso), kind: .expense,
            legs: [AccountLeg(accountID: account, amount: amount.negated)],
            factivity: .observed, lifecycle: lifecycle, note: note,
            provenance: Provenance(source: "TEST", evidenceGrade: .userConfirmed)
        )
    }

    private func document(
        accounts: [Account]? = nil,
        balances: [AccountBalance]? = nil,
        obligations: [RecurringObligation],
        transactions: [Transaction] = [],
        settlements: [ObligationSettlement] = []
    ) -> FinanceDocument {
        let accounts = accounts ?? [bank, wallet]
        let balances = balances ?? accounts.map {
            AccountBalance(
                accountID: $0.id,
                balance: Money(minorUnits: 100_000, currency: $0.currency),
                asOf: self.day("2026-09-01")
            )
        }
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "SYNTHETIC-TEST",
            accounts: accounts,
            balances: balances,
            transactions: transactions,
            planning: FinanceDocument.Planning(
                recurringObligations: obligations,
                settlements: settlements
            )
        )
    }

    private func forecast(
        _ document: FinanceDocument, from: String = "2026-09-01", to: String = "2026-10-31"
    ) throws -> ForecastResult {
        try ForecastEngine.run(
            ForecastComposer.makeRequest(
                from: document, startDate: day(from), endDate: day(to), scenario: .base
            )
        )
    }

    private func context(_ document: FinanceDocument, today: String = "2026-09-30", titles: [String: String] = [:]) -> ReconciliationContext {
        ReconciliationContext(document: document, today: day(today), titles: titles)
    }

    // MARK: - 1. One real payment is counted once, not twice

    func testMatchingRemovesTheDuplicateForecastOutflow() throws {
        let paid = actual(id: "tx-1", on: "2026-09-26", amount: euro("7.99"))
        let unmatched = document(obligations: [streamingRule()], transactions: [paid])

        // Before the match the two records coexist: the actual has already
        // moved the balance, and the expectation is still forecast.
        let before = try forecast(unmatched)
        XCTAssertTrue(
            before.appliedEvents.contains { $0.sourceRef == "ob-streaming" && $0.day == day("2026-09-26") },
            "the September occurrence should be forecast while nothing has settled it"
        )

        let matched = document(
            obligations: [streamingRule()],
            transactions: [paid],
            settlements: [
                .paid(id: "s-1", obligationID: "ob-streaming",
                      expectedDay: day("2026-09-26"), actualTransactionID: "tx-1")
            ]
        )
        let after = try forecast(matched)
        XCTAssertFalse(
            after.appliedEvents.contains { $0.sourceRef == "ob-streaming" && $0.day == day("2026-09-26") },
            "a settled occurrence must not remain a forecast outflow"
        )

        // 14. The projection moves by exactly the payment, once.
        let beforeEnd = before.projectedMonthEnd[month(2026, 9)]!
        let afterEnd = after.projectedMonthEnd[month(2026, 9)]!
        XCTAssertEqual(afterEnd.minorUnits - beforeEnd.minorUnits, 799,
                       "matching must free exactly one €7.99, never two and never none")
    }

    // MARK: - 2. The rule survives; future months are untouched

    func testFutureOccurrenceSurvivesAfterAnEarlierOneIsMatched() throws {
        let document = document(
            obligations: [streamingRule()],
            transactions: [actual(id: "tx-1", on: "2026-09-26", amount: euro("7.99"))],
            settlements: [
                .paid(id: "s-1", obligationID: "ob-streaming",
                      expectedDay: day("2026-09-26"), actualTransactionID: "tx-1")
            ]
        )
        let result = try forecast(document)
        XCTAssertTrue(
            result.appliedEvents.contains { $0.sourceRef == "ob-streaming" && $0.day == day("2026-10-26") },
            "settling September must never cancel October — an actual settles an occurrence, not the rule"
        )

        let october = OccurrenceExpander.occurrences(
            in: document, from: day("2026-10-01"), to: day("2026-10-31"), asOf: day("2026-09-30")
        )
        XCTAssertEqual(october.count, 1)
        XCTAssertEqual(october[0].status, .due)
    }

    // MARK: - 3. Rail mismatch: the bank is right, the template is not

    func testWalletRuleIsSettledByABankActualAndOnlyTheBankMoves() throws {
        // The planning template says this is paid electronically from the
        // wallet. The observed debit left the bank instead.
        let walletOnly = PaymentRequirement(currency: .eur, acceptableRails: [.electronicPayment])
        let paid = actual(id: "tx-1", on: "2026-09-26", amount: euro("7.99"), account: "bank")

        let unmatched = document(obligations: [streamingRule(requirement: walletOnly)], transactions: [paid])

        // The mismatch does not disqualify the candidate.
        let candidates = ReconciliationMatcher.candidates(forActual: "tx-1", in: context(unmatched))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].confidence, .strong,
                       "a different account must not weaken an otherwise exact match")
        XCTAssertTrue(candidates[0].signals.contains(.paidFromUnexpectedAccount(accountID: "bank")))
        XCTAssertTrue(candidates[0].signals.contains(.exactAmount))

        // And the match is accepted by validation.
        let matched = document(
            obligations: [streamingRule(requirement: walletOnly)],
            transactions: [paid],
            settlements: [
                .paid(id: "s-1", obligationID: "ob-streaming",
                      expectedDay: day("2026-09-26"), actualTransactionID: "tx-1")
            ]
        )
        XCTAssertNoThrow(try ReconciliationLedger.validate(matched.planning.settlements, against: matched))

        // The wallet is never drained by the settled occurrence.
        let before = try forecast(unmatched)
        let after = try forecast(matched)
        let walletBefore = before.dailyBalances.last!.endOfDay["wallet"]!
        let walletAfter = after.dailyBalances.last!.endOfDay["wallet"]!
        XCTAssertEqual(walletAfter.minorUnits - walletBefore.minorUnits, 799,
                       "the wallet stops being charged for a payment the bank actually made")
        XCTAssertFalse(
            after.appliedEvents.contains { $0.sourceRef == "ob-streaming" && $0.day == day("2026-09-26") }
        )
    }

    // MARK: - 4. Two dates, kept apart

    func testExpectedAndActualDatesAreBothPreserved() {
        // The rule expects day 26; the bank actually took it on the 29th.
        let paid = actual(id: "tx-1", on: "2026-09-29", amount: euro("7.99"))
        let document = document(
            obligations: [streamingRule()],
            transactions: [paid],
            settlements: [
                .paid(id: "s-1", obligationID: "ob-streaming",
                      expectedDay: day("2026-09-26"), actualTransactionID: "tx-1")
            ]
        )

        let settlement = document.planning.settlements[0]
        XCTAssertEqual(settlement.expectedDay, day("2026-09-26"),
                       "the inferred expectation keeps its own day")

        let occurrence = OccurrenceExpander.occurrences(
            in: document, from: day("2026-09-01"), to: day("2026-09-30"), asOf: day("2026-10-01")
        )[0]
        XCTAssertEqual(occurrence.expectedDay, day("2026-09-26"))
        XCTAssertEqual(occurrence.settledTransactionID, "tx-1")

        let evidence = document.transactions.first { $0.id == "tx-1" }!
        XCTAssertEqual(evidence.date, day("2026-09-29"),
                       "the observed date is evidence and is never overwritten by the plan")
    }

    // MARK: - 5. Exact amount is the strongest candidate

    func testExactAmountMatchIsStrongAndNeedsNoAmountConfirmation() {
        let paid = actual(id: "tx-1", on: "2026-09-27", amount: euro("3.49"))
        let document = document(obligations: [membershipRule()], transactions: [paid])

        let candidates = ReconciliationMatcher.candidates(forActual: "tx-1", in: context(document))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].confidence, .strong)
        XCTAssertTrue(candidates[0].signals.contains(.exactAmount))
        XCTAssertTrue(candidates[0].signals.contains(.sameDay))
        XCTAssertFalse(candidates[0].requiresAmountConfirmation)
    }

    // MARK: - 6. A near miss is never silently exact

    func testAmountMismatchIsOfferedButNeverTreatedAsExact() {
        // A stale €4.00 expectation against a €3.49 actual.
        let paid = actual(id: "tx-1", on: "2026-09-27", amount: euro("3.49"))
        let document = document(obligations: [membershipRule(amount: "4.00")], transactions: [paid])

        let candidates = ReconciliationMatcher.candidates(forActual: "tx-1", in: context(document))
        XCTAssertEqual(candidates.count, 1)
        XCTAssertFalse(candidates[0].signals.contains(.exactAmount),
                       "€4.00 and €3.49 must never be reported as the same figure")
        XCTAssertTrue(candidates[0].requiresAmountConfirmation)
        XCTAssertNotEqual(candidates[0].confidence, .strong)
        XCTAssertTrue(candidates[0].signals.contains(
            .amountDiffers(expected: euro("4.00"), actual: euro("3.49"))
        ))
    }

    func testWildlyDifferentAmountIsNotEvenOffered() {
        let paid = actual(id: "tx-1", on: "2026-09-26", amount: euro("54.00"))
        let document = document(obligations: [streamingRule()], transactions: [paid])
        XCTAssertTrue(ReconciliationMatcher.candidates(forActual: "tx-1", in: context(document)).isEmpty)
    }

    // MARK: - 7. Currency is a wall

    func testDifferentCurrencyIsNeverACandidate() {
        // 50 MAD out of a dirham cash pocket, against a euro rule. The bare
        // numbers are close; the currencies are not, so there is no candidate.
        let accounts = [bank, wallet, cashMAD]
        let paid = actual(id: "tx-mad", on: "2026-09-26", amount: dirham("7.99"), account: "cash-mad")
        let document = document(accounts: accounts, obligations: [streamingRule()], transactions: [paid])

        XCTAssertTrue(
            ReconciliationMatcher.candidates(forActual: "tx-mad", in: context(document)).isEmpty,
            "a dirham movement can never settle a euro obligation"
        )

        let invalid = [ObligationSettlement.paid(
            id: "s-1", obligationID: "ob-streaming",
            expectedDay: day("2026-09-26"), actualTransactionID: "tx-mad"
        )]
        XCTAssertThrowsError(try ReconciliationLedger.validate(invalid, against: document)) { error in
            guard case ReconciliationError.currencyMismatch = error else {
                return XCTFail("expected a currency mismatch, got \(error)")
            }
        }
    }

    // MARK: - 8. One actual settles at most one occurrence

    func testOneActualCannotSettleTwoOccurrences() {
        let paid = actual(id: "tx-1", on: "2026-09-26", amount: euro("7.99"))
        let document = document(
            obligations: [streamingRule(), membershipRule(amount: "7.99")],
            transactions: [paid]
        )
        let doubled = [
            ObligationSettlement.paid(id: "s-1", obligationID: "ob-streaming",
                                      expectedDay: day("2026-09-26"), actualTransactionID: "tx-1"),
            ObligationSettlement.paid(id: "s-2", obligationID: "ob-membership",
                                      expectedDay: day("2026-09-27"), actualTransactionID: "tx-1"),
        ]
        XCTAssertThrowsError(try ReconciliationLedger.validate(doubled, against: document)) { error in
            guard case ReconciliationError.actualAlreadyReconciled = error else {
                return XCTFail("expected the second use of one actual to be refused, got \(error)")
            }
        }
    }

    func testAlreadyReconciledActualIsNoLongerOffered() {
        let paid = actual(id: "tx-1", on: "2026-09-26", amount: euro("7.99"))
        let document = document(
            obligations: [streamingRule(), membershipRule(amount: "7.99")],
            transactions: [paid],
            settlements: [
                .paid(id: "s-1", obligationID: "ob-streaming",
                      expectedDay: day("2026-09-26"), actualTransactionID: "tx-1")
            ]
        )
        XCTAssertTrue(
            ReconciliationMatcher.candidates(forActual: "tx-1", in: context(document)).isEmpty,
            "a spent actual must not be offered against a second occurrence"
        )
    }

    // MARK: - 9. One occurrence takes at most one actual

    func testOneOccurrenceCannotBeSettledByTwoActuals() {
        // No partial-payment semantics exist, so two actuals against one
        // occurrence is refused rather than quietly summed.
        let first = actual(id: "tx-1", on: "2026-09-26", amount: euro("4.00"))
        let second = actual(id: "tx-2", on: "2026-09-27", amount: euro("3.99"))
        let document = document(obligations: [streamingRule()], transactions: [first, second])

        let doubled = [
            ObligationSettlement.paid(id: "s-1", obligationID: "ob-streaming",
                                      expectedDay: day("2026-09-26"), actualTransactionID: "tx-1"),
            ObligationSettlement.paid(id: "s-2", obligationID: "ob-streaming",
                                      expectedDay: day("2026-09-26"), actualTransactionID: "tx-2"),
        ]
        XCTAssertThrowsError(try ReconciliationLedger.validate(doubled, against: document)) { error in
            guard case ReconciliationError.occurrenceAlreadyResolved = error else {
                return XCTFail("expected the occurrence to refuse a second settlement, got \(error)")
            }
        }
    }

    func testResolvedOccurrenceOffersNoFurtherCandidates() {
        let first = actual(id: "tx-1", on: "2026-09-26", amount: euro("7.99"))
        let second = actual(id: "tx-2", on: "2026-09-27", amount: euro("7.99"))
        let document = document(
            obligations: [streamingRule()],
            transactions: [first, second],
            settlements: [
                .paid(id: "s-1", obligationID: "ob-streaming",
                      expectedDay: day("2026-09-26"), actualTransactionID: "tx-1")
            ]
        )
        XCTAssertTrue(
            ReconciliationMatcher.candidates(
                forOccurrence: OccurrenceID(obligationID: "ob-streaming", expectedDay: day("2026-09-26")),
                in: context(document)
            ).isEmpty
        )
    }

    // MARK: - 10. An unanswered occurrence stays a question

    func testUnmatchedOverdueOccurrenceRemainsVisibleAndStillForecast() throws {
        let document = document(obligations: [streamingRule()])

        let occurrences = OccurrenceExpander.occurrences(
            in: document, from: day("2026-09-01"), to: day("2026-09-30"), asOf: day("2026-09-30")
        )
        XCTAssertEqual(occurrences.count, 1)
        XCTAssertEqual(occurrences[0].status, .overdue,
                       "a day that passed unmatched is overdue — never assumed paid")
        XCTAssertFalse(occurrences[0].status.isResolved)

        XCTAssertEqual(
            OccurrenceExpander.unresolved(
                in: document, from: day("2026-09-01"), to: day("2026-09-30"), asOf: day("2026-09-30")
            ).count,
            1
        )
        let result = try forecast(document)
        XCTAssertTrue(result.appliedEvents.contains { $0.sourceRef == "ob-streaming" })
    }

    // MARK: - 11. Skipping one month is not cancelling

    func testSkippingOneOccurrenceDoesNotCancelTheRule() throws {
        let document = document(
            obligations: [streamingRule()],
            settlements: [.skipped(id: "s-1", obligationID: "ob-streaming", expectedDay: day("2026-09-26"))]
        )
        let result = try forecast(document)

        XCTAssertFalse(
            result.appliedEvents.contains { $0.sourceRef == "ob-streaming" && $0.day == day("2026-09-26") },
            "a skipped occurrence expects no money to move"
        )
        XCTAssertTrue(
            result.appliedEvents.contains { $0.sourceRef == "ob-streaming" && $0.day == day("2026-10-26") },
            "skipping September must leave October exactly where it was"
        )

        let october = OccurrenceExpander.occurrences(
            in: document, from: day("2026-10-01"), to: day("2026-10-31"), asOf: day("2026-09-30")
        )
        XCTAssertEqual(october.map(\.status), [.due])
    }

    func testMarkingAnOccurrenceNoLongerDueAlsoLeavesTheRuleRunning() throws {
        let document = document(
            obligations: [streamingRule()],
            settlements: [.noLongerDue(id: "s-1", obligationID: "ob-streaming", expectedDay: day("2026-09-26"))]
        )
        let result = try forecast(document)
        XCTAssertFalse(result.appliedEvents.contains { $0.day == day("2026-09-26") && $0.sourceRef == "ob-streaming" })
        XCTAssertTrue(result.appliedEvents.contains { $0.day == day("2026-10-26") && $0.sourceRef == "ob-streaming" })
    }

    // MARK: - 12. Cancelling the rule does not rewrite history

    func testCancellingTheRuleKeepsHistoricalSettlementsIntact() throws {
        let paid = actual(id: "tx-1", on: "2026-09-26", amount: euro("7.99"))
        let settlement = ObligationSettlement.paid(
            id: "s-1", obligationID: "ob-streaming",
            expectedDay: day("2026-09-26"), actualTransactionID: "tx-1"
        )
        // The rule is ended after September: no October occurrence exists.
        let cancelled = document(
            obligations: [streamingRule(through: month(2026, 9))],
            transactions: [paid],
            settlements: [settlement]
        )

        XCTAssertEqual(cancelled.planning.settlements, [settlement],
                       "ending a rule must not delete what was already reconciled")
        XCTAssertNoThrow(try ReconciliationLedger.validate(cancelled.planning.settlements, against: cancelled),
                         "a historical settlement stays valid against a rule that no longer recurs")

        let history = OccurrenceExpander.occurrences(
            in: cancelled, from: day("2026-09-01"), to: day("2026-09-30"), asOf: day("2026-11-01")
        )
        XCTAssertEqual(history.map(\.status), [.paid(actualTransactionID: "tx-1")])

        let result = try forecast(cancelled)
        XCTAssertFalse(result.appliedEvents.contains { $0.day == day("2026-10-26") && $0.sourceRef == "ob-streaming" })
        XCTAssertEqual(cancelled.transactions.first { $0.id == "tx-1" }?.date, day("2026-09-26"),
                       "the observed transaction is untouched by anything done to the rule")
    }

    // MARK: - 13. The match survives a round trip

    func testExportImportPreservesTheMatchRelationship() throws {
        let paid = actual(id: "tx-1", on: "2026-09-29", amount: euro("7.99"))
        let original = document(
            obligations: [streamingRule()],
            transactions: [paid],
            settlements: [
                .paid(id: "s-1", obligationID: "ob-streaming", expectedDay: day("2026-09-26"),
                      actualTransactionID: "tx-1", acceptedAmountDifference: false,
                      note: "settled from the bank",
                      provenance: Provenance(source: "TEST", evidenceGrade: .userConfirmed))
            ]
        )

        let restored = try Interchange.decode(Interchange.encode(original))
        XCTAssertEqual(restored.planning.settlements, original.planning.settlements)
        XCTAssertEqual(restored.planning.settlements[0].actualTransactionID, "tx-1")
        XCTAssertEqual(restored.planning.settlements[0].expectedDay, day("2026-09-26"))

        // And the suppression survives with it.
        XCTAssertFalse(
            try forecast(restored).appliedEvents.contains {
                $0.sourceRef == "ob-streaming" && $0.day == day("2026-09-26")
            }
        )

        // Byte-deterministic, like every other part of the document.
        XCTAssertEqual(try Interchange.encode(restored), try Interchange.encode(original))
    }

    func testDocumentsWithoutSettlementsStillDecode() throws {
        // A 1.1.0-shaped document has no `settlements` key at all.
        let json = """
        {
          "schemaVersion": "1.1.0",
          "documentKind": "SYNTHETIC-TEST",
          "accounts": [], "balances": [], "transactions": [], "expectedTransactions": [],
          "incomeSources": [], "installments": [], "debts": [],
          "planning": { "budgets": [], "recurringObligations": [], "carriedEURValues": [] }
        }
        """
        let decoded = try Interchange.decode(Data(json.utf8))
        XCTAssertEqual(decoded.planning.settlements, [],
                       "a document written before reconciliation existed means nothing is reconciled")
    }

    // MARK: - Validation of references

    func testSettlementMustPointAtRealThings() {
        let paid = actual(id: "tx-1", on: "2026-09-26", amount: euro("7.99"))
        let document = document(obligations: [streamingRule()], transactions: [paid])

        XCTAssertThrowsError(try ReconciliationLedger.validate(
            [.paid(id: "s-1", obligationID: "nope", expectedDay: day("2026-09-26"), actualTransactionID: "tx-1")],
            against: document
        )) { error in
            guard case ReconciliationError.unknownObligation = error else {
                return XCTFail("expected unknownObligation, got \(error)")
            }
        }

        XCTAssertThrowsError(try ReconciliationLedger.validate(
            [.paid(id: "s-1", obligationID: "ob-streaming", expectedDay: day("2026-09-26"), actualTransactionID: "nope")],
            against: document
        )) { error in
            guard case ReconciliationError.unknownTransaction = error else {
                return XCTFail("expected unknownTransaction, got \(error)")
            }
        }

        // A day the rule never produces cannot be settled.
        XCTAssertThrowsError(try ReconciliationLedger.validate(
            [.paid(id: "s-1", obligationID: "ob-streaming", expectedDay: day("2026-09-15"), actualTransactionID: "tx-1")],
            against: document
        )) { error in
            guard case ReconciliationError.notAnOccurrenceOfRule = error else {
                return XCTFail("expected notAnOccurrenceOfRule, got \(error)")
            }
        }
    }

    func testExpectedOrReversedTransactionsCannotSettleAnything() {
        let expectedNotObserved = Transaction(
            id: "tx-plan", date: day("2026-09-26"), kind: .expense,
            legs: [AccountLeg(accountID: "bank", amount: euro("7.99").negated)],
            factivity: .expected, provenance: .devFixture
        )
        let reversed = actual(id: "tx-rev", on: "2026-09-26", amount: euro("7.99"), lifecycle: .reversed)
        let document = document(
            obligations: [streamingRule()],
            transactions: [expectedNotObserved, reversed]
        )

        XCTAssertThrowsError(try ReconciliationLedger.validate(
            [.paid(id: "s-1", obligationID: "ob-streaming", expectedDay: day("2026-09-26"), actualTransactionID: "tx-plan")],
            against: document
        )) { error in
            guard case ReconciliationError.actualIsNotObserved = error else {
                return XCTFail("expected actualIsNotObserved, got \(error)")
            }
        }
        XCTAssertThrowsError(try ReconciliationLedger.validate(
            [.paid(id: "s-1", obligationID: "ob-streaming", expectedDay: day("2026-09-26"), actualTransactionID: "tx-rev")],
            against: document
        )) { error in
            guard case ReconciliationError.actualIsReversed = error else {
                return XCTFail("expected actualIsReversed, got \(error)")
            }
        }

        // Neither is offered as a candidate either.
        XCTAssertTrue(ReconciliationMatcher.candidates(forActual: "tx-plan", in: context(document)).isEmpty)
        XCTAssertTrue(ReconciliationMatcher.candidates(forActual: "tx-rev", in: context(document)).isEmpty)
    }

    // MARK: - Candidate proposal, both directions

    func testOccurrenceOffersItsPlausibleActualsBestFirst() {
        let exact = actual(id: "tx-exact", on: "2026-09-28", amount: euro("7.99"))
        let near = actual(id: "tx-near", on: "2026-09-24", amount: euro("8.50"))
        let document = document(obligations: [streamingRule()], transactions: [exact, near])

        let candidates = ReconciliationMatcher.candidates(
            forOccurrence: OccurrenceID(obligationID: "ob-streaming", expectedDay: day("2026-09-26")),
            in: context(document)
        )
        XCTAssertEqual(candidates.map(\.actualTransactionID), ["tx-exact", "tx-near"],
                       "the exact amount must be proposed first")
        XCTAssertTrue(candidates[0].signals.contains(.daysApart(2)))
        XCTAssertFalse(candidates[0].requiresAmountConfirmation)
        XCTAssertTrue(candidates[1].requiresAmountConfirmation)
    }

    func testTitleSimilarityLiftsAMatchWithoutBeingRequired() {
        let titled = actual(id: "tx-1", on: "2026-09-26", amount: euro("7.99"))
        let document = document(obligations: [streamingRule()], transactions: [titled])

        let withTitle = ReconciliationMatcher.candidates(
            forActual: "tx-1", in: context(document, titles: ["tx-1": "Streaming Premium"])
        )
        let withoutTitle = ReconciliationMatcher.candidates(forActual: "tx-1", in: context(document))

        XCTAssertTrue(withTitle[0].signals.contains(.titleMatch))
        XCTAssertGreaterThan(withTitle[0].score, withoutTitle[0].score)
        XCTAssertEqual(withoutTitle.count, 1, "a missing merchant name never removes a candidate")
    }

    func testCandidatesOutsideTheWindowAreNotProposed() {
        // Next month's charge must never be a candidate for this month's.
        let paid = actual(id: "tx-1", on: "2026-10-26", amount: euro("7.99"))
        let document = document(obligations: [streamingRule()], transactions: [paid])

        let candidates = ReconciliationMatcher.candidates(
            forOccurrence: OccurrenceID(obligationID: "ob-streaming", expectedDay: day("2026-09-26")),
            in: context(document)
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testHypotheticalRuleHasNothingToReconcile() {
        let document = document(obligations: [streamingRule(status: .hypothetical)])
        XCTAssertTrue(
            OccurrenceExpander.occurrences(
                in: document, from: day("2026-09-01"), to: day("2026-10-31"), asOf: day("2026-09-30")
            ).isEmpty
        )
    }

    // MARK: - Ledger shape

    func testLedgerIsDeterministicRegardlessOfInputOrder() {
        let a = ObligationSettlement.skipped(id: "s-a", obligationID: "ob-streaming", expectedDay: day("2026-09-26"))
        let b = ObligationSettlement.skipped(id: "s-b", obligationID: "ob-membership", expectedDay: day("2026-09-27"))
        XCTAssertEqual(ReconciliationLedger([a, b]).settlements, ReconciliationLedger([b, a]).settlements)
        XCTAssertTrue(ReconciliationLedger([a, b]).isResolved(obligationID: "ob-streaming", day: day("2026-09-26")))
        XCTAssertFalse(ReconciliationLedger([a, b]).isResolved(obligationID: "ob-streaming", day: day("2026-10-26")))
    }
}
