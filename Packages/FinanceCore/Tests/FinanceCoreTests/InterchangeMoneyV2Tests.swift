import XCTest
@testable import FinanceCore

final class InterchangeMoneyV2Tests: XCTestCase {
    let day = Day(year: 2026, month: 9, day: 1)
    let targets: [InterchangeTarget] = [.minimumRequired, .format(.v1), .format(.v2)]

    func document(_ version: String = "1.4.0", v2: Bool = false, planning: Bool = false) -> FinanceDocument {
        let currency = Currency(code: "EUR", minorUnitDigits: v2 ? 0 : 2)
        return FinanceDocument(schemaVersion: version, documentKind: "SYNTHETIC",
            accounts: [Account(id: "a", name: "Synthetic", currency: currency, kind: .bank, supportedRails: [])],
            balances: [AccountBalance(accountID: "a", balance: Money(minorUnits: 1, currency: currency), asOf: day)],
            planning: .init(plannedPurchases: planning ? [PlannedPurchase(id: "p", name: "Synthetic",
                targetAmount: Money(minorUnits: 100, currency: .eur), requirement: .euroBankPayment())] : []))
    }

    func testDomainCurrencyAndMoneyGridIsLosslessByDefault() throws {
        let units: [Int64] = [.min, -1, 0, 1, .max, 9_007_199_254_740_991, 9_007_199_254_740_992,
                              9_007_199_254_740_993, -9_007_199_254_740_993]
        for code in ["EUR", "JPY", "KWD", "XAA", "XAF", "ZZZ"] {
            var distinct = Set<Data>()
            for exponent in 0...6 {
                let c = Currency(code: code, minorUnitDigits: exponent)
                let encoded = try JSONEncoder().encode(c)
                distinct.insert(encoded)
                XCTAssertEqual(try JSONDecoder().decode(Currency.self, from: encoded), c)
                for n in units {
                    let m = Money(minorUnits: n, currency: c)
                    let data = try JSONEncoder().encode(m)
                    XCTAssertEqual(try JSONDecoder().decode(Money.self, from: data), m)
                    let text = String(decoding: data, as: UTF8.self)
                    XCTAssertTrue(text.contains("\"minorUnits\":\(n)"))
                    XCTAssertTrue(text.contains("\"exponent\":\(exponent)"))
                }
            }
            XCTAssertEqual(distinct.count, 7)
        }
    }

    func testMalformedV2AndExtraKeys() throws {
        let currencies = ["{}", "{\"code\":3,\"exponent\":2}", "{\"code\":\"eur\",\"exponent\":2}",
            "{\"code\":\"EU\",\"exponent\":2}", "{\"code\":\"EURO\",\"exponent\":2}",
            "{\"code\":\"ÉUR\",\"exponent\":2}", "{\"code\":\"EUR\"}",
            "{\"code\":\"EUR\",\"exponent\":\"2\"}", "{\"code\":\"EUR\",\"exponent\":-1}",
            "{\"code\":\"EUR\",\"exponent\":7}", "{\"code\":\"EUR\",\"exponent\":2.5}",
            "{\"exponent\":2}", "null", "\"EUR\""]
        for raw in currencies { XCTAssertThrowsError(try JSONDecoder().decode(Currency.self, from: Data(raw.utf8))) }
        let c = "{\"code\":\"XAA\",\"exponent\":3}"
        for amount in ["null", "\"1\"", "true", "[]", "{}", "9223372036854775808", "-9223372036854775809", "1.5"] {
            XCTAssertThrowsError(try JSONDecoder().decode(Money.self, from: Data("{\"minorUnits\":\(amount),\"currency\":\(c)}".utf8)))
        }
        for raw in ["{}", "{\"currency\":\(c)}", "{\"minorUnits\":1}", "{\"minorUnits\":1,\"currency\":{}}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(Money.self, from: Data(raw.utf8)))
        }
        let raw = "{\"minorUnits\":1,\"extra\":true,\"currency\":{\"code\":\"XAA\",\"exponent\":3,\"extra\":1}}"
        XCTAssertEqual(try JSONDecoder().decode(Money.self, from: Data(raw.utf8)), Money(minorUnits: 1, currency: Currency(code: "XAA", minorUnitDigits: 3)))
        for (token, expected) in [("1.0", Int64(1)), ("1e2", Int64(100))] {
            XCTAssertEqual(try JSONDecoder().decode(Money.self, from: Data("{\"minorUnits\":\(token),\"currency\":\(c)}".utf8)).minorUnits, expected)
        }
    }

