import XCTest
@testable import FinanceCore

final class CurrentHoldingsTests: XCTestCase {
    private let anchorDay = Day(year: 2026, month: 8, day: 22)
    private let today = Day(year: 2026, month: 8, day: 31)
    private let observedAt = Date(timeIntervalSince1970: 1_777_680_000)

    func testForensicFallbackAfterAnchorOnly() {
        let document = forensicDocument(includingDuplicate: false)
        let fallback = CurrentHoldings.derivedLedgerBalance(
            accountID: "bank-main", asOf: today, in: document
        )
        XCTAssertEqual(fallback?.minorUnits, 36_862)
        XCTAssertEqual(fallback?.currency, .eur)
    }

    func testPreAnchorSettlementDoesNotReplay() {
        let document = forensicDocument(includingDuplicate: true)
        let fallback = CurrentHoldings.derivedLedgerBalance(
            accountID: "bank-main", asOf: today, in: document
        )
        XCTAssertEqual(fallback?.minorUnits, 36_862)
        let duplicate = document.transactions.first { $0.id == "transaction-duplicate-16244" }!
        XCTAssertEqual(duplicate.date, Day(year: 2026, month: 8, day: 22))
        XCTAssertLessThanOrEqual(duplicate.date, anchorDay)
    }

    func testOrderIndependenceOfInsertion() {
        let amounts: [(String, Int64, Day)] = [
            ("a", -399, Day(year: 2026, month: 8, day: 30)),
            ("b", -799, Day(year: 2026, month: 8, day: 28)),
            ("c", -349, Day(year: 2026, month: 8, day: 27))
        ]
        let permutations = [
            amounts,
            [amounts[2], amounts[0], amounts[1]],
            [amounts[1], amounts[2], amounts[0]],
            amounts.reversed()
        ]
        let results: [Int64] = permutations.map { order in
            var document = baseDocument()
            document.transactions = order.map { id, amount, day in
                expense(id: "tx-\(id)", account: "bank-main", amount: amount, date: day)
            }
            return CurrentHoldings.derivedLedgerBalance(
                accountID: "bank-main", asOf: today, in: document
            )!.minorUnits
        }
        XCTAssertTrue(results.allSatisfy { $0 == 36_862 })
        XCTAssertEqual(Set(results).count, 1)
    }

    func testDeleteAndReverseRecomputeWithoutMutatingAnchor() {
        var document = forensicDocument(includingDuplicate: false)
        let originalAnchor = document.balances[0]
        document.transactions.removeAll { $0.id == "tx-799" }
        XCTAssertEqual(
            CurrentHoldings.derivedLedgerBalance(accountID: "bank-main", asOf: today, in: document)?.minorUnits,
            37_661
        )
        XCTAssertEqual(document.balances[0], originalAnchor)

        document = forensicDocument(includingDuplicate: false)
        document.transactions = document.transactions.map { transaction in
            guard transaction.id == "tx-799" else { return transaction }
            return reversing(transaction)
        }
        XCTAssertEqual(
            CurrentHoldings.derivedLedgerBalance(accountID: "bank-main", asOf: today, in: document)?.minorUnits,
            37_661
        )
        XCTAssertEqual(document.balances[0], originalAnchor)
    }

    func testProviderOverridesReviewIndependentOfLedger() {
        var document = forensicDocument(includingDuplicate: true)
        document.providerBalanceSnapshots = [
            ProviderBalanceSnapshot(
                id: "bnp-clbd", bindingID: "binding-bnp", provider: .bnp,
                balanceType: "CLBD", amount: Money(minorUnits: 36_862, currency: .eur),
                referenceDate: today, observedAt: observedAt
            ),
            ProviderBalanceSnapshot(
                id: "bnp-xpcd", bindingID: "binding-bnp", provider: .bnp,
                balanceType: "XPCD", amount: Money(minorUnits: 40_000, currency: .eur),
                referenceDate: today, observedAt: observedAt
            )
        ]
        let value = CurrentHoldings.effective(accountID: "bank-main", asOf: today, in: document)
        XCTAssertEqual(value.amount?.minorUnits, 36_862)
        XCTAssertEqual(
            value.source,
            .provider(provider: .bnp, balanceType: "CLBD", snapshotID: "bnp-clbd")
        )
        XCTAssertEqual(value.ledgerFallback?.minorUnits, 36_862)
        XCTAssertEqual(value.driftFromLedger?.minorUnits, 0)
        XCTAssertEqual(document.balances[0].balance.minorUnits, 38_409)
    }

