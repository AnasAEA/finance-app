import XCTest
@testable import FinanceCore

/// `MoneyBag`'s wire had to carry a currency's exponent, not just its code.
///
/// A bag is keyed on the whole `Currency` identity — code *and* minor-unit
/// digits — but every entry used to be written as a bare code. A holding in
/// `EUR/4` therefore encoded as `["EUR",100]` and read back as `EUR/2`: a
/// different currency, and an amount a hundred times off, with nothing raised.
/// Two holdings sharing a code decoded as one repeated code and collided.
///
/// These tests pin both halves of the repair: the explicit nested-array form
/// that carries an exponent, and the compact pair form that ordinary bags keep.
final class MoneyBagWireFidelityTests: XCTestCase {

    private func currency(_ code: String, _ exponent: Int) -> Currency {
        Currency(code: code, minorUnitDigits: exponent)
    }

    private func bag(_ holdings: (String, Int, Int64)...) -> MoneyBag {
        MoneyBag(holdings.map { Money(minorUnits: $0.2, currency: currency($0.0, $0.1)) })
    }

    private func json(_ bag: MoneyBag) throws -> String {
        try XCTUnwrap(String(data: JSONEncoder().encode(bag), encoding: .utf8))
    }

    private func decode(_ raw: String) throws -> MoneyBag {
        try JSONDecoder().decode(MoneyBag.self, from: Data(raw.utf8))
    }

    // MARK: - The original regression

