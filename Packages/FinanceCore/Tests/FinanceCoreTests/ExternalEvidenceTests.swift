import XCTest
@testable import FinanceCore

final class ExternalEvidenceTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_777_680_000)
    private let boundary = Day(year: 2026, month: 8, day: 22)

    private func document(recurring: Bool = false) -> FinanceDocument {
        let obligations: [RecurringObligation] = recurring ? [
            RecurringObligation(
                id: "rule-streaming",
                name: "Streaming Premium",
                amount: Money(minorUnits: 799, currency: .eur),
                spec: .monthly(onDay: 26, from: MonthKey(year: 2026, month: 8), through: nil),
                requirement: .euroBankPayment(rails: [.cardDebit]),
                spendingClass: .optional
            )
        ] : []
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [
                Account(id: "bank", name: "Bank A", currency: .eur, kind: .bank,
                        supportedRails: [.cardDebit, .sepaCreditTransfer]),
                Account(id: "wallet", name: "Wallet", currency: .eur, kind: .wallet,
                        supportedRails: [.electronicPayment]),
                Account(id: "revolut-eur", name: "Revolut EUR", currency: .eur, kind: .wallet,
                        supportedRails: [.cardDebit]),
                Account(id: "revolut-chf", name: "Revolut CHF", currency: Currency(code: "CHF"), kind: .wallet,
                        supportedRails: [.cardDebit]),
                Account(id: "cash", name: "Cash", currency: .eur, kind: .cash,
                        supportedRails: [.physicalCash])
            ],
            balances: [
                AccountBalance(accountID: "bank", balance: Money(minorUnits: 38_409, currency: .eur), asOf: boundary),
                AccountBalance(accountID: "wallet", balance: Money(minorUnits: 0, currency: .eur), asOf: boundary),
                AccountBalance(accountID: "revolut-eur", balance: Money(minorUnits: 5_000, currency: .eur), asOf: boundary),
                AccountBalance(accountID: "revolut-chf", balance: Money(minorUnits: 2_000, currency: Currency(code: "CHF")), asOf: boundary),
                AccountBalance(accountID: "cash", balance: Money(minorUnits: 0, currency: .eur), asOf: boundary)
            ],
            planning: FinanceDocument.Planning(recurringObligations: obligations),
            externalAccountBindings: [
                binding("binding-bank", provider: .bnp, remote: "acct_bank", local: "bank"),
                binding("binding-wallet", provider: .paypal, remote: "acct_wallet", local: "wallet"),
                binding("binding-rev-eur", provider: .revolut, remote: "acct_rev_eur", local: "revolut-eur"),
                binding("binding-rev-chf", provider: .revolut, remote: "acct_rev_chf", local: "revolut-chf")
            ]
        )
    }

    private func binding(
        _ id: String, provider: ExternalProvider, remote: String, local: String
    ) -> ExternalAccountBinding {
        ExternalAccountBinding(
            id: id, provider: provider, remoteOpaqueAccountID: remote,
            localAccountID: local, syncStartBoundary: boundary, createdAt: observedAt
        )
    }

    private func observation(
        _ id: String,
        bindingID: String = "binding-bank",
        provider: ExternalProvider = .bnp,
        amount: Int64 = -799,
        status: ExternalObservationStatus = .booked,
        identity: ExternalObservationIdentity = .durable,
        booking: Day? = Day(year: 2026, month: 8, day: 26),
        transaction: Day? = nil,
        value: Day? = nil,
        derived: Day? = nil,
        derivedProvenance: DerivedExternalDateProvenance? = nil,
        merchant: String? = nil,
        raw: String? = "SYNTHETIC MERCHANT",
        code: String? = nil,
        eligible: Bool = true
    ) -> ExternalObservation {
        ExternalObservation(
            id: id,
            bindingID: bindingID,
            provider: provider,
            identity: identity,
            status: status,
            creditDebitIndicator: amount < 0 ? .debit : .credit,
            amount: Money(minorUnits: amount, currency: .eur),
            bookingDate: booking,
            transactionDate: transaction,
            valueDate: value,
            derivedTransactionDate: derived,
            derivedDateProvenance: derivedProvenance,
            rawMerchantText: raw,
            structuredMerchantName: merchant,
            remittance: raw,
            bankTransactionCode: code,
            eligibleForEconomicActual: eligible,
            observedAt: observedAt
        )
    }

    private func actual(_ id: String = "actual", amount: Int64 = -799, account: String = "bank") -> Transaction {
        Transaction(
            id: id,
            date: Day(year: 2026, month: 8, day: 26),
            kind: .expense,
            legs: [AccountLeg(accountID: account, amount: Money(minorUnits: amount, currency: .eur))],
            factivity: .observed,
            provenance: Provenance(source: "TEST-USER", evidenceGrade: .userConfirmed)
        )
    }

    private func importObservations(_ observations: [ExternalObservation], into document: inout FinanceDocument) throws {
        try ExternalEvidenceReview.importBatch(
            ExternalEvidenceBatch(observations: observations), into: &document
        )
    }

    // 1
    func testSameBookedObservationImportedTwiceIsOneObservation() throws {
        var value = document()
        let row = observation("obs-1")
        try importObservations([row], into: &value)
        try importObservations([row], into: &value)
        XCTAssertEqual(value.externalObservations.count, 1)
        XCTAssertEqual(value.observationResolutions.count, 1)
    }

    func testSameObservationPromotesFromProvisionalToDurableBookedReview() throws {
        var value = document()
        try importObservations([
            observation(
                "upserted", status: .pending,
                identity: .provisionalSnapshot, eligible: false
            )
        ], into: &value)
        XCTAssertEqual(value.observationResolutions[0].state, .provisional)

        try importObservations([observation("upserted")], into: &value)

        XCTAssertEqual(value.externalObservations.count, 1)
        XCTAssertEqual(value.externalObservations[0].status, .booked)
        XCTAssertEqual(value.externalObservations[0].identity, .durable)
        XCTAssertEqual(value.observationResolutions[0].state, .unreviewed)
        XCTAssertEqual(ExternalEvidenceReview.reviewQueue(in: value).map(\.id), ["upserted"])
    }

    // 2
    func testPreCutoverObservationDoesNotEnterReviewQueue() throws {
        var value = document()
        try importObservations([
            observation("old", booking: Day(year: 2026, month: 8, day: 22))
        ], into: &value)
        XCTAssertTrue(ExternalEvidenceReview.reviewQueue(in: value).isEmpty)
        XCTAssertEqual(value.observationResolutions.first?.state, .outsideSyncBoundary)
    }

    // 3
    func testPostCutoverObservationEntersReviewQueue() throws {
        var value = document()
        try importObservations([observation("new")], into: &value)
        XCTAssertEqual(ExternalEvidenceReview.reviewQueue(in: value).map(\.id), ["new"])
    }

    // 4
    func testPendingObservationCannotCreateDurableEconomicActual() throws {
        var value = document()
        try importObservations([
            observation("pending", status: .pending, identity: .provisionalSnapshot, eligible: false)
        ], into: &value)
        XCTAssertThrowsError(
            try ExternalEvidenceReview.createTransaction(
                actual(), evidence: [.init(observationID: "pending", role: .accountMovement)],
                resolvedAt: observedAt, in: &value
            )
        )
        XCTAssertTrue(value.transactions.isEmpty)
    }

    // 5
    func testRejectedPayPalObservationIsEconomicallyIneligible() throws {
        var value = document()
        try importObservations([
            observation(
                "rejected", bindingID: "binding-wallet", provider: .paypal,
                status: .rejected, booking: nil,
                transaction: Day(year: 2026, month: 8, day: 26), eligible: false
            )
        ], into: &value)
        XCTAssertEqual(value.observationResolutions.first?.state, .economicallyIneligible)
        XCTAssertFalse(value.externalObservations[0].eligibleForEconomicActual)
    }

    // 6
    func testBankMovementAndPayPalMerchantEvidenceCreateOneTransaction() throws {
        var value = document()
        let bank = observation("bank-evidence", raw: "PAYPAL EUROPE")
        let wallet = observation(
            "wallet-evidence", bindingID: "binding-wallet", provider: .paypal,
            booking: nil, transaction: Day(year: 2026, month: 8, day: 25),
            merchant: "Google Payment Ireland", raw: nil
        )
        try importObservations([bank, wallet], into: &value)
        try ExternalEvidenceReview.createTransaction(
            actual(),
            evidence: [
                .init(observationID: bank.id, role: .accountMovement),
                .init(observationID: wallet.id, role: .merchantEnrichment)
            ],
            resolvedAt: observedAt,
            in: &value
        )
        XCTAssertEqual(value.transactions.count, 1)
        XCTAssertEqual(value.externalEvidenceLinks.count, 2)
        XCTAssertEqual(Set(value.externalEvidenceLinks.map(\.transactionID)), ["actual"])
    }

    // 7
    func testLinkedPayPalObservationCannotGenerateASecondExpense() throws {
        var value = document()
        let bank = observation("bank-evidence", raw: "PAYPAL EUROPE")
        let wallet = observation(
            "wallet-evidence", bindingID: "binding-wallet", provider: .paypal,
            booking: nil, transaction: Day(year: 2026, month: 8, day: 25), merchant: "Merchant"
        )
        try importObservations([bank, wallet], into: &value)
        try ExternalEvidenceReview.createTransaction(
            actual(), evidence: [
                .init(observationID: bank.id, role: .accountMovement),
                .init(observationID: wallet.id, role: .merchantEnrichment)
            ], resolvedAt: observedAt, in: &value
        )
        XCTAssertThrowsError(
            try ExternalEvidenceReview.createTransaction(
                actual("duplicate", account: "wallet"),
                evidence: [.init(observationID: wallet.id, role: .accountMovement)],
                resolvedAt: observedAt, in: &value
            )
        )
        XCTAssertEqual(value.transactions.count, 1)
    }

    // 8
    func testUniqueCrossProviderCandidateIsSuggestionOnly() throws {
        var value = document()
        let bank = observation("bank")
        let wallet = observation(
            "wallet", bindingID: "binding-wallet", provider: .paypal,
            booking: nil, transaction: Day(year: 2026, month: 8, day: 25)
        )
        let candidate = CrossProviderCandidate(
            id: "candidate", bankObservationID: bank.id, walletObservationID: wallet.id,
            state: .unique, candidateCount: 1, amount: bank.amount.magnitude,
            rule: "same_amount_window", computedAt: observedAt
        )
        try ExternalEvidenceReview.importBatch(
            .init(observations: [bank, wallet], candidates: [candidate]), into: &value
        )
        XCTAssertTrue(value.externalEvidenceLinks.isEmpty)
        XCTAssertTrue(ExternalEvidenceReview.suggestions(for: bank.id, in: value).contains {
            $0.kind == .crossProviderEvidence && $0.relatedObservationID == wallet.id
        })
    }

    // 9
    func testAmbiguousCandidateProducesNoAutomaticLink() throws {
        var value = document()
        let bank = observation("bank")
        let candidate = CrossProviderCandidate(
            id: "ambiguous", bankObservationID: bank.id, walletObservationID: nil,
            state: .ambiguous, candidateCount: 2, amount: bank.amount.magnitude,
            rule: "same_amount_window", computedAt: observedAt
        )
        try ExternalEvidenceReview.importBatch(
            .init(observations: [bank], candidates: [candidate]), into: &value
        )
        XCTAssertTrue(value.externalEvidenceLinks.isEmpty)
        XCTAssertEqual(
            ExternalEvidenceReview.suggestions(for: bank.id, in: value).last?.kind,
            .merchantUnresolved
        )
    }

    // 10
    func testUnresolvedCandidateRemainsUnresolved() throws {
        var value = document()
        let bank = observation("bank")
        let candidate = CrossProviderCandidate(
            id: "unresolved", bankObservationID: bank.id, walletObservationID: nil,
            state: .unresolved, candidateCount: 0, amount: bank.amount.magnitude,
            rule: "same_amount_window", computedAt: observedAt
        )
        try ExternalEvidenceReview.importBatch(
            .init(observations: [bank], candidates: [candidate]), into: &value
        )
        XCTAssertEqual(value.crossProviderCandidates[0].state, .unresolved)
        XCTAssertTrue(value.externalEvidenceLinks.isEmpty)
    }

    // 11
    func testManualTransactionCanBeLinkedInsteadOfDuplicated() throws {
        var value = document()
        value.transactions = [actual("manual")]
        try importObservations([observation("bank")], into: &value)
        try ExternalEvidenceReview.linkExistingTransaction(
            transactionID: "manual",
            evidence: [.init(observationID: "bank", role: .accountMovement)],
            resolvedAt: observedAt,
            in: &value
        )
        XCTAssertEqual(value.transactions.map(\.id), ["manual"])
        XCTAssertEqual(value.externalEvidenceLinks.first?.transactionID, "manual")
    }

    // 12
    func testConfirmedObservationSettlesExpectedOccurrence() throws {
        var value = document(recurring: true)
        try importObservations([observation("streaming")], into: &value)
        let occurrence = OccurrenceID(
            obligationID: "rule-streaming", expectedDay: Day(year: 2026, month: 8, day: 26)
        )
        try ExternalEvidenceReview.createTransaction(
            actual("streaming-actual"),
            evidence: [.init(observationID: "streaming", role: .accountMovement)],
            settling: occurrence,
            resolvedAt: observedAt,
            in: &value
        )
        XCTAssertEqual(value.planning.settlements.first?.actualTransactionID, "streaming-actual")
    }

    // 13
    func testFutureRecurringOccurrenceRemainsActive() throws {
        var value = document(recurring: true)
        try importObservations([observation("streaming")], into: &value)
        try ExternalEvidenceReview.createTransaction(
            actual("streaming-actual"),
            evidence: [.init(observationID: "streaming", role: .accountMovement)],
            settling: OccurrenceID(
                obligationID: "rule-streaming", expectedDay: Day(year: 2026, month: 8, day: 26)
            ),
            resolvedAt: observedAt,
            in: &value
        )
        let future = OccurrenceExpander.occurrences(
            in: value,
            from: Day(year: 2026, month: 9, day: 1),
            to: Day(year: 2026, month: 9, day: 30),
            asOf: Day(year: 2026, month: 9, day: 1),
            ledger: ReconciliationLedger(value.planning.settlements)
        )
        XCTAssertEqual(future.map(\.expectedDay), [Day(year: 2026, month: 9, day: 26)])
        XCTAssertFalse(future[0].status.isResolved)
    }

    // 14
    func testATMCodeNeverAutomaticallyClassifiesAsSpending() throws {
        var value = document()
        try importObservations([observation("atm", code: "ATM")], into: &value)
        XCTAssertTrue(ExternalEvidenceReview.suggestions(for: "atm", in: value).contains {
            $0.kind == .atmCashMovement
        })
        XCTAssertTrue(value.transactions.isEmpty)
    }

    // 15
    func testTransferTopupExchangeNeverAutomaticallyClassifyAsSpending() throws {
        for code in ["TRANSFER", "TOPUP", "EXCHANGE"] {
            var value = document()
            try importObservations([observation("row", code: code)], into: &value)
            XCTAssertTrue(ExternalEvidenceReview.suggestions(for: "row", in: value).contains {
                $0.kind == .likelyTransfer
            }, code)
            XCTAssertTrue(value.transactions.isEmpty, code)
        }
    }

    // 16
    func testRefundReversalNeverAutomaticallyClassifiesAsIncome() throws {
        for code in ["REFUND", "REVERSAL", "CARD_REFUND"] {
            var value = document()
            try importObservations([observation("row", amount: 799, code: code)], into: &value)
            XCTAssertTrue(ExternalEvidenceReview.suggestions(for: "row", in: value).contains {
                $0.kind == .refundOrReversal
            }, code)
            XCTAssertTrue(value.transactions.isEmpty, code)
        }
    }

    // 17
    func testRevolutSharedReferenceLegsRemainSeparateObservations() throws {
        var value = document()
        let eur = observation(
            "obs-rev-eur", bindingID: "binding-rev-eur", provider: .revolut,
            amount: -1_000, code: "EXCHANGE"
        )
        let chf = ExternalObservation(
            id: "obs-rev-chf", bindingID: "binding-rev-chf", provider: .revolut,
            status: .booked, creditDebitIndicator: .credit,
            amount: Money(minorUnits: 950, currency: Currency(code: "CHF")),
            bookingDate: Day(year: 2026, month: 8, day: 26),
            valueDate: Day(year: 2026, month: 8, day: 26),
            bankTransactionCode: "EXCHANGE", eligibleForEconomicActual: true,
            observedAt: observedAt
        )
        try importObservations([eur, chf], into: &value)
        XCTAssertEqual(Set(value.externalObservations.map(\.id)), ["obs-rev-eur", "obs-rev-chf"])
    }

    // 18
    func testProviderBalanceSnapshotDoesNotOverwriteLedgerBalance() throws {
        var value = document()
        let opening = value.balances.first { $0.accountID == "bank" }
        let provider = ProviderBalanceSnapshot(
            id: "balance", bindingID: "binding-bank", provider: .bnp,
            balanceType: "CLBD", amount: Money(minorUnits: 37_261, currency: .eur),
            referenceDate: Day(year: 2026, month: 8, day: 26), observedAt: observedAt
        )
        try ExternalEvidenceReview.importBatch(.init(balances: [provider]), into: &value)
        XCTAssertEqual(value.balances.first { $0.accountID == "bank" }, opening)
        XCTAssertEqual(value.providerBalanceSnapshots.first?.amount.minorUnits, 37_261)

        let wrongProvider = ProviderBalanceSnapshot(
            id: "wrong-provider", bindingID: "binding-bank", provider: .paypal,
            balanceType: "CLBD", amount: Money(minorUnits: 1, currency: .eur),
            observedAt: observedAt
        )
        XCTAssertThrowsError(
            try ExternalEvidenceReview.importBatch(.init(balances: [wrongProvider]), into: &value)
        )
        XCTAssertEqual(value.providerBalanceSnapshots.map(\.id), ["balance"], "a rejected batch is atomic")
    }

    // 19
    func testAllProviderDatesRemainDistinct() {
        let row = observation(
            "dates",
            booking: Day(year: 2026, month: 8, day: 26),
            transaction: Day(year: 2026, month: 8, day: 24),
            value: Day(year: 2026, month: 8, day: 27),
            derived: Day(year: 2026, month: 8, day: 23),
            derivedProvenance: .parsedFromProviderRemittance
        )
        XCTAssertEqual(row.bookingDate?.day, 26)
        XCTAssertEqual(row.transactionDate?.day, 24)
        XCTAssertEqual(row.valueDate?.day, 27)
        XCTAssertEqual(row.derivedTransactionDate?.day, 23)
    }

    // 20
    func testDerivedBNPCardDateRetainsProvenance() {
        let row = observation(
            "derived", derived: Day(year: 2026, month: 8, day: 18),
            derivedProvenance: .parsedFromProviderRemittance
        )
        XCTAssertEqual(row.derivedTransactionDate, Day(year: 2026, month: 8, day: 18))
        XCTAssertEqual(row.derivedDateProvenance, .parsedFromProviderRemittance)
        XCTAssertNil(row.transactionDate)

        var value = document()
        XCTAssertThrowsError(
            try importObservations([
                observation(
                    "missing-provenance", derived: Day(year: 2026, month: 8, day: 18)
                )
            ], into: &value)
        )
        XCTAssertTrue(value.externalObservations.isEmpty, "a derived date cannot lose its audit trail")
    }

    // 21
    func testObservedMerchantSurvivesUserLabelOverride() throws {
        var value = document()
        let row = observation("merchant", merchant: "Google Payment Ireland")
        try importObservations([row], into: &value)
        let userLabeled = Transaction(
            id: "labeled", date: Day(year: 2026, month: 8, day: 26), kind: .expense,
            legs: [AccountLeg(accountID: "bank", amount: row.amount)],
            factivity: .observed, note: "YouTube Premium",
            provenance: Provenance(source: "USER", evidenceGrade: .userConfirmed)
        )
        try ExternalEvidenceReview.createTransaction(
            userLabeled, evidence: [.init(observationID: row.id, role: .accountMovement)],
            resolvedAt: observedAt, in: &value
        )
        XCTAssertEqual(value.externalObservations[0].structuredMerchantName, "Google Payment Ireland")
        XCTAssertEqual(value.transactions[0].note, "YouTube Premium")
    }

    // 22
    func testOneObservationCannotAccountMovementLinkTwoTransactions() throws {
        var value = document()
        let row = observation("one")
        try importObservations([row], into: &value)
        value.transactions = [actual("first"), actual("second")]
        value.externalEvidenceLinks = [
            .init(id: "link-1", observationID: row.id, transactionID: "first", role: .accountMovement),
            .init(id: "link-2", observationID: row.id, transactionID: "second", role: .supportingEvidence)
        ]
        value.observationResolutions[0].state = .linkedToTransaction
        XCTAssertThrowsError(try ExternalEvidenceReview.validate(value)) { error in
            guard case ExternalEvidenceError.observationLinkedToMultipleTransactions("one") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    // 23
    func testManyObservationsSupportOneTransactionWithDistinctRoles() throws {
        var value = document()
        let bank = observation("bank", raw: "PAYPAL")
        let wallet = observation(
            "wallet", bindingID: "binding-wallet", provider: .paypal,
            booking: nil, transaction: Day(year: 2026, month: 8, day: 25), merchant: "Merchant"
        )
        try importObservations([bank, wallet], into: &value)
        try ExternalEvidenceReview.createTransaction(
            actual(), evidence: [
                .init(observationID: bank.id, role: .accountMovement),
                .init(observationID: wallet.id, role: .merchantEnrichment)
            ], resolvedAt: observedAt, in: &value
        )
        XCTAssertEqual(Set(value.externalEvidenceLinks.map(\.role)), [.accountMovement, .merchantEnrichment])
        XCTAssertEqual(Set(value.externalEvidenceLinks.map(\.transactionID)).count, 1)
    }

    // 24
    func testExportImportPreservesEvidenceLinksAndIsDeterministic() throws {
        var value = document()
        let row = observation("bank")
        try importObservations([row], into: &value)
        try ExternalEvidenceReview.createTransaction(
            actual(), evidence: [.init(observationID: row.id, role: .accountMovement)],
            resolvedAt: observedAt, in: &value
        )
        let first = try Interchange.encode(value)
        let decoded = try Interchange.decode(first)
        let second = try Interchange.encode(decoded)
        XCTAssertEqual(decoded.externalObservations, value.externalObservations)
        XCTAssertEqual(decoded.externalEvidenceLinks, value.externalEvidenceLinks)
        XCTAssertEqual(first, second)
    }

    // 25 — Phase 2.4D status regression
    func testUnreviewedBookedObservationThatBecomesRejectedLeavesTheQueue() throws {
        var value = document()
        try importObservations([observation("regressing")], into: &value)
        XCTAssertEqual(ExternalEvidenceReview.reviewQueue(in: value).map(\.id), ["regressing"])

        let rejected = ExternalObservation(
            id: "regressing", bindingID: "binding-bank", provider: .bnp,
            status: .rejected, creditDebitIndicator: .debit,
            amount: Money(minorUnits: -799, currency: .eur),
            bookingDate: Day(year: 2026, month: 8, day: 26),
            rawMerchantText: "SYNTHETIC MERCHANT",
            eligibleForEconomicActual: false,
            observedAt: observedAt.addingTimeInterval(3_600)
        )
        try importObservations([rejected], into: &value)

        XCTAssertTrue(ExternalEvidenceReview.reviewQueue(in: value).isEmpty)
        XCTAssertEqual(value.observationResolutions[0].state, .economicallyIneligible)
        XCTAssertTrue(ExternalEvidenceReview.providerStatusWarnings(in: value).isEmpty)
    }

    // 26
    func testUnreviewedObservationThatBecomesPendingReturnsToProvisional() throws {
        var value = document()
        try importObservations([observation("wobbling")], into: &value)

        let pending = ExternalObservation(
            id: "wobbling", bindingID: "binding-bank", provider: .bnp,
            identity: .provisionalSnapshot, status: .pending, creditDebitIndicator: .debit,
            amount: Money(minorUnits: -799, currency: .eur),
            bookingDate: Day(year: 2026, month: 8, day: 26),
            eligibleForEconomicActual: false,
            observedAt: observedAt.addingTimeInterval(3_600)
        )
        try importObservations([pending], into: &value)

        XCTAssertEqual(value.observationResolutions[0].state, .provisional)
    }

    // 27
    func testResolvedObservationKeepsItsResolutionAndRaisesAWarning() throws {
        var value = document()
        let row = observation("settled")
        try importObservations([row], into: &value)
        try ExternalEvidenceReview.createTransaction(
            actual(), evidence: [.init(observationID: row.id, role: .accountMovement)],
            resolvedAt: observedAt, in: &value
        )
        XCTAssertEqual(value.transactions.count, 1)

        let rejected = ExternalObservation(
            id: "settled", bindingID: "binding-bank", provider: .bnp,
            status: .rejected, creditDebitIndicator: .debit,
            amount: Money(minorUnits: -799, currency: .eur),
            bookingDate: Day(year: 2026, month: 8, day: 26),
            rawMerchantText: "SYNTHETIC MERCHANT",
            eligibleForEconomicActual: false,
            observedAt: observedAt.addingTimeInterval(3_600)
        )
        try importObservations([rejected], into: &value)

        // The person's decision stands, and so does the money they recorded.
        XCTAssertEqual(value.observationResolutions[0].state, .linkedToTransaction)
        XCTAssertEqual(value.transactions.count, 1)
        XCTAssertEqual(value.externalEvidenceLinks.count, 1)
        // But the divergence is surfaced rather than buried.
        XCTAssertEqual(ExternalEvidenceReview.providerStatusWarnings(in: value), ["settled"])
    }

    // 28
    func testObservationMarkedNoEconomicEffectAlsoKeepsItsResolutionOnRegression() throws {
        var value = document()
        try importObservations([observation("ignored")], into: &value)
        try ExternalEvidenceReview.markNoEconomicEffect(
            observationID: "ignored", resolvedAt: observedAt, in: &value
        )

        let rejected = ExternalObservation(
            id: "ignored", bindingID: "binding-bank", provider: .bnp,
            status: .rejected, creditDebitIndicator: .debit,
            amount: Money(minorUnits: -799, currency: .eur),
            bookingDate: Day(year: 2026, month: 8, day: 26),
            rawMerchantText: "SYNTHETIC MERCHANT",
            eligibleForEconomicActual: false,
            observedAt: observedAt.addingTimeInterval(3_600)
        )
        try importObservations([rejected], into: &value)

        XCTAssertEqual(value.observationResolutions[0].state, .noEconomicEffect)
        XCTAssertEqual(ExternalEvidenceReview.providerStatusWarnings(in: value), ["ignored"])
    }

    // 29
    func testAnOlderResyncNeverRewritesNewerEvidenceOrState() throws {
        var value = document()
        try importObservations([observation("stable")], into: &value)

        let stale = ExternalObservation(
            id: "stable", bindingID: "binding-bank", provider: .bnp,
            status: .rejected, creditDebitIndicator: .debit,
            amount: Money(minorUnits: -799, currency: .eur),
            bookingDate: Day(year: 2026, month: 8, day: 26),
            eligibleForEconomicActual: false,
            observedAt: observedAt.addingTimeInterval(-3_600)
        )
        try importObservations([stale], into: &value)

        XCTAssertEqual(value.externalObservations[0].status, .booked)
        XCTAssertEqual(value.observationResolutions[0].state, .unreviewed)
    }
}

final class ExternalEvidenceMigrationTests: XCTestCase {
    private func sourceDocument(withSettlement: Bool) -> FinanceDocument {
        let day = Day(year: 2026, month: 9, day: 26)
        let account = Account(
            id: "bank", name: "Bank", currency: .eur, kind: .bank,
            supportedRails: [.cardDebit]
        )
        let arrival = Transaction(
            id: "owned-arrival", date: day, kind: .passThrough,
            legs: [AccountLeg(accountID: account.id, amount: Money(minorUnits: 1_000, currency: .eur))],
            ownership: [
                OwnershipSplit(
                    ownerID: "self", isSelf: true,
                    amount: Money(minorUnits: 400, currency: .eur)
                ),
                OwnershipSplit(
                    ownerID: "other", isSelf: false,
                    amount: Money(minorUnits: 600, currency: .eur)
                )
            ],
            factivity: .observed,
            provenance: Provenance(source: "MIGRATION-TEST", evidenceGrade: .userConfirmed)
        )
        let actual = Transaction(
            id: "streaming-actual", date: day, kind: .expense,
            legs: [AccountLeg(accountID: account.id, amount: Money(minorUnits: -799, currency: .eur))],
            factivity: .observed,
            provenance: Provenance(source: "MIGRATION-TEST", evidenceGrade: .userConfirmed)
        )
        let obligation = RecurringObligation(
            id: "streaming-rule", name: "Streaming", amount: Money(minorUnits: 799, currency: .eur),
            spec: .monthly(onDay: 26, from: MonthKey(year: 2026, month: 9), through: nil),
            requirement: .euroBankPayment(rails: [.cardDebit]), spendingClass: .optional
        )
        return FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "MIGRATION-TEST",
            accounts: [account],
            balances: [
                AccountBalance(
                    accountID: account.id, balance: Money(minorUnits: 10_000, currency: .eur), asOf: day
                )
            ],
            transactions: withSettlement ? [arrival, actual] : [arrival],
            planning: FinanceDocument.Planning(
                recurringObligations: withSettlement ? [obligation] : [],
                settlements: withSettlement ? [
                    .paid(
                        id: "settlement", obligationID: obligation.id, expectedDay: day,
                        actualTransactionID: actual.id,
                        provenance: Provenance(source: "MIGRATION-TEST", evidenceGrade: .userConfirmed)
                    )
                ] : []
            )
        )
    }

    /// Produces the shape an older writer emitted by removing every 1.3 key;
    /// 1.1 also predates the 1.2 settlements key.
    private func legacyPayload(version: String, withSettlement: Bool) throws -> Data {
        let encoded = try Interchange.encode(sourceDocument(withSettlement: withSettlement))
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        root["schemaVersion"] = version
        for key in [
            "externalAccountBindings", "externalObservations", "providerBalanceSnapshots",
            "externalEvidenceLinks", "observationResolutions", "crossProviderCandidates"
        ] {
            root.removeValue(forKey: key)
        }
        if version == "1.1.0", var planning = root["planning"] as? [String: Any] {
            planning.removeValue(forKey: "settlements")
            root["planning"] = planning
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    func testVersion110DefaultsEvidenceEmpty() throws {
        let original = sourceDocument(withSettlement: false)
        var value = try Interchange.decode(legacyPayload(version: "1.1.0", withSettlement: false))
        XCTAssertTrue(value.externalObservations.isEmpty)
        XCTAssertTrue(value.externalEvidenceLinks.isEmpty)
        XCTAssertEqual(value.transactions, original.transactions, "1.1 ownership and economics must survive")
        XCTAssertTrue(value.planning.settlements.isEmpty)
        value.schemaVersion = Interchange.currentSchemaVersion
        XCTAssertEqual(try Interchange.decode(Interchange.encode(value)).transactions, original.transactions)
    }

    func testVersion120PreservesSettlementsAndDefaultsEvidenceEmpty() throws {
        let original = sourceDocument(withSettlement: true)
        var value = try Interchange.decode(legacyPayload(version: "1.2.0", withSettlement: true))
        XCTAssertEqual(value.transactions, original.transactions)
        XCTAssertEqual(value.planning.settlements, original.planning.settlements)
        XCTAssertTrue(value.externalAccountBindings.isEmpty)
        XCTAssertTrue(value.externalObservations.isEmpty)
        XCTAssertTrue(value.providerBalanceSnapshots.isEmpty)
        XCTAssertTrue(value.externalEvidenceLinks.isEmpty)
        XCTAssertTrue(value.observationResolutions.isEmpty)
        XCTAssertTrue(value.crossProviderCandidates.isEmpty)
        value.schemaVersion = Interchange.currentSchemaVersion
        XCTAssertEqual(
            try Interchange.decode(Interchange.encode(value)).planning.settlements,
            original.planning.settlements
        )
    }

    func testReadableVersionsIncludeAllAdditiveMinorVersions() {
        XCTAssertEqual(
            Interchange.readableSchemaVersions,
            ["1.1.0", "1.2.0", "1.3.0", "1.4.0", "1.5.0", "1.6.0", "2.0.0"]
        )
        XCTAssertEqual(Interchange.currentSchemaVersion, "1.6.0")
    }

    func testCurrentSchemaEncodingIsDeterministicWithEmptyEvidence() throws {
        let old = try Interchange.decode(legacyPayload(version: "1.1.0", withSettlement: false))
        var migrated = old
        migrated.schemaVersion = Interchange.currentSchemaVersion
        XCTAssertEqual(try Interchange.encode(migrated), try Interchange.encode(migrated))
    }
}