    func testProviderUnavailableFallsBackToLedger() {
        let document = forensicDocument(includingDuplicate: false)
        let value = CurrentHoldings.effective(accountID: "bank-main", asOf: today, in: document)
        XCTAssertEqual(value.source, .ledgerFallback)
        XCTAssertEqual(value.amount?.minorUnits, 36_862)
    }

    func testProviderTypeSelectionIsPinnedPerProvider() {
        XCTAssertEqual(CurrentHoldings.preferredBalanceType(for: .bnp), "CLBD")
        XCTAssertEqual(CurrentHoldings.preferredBalanceType(for: .paypal), "XPCD")
        XCTAssertEqual(CurrentHoldings.preferredBalanceType(for: .revolut), "ITAV")
        XCTAssertNil(CurrentHoldings.preferredBalanceType(for: ExternalProvider(rawValue: "unknown")))
    }

    func testPaypalAndRevolutUseTheirOnlyCanonicalType() {
        var document = forensicDocument(includingDuplicate: false)
        document.providerBalanceSnapshots = [
            ProviderBalanceSnapshot(
                id: "rev-itav", bindingID: "binding-revolut", provider: .revolut,
                balanceType: "ITAV", amount: Money(minorUnits: 7_885, currency: .eur),
                referenceDate: today, observedAt: observedAt
            ),
            ProviderBalanceSnapshot(
                id: "pp-xpcd", bindingID: "binding-paypal", provider: .paypal,
                balanceType: "XPCD", amount: Money(minorUnits: 0, currency: .eur),
                referenceDate: today, observedAt: observedAt
            )
        ]
        XCTAssertEqual(
            CurrentHoldings.effective(accountID: "revolut-eur", asOf: today, in: document).amount?.minorUnits,
            7_885
        )
        XCTAssertEqual(
            CurrentHoldings.effective(accountID: "paypal-eur", asOf: today, in: document).amount?.minorUnits,
            0
        )
        XCTAssertEqual(
            CurrentHoldings.euroFinancialAccountLiquidity(in: document, asOf: today).minorUnits,
            44_747
        )
    }

    func testUnlikeBalanceTypesAreNotGuessed() {
        var document = baseDocument()
        document.externalAccountBindings = [
            ExternalAccountBinding(
                id: "binding-bnp", provider: ExternalProvider(rawValue: "otherbank"),
                remoteOpaqueAccountID: "acct", localAccountID: "bank-main",
                syncStartBoundary: anchorDay, createdAt: observedAt
            )
        ]
        document.providerBalanceSnapshots = [
            ProviderBalanceSnapshot(
                id: "a", bindingID: "binding-bnp", provider: ExternalProvider(rawValue: "otherbank"),
                balanceType: "FOO", amount: Money(minorUnits: 1, currency: .eur),
                observedAt: observedAt
            ),
            ProviderBalanceSnapshot(
                id: "b", bindingID: "binding-bnp", provider: ExternalProvider(rawValue: "otherbank"),
                balanceType: "BAR", amount: Money(minorUnits: 9_999, currency: .eur),
                observedAt: observedAt.addingTimeInterval(10)
            )
        ]
        XCTAssertNil(CurrentHoldings.canonicalProviderSnapshot(for: "bank-main", in: document))
        XCTAssertEqual(
            CurrentHoldings.effective(accountID: "bank-main", asOf: today, in: document).source,
            .ledgerFallback
        )
    }

    func testNoFXGuessing() {
        var document = baseDocument()
        document.providerBalanceSnapshots = [
            ProviderBalanceSnapshot(
                id: "mad", bindingID: "binding-bnp", provider: .bnp,
                balanceType: "CLBD", amount: Money(minorUnits: 100_000, currency: .mad),
                observedAt: observedAt
            )
        ]
        XCTAssertNil(CurrentHoldings.canonicalProviderSnapshot(for: "bank-main", in: document))
        let cash = CurrentHoldings.effective(accountID: "cash-mad", asOf: today, in: document)
        XCTAssertEqual(cash.amount?.currency, .mad)
        XCTAssertEqual(
            CurrentHoldings.euroFinancialAccountLiquidity(in: document, asOf: today).currency,
            .eur
        )
    }

