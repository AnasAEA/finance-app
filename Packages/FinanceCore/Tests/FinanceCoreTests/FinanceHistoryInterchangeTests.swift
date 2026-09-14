import XCTest
@testable import FinanceCore

final class FinanceHistoryInterchangeTests: XCTestCase {
    private let cutoff = Day(isoString: "2026-08-15")!

    private func record(
        id: String = "CT-BNP-00001",
        date: String = "2025-03-04",
        accountID: String = "bnp-main",
        provider: String = "BNP",
        originalCents: Int64 = -1_299,
        originalCurrency: String = "EUR",
        bookedEUR: Int64? = -1_299,
        economicEUR: Int64? = 1_299,
        personalEUR: Int64? = 1_299,
        internalTransfer: Bool = false,
        passThrough: FinanceHistoryPassThrough = .none
    ) -> FinanceHistoricalRecord {
        FinanceHistoricalRecord(
            historicalID: id,
            date: Day(isoString: date)!,
            accountID: accountID,
            provider: provider,
            rail: "CARD",
            merchant: "Café Étude",
            description: "Cafe Etude",
            rawDescription: "CARTE 04/03 CAFE ETUDE",
            originalAmount: FinanceHistoryOriginalAmount(cents: originalCents, currency: originalCurrency),
            bookedAmountEURCents: bookedEUR,
            economicAmountEURCents: economicEUR,
            personalAmountEURCents: personalEUR,
            category: FinanceHistoryCategory(top: "FOOD", sub: "Cafe"),
            economicType: internalTransfer ? "INTERNAL_TRANSFER" : "SPENDING",
            status: "BOOKED_EUR",
            provenance: "DIRECTLY_OBSERVED",
            confidence: "high",
            flags: FinanceHistoryFlags(
                internalTransfer: internalTransfer,
                passThrough: passThrough,
                financingLeg: false
            ),
            economicViewRole: internalTransfer ? "PLUMBING" : "PRIMARY",
            links: FinanceHistoryLinks(groupID: "GROUP-1"),
            evidence: FinanceHistoryEvidence(ruleID: "B01", basis: "Direct statement row")
        )
    }

    private func payload(records: [FinanceHistoricalRecord]? = nil) -> FinanceHistoryPayload {
        let records = records ?? [
            record(),
            record(
                id: "CT-PAYPAL-00001",
                date: "2025-05-11",
                accountID: "paypal-wallet",
                provider: "PAYPAL",
                originalCents: -3_499,
                originalCurrency: "USD",
                bookedEUR: -3_120,
                economicEUR: 3_120,
                personalEUR: 3_120
            ),
        ]
        return FinanceHistoryPayload(
            archiveCutoff: cutoff,
            recordCount: records.count,
            dateRange: FinanceHistoryDateRange(
                start: records.map(\.date).min()!,
                end: records.map(\.date).max()!
            ),
            accounts: [
                FinanceHistoryAccount(id: "paypal-wallet", name: "PayPal", provider: "PAYPAL"),
                FinanceHistoryAccount(id: "bnp-main", name: "BNP", provider: "BNP"),
            ],
            sourceGaps: [
                FinanceHistorySourceGap(
                    startMonth: MonthKey(isoString: "2023-03")!,
                    endMonth: MonthKey(isoString: "2024-09")!,
                    completeness: "NO_TRANSACTION_EVIDENCE",
                    affectedSources: ["BNP", "PAYPAL"],
                    message: "Bank records for part of this period are incomplete."
                ),
            ],
            records: records
        )
    }

    private func document(records: [FinanceHistoricalRecord]? = nil) throws -> FinanceHistoryDocument {
        try FinanceHistoryInterchange.make(
            archiveID: "history-2026-08-15",
            sourceRevision: "0123456789abcdef0123456789abcdef01234567",
            payload: payload(records: records)
        )
    }

    private func rehash(_ document: inout FinanceHistoryDocument) throws {
        document.contentSHA256 = try FinanceHistoryInterchange.contentSHA256(for: document.payload)
    }

    private func validationCodes(from error: Error) -> Set<String> {
        Set((error as? FinanceHistoryValidationError)?.issues.map(\.code) ?? [])
    }