    func testEverySuccessfulEncodingCanBeDecodedByCurrentReader() throws {
        for source in ["1.4.0", "1.6.0", "2.0.0"] { for planning in [false, true] { for v2 in [false, true] {
            let d = document(source, v2: v2, planning: planning)
            for target in targets {
                if target == .format(.v1) && v2 {
                    XCTAssertThrowsError(try Interchange.encode(d, as: target))
                    continue
                }
                let output = try Interchange.encode(d, as: target)
                let read = try Interchange.decode(output)
                let wantsV2 = target == .format(.v2) || (target == .minimumRequired && (source == "2.0.0" || v2))
                let expected = wantsV2 ? "2.0.0" : (source == "2.0.0" || planning ? "1.6.0" : source)
                XCTAssertEqual(read.schemaVersion, expected)
                var expectedDocument = d
                expectedDocument.schemaVersion = expected
                XCTAssertEqual(read, expectedDocument)
                let root = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
                let balances = try XCTUnwrap(root["balances"] as? [[String: Any]])
                XCTAssertEqual(balances[0]["balance"] is [String: Any], wantsV2)
                XCTAssertEqual(balances[0]["balance"] is String, !wantsV2)
            }
        } } }
    }

    func testV2CanonicalDocumentDefaultReencodeUsesMatchingVersionAndBody() throws {
        let decoded = try Interchange.decode(Interchange.encode(document(), as: .format(.v2)))
        let output = try Interchange.encode(decoded)
        XCTAssertEqual(try Interchange.decode(output).schemaVersion, "2.0.0")
        XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("\"minorUnits\""))
    }
    func testV1CodecNeverEmitsV2SchemaVersion() throws {
        let d = document("2.0.0")
        let encoder = Interchange.encoder()
        encoder.userInfo[.financeDocumentMoneyWire] = InterchangeFormat.v1
        XCTAssertThrowsError(try encoder.encode(d))
        XCTAssertEqual(try Interchange.decode(Interchange.encode(d, as: .format(.v1))).schemaVersion, "1.6.0")
    }
    /// The four version constants mean four different things and happen to
    /// collapse onto two strings today. Pinning the relationships keeps any of
    /// them from becoming a stale literal nothing reads.
    func testVersionConstantsAgreeWithTheFormatMapping() throws {
        XCTAssertEqual(try Interchange.format(for: Interchange.currentSchemaVersion), .v1)
        XCTAssertEqual(try Interchange.format(for: Interchange.planningStateSchemaVersion), .v1)
        XCTAssertEqual(try Interchange.format(for: Interchange.explicitMonetarySchemaVersion), .v2)
        XCTAssertEqual(try Interchange.format(for: Interchange.latestSchemaVersion), .v2)

        // Everything this build can write, it can read.
        for version in [Interchange.currentSchemaVersion, Interchange.planningStateSchemaVersion,
                        Interchange.explicitMonetarySchemaVersion, Interchange.latestSchemaVersion] {
            XCTAssertTrue(Interchange.readableSchemaVersions.contains(version), version)
        }

        // `latestSchemaVersion` is exactly the newest readable version.
        for version in Interchange.readableSchemaVersions {
            XCTAssertTrue(Interchange.isVersion(Interchange.latestSchemaVersion, atLeast: version), version)
        }
        XCTAssertFalse(Interchange.isVersion(Interchange.currentSchemaVersion, atLeast: Interchange.latestSchemaVersion))
    }

    func testV2CodecAlwaysEmits200() throws {
        for version in Interchange.readableSchemaVersions {
            XCTAssertEqual(try Interchange.decode(Interchange.encode(document(version), as: .format(.v2))).schemaVersion, "2.0.0")
        }
        XCTAssertThrowsError(try JSONEncoder().encode(document("1.6.0")))
    }
    func testExplicitV1DowngradeFromV2UsesValidV1Version() throws {
        XCTAssertEqual(try Interchange.decode(Interchange.encode(document("2.0.0"), as: .format(.v1))).schemaVersion, "1.6.0")
    }
    /// The two independent reasons to raise a version compose: durable
    /// planning floors a V1 document at 1.6.0, a non-canonical exponent forces
    /// V2 outright, and when both apply V2 wins without losing the planning
    /// rows. Asserted directly rather than by delegating to another test.
    func testPlanningAndMoneyVersionRequirementsComposeCorrectly() throws {
        // planning only -> floored to 1.6.0, still V1 money on the wire.
        let planningOnly = document("1.4.0", planning: true)
        let flooredBytes = try Interchange.encode(planningOnly)
        let floored = try Interchange.decode(flooredBytes)
        XCTAssertEqual(floored.schemaVersion, "1.6.0")
        XCTAssertFalse(Interchange.documentRequiresV2(planningOnly))
        let flooredRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: flooredBytes) as? [String: Any])
        let flooredBalances = try XCTUnwrap(flooredRoot["balances"] as? [[String: Any]])
        XCTAssertTrue(flooredBalances[0]["balance"] is String, "durable planning alone must not change the money wire")

        // money only -> V2, no planning rows involved.
        let moneyOnly = document("1.4.0", v2: true)
        XCTAssertEqual(try Interchange.decode(Interchange.encode(moneyOnly)).schemaVersion, "2.0.0")

        // both -> V2, and the planning rows survive intact.
        let both = document("1.4.0", v2: true, planning: true)
        let read = try Interchange.decode(try Interchange.encode(both))
        XCTAssertEqual(read.schemaVersion, "2.0.0")
        XCTAssertEqual(read.planning.plannedPurchases.map(\.id), ["p"])
        XCTAssertEqual(read.accounts.first?.currency, Currency(code: "EUR", minorUnitDigits: 0))

        // explicit V1 on the combined document refuses for the money reason.
        XCTAssertThrowsError(try Interchange.encode(both, as: .format(.v1))) { error in
            XCTAssertEqual(error as? InterchangeError, .notRepresentableInV1(field: "accounts[0].currency"))
        }
    }
    func testCallerDocumentIsNotMutatedDuringEncoding() throws {
        let d = document("1.4.0", planning: true)
        for target in targets { _ = try Interchange.encode(d, as: target); XCTAssertEqual(d.schemaVersion, "1.4.0") }
    }
    func testInt64ExtremesDoNotTriggerV2() throws {
        for n in [Int64.min, .max] {
            var d = document()
            d.balances = [.init(accountID: "a", balance: Money(minorUnits: n, currency: .eur), asOf: day)]
            XCTAssertFalse(Interchange.documentRequiresV2(d))
            XCTAssertEqual(try Interchange.decode(Interchange.encode(d)), d)
        }
    }
    func testVersionDispatchBeforeMoneyAndOldReaderRejection() throws {
        let data = Data("{\"schemaVersion\":\"3.0.0\",\"balances\":\"garbage\"}".utf8)
        XCTAssertThrowsError(try Interchange.decode(data)) { error in
            XCTAssertEqual(error as? InterchangeError, .unsupportedSchemaVersion(found: "3.0.0"))
        }
        struct Envelope: Decodable { let schemaVersion: String }
        let v2 = try Interchange.encode(document(), as: .format(.v2))
        let envelope = try JSONDecoder().decode(Envelope.self, from: v2)
        let frozenOldVersions: Set<String> = ["1.1.0", "1.2.0", "1.3.0", "1.4.0", "1.5.0", "1.6.0"]
        XCTAssertFalse(frozenOldVersions.contains(envelope.schemaVersion))
        XCTAssertThrowsError(try legacyMoneyDecoder().decode(FinanceDocument.self, from: v2))
    }
}