    func testManualCashWithoutProviderUsesLedgerFallback() {
        var document = baseDocument()
        document.transactions = [
            expense(
                id: "cash-spend",
                account: "cash-eur",
                amount: -500,
                date: Day(year: 2026, month: 8, day: 25)
            )
        ]
        let value = CurrentHoldings.effective(accountID: "cash-eur", asOf: today, in: document)
        XCTAssertEqual(value.source, .ledgerFallback)
        XCTAssertEqual(value.amount?.minorUnits, 1_000)
        XCTAssertEqual(document.balances.first { $0.accountID == "cash-eur" }?.balance.minorUnits, 1_500)
    }

    func testSameDayAsAnchorIsNotReplayed() {
        var document = baseDocument()
        document.transactions = [
            expense(id: "same-day", account: "bank-main", amount: -100, date: anchorDay)
        ]
        XCTAssertEqual(
            CurrentHoldings.derivedLedgerBalance(accountID: "bank-main", asOf: today, in: document)?.minorUnits,
            38_409
        )
    }

    func testLegacyMutatedCacheDoesNotDoubleReplay() {
        var document = forensicDocument(includingDuplicate: false)
        document.balances = [
            AccountBalance(
                accountID: "bank-main",
                balance: Money(minorUnits: 20_618, currency: .eur),
                asOf: today,
                status: .carriedForward
            )
        ]
        XCTAssertEqual(
            CurrentHoldings.derivedLedgerBalance(accountID: "bank-main", asOf: today, in: document)?.minorUnits,
            20_618
        )
        XCTAssertEqual(
            CurrentHoldings.overlayBalances(in: document, asOf: today)[0].balance.minorUnits,
            20_618
        )
    }

    func testOverlayDoesNotMutateStoredAnchors() {
        var document = forensicDocument(includingDuplicate: false)
        document.providerBalanceSnapshots = [
            ProviderBalanceSnapshot(
                id: "bnp-clbd", bindingID: "binding-bnp", provider: .bnp,
                balanceType: "CLBD", amount: Money(minorUnits: 36_862, currency: .eur),
                referenceDate: today, observedAt: observedAt
            )
        ]
        let overlay = CurrentHoldings.overlayBalances(in: document, asOf: today)
        XCTAssertEqual(overlay.first { $0.accountID == "bank-main" }?.balance.minorUnits, 36_862)
        XCTAssertEqual(document.balances.first { $0.accountID == "bank-main" }?.balance.minorUnits, 38_409)
        XCTAssertEqual(document.balances.first { $0.accountID == "bank-main" }?.asOf, anchorDay)
    }

    func testInactiveBindingIsIgnored() {
        var document = forensicDocument(includingDuplicate: false)
        document.externalAccountBindings = document.externalAccountBindings.map { binding in
            guard binding.id == "binding-bnp" else { return binding }
            return ExternalAccountBinding(
                id: binding.id, provider: binding.provider,
                remoteOpaqueAccountID: binding.remoteOpaqueAccountID,
                localAccountID: binding.localAccountID,
                syncStartBoundary: binding.syncStartBoundary,
                isActive: false, createdAt: binding.createdAt
            )
        }
        document.providerBalanceSnapshots = [
            ProviderBalanceSnapshot(
                id: "bnp-clbd", bindingID: "binding-bnp", provider: .bnp,
                balanceType: "CLBD", amount: Money(minorUnits: 36_862, currency: .eur),
                observedAt: observedAt
            )
        ]
        XCTAssertEqual(
            CurrentHoldings.effective(accountID: "bank-main", asOf: today, in: document).source,
            .ledgerFallback
        )
    }