    func testValidDocumentRoundTripsAndPreservesStableIDs() throws {
        let original = try document()
        let encoded = try FinanceHistoryInterchange.encode(original)
        let decoded = try FinanceHistoryInterchange.decodeValidated(encoded)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.payload.records.map(\.historicalID), original.payload.records.map(\.historicalID))
        XCTAssertEqual(decoded.recordsHash, decoded.contentSHA256)
        XCTAssertEqual(decoded.payload.records[1].originalAmount.money?.currency, .usd)
    }

    func testHistoricalAmountsResolveThroughTheFrozenTable() throws {
        // A 1.x archive never wrote an exponent, so the only honest reading is
        // the frozen historical table. `Currency(code:)` consults the evolving
        // registry; routing history through it again would let an unrelated
        // "add currency support" commit silently rescale archives already on
        // disk. The two tables agree today, so this bites the moment they drift.
        for code in ["EUR", "USD", "GBP", "JPY", "KWD", "BHD", "CLP", "XAA", "XTS"] {
            let amount = FinanceHistoryOriginalAmount(cents: 100, currency: code)
            XCTAssertEqual(
                amount.money,
                Money(
                    minorUnits: 100,
                    currency: Currency(
                        code: code,
                        minorUnitDigits: Currency.legacyDefaultDigits(code)
                    )
                ),
                "\(code) must keep its frozen historical scale"
            )
        }
    }

    func testEncodingAndHashAreDeterministicAcrossInputCollectionOrder() throws {
        let first = try document()
        var reorderedPayload = first.payload
        reorderedPayload.records.reverse()
        reorderedPayload.accounts.reverse()
        reorderedPayload.sourceGaps[0].affectedSources.reverse()
        let second = try FinanceHistoryInterchange.make(
            archiveID: first.archiveID,
            sourceRevision: first.sourceRevision,
            payload: reorderedPayload
        )

        XCTAssertEqual(first.contentSHA256, second.contentSHA256)
        XCTAssertEqual(
            try FinanceHistoryInterchange.encode(first),
            try FinanceHistoryInterchange.encode(second)
        )
    }

    func testTamperedPayloadHashIsRejected() throws {
        var value = try document()
        value.payload.records[0].description = "Changed after signing"

        XCTAssertThrowsError(try FinanceHistoryInterchange.validate(value)) { error in
            XCTAssertTrue(self.validationCodes(from: error).contains("content_hash_mismatch"))
        }
    }

    func testWrongSchemaVersionAndKindAreRejected() throws {
        var value = try document()
        // A version this build cannot read. 2.0.0 is readable now, so the
        // sentinel moved forward; the assertion is unchanged.
        value.schemaVersion = "3.0.0"
        value.documentKind = "finance-document"

        XCTAssertThrowsError(try FinanceHistoryInterchange.validate(value)) { error in
            let codes = self.validationCodes(from: error)
            XCTAssertTrue(codes.contains("unsupported_schema_version"))
            XCTAssertTrue(codes.contains("wrong_document_kind"))
        }
    }

    func testDuplicateStableIDsAreRejected() throws {
        let duplicate = record(id: "CT-BNP-00001", date: "2025-04-01")
        var value = try document()
        value.payload.records = [record(), duplicate]
        value.payload.recordCount = 2
        value.payload.dateRange = FinanceHistoryDateRange(
            start: Day(isoString: "2025-03-04")!,
            end: Day(isoString: "2025-04-01")!
        )
        try rehash(&value)

        XCTAssertThrowsError(try FinanceHistoryInterchange.validate(value)) { error in
            XCTAssertTrue(self.validationCodes(from: error).contains("duplicate_historical_id"))
        }
    }

    func testRecordAfterArchiveCutoffIsRejected() throws {
        let future = record(id: "CT-BNP-FUTURE", date: "2026-08-16")
        var value = try document()
        value.payload.records = [future]
        value.payload.recordCount = 1
        value.payload.dateRange = FinanceHistoryDateRange(start: future.date, end: future.date)
        try rehash(&value)

        XCTAssertThrowsError(try FinanceHistoryInterchange.validate(value)) { error in
            let codes = self.validationCodes(from: error)
            XCTAssertTrue(codes.contains("record_after_cutoff"))
            XCTAssertTrue(codes.contains("range_after_cutoff"))
        }
    }

    func testCountAndDateRangeMustMatchRecords() throws {
        var value = try document()
        value.payload.recordCount += 1
        value.payload.dateRange.start = Day(isoString: "2025-01-01")!
        try rehash(&value)

        XCTAssertThrowsError(try FinanceHistoryInterchange.validate(value)) { error in
            let codes = self.validationCodes(from: error)
            XCTAssertTrue(codes.contains("record_count_mismatch"))
            XCTAssertTrue(codes.contains("date_range_mismatch"))
        }
    }

    func testUnknownAccountAndProviderMismatchAreRejected() throws {
        var value = try document()
        value.payload.records[0].accountID = "missing"
        value.payload.records[1].provider = "BNP"
        try rehash(&value)

        XCTAssertThrowsError(try FinanceHistoryInterchange.validate(value)) { error in
            let codes = self.validationCodes(from: error)
            XCTAssertTrue(codes.contains("unknown_account"))
            XCTAssertTrue(codes.contains("provider_mismatch"))
        }
    }

    func testCurrencyAndEURAmountConsistencyAreValidated() throws {
        var value = try document()
        value.payload.records[0].originalAmount.currency = "eur"
        value.payload.records[0].bookedAmountEURCents = -1_000
        try rehash(&value)

        XCTAssertThrowsError(try FinanceHistoryInterchange.validate(value)) { error in
            XCTAssertTrue(self.validationCodes(from: error).contains("invalid_currency"))
        }

        value.payload.records[0].originalAmount.currency = "EUR"
        try rehash(&value)
        XCTAssertThrowsError(try FinanceHistoryInterchange.validate(value)) { error in
            XCTAssertTrue(self.validationCodes(from: error).contains("inconsistent_eur_amount"))
        }
    }

    func testInternalTransferPreservesMovementAmountsWithoutBecomingLiveEconomics() throws {
        let transfer = record(internalTransfer: true)
        let value = try document(records: [transfer])
        let decoded = try FinanceHistoryInterchange.decodeValidated(
            FinanceHistoryInterchange.encode(value)
        )

        XCTAssertTrue(decoded.payload.records[0].flags.internalTransfer)
        XCTAssertEqual(decoded.payload.records[0].economicAmountEURCents, 1_299)
        XCTAssertEqual(decoded.payload.records[0].personalAmountEURCents, 1_299)
    }

    func testGapRangesAndSourcesAreValidated() throws {
        var value = try document()
        value.payload.sourceGaps[0].startMonth = MonthKey(isoString: "2026-10")!
        value.payload.sourceGaps[0].endMonth = MonthKey(isoString: "2026-09")!
        value.payload.sourceGaps[0].affectedSources = []
        try rehash(&value)

        XCTAssertThrowsError(try FinanceHistoryInterchange.validate(value)) { error in
            let codes = self.validationCodes(from: error)
            XCTAssertTrue(codes.contains("invalid_gap_range"))
            XCTAssertTrue(codes.contains("gap_after_cutoff"))
            XCTAssertTrue(codes.contains("empty_gap_sources"))
        }
    }

    func testSensitiveAccountIdentifiersAreRejected() throws {
        var value = try document()
        value.payload.accounts[0].name = "PayPal FR7612345678901234567890123"
        try rehash(&value)

        XCTAssertThrowsError(try FinanceHistoryInterchange.validate(value)) { error in
            XCTAssertTrue(self.validationCodes(from: error).contains("unsafe_account_name"))
        }
    }

    func testUnknownJSONFieldIsRejectedBeforeDecoding() throws {
        let data = try FinanceHistoryInterchange.encode(try document())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["unexpected"] = true
        let invalid = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try FinanceHistoryInterchange.decodeValidated(invalid)) { error in
            XCTAssertEqual((error as? FinanceHistorySchemaError)?.path, "$.unexpected")
        }
    }

    func testMalformedDayIsRejectedBySchemaDecoding() throws {
        let data = try FinanceHistoryInterchange.encode(try document())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var payload = try XCTUnwrap(object["payload"] as? [String: Any])
        var records = try XCTUnwrap(payload["records"] as? [[String: Any]])
        records[0]["date"] = "2025-02-30"
        payload["records"] = records
        object["payload"] = payload
        let invalid = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try FinanceHistoryInterchange.decodeValidated(invalid)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    // MARK: - Golden corpus and the 2.0.0 monetary wire

    private func fixtureData(_ name: String) throws -> Data {
        let directory = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return try Data(contentsOf: directory.appendingPathComponent(name))
    }

    /// `code/exponent minorUnits` for every record, in canonical order.
    private func monetaryIdentities(_ document: FinanceHistoryDocument) -> [String] {
        document.payload.records.map { record in
            let amount = record.originalAmount
            return "\(record.historicalID) \(amount.currency)/\(amount.currencyExponent) \(amount.cents)"
        }
    }

    func testFrozen100ArchiveDecodesUnchanged() throws {
        let decoded = try FinanceHistoryInterchange.decodeValidated(
            fixtureData("finance-history-1.0.0.json")
        )

        XCTAssertEqual(decoded.schemaVersion, "1.0.0")
        XCTAssertEqual(decoded.payload.recordCount, 5)
        // JPY resolves at zero digits and the unknown code at two, from the
        // frozen table — a 1.x archive states neither.
        XCTAssertEqual(monetaryIdentities(decoded), [
            "SYN-0001 EUR/2 -12345",
            "SYN-0002 USD/2 -5000",
            "SYN-0003 JPY/0 -1000",
            "SYN-0004 EUR/2 250000",
            "SYN-0005 XAA/2 100",
        ])
        XCTAssertEqual(decoded.payload.records.compactMap(\.economicSource), [])
    }

    func testFrozen110ArchiveDecodesUnchanged() throws {
        let decoded = try FinanceHistoryInterchange.decodeValidated(
            fixtureData("finance-history-1.1.0.json")
        )

        XCTAssertEqual(decoded.schemaVersion, "1.1.0")
        XCTAssertEqual(monetaryIdentities(decoded), [
            "SYN-0001 EUR/2 -12345",
            "SYN-0002 USD/2 -5000",
            "SYN-0003 JPY/0 -1000",
            "SYN-0004 EUR/2 250000",
            "SYN-0005 XAA/2 100",
        ])
        XCTAssertEqual(
            decoded.payload.records.map(\.economicSource),
            [nil, nil, "EARNED", "PARENTAL_SUPPORT", nil]
        )
    }

    func testFrozenArchivesReEncodeByteIdentically() throws {
        // Ordinary re-encode is version-sticky: a document that arrived as 1.0.0
        // leaves as 1.0.0, in exactly the bytes it arrived in.
        for name in ["finance-history-1.0.0.json", "finance-history-1.1.0.json", "finance-history-2.0.0.json"] {
            let original = try fixtureData(name)
            let decoded = try FinanceHistoryInterchange.decodeValidated(original)
            XCTAssertEqual(try FinanceHistoryInterchange.encode(decoded), original, name)
        }
    }

    func testRegistryDriftDoesNotChangeHistoricalMeaning() throws {
        let decoded = try FinanceHistoryInterchange.decodeValidated(
            fixtureData("finance-history-1.0.0.json")
        )
        // Every 1.x identity must equal the frozen reading of its code. The
        // evolving `Currency(code:)` registry agrees today; if a later commit
        // teaches it a new currency, this is what refuses to follow.
        for record in decoded.payload.records {
            let amount = record.originalAmount
            XCTAssertEqual(
                amount.money?.currency,
                Currency(
                    code: amount.currency,
                    minorUnitDigits: Currency.legacyDefaultDigits(amount.currency)
                ),
                "\(record.historicalID) must keep its frozen historical scale"
            )
        }
    }

    func testExplicitExponentRoundTripsExactly() throws {
        let decoded = try FinanceHistoryInterchange.decodeValidated(
            fixtureData("finance-history-2.0.0.json")
        )

        XCTAssertEqual(decoded.schemaVersion, "2.0.0")
        XCTAssertEqual(monetaryIdentities(decoded), [
            "SYN-0001 EUR/2 -12345",
            "SYN-0002 XAA/5 100",
            "SYN-0003 EUR/0 100",
            "SYN-0004 JPY/0 -1000",
            "SYN-0005 KWD/3 9007199254740993",
        ])

        // Identities 1.x cannot express at all now survive a full round trip.
        let identities: [Currency] = [
            Currency(code: "EUR", minorUnitDigits: 0),
            Currency(code: "EUR", minorUnitDigits: 3),
            Currency(code: "JPY", minorUnitDigits: 2),
            Currency(code: "XAA", minorUnitDigits: 5),
            Currency(code: "KWD", minorUnitDigits: 6),
        ]
        for currency in identities {
            let money = Money(minorUnits: 100, currency: currency)
            let amount = FinanceHistoryOriginalAmount(money)
            var value = decoded
            value.payload.records[1].originalAmount = amount
            value.payload.records[1].economicAmountEURCents = -1
            value.payload.records[1].personalAmountEURCents = -1
            try rehash(&value)
            let back = try FinanceHistoryInterchange.decodeValidated(
                FinanceHistoryInterchange.encode(value)
            )
            XCTAssertEqual(back.payload.records[1].originalAmount.money, money, "\(currency)/\(currency.minorUnitDigits)")
        }
    }

    func testOldReaderRejectsV2Bytes() throws {
        // A build that predates 2.0.0 refuses it by version.
        var forgedFuture = try JSONSerialization.jsonObject(
            with: fixtureData("finance-history-2.0.0.json")
        ) as! [String: Any]
        forgedFuture["schemaVersion"] = "3.0.0"
        XCTAssertThrowsError(
            try FinanceHistoryInterchange.decodeValidated(
                JSONSerialization.data(withJSONObject: forgedFuture)
            )
        ) { error in
            XCTAssertTrue(self.validationCodes(from: error).contains("unsupported_schema_version"))
        }

        // And if the version is forged down to one an old build does read, the
        // historical grammar rejects the 2.0.0 monetary body structurally
        // rather than reinterpreting it. Never a silent change of meaning.
        var forgedLegacy = try JSONSerialization.jsonObject(
            with: fixtureData("finance-history-2.0.0.json")
        ) as! [String: Any]
        forgedLegacy["schemaVersion"] = "1.1.0"
        XCTAssertThrowsError(
            try FinanceHistoryInterchange.decodeValidated(
                JSONSerialization.data(withJSONObject: forgedLegacy)
            )
        ) { error in
            XCTAssertEqual(
                (error as? FinanceHistorySchemaError)?.path,
                "$.payload.records[0].originalAmount.cents"
            )
        }
    }

    func testVersionAndBodyMustAgree() throws {
        // 1.x envelope carrying a 2.0.0 body.
        var v2UnderLegacy = try JSONSerialization.jsonObject(
            with: fixtureData("finance-history-2.0.0.json")
        ) as! [String: Any]
        v2UnderLegacy["schemaVersion"] = "1.0.0"
        XCTAssertThrowsError(
            try FinanceHistoryInterchange.decodeValidated(
                JSONSerialization.data(withJSONObject: v2UnderLegacy)
            )
        ) { XCTAssertTrue($0 is FinanceHistorySchemaError) }

        // 2.0.0 envelope carrying a 1.x body.
        var legacyUnderV2 = try JSONSerialization.jsonObject(
            with: fixtureData("finance-history-1.1.0.json")
        ) as! [String: Any]
        legacyUnderV2["schemaVersion"] = "2.0.0"
        XCTAssertThrowsError(
            try FinanceHistoryInterchange.decodeValidated(
                JSONSerialization.data(withJSONObject: legacyUnderV2)
            )
        ) { error in
            XCTAssertEqual(
                (error as? FinanceHistorySchemaError)?.path,
                "$.payload.records[0].originalAmount.minorUnits"
            )
        }

        // The validated writer also refuses a 1.x document whose identity needs
        // 2.0.0 — never rescaled. Whether *any* public encoding route can emit
        // a mismatched pair is a separate question, covered by the
        // public-surface tests below.
        var noncanonicalUnderLegacy = try FinanceHistoryInterchange.decodeValidated(
            fixtureData("finance-history-1.1.0.json")
        )
        noncanonicalUnderLegacy.payload.records[0].originalAmount =
            FinanceHistoryOriginalAmount(cents: 100, currency: "EUR", currencyExponent: 0)
        noncanonicalUnderLegacy.payload.records[0].bookedAmountEURCents = nil
        try? rehash(&noncanonicalUnderLegacy)
        XCTAssertThrowsError(try FinanceHistoryInterchange.encode(noncanonicalUnderLegacy)) { error in
            XCTAssertTrue(
                self.validationCodes(from: error).contains("not_representable_in_legacy_version")
            )
        }
    }

    func testMissingExponentIsRejectedNotDefaulted() throws {
        var object = try JSONSerialization.jsonObject(
            with: fixtureData("finance-history-2.0.0.json")
        ) as! [String: Any]
        var payload = object["payload"] as! [String: Any]
        var records = payload["records"] as! [[String: Any]]
        var amount = records[0]["originalAmount"] as! [String: Any]
        var currency = amount["currency"] as! [String: Any]
        currency.removeValue(forKey: "exponent")
        amount["currency"] = currency
        records[0]["originalAmount"] = amount
        payload["records"] = records
        object["payload"] = payload

        XCTAssertThrowsError(
            try FinanceHistoryInterchange.decodeValidated(
                JSONSerialization.data(withJSONObject: object)
            )
        ) { error in
            XCTAssertEqual(
                (error as? FinanceHistorySchemaError)?.path,
                "$.payload.records[0].originalAmount.currency.exponent"
            )
        }

        // Out of range is a validation issue, never a coerced value or a trap.
        var outOfRange = try FinanceHistoryInterchange.decodeValidated(
            fixtureData("finance-history-2.0.0.json")
        )
        outOfRange.payload.records[0].originalAmount.currencyExponent = 7
        XCTAssertThrowsError(try FinanceHistoryInterchange.validate(outOfRange)) { error in
            XCTAssertTrue(self.validationCodes(from: error).contains("invalid_currency_exponent"))
        }
    }

    func testV2PreservesEconomicSource() throws {
        let decoded = try FinanceHistoryInterchange.decodeValidated(
            fixtureData("finance-history-2.0.0.json")
        )
        XCTAssertEqual(
            decoded.payload.records.map(\.economicSource),
            [nil, nil, "PARENTAL_SUPPORT", "EARNED", nil]
        )
        // A monetary version must carry every earlier feature forward.
        let reencoded = try FinanceHistoryInterchange.decodeValidated(
            FinanceHistoryInterchange.encode(decoded)
        )
        XCTAssertEqual(reencoded.payload.records.map(\.economicSource),
                       decoded.payload.records.map(\.economicSource))
    }

    func test100ArchiveWithEconomicSourceRemainsHistoricallyAccepted() throws {
        // The historical grammar has always accepted a 1.0.0 document carrying
        // the 1.1.0 `economicSource` field. That is untidy, but it is what
        // already-written archives rely on, and a monetary repair is not the
        // place to retroactively start rejecting them.
        var object = try JSONSerialization.jsonObject(
            with: fixtureData("finance-history-1.1.0.json")
        ) as! [String: Any]
        object["schemaVersion"] = "1.0.0"
        let decoded = try FinanceHistoryInterchange.decodeValidated(
            JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.schemaVersion, "1.0.0")
        XCTAssertEqual(decoded.payload.records[2].economicSource, "EARNED")
        XCTAssertEqual(decoded.payload.records[3].economicSource, "PARENTAL_SUPPORT")
    }

    func testInt64MinStillRejectedInAllFourFields() throws {
        // History persists an indexed magnitude column, and `abs(.min)` traps.
        // FinanceDocument 2.0.0 treats Int64.min as ordinary data; history is
        // deliberately stricter and this version does not widen that.
        for name in ["finance-history-1.1.0.json", "finance-history-2.0.0.json"] {
            let base = try FinanceHistoryInterchange.decodeValidated(fixtureData(name))
            let mutations: [(String, (inout FinanceHistoricalRecord) -> Void)] = [
                ("originalAmount", { $0.originalAmount.cents = .min }),
                ("bookedAmountEURCents", { $0.bookedAmountEURCents = .min }),
                ("economicAmountEURCents", { $0.economicAmountEURCents = .min }),
                ("personalAmountEURCents", { $0.personalAmountEURCents = .min }),
            ]
            for (field, mutate) in mutations {
                var value = base
                mutate(&value.payload.records[0])
                try? rehash(&value)
                XCTAssertThrowsError(try FinanceHistoryInterchange.validate(value), "\(name) \(field)") { error in
                    XCTAssertTrue(
                        self.validationCodes(from: error).contains("invalid_amount"),
                        "\(name) \(field) must stay rejected"
                    )
                }
            }
        }
    }

    func testAllFourAmountFieldsCovered() throws {
        // Guards against a future field escaping range validation entirely.
        let decoded = try FinanceHistoryInterchange.decodeValidated(
            fixtureData("finance-history-2.0.0.json")
        )
        let record = decoded.payload.records[2]
        XCTAssertEqual(record.originalAmount.cents, 100)
        XCTAssertEqual(record.bookedAmountEURCents, 10_000)
        XCTAssertEqual(record.economicAmountEURCents, 10_000)
        XCTAssertEqual(record.personalAmountEURCents, 10_000)
        // The three EUR fields are fixed scale 2 and carry no currency of their
        // own; only `originalAmount` has an independent identity.
        XCTAssertEqual(record.originalAmount.currencyExponent, 0)
    }

    func testEURConsistencyScalesExactlyUnderV2() throws {
        var base = try FinanceHistoryInterchange.decodeValidated(
            fixtureData("finance-history-2.0.0.json")
        )
        // EUR/0 100 minor units is 100 euro, which is 10_000 EUR cents exactly.
        base.payload.records[2].bookedAmountEURCents = 100
        try rehash(&base)
        XCTAssertThrowsError(try FinanceHistoryInterchange.validate(base)) { error in
            XCTAssertTrue(self.validationCodes(from: error).contains("inconsistent_eur_amount"))
        }

        // EUR/3: 100 minor units is 0.100 euro, exactly 10 EUR cents.
        var scaled = try FinanceHistoryInterchange.decodeValidated(
            fixtureData("finance-history-2.0.0.json")
        )
        scaled.payload.records[2].originalAmount =
            FinanceHistoryOriginalAmount(cents: 100, currency: "EUR", currencyExponent: 3)
        scaled.payload.records[2].bookedAmountEURCents = 10
        try rehash(&scaled)
        XCTAssertNoThrow(try FinanceHistoryInterchange.validate(scaled))

        // EUR/3: 1 minor unit is 0.001 euro, which has no exact EUR/2 value.
        // Rejected rather than rounded into agreement.
        var subCent = scaled
        subCent.payload.records[2].originalAmount =
            FinanceHistoryOriginalAmount(cents: 1, currency: "EUR", currencyExponent: 3)
        subCent.payload.records[2].bookedAmountEURCents = 0
        try rehash(&subCent)
        XCTAssertThrowsError(try FinanceHistoryInterchange.validate(subCent)) { error in
            XCTAssertTrue(self.validationCodes(from: error).contains("inconsistent_eur_amount"))
        }
    }

    func testLargeMinorUnitsSurviveExactly() throws {
        let decoded = try FinanceHistoryInterchange.decodeValidated(
            fixtureData("finance-history-2.0.0.json")
        )
        // 2^53 + 1 is not exactly representable as a Double.
        XCTAssertEqual(decoded.payload.records[4].originalAmount.cents, 9_007_199_254_740_993)

        var extreme = decoded
        extreme.payload.records[4].originalAmount =
            FinanceHistoryOriginalAmount(cents: .max, currency: "KWD", currencyExponent: 3)
        extreme.payload.records[4].economicAmountEURCents = .max
        try rehash(&extreme)
        let back = try FinanceHistoryInterchange.decodeValidated(
            FinanceHistoryInterchange.encode(extreme)
        )
        XCTAssertEqual(back.payload.records[4].originalAmount.cents, .max)
        XCTAssertEqual(back.payload.records[4].economicAmountEURCents, .max)
    }

    func testMalformedCurrencyThrowsNeverTraps() throws {
        let base = try FinanceHistoryInterchange.decodeValidated(
            fixtureData("finance-history-2.0.0.json")
        )
        for code in ["eur", "EURO", "EU", "E1R", ""] {
            var value = base
            value.payload.records[0].originalAmount =
                FinanceHistoryOriginalAmount(cents: 1, currency: code, currencyExponent: 2)
            value.payload.records[0].bookedAmountEURCents = nil
            try? rehash(&value)
            XCTAssertThrowsError(try FinanceHistoryInterchange.validate(value), code) { error in
                XCTAssertTrue(self.validationCodes(from: error).contains("invalid_currency"), code)
            }
            // The resolver reports absence instead of tripping a precondition.
            XCTAssertNil(value.payload.records[0].originalAmount.money, code)
        }
    }

    func testPythonProducedFixtureImports() throws {
        // Bytes from the real budget-repository exporter, both targets.
        let modern = try FinanceHistoryInterchange.decodeValidated(
            fixtureData("finance-history-python-2.0.0.json")
        )
        XCTAssertEqual(modern.schemaVersion, "2.0.0")
        XCTAssertEqual(modern.payload.recordCount, 2)
        XCTAssertEqual(
            modern.payload.records.map { $0.originalAmount.money },
            Array(repeating: Money(minorUnits: -1_349, currency: .eur), count: 2)
        )
        // Accepting these bytes at all proves Swift's canonical payload encoder
        // reproduces the Python producer's compact canonical bytes exactly,
        // nested currency object included — otherwise the digest would not
        // match. Whole-document formatting is not part of that contract.
        XCTAssertEqual(
            try FinanceHistoryInterchange.contentSHA256(
                for: modern.payload, schemaVersion: modern.schemaVersion
            ),
            modern.contentSHA256
        )
        XCTAssertEqual(
            try FinanceHistoryInterchange.decodeValidated(
                FinanceHistoryInterchange.encode(modern)
            ),
            modern
        )

        let legacy = try FinanceHistoryInterchange.decodeValidated(
            fixtureData("finance-history-python-1.1.0.json")
        )
        XCTAssertEqual(legacy.schemaVersion, "1.1.0")
        // The producer's two targets state the same money.
        XCTAssertEqual(legacy.payload.records.map { $0.originalAmount.money },
                       modern.payload.records.map { $0.originalAmount.money })
    }

    /// Opt-in local differential over the private canonical export. CI and the
    /// repository never need or receive private transaction data.
    func testCanonicalCorpusEconomicsUnchanged() throws {
        guard let path = ProcessInfo.processInfo.environment["FINANCE_HISTORY_ARCHIVE_PATH"] else {
            throw XCTSkip("set FINANCE_HISTORY_ARCHIVE_PATH for a local private-corpus differential")
        }
        let decoded = try FinanceHistoryInterchange.decodeValidated(
            try Data(contentsOf: URL(fileURLWithPath: path))
        )
        for record in decoded.payload.records {
            let amount = record.originalAmount
            XCTAssertEqual(
                amount.money?.currency,
                Currency(
                    code: amount.currency,
                    minorUnitDigits: FinanceHistoryInterchange.monetaryWire(for: decoded.schemaVersion) == .v2
                        ? amount.currencyExponent
                        : Currency.legacyDefaultDigits(amount.currency)
                )
            )
        }
        // Value round trip, not byte equality: the producer's whole-document
        // formatting is its own, and only the canonical payload bytes behind
        // `contentSHA256` are a cross-language contract.
        XCTAssertEqual(
            try FinanceHistoryInterchange.decodeValidated(
                FinanceHistoryInterchange.encode(decoded)
            ),
            decoded
        )
    }

    // MARK: - Public encoding surface

    // The validated wrapper was never the whole encoding surface. `encoder(for:)`
    // is public, `FinanceHistoryDocument` is public `Codable` with a mutable
    // `schemaVersion`, and a bare `JSONEncoder` needs no FinanceCore API at all.
    // Every one of those routes must agree with the document's declared version
    // or refuse, because `schemaVersion` sits outside `contentSHA256` and no
    // digest can catch a body that disagrees with its envelope.

    private func schemaErrorPath(from error: Error) -> String? {
        (error as? FinanceHistorySchemaError)?.path
    }

    func testPublicEncoderRejectsV2DocumentWithLegacyEncoder() throws {
        let v2 = try FinanceHistoryInterchange.decodeValidated(fixtureData("finance-history-2.0.0.json"))
        XCTAssertThrowsError(
            try FinanceHistoryInterchange.encoder(for: "1.1.0").encode(v2)
        ) { XCTAssertEqual(self.schemaErrorPath(from: $0), "schemaVersion") }
    }

    func testPublicEncoderRejectsLegacyDocumentWithV2Encoder() throws {
        for name in ["finance-history-1.0.0.json", "finance-history-1.1.0.json"] {
            let legacy = try FinanceHistoryInterchange.decodeValidated(fixtureData(name))
            XCTAssertThrowsError(
                try FinanceHistoryInterchange.encoder(for: "2.0.0").encode(legacy), name
            ) { XCTAssertEqual(self.schemaErrorPath(from: $0), "schemaVersion", name) }
            // `encoder()` is the 2.0.0 convenience, so it must refuse too.
            XCTAssertThrowsError(
                try FinanceHistoryInterchange.encoder().encode(legacy), name
            ) { XCTAssertEqual(self.schemaErrorPath(from: $0), "schemaVersion", name) }
        }
    }

    func testPlainJSONEncoderCannotInventFinanceHistoryWire() throws {
        for name in ["finance-history-1.0.0.json", "finance-history-1.1.0.json", "finance-history-2.0.0.json"] {
            let document = try FinanceHistoryInterchange.decodeValidated(fixtureData(name))
            XCTAssertThrowsError(try JSONEncoder().encode(document), name) {
                XCTAssertEqual(self.schemaErrorPath(from: $0), "schemaVersion", name)
            }
        }
        // The amount has no version of its own, so it has no authority to pick
        // a grammar either.
        struct Holder: Codable { var originalAmount: FinanceHistoryOriginalAmount }
        let holder = Holder(originalAmount: FinanceHistoryOriginalAmount(cents: 100, currency: "EUR"))
        XCTAssertThrowsError(try JSONEncoder().encode(holder)) {
            XCTAssertEqual(self.schemaErrorPath(from: $0), "originalAmount")
        }
    }

    func testPublicEncoderRejectsAnUnreadableVersion() throws {
        var future = try FinanceHistoryInterchange.decodeValidated(fixtureData("finance-history-2.0.0.json"))
        future.schemaVersion = "3.0.0"
        XCTAssertThrowsError(try FinanceHistoryInterchange.encoder(for: "3.0.0").encode(future)) {
            XCTAssertEqual(self.schemaErrorPath(from: $0), "schemaVersion")
        }
    }

    func testMatchingPublicEncoderStillEncodesLegacyDocument() throws {
        for name in ["finance-history-1.0.0.json", "finance-history-1.1.0.json"] {
            let onDisk = try fixtureData(name)
            let document = try FinanceHistoryInterchange.decodeValidated(onDisk)
            let encoded = try FinanceHistoryInterchange.encoder(for: document.schemaVersion).encode(document)
            XCTAssertEqual(encoded, onDisk, name)
        }
    }

    func testMatchingPublicEncoderStillEncodesV2Document() throws {
        let onDisk = try fixtureData("finance-history-2.0.0.json")
        let document = try FinanceHistoryInterchange.decodeValidated(onDisk)
        let encoded = try FinanceHistoryInterchange.encoder(for: "2.0.0").encode(document)
        XCTAssertEqual(encoded, onDisk)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let payload = try XCTUnwrap(object["payload"] as? [String: Any])
        let records = try XCTUnwrap(payload["records"] as? [[String: Any]])
        let amount = try XCTUnwrap(records[0]["originalAmount"] as? [String: Any])
        XCTAssertEqual(Set(amount.keys), ["minorUnits", "currency"])
    }

    func testHighLevelEncodeRemainsAtomic() throws {
        for name in ["finance-history-1.0.0.json", "finance-history-1.1.0.json", "finance-history-2.0.0.json"] {
            let onDisk = try fixtureData(name)
            let document = try FinanceHistoryInterchange.decodeValidated(onDisk)
            let encoded = try FinanceHistoryInterchange.encode(document)
            XCTAssertEqual(encoded, onDisk, name)

            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let payload = try XCTUnwrap(object["payload"] as? [String: Any])
            let records = try XCTUnwrap(payload["records"] as? [[String: Any]])
            let amount = try XCTUnwrap(records[0]["originalAmount"] as? [String: Any])
            let expected: Set<String> = document.schemaVersion == "2.0.0"
                ? ["minorUnits", "currency"] : ["cents", "currency"]
            XCTAssertEqual(Set(amount.keys), expected, name)
            XCTAssertEqual(object["schemaVersion"] as? String, document.schemaVersion, name)
        }
    }

    func testSearchNormalizationIsCaseDiacriticWidthAndPunctuationInsensitive() {
        XCTAssertEqual(FinanceHistorySearchNormalization.normalize("  CAFÉ—Étude  "), "cafe etude")
        XCTAssertEqual(FinanceHistorySearchNormalization.normalize("Ｕｂｅｒ / COHOLDER"), "uber coholder")

        let searchText = record().normalizedSearchText(accountName: "BNP Courant")
        XCTAssertTrue(searchText.contains("cafe etude"))
        XCTAssertTrue(searchText.contains("food"))
        XCTAssertTrue(searchText.contains("bnp courant"))
    }

    func testFiveThousandSyntheticRowsValidateAndRoundTrip() throws {
        let records = (0..<5_000).map { index in
            record(
                id: String(format: "CT-BNP-%05d", index),
                date: String(format: "2025-%02d-%02d", index % 12 + 1, index % 28 + 1)
            )
        }
        let value = try document(records: records)
        let encoded = try FinanceHistoryInterchange.encode(value)
        let decoded = try FinanceHistoryInterchange.decodeValidated(encoded)

        XCTAssertEqual(decoded.payload.records.count, 5_000)
        XCTAssertEqual(Set(decoded.payload.records.map(\.historicalID)).count, 5_000)
    }

    /// Opt-in local contract check for the ignored private export. CI and the
    /// repository never need or receive private transaction data.
    func testPrivateArchiveContractWhenPathIsExplicitlyProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["FINANCE_HISTORY_ARCHIVE_PATH"] else {
            throw XCTSkip("set FINANCE_HISTORY_ARCHIVE_PATH for a local private-export contract check")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let value = try FinanceHistoryInterchange.decodeValidated(data)

        XCTAssertEqual(value.payload.recordCount, value.payload.records.count)
        XCTAssertFalse(value.payload.records.isEmpty)
        XCTAssertLessThanOrEqual(value.payload.dateRange.end, value.payload.archiveCutoff)
    }
}
