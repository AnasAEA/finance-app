import XCTest
@testable import FinanceCore

/// `MoneyBag`: multi-currency holdings with no
/// implicit conversion anywhere. EUR and MAD coexist; neither can ever be
/// summed into the other.
final class MoneyBagTests: XCTestCase {

    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    private func dirham(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .mad)!
    }

    func testCurrenciesAreKeptSeparateAndSorted() {
        var bag = MoneyBag.empty
        bag.add(dirham("200.00"))
        bag.add(euro("396.00"))
        bag.add(euro("100.00"))

        XCTAssertEqual(bag.currencies, [.eur, .mad], "sorted by ISO code, deterministic")
        XCTAssertEqual(bag.amount(in: .eur), euro("496.00"))
        XCTAssertEqual(bag.amount(in: .mad), dirham("200.00"))
        XCTAssertEqual(bag.amount(in: .usd), Money(minorUnits: 0, currency: .usd),
                       "a currency the bag does not hold is zero — not an error, not a conversion")
    }

    func testZeroEntriesAreAbsentNotStored() {
        var bag = MoneyBag.empty
        bag.add(euro("0.00"))
        XCTAssertTrue(bag.isEmpty)
        XCTAssertEqual(bag.currencies, [])

        // And a currency that nets back to zero disappears again.
        bag.add(euro("50.00"))
        bag.add(euro("-50.00"))
        XCTAssertEqual(bag.currencies, [], "a currency with no money is absent, not zero")
    }

    func testAddingAndMergingNeverConvert() {
        let euros = MoneyBag(euro("100.00"))
        let dirhams = MoneyBag(dirham("200.00"))
        let both = euros + dirhams

        XCTAssertEqual(both.currencies, [.eur, .mad])
        XCTAssertEqual(both.amount(in: .eur), euro("100.00"))
        XCTAssertEqual(both.amount(in: .mad), dirham("200.00"))

        let topped = both.adding(euro("0.01"))
        XCTAssertEqual(topped.amount(in: .eur), euro("100.01"))
        XCTAssertEqual(topped.amount(in: .mad), dirham("200.00"), "adding EUR touched nothing in MAD")

        let drained = topped.subtracting(dirham("200.00"))
        XCTAssertEqual(drained.currencies, [.eur], "the emptied currency dropped out")
    }

    func testSubtractingBelowZeroKeepsTheEntry() {
        var bag = MoneyBag(euro("50.00"))
        bag.subtract(euro("100.00"))
        XCTAssertEqual(bag.amount(in: .eur), euro("-50.00"),
                       "a bag may hold negative amounts (an overdraft); it never 'borrows' from another currency")
    }

    func testCodableIsADeterministicSortedArray() throws {
        // Build the same holdings in two different insertion orders; the
        // encoded bytes must be identical.
        var first = MoneyBag.empty
        first.add(dirham("200.00"))
        first.add(euro("396.00"))

        var second = MoneyBag.empty
        second.add(euro("396.00"))
        second.add(dirham("100.00"))
        second.add(dirham("100.00"))

        let encoder = JSONEncoder()
        let firstBytes = try encoder.encode(first)
        let secondBytes = try encoder.encode(second)
        XCTAssertEqual(firstBytes, secondBytes, "insertion order must never leak into the encoding")

        let decoded = try JSONDecoder().decode(MoneyBag.self, from: firstBytes)
        XCTAssertEqual(decoded, first)

        // The shape itself is a flat sorted array of entries.
        XCTAssertEqual(
            String(data: firstBytes, encoding: .utf8),
            #"[["EUR",39600],["MAD",20000]]"#
        )
    }

    /// The encoding must not contain a JSON object at all.
    ///
    /// A keyed container's key order belongs to the encoder — Foundation
    /// writes one in hash order — so an object form is byte-stable only when
    /// every caller remembers `.sortedKeys`. This is the assertion that pins
    /// the shape: the previous `{ "currency": …, "minorUnits": … }` entries
    /// fail it outright rather than one unlucky seed in two.
    func testEncodingContainsNoEncoderOrderedObjectKeys() throws {
        var bag = MoneyBag.empty
        for code in ["EUR", "MAD", "USD", "GBP", "CHF", "DZD", "JPY", "KWD"] {
            bag.add(Money(minorUnits: 1_234, currency: Currency(code: code)))
        }
        let text = try XCTUnwrap(String(data: JSONEncoder().encode(bag), encoding: .utf8))
        XCTAssertFalse(text.contains("{"), "an object's key order is the encoder's to choose")
        XCTAssertFalse(text.contains("currency"))
        XCTAssertFalse(text.contains("minorUnits"))
    }

    /// Equal bags encode identically however they were built, and whatever
    /// order the dictionary happens to hold them in this run.
    func testEncodingIsStableAcrossRandomisedInsertionOrders() throws {
        let codes = ["EUR", "MAD", "USD", "GBP", "CHF", "DZD", "JPY", "KWD"]
        let expected = try JSONEncoder().encode(
            MoneyBag(codes.map { Money(minorUnits: 1_234, currency: Currency(code: $0)) })
        )
        for _ in 0..<200 {
            var bag = MoneyBag.empty
            for code in codes.shuffled() {
                bag.add(Money(minorUnits: 1_234, currency: Currency(code: code)))
            }
            XCTAssertEqual(try JSONEncoder().encode(bag), expected)
        }
    }

    /// Two currencies may share a code and disagree about minor-unit digits:
    /// `Currency` hashes on both, so the bag holds them as separate keys.
    /// Ordering on the code alone left them equal to the comparator, and
    /// `sort` is not stable, so which came first was decided by the hash seed.
    func testSameCodeDifferentDigitsHasOneTotalOrder() throws {
        let twoDigits = Currency(code: "XAA", minorUnitDigits: 2)
        let threeDigits = Currency(code: "XAA", minorUnitDigits: 3)

        var ascending = MoneyBag.empty
        ascending.add(Money(minorUnits: 100, currency: twoDigits))
        ascending.add(Money(minorUnits: 200, currency: threeDigits))

        var descending = MoneyBag.empty
        descending.add(Money(minorUnits: 200, currency: threeDigits))
        descending.add(Money(minorUnits: 100, currency: twoDigits))

        XCTAssertEqual(ascending.currencies, [twoDigits, threeDigits])
        XCTAssertEqual(descending.currencies, [twoDigits, threeDigits])
        // XAA/2 is what a bare "XAA" has always meant, so it keeps the pair
        // form; XAA/3 has to state its exponent to survive at all.
        XCTAssertEqual(
            String(data: try JSONEncoder().encode(ascending), encoding: .utf8),
            #"[["XAA",100],[["XAA",3],200]]"#
        )
        XCTAssertEqual(
            try JSONEncoder().encode(ascending), try JSONEncoder().encode(descending)
        )
        XCTAssertEqual(ascending.description, descending.description)

        // Both holdings survive the round trip. This bag used to throw on
        // decode: every entry wrote a bare code, so two distinct currencies
        // arrived as one repeated code and collided.
        let decoded = try JSONDecoder().decode(MoneyBag.self, from: JSONEncoder().encode(ascending))
        XCTAssertEqual(decoded, ascending)
        XCTAssertEqual(decoded.currencies, [twoDigits, threeDigits])
        XCTAssertEqual(decoded.amount(in: twoDigits).minorUnits, 100)
        XCTAssertEqual(decoded.amount(in: threeDigits).minorUnits, 200)
    }

    /// Bags written in the previous `{ currency, minorUnits }` object form are
    /// still read, so nothing hand-written or already on disk becomes garbage.
    func testLegacyObjectEntriesStillDecode() throws {
        let json = #"[{"currency":"EUR","minorUnits":39600},{"minorUnits":20000,"currency":"MAD"}]"#
        let decoded = try JSONDecoder().decode(MoneyBag.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.amount(in: .eur), euro("396.00"))
        XCTAssertEqual(decoded.amount(in: .mad), dirham("200.00"))
        XCTAssertEqual(
            String(data: try JSONEncoder().encode(decoded), encoding: .utf8),
            #"[["EUR",39600],["MAD",20000]]"#
        )
    }

    /// A historical entry carries its currency as a bare code and relies on
    /// the legacy table to rebuild one. What changed is the failure mode: an
    /// unparseable code used to reach `Currency`'s precondition and take the
    /// process down, which is not an option for untrusted stored bytes.
    func testMalformedCurrencyCodeThrowsInsteadOfTrapping() {
        for raw in [#"[["eur",100]]"#, #"[["EURO",100]]"#, #"[["EU",100]]"#,
                    #"[["E1R",100]]"#, #"[[123,100]]"#,
                    #"[{"currency":"eur","minorUnits":100}]"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(MoneyBag.self, from: Data(raw.utf8)), raw)
        }
        // A well-formed code still decodes at its legacy exponent.
        let bag = try? JSONDecoder().decode(MoneyBag.self, from: Data(#"[["XAA",100]]"#.utf8))
        XCTAssertEqual(bag?.amount(in: Currency(code: "XAA", minorUnitDigits: 2)).minorUnits, 100)
    }

    func testDuplicateCurrencyEntriesAreRejectedOnDecode() {
        let json = """
        [ { "currency" : "EUR", "minorUnits" : 100 }, { "currency" : "EUR", "minorUnits" : 200 } ]
        """
        XCTAssertThrowsError(try JSONDecoder().decode(MoneyBag.self, from: Data(json.utf8)))
    }

    func testDescriptionListsEachCurrency() {
        var bag = MoneyBag.empty
        bag.add(euro("54.00"))
        bag.add(dirham("200.00"))
        XCTAssertEqual(bag.description, "EUR 54.00 + MAD 200.00")
    }
}