    func testEvidenceLinkCardinalityStillForbidsOneObservationToManyTransactions() throws {
        var document = forensicDocument(includingDuplicate: false)
        let first = document.transactions.first { $0.id == "tx-phone-a" }!
        let second = document.transactions.first { $0.id == "tx-phone-b" }!
        document.externalObservations.append(collectionObservation())
        document.observationResolutions.append(
            ExternalObservationResolution(observationID: "obs-16244", state: .linkedToTransaction)
        )
        document.externalEvidenceLinks = [
            ExternalEvidenceLink(
                id: "link-a", observationID: "obs-16244",
                transactionID: first.id, role: .supportingEvidence
            ),
            ExternalEvidenceLink(
                id: "link-b", observationID: "obs-16244",
                transactionID: second.id, role: .supportingEvidence
            )
        ]
        XCTAssertThrowsError(try ExternalEvidenceReview.validate(document)) { error in
            XCTAssertEqual(
                error as? ExternalEvidenceError,
                .observationLinkedToMultipleTransactions("obs-16244")
            )
        }
    }

    func testAccountMovementLinkRequiresExactAmount() throws {
        var document = forensicDocument(includingDuplicate: false)
        let first = document.transactions.first { $0.id == "tx-phone-a" }!
        document.externalObservations.append(collectionObservation())
        document.observationResolutions.append(
            ExternalObservationResolution(observationID: "obs-16244", state: .linkedToTransaction)
        )
        document.externalEvidenceLinks = [
            ExternalEvidenceLink(
                id: "link-a", observationID: "obs-16244",
                transactionID: first.id, role: .accountMovement
            )
        ]
        XCTAssertThrowsError(try ExternalEvidenceReview.validate(document)) { error in
            XCTAssertEqual(
                error as? ExternalEvidenceError,
                .accountMovementDoesNotMatchLeg(observationID: "obs-16244", transactionID: first.id)
            )
        }
    }

    func testForecastComposerStartsFromEffectiveHoldings() throws {
        var document = forensicDocument(includingDuplicate: false)
        document.providerBalanceSnapshots = [
            ProviderBalanceSnapshot(
                id: "bnp-clbd", bindingID: "binding-bnp", provider: .bnp,
                balanceType: "CLBD", amount: Money(minorUnits: 36_862, currency: .eur),
                observedAt: observedAt
            )
        ]
        let request = ForecastComposer.makeRequest(
            from: document, startDate: today, endDate: try XCTUnwrap(today.advanced(by: 30))
        )
        XCTAssertEqual(request.startingBalances["bank-main"]?.minorUnits, 36_862)
        XCTAssertEqual(document.balances.first { $0.accountID == "bank-main" }?.balance.minorUnits, 38_409)
    }

    func testOverviewLiquidityMatchesOverlay() throws {
        var document = forensicDocument(includingDuplicate: false)
        document.providerBalanceSnapshots = [
            ProviderBalanceSnapshot(
                id: "bnp-clbd", bindingID: "binding-bnp", provider: .bnp,
                balanceType: "CLBD", amount: Money(minorUnits: 36_862, currency: .eur),
                observedAt: observedAt
            ),
            ProviderBalanceSnapshot(
                id: "rev-itav", bindingID: "binding-revolut", provider: .revolut,
                balanceType: "ITAV", amount: Money(minorUnits: 7_885, currency: .eur),
                observedAt: observedAt
            ),
            ProviderBalanceSnapshot(
                id: "pp-xpcd", bindingID: "binding-paypal", provider: .paypal,
                balanceType: "XPCD", amount: Money(minorUnits: 0, currency: .eur),
                observedAt: observedAt
            )
        ]
        let request = ForecastComposer.makeRequest(
            from: document, startDate: today, endDate: try XCTUnwrap(today.advanced(by: 30))
        )
        let result = try! ForecastEngine.run(request)
        let overview = FinanceOverview.snapshot(
            document: document, result: result, today: today, horizonDays: 30
        )
        XCTAssertEqual(overview.financialAccountLiquidity.minorUnits, 44_747)
        XCTAssertEqual(
            CurrentHoldings.euroFinancialAccountLiquidity(in: document, asOf: today).minorUnits,
            44_747
        )
    }

    // MARK: - Fixtures