    /// The exact case that was silently corrupt: one holding at a non-default
    /// exponent. It used to come back as `EUR/2`.
    func testEUR4RoundTripsAsEUR4NotEUR2() throws {
        let original = bag(("EUR", 4, 100))
        XCTAssertEqual(try json(original), #"[[["EUR",4],100]]"#)

        let decoded = try decode(try json(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.currencies, [currency("EUR", 4)])
        XCTAssertEqual(decoded.amount(in: currency("EUR", 4)).minorUnits, 100)
        XCTAssertEqual(decoded.amount(in: .eur).minorUnits, 0,
                       "EUR/4 must not answer to EUR/2 — they are different currencies")
    }

    /// The other half of the same defect: two holdings sharing a code used to
    /// write the code twice and fail the duplicate check on decode.
    func testTwoExponentsOfOneCodeBothSurvive() throws {
        let original = bag(("EUR", 2, 39_600), ("EUR", 4, 100))
        XCTAssertEqual(try json(original), #"[["EUR",39600],[["EUR",4],100]]"#)

        let decoded = try decode(try json(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.currencies, [currency("EUR", 2), currency("EUR", 4)])
        XCTAssertEqual(decoded.amount(in: .eur).minorUnits, 39_600)
        XCTAssertEqual(decoded.amount(in: currency("EUR", 4)).minorUnits, 100)
    }

    // MARK: - Ordinary bytes are frozen

    /// A bag of currencies at their historical exponents must encode to the
    /// bytes it always did. These literals are the pre-repair output.
    func testOrdinaryBagsKeepTheirExistingBytes() throws {
        XCTAssertEqual(try json(bag(("EUR", 2, 39_600))), #"[["EUR",39600]]"#)
        XCTAssertEqual(try json(bag(("JPY", 0, 1_234))), #"[["JPY",1234]]"#)
        XCTAssertEqual(try json(bag(("KWD", 3, 3_750))), #"[["KWD",3750]]"#)
        XCTAssertEqual(try json(bag(("XAA", 2, 100))), #"[["XAA",100]]"#,
                       "an unknown code's historical default is two digits")
        XCTAssertEqual(
            try json(bag(("EUR", 2, 39_600), ("JPY", 0, 1_234),
                         ("KWD", 3, 3_750), ("MAD", 2, 20_000))),
            #"[["EUR",39600],["JPY",1234],["KWD",3750],["MAD",20000]]"#
        )
    }

    /// The explicit form appears only where the pair form cannot tell the
    /// truth — never for a currency at its historical exponent.
    func testExplicitFormAppearsOnlyWhenTheExponentIsNotTheHistoricalOne() throws {
        for (code, exponent) in [("EUR", 2), ("MAD", 2), ("USD", 2), ("XAA", 2),
                                 ("JPY", 0), ("KRW", 0), ("KWD", 3), ("BHD", 3)] {
            XCTAssertEqual(try json(bag((code, exponent, 100))), #"[["\#(code)",100]]"#,
                           "\(code)/\(exponent) is the historical reading of a bare \(code)")
        }
        for (code, exponent) in [("EUR", 0), ("EUR", 1), ("EUR", 3), ("EUR", 4), ("EUR", 6),
                                 ("JPY", 2), ("KWD", 2), ("XAA", 5)] {
            XCTAssertEqual(try json(bag((code, exponent, 100))), #"[[["\#(code)",\#(exponent)],100]]"#,
                           "\(code)/\(exponent) cannot be written as a bare \(code)")
        }
    }

    // MARK: - Round-trip law

    /// `decode(encode(bag)) == bag`, over the domain the bag actually admits.
    func testRoundTripLawAcrossTheDomain() throws {
        let bags: [(String, MoneyBag)] = [
            ("empty", MoneyBag.empty),
            ("EUR/0", bag(("EUR", 0, 100))),
            ("EUR/2", bag(("EUR", 2, 39_600))),
            ("EUR/4", bag(("EUR", 4, 100))),
            ("XAA/5", bag(("XAA", 5, 7))),
            ("EUR/2+EUR/4", bag(("EUR", 2, 39_600), ("EUR", 4, 100))),
            ("EUR/0+EUR/2+EUR/6", bag(("EUR", 0, 1), ("EUR", 2, 2), ("EUR", 6, 3))),
            ("JPY/0+JPY/3", bag(("JPY", 0, 500), ("JPY", 3, 500_000))),
            ("XAA/0+XAA/3+XAA/6", bag(("XAA", 0, 1), ("XAA", 3, 2), ("XAA", 6, 3))),
            ("mixed codes and exponents",
             bag(("EUR", 2, -1), ("EUR", 4, 1), ("JPY", 0, 7), ("KWD", 3, -3_750),
                 ("MAD", 2, 20_000), ("XAA", 6, 999))),
        ]
        for (label, original) in bags {
            let decoded = try decode(try json(original))
            XCTAssertEqual(decoded, original, label)
            XCTAssertEqual(decoded.currencies, original.currencies, label)
            for currency in original.currencies {
                XCTAssertEqual(decoded.amount(in: currency), original.amount(in: currency), label)
            }
        }
    }

    /// Every exponent the domain allows survives, at both ends of Int64.
    func testEveryValidExponentRoundTripsAtInt64Boundaries() throws {
        for code in ["EUR", "XAA", "JPY", "KWD"] {
            for exponent in 0...6 {
                for units: Int64 in [.min, -1, 0, 1, .max, 9_007_199_254_740_993, -9_007_199_254_740_993] {
                    let original = bag((code, exponent, units))
                    let decoded = try decode(try json(original))
                    XCTAssertEqual(decoded, original, "\(code)/\(exponent) @ \(units)")
                    XCTAssertEqual(decoded.amount(in: currency(code, exponent)).minorUnits, units)
                }
            }
        }
    }

    /// `2^53 + 1` is the first integer a `Double` cannot hold. If minor units
    /// ever route through one, this comes back even.
    func testMinorUnitsBeyondDoublePrecisionAreExact() throws {
        let beyondDouble: Int64 = 9_007_199_254_740_993      // 2^53 + 1
        XCTAssertEqual(try json(bag(("EUR", 4, beyondDouble))),
                       #"[[["EUR",4],9007199254740993]]"#)
        XCTAssertEqual(try json(bag(("EUR", 2, beyondDouble))),
                       #"[["EUR",9007199254740993]]"#)
        let exact: [(String, Int64, Int)] = [
            (#"[[["EUR",4],9007199254740993]]"#, 9_007_199_254_740_993, 4),
            (#"[[["EUR",4],-9007199254740993]]"#, -9_007_199_254_740_993, 4),
            (#"[["EUR",9007199254740993]]"#, 9_007_199_254_740_993, 2),
            (#"[[["EUR",4],-9223372036854775808]]"#, .min, 4),
            (#"[[["EUR",4],9223372036854775807]]"#, .max, 4),
        ]
        for (raw, units, exponent) in exact {
            let decoded = try decode(raw)
            XCTAssertEqual(decoded.amount(in: currency("EUR", exponent)).minorUnits, units, raw)
        }
    }

    // MARK: - Deterministic order

    /// Insertion order never leaks, and the two forms interleave by the same
    /// (code, digits) total order the bag already used.
    func testEncodingIsDeterministicAcrossInsertionOrders() throws {
        let holdings = [
            Money(minorUnits: 100, currency: currency("EUR", 4)),
            Money(minorUnits: 39_600, currency: .eur),
            Money(minorUnits: 1, currency: currency("EUR", 0)),
            Money(minorUnits: 7, currency: .jpy),
            Money(minorUnits: 9, currency: currency("JPY", 3)),
            Money(minorUnits: 20_000, currency: .mad),
        ]
        let expected = #"[[["EUR",0],1],["EUR",39600],[["EUR",4],100],["JPY",7],[["JPY",3],9],["MAD",20000]]"#
        for _ in 0..<200 {
            XCTAssertEqual(try json(MoneyBag(holdings.shuffled())), expected)
        }
    }

    // MARK: - Duplicate identity

    /// Duplicate means the same code *and* the same exponent.
    func testDuplicateDetectionUsesWholeCurrencyIdentity() throws {
        let distinct = try decode(#"[["EUR",100],[["EUR",4],200]]"#)
        XCTAssertEqual(distinct.currencies, [currency("EUR", 2), currency("EUR", 4)])

        // ... including when one side spells its exponent out and the other
        // leaves it implied.
        for raw in [#"[[["EUR",4],100],[["EUR",4],200]]"#,
                    #"[["EUR",100],["EUR",200]]"#,
                    #"[["EUR",100],[["EUR",2],200]]"#,
                    #"[[["EUR",2],100],["EUR",200]]"#,
                    #"[["EUR",100],{"currency":"EUR","minorUnits":200}]"#] {
            XCTAssertThrowsError(try decode(raw), raw)
        }
    }

    /// The bag holds same-code/different-exponent holdings in memory too —
    /// the wire is not inventing a state the domain rejects.
    func testDomainAdmitsSameCodeDifferentExponents() {
        var held = MoneyBag.empty
        held.add(Money(minorUnits: 39_600, currency: .eur))
        held.add(Money(minorUnits: 100, currency: currency("EUR", 4)))
        XCTAssertEqual(held.currencies, [currency("EUR", 2), currency("EUR", 4)])
        XCTAssertEqual(held.amount(in: .eur).minorUnits, 39_600)
        XCTAssertEqual(held.amount(in: currency("EUR", 4)).minorUnits, 100)

        // Adding to one exponent leaves the other alone.
        held.add(Money(minorUnits: 1, currency: .eur))
        XCTAssertEqual(held.amount(in: .eur).minorUnits, 39_601)
        XCTAssertEqual(held.amount(in: currency("EUR", 4)).minorUnits, 100)
    }

    // MARK: - Malformed input

    /// Legacy rejection is preserved; the new form has strict structure.
    func testMalformedEntriesThrow() {
        let malformed = [
            #"[["EUR"]]"#, #"[[]]"#, #"[["eur",100]]"#, #"[["EURO",100]]"#,
            #"[["EU",100]]"#, #"[["E1R",100]]"#, #"[[123,100]]"#,
            #"[["EUR","100"]]"#, #"[["EUR",1.5]]"#, #"[["EUR",null]]"#,
            #"[["EUR",9223372036854775808]]"#,
            #"[[["EUR",4]]]"#, #"[[["EUR",4],100,7]]"#,
            #"[[["EUR"],100]]"#, #"[[["EUR",4,5],100]]"#,
            #"[[["eur",4],100]]"#, #"[[["EURO",4],100]]"#,
            #"[[["EUR","4"],100]]"#, #"[[["EUR",null],100]]"#,
            #"[[["EUR",1.5],100]]"#, #"[[["EUR",-1],100]]"#,
            #"[[["EUR",7],100]]"#, #"[[["EUR",4],"100"]]"#,
            #"[[["EUR",4],1.5]]"#, #"[[["EUR",4],null]]"#,
            #"[[["EUR",4],9223372036854775808]]"#,
            #"[[["EUR",4],-9223372036854775809]]"#,
            #"[[["EUR",9223372036854775808],100]]"#,
            #"["EUR"]"#, #"[100]"#, #"[null]"#, #"{"EUR":100}"#,
        ]
        for raw in malformed { XCTAssertThrowsError(try decode(raw), raw) }
    }

    /// A legacy array's second element is minor units, always, even when its
    /// value would pass for an exponent. Its trailing values are irrelevant.
    /// Reading it any other way would re-interpret bytes already written.
    func testPairFormSecondElementIsAlwaysMinorUnits() throws {
        for units: Int64 in [0, 1, 2, 3, 4, 5, 6, 7, -1, .max] {
            let decoded = try decode(#"[["EUR",\#(units)]]"#)
            if units == 0 {
                XCTAssertTrue(decoded.isEmpty, "a zero holding is absent, not stored")
                continue
            }
            XCTAssertEqual(decoded.currencies, [.eur], "\(units)")
            XCTAssertEqual(decoded.amount(in: .eur).minorUnits, units,
                           "[\"EUR\",\(units)] is \(units) minor units of EUR/2")
        }
        // The nested explicit form carries the exponent independently.
        XCTAssertEqual(try decode(#"[[["EUR",4],100]]"#).amount(in: currency("EUR", 4)).minorUnits, 100)
    }

    /// An out-of-range exponent is refused outright — never clamped, never
    /// swapped for a default, never quietly rescaled into one that fits.
    func testOutOfRangeExponentIsRefusedNotNormalised() {
        for exponent in [-2, -1, 7, 8, 99] {
            XCTAssertThrowsError(try decode(#"[[["EUR",\#(exponent)],100]]"#), "exponent \(exponent)")
        }
    }

    // MARK: - Legacy object form

    /// The `{ currency, minorUnits }` form still reads, still at the frozen
    /// exponent for its bare code, and re-encodes into the current shape.
    func testLegacyObjectFormKeepsItsFrozenReading() throws {
        let decoded = try decode(
            #"[{"currency":"EUR","minorUnits":39600},{"minorUnits":1234,"currency":"JPY"},"#
            + #"{"currency":"KWD","minorUnits":3750},{"currency":"XAA","minorUnits":100}]"#)
        XCTAssertEqual(decoded.currencies,
                       [.eur, .jpy, .kwd, currency("XAA", 2)])
        XCTAssertEqual(decoded.amount(in: .eur).minorUnits, 39_600)
        XCTAssertEqual(decoded.amount(in: .jpy).minorUnits, 1_234)
        XCTAssertEqual(decoded.amount(in: .kwd).minorUnits, 3_750)
        XCTAssertEqual(try json(decoded),
                       #"[["EUR",39600],["JPY",1234],["KWD",3750],["XAA",100]]"#)

        // It carries a bare code, so it has no way to say EUR/4 — and must not
        // grow one by borrowing `Currency`'s own V2 keyed shape.
        for raw in [#"[{"currency":"eur","minorUnits":100}]"#,
                    #"[{"currency":"EUR","minorUnits":"100"}]"#,
                    #"[{"currency":"EUR"}]"#,
                    #"[{"minorUnits":100}]"#,
                    #"[{"currency":{"code":"EUR","exponent":4},"minorUnits":100}]"#] {
            XCTAssertThrowsError(try decode(raw), raw)
        }
    }

    // MARK: - Decoder accepts every form, including a redundant explicit one

    /// A writer that always states the exponent is still read correctly; the
    /// encoder simply does not produce that form for ordinary currencies.
    func testExplicitFormIsAcceptedEvenWhereThePairFormWouldDo() throws {
        let decoded = try decode(#"[[["EUR",2],39600],[["JPY",0],1234],[["KWD",3],3750]]"#)
        XCTAssertEqual(decoded, MoneyBag([
            Money(minorUnits: 39_600, currency: .eur),
            Money(minorUnits: 1_234, currency: .jpy),
            Money(minorUnits: 3_750, currency: .kwd),
        ]))
        XCTAssertEqual(try json(decoded), #"[["EUR",39600],["JPY",1234],["KWD",3750]]"#,
                       "re-encoding canonicalises back to the pair form")
    }

    /// All three forms can sit in one array.
    func testAllThreeFormsMixInOneBag() throws {
        let decoded = try decode(
            #"[["EUR",39600],[["EUR",4],100],{"currency":"MAD","minorUnits":20000}]"#)
        XCTAssertEqual(decoded.currencies, [.eur, currency("EUR", 4), .mad])
        XCTAssertEqual(decoded.amount(in: currency("EUR", 4)).minorUnits, 100)
        XCTAssertEqual(try json(decoded), #"[["EUR",39600],[["EUR",4],100],["MAD",20000]]"#)
    }

    // MARK: - Registry drift

    /// The two-element form's meaning is frozen to `legacyDefaultDigits`, not
    /// to the evolving table behind `Currency(code:)`.
    ///
    /// The two agree today, so this asserts the coupling over every code the
    /// frozen table names plus unknown ones. Add `XAA` to
    /// `knownMinorUnitDigits` and this test still expects 2 — which is the
    /// point: yesterday's bytes cannot be re-read by tomorrow's registry.
    func testCompactFormIsFrozenToTheHistoricalTableNotTheEvolvingOne() throws {
        let codes = ["JPY", "KRW", "VND", "CLP",
                     "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND",
                     "EUR", "MAD", "USD", "GBP", "CHF", "DZD",
                     "XAA", "XBB", "ZZZ", "AAA"]
        for code in codes {
            let decoded = try decode(#"[["\#(code)",100]]"#)
            let held = try XCTUnwrap(decoded.currencies.first)
            XCTAssertEqual(held.code, code)
            XCTAssertEqual(held.minorUnitDigits, Currency.legacyDefaultDigits(code),
                           "a bare \(code) must keep the exponent it has always had")
            XCTAssertEqual(decoded.amount(in: held).minorUnits, 100)
        }

        // The legacy object form shares the same frozen reading.
        for code in codes {
            let decoded = try decode(#"[{"currency":"\#(code)","minorUnits":100}]"#)
            let held = try XCTUnwrap(decoded.currencies.first)
            XCTAssertEqual(held.minorUnitDigits, Currency.legacyDefaultDigits(code), code)
        }
    }

    /// The frozen table itself, pinned entry by entry. `legacyDefaultDigits`
    /// is shared with the FinanceDocument V1 money wire on purpose: one frozen
    /// historical reading, not two tables drifting apart.
    func testFrozenHistoricalTableIsPinned() {
        for code in ["JPY", "KRW", "VND", "CLP"] {
            XCTAssertEqual(Currency.legacyDefaultDigits(code), 0, code)
        }
        for code in ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"] {
            XCTAssertEqual(Currency.legacyDefaultDigits(code), 3, code)
        }
        for code in ["EUR", "MAD", "USD", "GBP", "CHF", "DZD", "XAA", "ZZZ"] {
            XCTAssertEqual(Currency.legacyDefaultDigits(code), 2, code)
        }
    }

    /// The encoder's choice of form is the same predicate the decoder reads
    /// back with. If they ever disagree, a bag stops round-tripping — so the
    /// coupling is asserted directly rather than left to coincidence.
    func testEncoderFormMatchesTheDecodersHistoricalReading() throws {
        for code in ["EUR", "JPY", "KWD", "XAA"] {
            for exponent in 0...6 {
                let text = try json(bag((code, exponent, 100)))
                let isPairForm = text == #"[["\#(code)",100]]"#
                XCTAssertEqual(isPairForm, exponent == Currency.legacyDefaultDigits(code),
                               "\(code)/\(exponent) wrote \(text)")
                XCTAssertEqual(try decode(text), bag((code, exponent, 100)), "\(code)/\(exponent)")
            }
        }
    }

    /// Baseline 7074624 consumed code + Int64 and ignored every trailing value.
    /// These literals are historical protocol behavior, including the blocked
    /// candidate's flat triple, which must never acquire exponent meaning.
    func testHistoricalArraysPreserveIgnoredTrailingValues() throws {
        let cases: [(String, Int64)] = [
            (#"["EUR",4]"#, 4), (#"["EUR",4,100]"#, 4),
            (#"["EUR",1,2,3]"#, 1), (#"["EUR",-1,9]"#, -1),
            (#"["EUR",9223372036854775807,0]"#, .max),
            (#"["EUR",0,"ignored"]"#, 0), (#"["EUR",4,null]"#, 4),
            (#"["EUR",4,"anything"]"#, 4), (#"["EUR",4,{}]"#, 4),
            (#"["EUR",4,[]]"#, 4), (#"["EUR",4,100,200,300]"#, 4),
        ]
        for (entry, units) in cases {
            let raw = "[\(entry)]"
            let expected = bag(("EUR", 2, units))
            XCTAssertEqual(try decode(raw), expected, raw)
            XCTAssertEqual(try baseline(raw), expected, raw)
        }
    }

    func testLegacyObjectsIgnoreExponentLikeUnknownKeys() throws {
        for raw in [#"[{"currency":"EUR","minorUnits":4}]"#,
                    #"[{"currency":"EUR","minorUnits":4,"exponent":6}]"#,
                    #"[{"currency":"EUR","minorUnits":4,"unknown":{"code":"XAA","exponent":5}}]"#] {
            XCTAssertEqual(try decode(raw), bag(("EUR", 2, 4)))
            XCTAssertEqual(try decode(raw), try baseline(raw))
        }
    }

    func testLegacyZeroSkipsMetadataButStillRequiresFieldTypes() throws {
        for raw in [#"[["bad",0]]"#, #"[["",0,null]]"#,
                    #"[{"currency":"EURO","minorUnits":0}]"#,
                    #"[["EUR",0],["EUR",100],["EUR",0]]"#] {
            XCTAssertEqual(try decode(raw), try baseline(raw), raw)
        }
        for raw in [#"[[123,0]]"#, #"[{"currency":{},"minorUnits":0}]"#,
                    #"[{"currency":"EUR"}]"#, #"[{"minorUnits":0}]"#,
                    #"[{"currency":"EUR","minorUnits":"0"}]"#] {
            XCTAssertThrowsError(try decode(raw), raw)
            XCTAssertThrowsError(try baseline(raw), raw)
        }
        XCTAssertEqual(bag(("EUR", 4, 0)), .empty)
        XCTAssertEqual(try decode(#"[[["EUR",4],0]]"#), .empty)
        // New metadata is always validated, even for a zero holding.
        XCTAssertThrowsError(try decode(#"[[["bad",4],0]]"#))
        XCTAssertThrowsError(try decode(#"[[["EUR",7],0]]"#))
    }

    /// Hard gate: new bytes must fail at the baseline's first String decode,
    /// not merely fail a later check or return a different amount.
    func testOldReaderRejectsEveryNewExplicitRepresentation() throws {
        for code in ["EUR", "JPY", "KWD", "XAA"] {
            for exponent in 0...6 where exponent != Currency.legacyDefaultDigits(code) {
                for units: Int64 in [.min, -1, 1, .max, 9_007_199_254_740_993] {
                    let original = bag((code, exponent, units))
                    let raw = try json(original)
                    XCTAssertEqual(try decode(raw), original)
                    XCTAssertThrowsError(try baseline(raw), raw) { error in
                        guard case DecodingError.typeMismatch(let type, let context) = error else {
                            return XCTFail("Expected structural String type mismatch, got \(error)")
                        }
                        XCTAssertTrue(type == String.self)
                        XCTAssertEqual(context.codingPath.compactMap(\.intValue), [0, 0])
                    }
                }
            }
        }
    }

    func testIgnoredTrailingArrayStillDuplicatesCanonicalObject() {
        let raw = #"[["EUR",4,100],{"currency":"EUR","minorUnits":200}]"#
        XCTAssertThrowsError(try decode(raw))
        XCTAssertThrowsError(try baseline(raw))
    }

    private func baseline(_ raw: String) throws -> MoneyBag {
        try JSONDecoder().decode(HistoricalMoneyBagReader.self, from: Data(raw.utf8)).bag
    }

}


/// Frozen decoder contract copied from MoneyBag at
/// 70746243ba0c3d8aec54f3ef412dc394a706023b. Keep independent of the current
/// MoneyBag decoder: in particular, never teach this reader the new wire.
/// Storage is materialized through MoneyBag's unchanged public initializer.
private struct HistoricalMoneyBagReader: Decodable {
    let bag: MoneyBag

    private struct Entry: Decodable {
        let code: String
        let minorUnits: Int64
        private enum ObjectKey: String, CodingKey { case currency, minorUnits }

        init(from decoder: Decoder) throws {
            if var pair = try? decoder.unkeyedContainer() {
                code = try pair.decode(String.self)
                minorUnits = try pair.decode(Int64.self)
                return
            }
            let object = try decoder.container(keyedBy: ObjectKey.self)
            code = try object.decode(String.self, forKey: .currency)
            minorUnits = try object.decode(Int64.self, forKey: .minorUnits)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let entries = try container.decode([Entry].self)
        var storage: [Currency: Int64] = [:]
        for entry in entries where entry.minorUnits != 0 {
            let currency: Currency
            do {
                currency = try Currency.validating(code: entry.code,
                    exponent: Currency.legacyDefaultDigits(entry.code))
            } catch {
                throw DecodingError.dataCorruptedError(in: container,
                    debugDescription: "Invalid money bag currency")
            }
            guard storage[currency] == nil else {
                throw DecodingError.dataCorruptedError(in: container,
                    debugDescription: "Duplicate currency \(entry.code) in money bag")
            }
            storage[currency] = entry.minorUnits
        }
        bag = MoneyBag(storage.map { Money(minorUnits: $0.value, currency: $0.key) })
    }
}