    private func baseDocument() -> FinanceDocument {
        FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "TEST",
            accounts: [
                Account(id: "bank-main", name: "BNP", currency: .eur, kind: .bank,
                        supportedRails: PaymentRail.euroBankRails, drawOrder: 0),
                Account(id: "revolut-eur", name: "Revolut", currency: .eur, kind: .wallet,
                        supportedRails: PaymentRail.euroWalletRails, drawOrder: 1),
                Account(id: "paypal-eur", name: "PayPal", currency: .eur, kind: .wallet,
                        supportedRails: PaymentRail.euroWalletRails, drawOrder: 2),
                Account(id: "cash-eur", name: "Cash EUR", currency: .eur, kind: .cash,
                        supportedRails: PaymentRail.cashOnlyRails, drawOrder: 3),
                Account(id: "cash-mad", name: "Cash MAD", currency: .mad, kind: .cash,
                        supportedRails: PaymentRail.cashOnlyRails, drawOrder: 4)
            ],
            balances: [
                AccountBalance(
                    accountID: "bank-main",
                    balance: Money(minorUnits: 38_409, currency: .eur),
                    asOf: anchorDay,
                    status: .carriedForward
                ),
                AccountBalance(
                    accountID: "revolut-eur",
                    balance: Money(minorUnits: 7_885, currency: .eur),
                    asOf: anchorDay,
                    status: .carriedForward
                ),
                AccountBalance(
                    accountID: "paypal-eur",
                    balance: Money(minorUnits: 0, currency: .eur),
                    asOf: anchorDay,
                    status: .carriedForward
                ),
                AccountBalance(
                    accountID: "cash-eur",
                    balance: Money(minorUnits: 1_500, currency: .eur),
                    asOf: anchorDay,
                    status: .observed
                ),
                AccountBalance(
                    accountID: "cash-mad",
                    balance: Money(minorUnits: 20_000, currency: .mad),
                    asOf: anchorDay,
                    status: .observed
                )
            ],
            externalAccountBindings: [
                binding("binding-bnp", .bnp, "bank-main"),
                binding("binding-revolut", .revolut, "revolut-eur"),
                binding("binding-paypal", .paypal, "paypal-eur")
            ]
        )
    }

    private func forensicDocument(includingDuplicate: Bool) -> FinanceDocument {
        var document = baseDocument()
        document.transactions = [
            expense(id: "tx-399", account: "bank-main", amount: -399,
                    date: Day(year: 2026, month: 8, day: 30)),
            expense(id: "tx-799", account: "bank-main", amount: -799,
                    date: Day(year: 2026, month: 8, day: 28)),
            expense(id: "tx-349", account: "bank-main", amount: -349,
                    date: Day(year: 2026, month: 8, day: 27)),
            expense(id: "tx-phone-a", account: "paypal-eur", amount: -8_122,
                    date: Day(year: 2026, month: 8, day: 20)),
            expense(id: "tx-phone-b", account: "paypal-eur", amount: -8_122,
                    date: Day(year: 2026, month: 8, day: 20))
        ]
        if includingDuplicate {
            document.transactions.append(
                expense(
                    id: "transaction-duplicate-16244",
                    account: "bank-main",
                    amount: -16_244,
                    date: Day(year: 2026, month: 8, day: 22)
                )
            )
        }
        return document
    }

    private func binding(_ id: String, _ provider: ExternalProvider, _ local: String) -> ExternalAccountBinding {
        ExternalAccountBinding(
            id: id, provider: provider, remoteOpaqueAccountID: "acct-\(id)",
            localAccountID: local, syncStartBoundary: anchorDay, createdAt: observedAt
        )
    }

    private func expense(id: String, account: String, amount: Int64, date: Day) -> Transaction {
        Transaction(
            id: id,
            date: date,
            kind: .expense,
            legs: [AccountLeg(accountID: account, amount: Money(minorUnits: amount, currency: .eur))],
            factivity: .observed,
            lifecycle: .cleared,
            provenance: Provenance(source: "TEST", evidenceGrade: .userConfirmed)
        )
    }

    private func reversing(_ transaction: Transaction) -> Transaction {
        Transaction(
            id: transaction.id,
            date: transaction.date,
            kind: transaction.kind,
            legs: transaction.legs,
            factivity: transaction.factivity,
            lifecycle: .reversed,
            provenance: transaction.provenance
        )
    }

    private func collectionObservation() -> ExternalObservation {
        ExternalObservation(
            id: "obs-16244",
            bindingID: "binding-bnp",
            provider: .bnp,
            status: .booked,
            creditDebitIndicator: .debit,
            amount: Money(minorUnits: -16_244, currency: .eur),
            bookingDate: Day(year: 2026, month: 8, day: 25),
            eligibleForEconomicActual: true,
            observedAt: observedAt
        )
    }
}
