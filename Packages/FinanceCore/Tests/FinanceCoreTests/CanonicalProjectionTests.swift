import XCTest
import Foundation
@testable import FinanceCore

final class CanonicalProjectionTests: XCTestCase {
    typealias W = CheckpointWire
    let day = Day(index: 0)
    func money(_ units: Int64, _ code: String = "EUR", _ digits: Int = 2) -> Money {
        Money(minorUnits: units, currency: Currency(code: code, minorUnitDigits: digits))
    }
    func fixture() -> SemanticPeriodProjection {
        SemanticPeriodProjection(
            period: SemanticInterval(start: day, end: Day(index: 30)), kind: .monthly, coverage: .complete,
            budget: SemanticBudgetFact(periodEconomicSpending: money(-7, "XAF", 0), uncategorized: money(0), attributions: [
                .init(transactionID: "refund", budgetID: "budget", basis: .refundOfLinkedTransaction("prior"), amount: money(-1234, "KWD", 3)),
                .init(transactionID: "purchase", budgetID: nil, basis: .unattributed, amount: money(100))
            ]),
            transactions: [
                .init(id: "refund", day: Day(index: 2), kind: .refund, lifecycle: .cleared, factivity: .observed,
                      legs: [.init(accountID: "cash", minorUnits: 1234, currencyCode: "KWD"), .init(accountID: "bank", minorUnits: -7, currencyCode: "XAF")],
                      incomeSourceID: nil, ownedMinorUnits: 0, categoryKey: "food"),
                .init(id: "purchase", day: day, kind: .expense, lifecycle: .reconciled, factivity: .observed,
                      legs: [.init(accountID: "bank", minorUnits: -100, currencyCode: "EUR")], incomeSourceID: "source", ownedMinorUnits: nil, categoryKey: nil)
            ], observations: [
                .init(id: "evidence", statusToken: "BOOK", identity: .durable, providerEligibleForEconomicActual: true,
                      bindingIsActive: false, resolution: .linkedToTransaction, minorUnits: -100, currencyCode: "EUR", economicDay: day,
                      links: [.init(transactionID: "purchase", role: .accountMovement), .init(transactionID: "refund", role: .supportingEvidence)],
                      aggregate: .init(basis: .structuralCandidateOnly, pairedTransactionIDs: ["refund", "prior"])),
                .init(id: "regressed", statusToken: "provider:unknown", identity: .provisionalSnapshot, providerEligibleForEconomicActual: false,
                      bindingIsActive: true, resolution: .noEconomicEffect, minorUnits: 0, currencyCode: "XAF", economicDay: nil, links: [], aggregate: nil)
            ], expectations: [
                .init(obligationID: "rent", expectedDay: Day(index: 4), minorUnits: 100, currencyCode: "EUR", statusToken: "paid", settledByTransactionID: "purchase"),
                .init(obligationID: "fee", expectedDay: Day(index: 5), minorUnits: 0, currencyCode: "XAF", statusToken: "overdue", settledByTransactionID: nil)
            ])
    }

    // Independently assembled from the documented grammar, with hashlib SHA-256.
    // Fixed tokens make stored-property renames irrelevant to this vector.
    static let golden = "rs26:semantic-period-projectiona8:s2:v1rs8:intervala2:rs3:daya1:i1:0rs3:daya1:i2:30rs7:monthlya0:rs8:completea0:rs6:budgeta3:rs5:moneya3:i2:-7s3:XAFi1:0rs5:moneya3:i1:0s3:EURi1:2a2:rs11:attributiona4:s6:refundps6:budgetrs13:linked-refunda1:s5:priorrs5:moneya3:i5:-1234s3:KWDi1:3rs11:attributiona4:s8:purchasenrs12:unattributeda0:rs5:moneya3:i3:100s3:EURi1:2a2:rs11:transactiona9:s6:refundrs3:daya1:i1:2rs6:refunda0:rs7:cleareda0:rs8:observeda0:a2:rs3:lega3:s4:banki2:-7s3:XAFrs3:lega3:s4:cashi4:1234s3:KWDnpi1:0ps4:foodrs11:transactiona9:s8:purchasers3:daya1:i1:0rs7:expensea0:rs10:reconcileda0:rs8:observeda0:a1:rs3:lega3:s4:banki4:-100s3:EURps6:sourcenna2:rs11:observationa11:s8:evidences4:BOOKrs7:durablea0:b1b0rs19:linkedToTransactiona0:i4:-100s3:EURprs3:daya1:i1:0a2:rs4:linka2:s6:refundrs18:supportingEvidencea0:rs4:linka2:s8:purchasers15:accountMovementa0:prs9:aggregatea2:rs23:structuralCandidateOnlya0:a2:s5:priors6:refundrs11:observationa11:s9:regresseds16:provider:unknownrs19:provisionalSnapshota0:b0b1rs16:noEconomicEffecta0:i1:0s3:XAFna0:na2:rs11:expectationa6:s3:feers3:daya1:i1:5i1:0s3:XAFrs7:overduea0:nrs11:expectationa6:s4:rentrs3:daya1:i1:4i3:100s3:EURrs4:paida0:ps8:purchase"
    static let goldenDigest = "9913eaec56cc0d43a4cb825c766576f986e50ff94df8b74364b5a751b29f6a7d"

    func testGoldenAndRoundTrip() throws {
        let payload = try CanonicalSemanticPeriodProjection(fixture())
        XCTAssertEqual(payload.bytes, Array(Self.golden.utf8))
        XCTAssertEqual(payload.digest.diagnosticHex, Self.goldenDigest)
        let decoded = try CanonicalSemanticPeriodProjection(bytes: payload.bytes)
        XCTAssertEqual(try CanonicalSemanticPeriodProjection(decoded.projection).bytes, payload.bytes)
        XCTAssertEqual(decoded.projection.budget.periodEconomicSpending, money(-7, "XAF", 0))
        XCTAssertEqual(decoded.projection.budget.attributions.first { $0.transactionID == "refund" }?.amount, money(-1234, "KWD", 3))
        XCTAssertEqual(decoded.projection.period, fixture().period)
    }

    func reorder(_ value: W, random: Bool) -> W {
        switch value {
        case let .array(values): return .array((random ? values.shuffled() : values.reversed()).map { reorder($0, random: random) })
        case let .record(tag, fields): return .record(tag, fields.map { reorder($0, random: random) })
        case let .present(child): return .present(reorder(child, random: random))
        default: return value
        }
    }
    func testDeterminismAndUnsortedInitializerBypass() throws {
        let node = try CanonicalProjectionV1.node(fixture())
        let bytes = node.bytes
        for i in 0..<50 {
            XCTAssertEqual(try CanonicalSemanticPeriodProjection(fixture()).bytes, bytes)
            let unsorted = try CanonicalProjectionV1.projection(reorder(node, random: i != 0))
            let payload = try CanonicalSemanticPeriodProjection(unsorted)
            XCTAssertEqual(payload.bytes, bytes)
            XCTAssertEqual(payload.digest.diagnosticHex, Self.goldenDigest)
        }
        XCTAssertThrowsError(try CanonicalSemanticPeriodProjection(bytes: reorder(node, random: false).bytes))
    }

    func testAllMoneyExponentsAndIntegerExtremes() throws {
        for (code, digits) in [("XAF", 0), ("EUR", 2), ("KWD", 3), ("ZZZ", 6)] {
            for amount in [Int64.min, Int64.max, 0, 1, -1] {
                let value = money(amount, code, digits)
                let node = try CanonicalProjectionV1.node(value)
                var reader = CheckpointWireReader(bytes: node.bytes)
                XCTAssertEqual(try CanonicalProjectionV1.readMoney(reader.value()), value)
                XCTAssertEqual(try CanonicalProjectionV1.readMoney(node).currency.minorUnitDigits, digits)
                let integer = W.integer(amount)
                XCTAssertEqual(integer.bytes, Array("i\(String(amount).count):\(amount)".utf8))
            }
        }
    }

    func testMalformedGrammar() throws {
        let invalid = ["", "s", "s:abc", "s01:a", "s-1:x", "s9999999999999999999999999:x", "s4:abc",
                       "a99999999999999999999999:", "a2:n", "i2:-0", "i2:+1", "i2:01", "i1:x",
                       "i19:9223372036854775808", "b2", "p", "rns0:", "?", "i0:"]
        for input in invalid {
            var first = CheckpointWireReader(bytes: Array(input.utf8))
            var second = CheckpointWireReader(bytes: Array(input.utf8))
            var error: SemanticProjectionFormatError?
            XCTAssertThrowsError(try first.value(), input) { error = $0 as? SemanticProjectionFormatError }
            XCTAssertThrowsError(try second.value(), input) { XCTAssertEqual($0 as? SemanticProjectionFormatError, error) }
        }
        var utf8 = CheckpointWireReader(bytes: [115, 49, 58, 255])
        XCTAssertThrowsError(try utf8.value())
        var deep = CheckpointWireReader(bytes: Array((String(repeating: "p", count: 40) + "n").utf8))
        XCTAssertThrowsError(try deep.value())
        for end in 0..<Self.golden.utf8.count {
            XCTAssertThrowsError(try CanonicalSemanticPeriodProjection(bytes: Array(Self.golden.utf8.prefix(end))))
        }
        XCTAssertThrowsError(try CanonicalSemanticPeriodProjection(bytes: Array((Self.golden + "n").utf8)))
    }

    /// Day-F2 made `Day.index` optional. V1's accepted domain, its rejected
    /// boundary, its bytes and its digest are all exactly where they were: the
    /// checked unwrap replaced the trap the year guard already stood in front
    /// of, and moved nothing.
    func testCheckedIndexPlumbingLeavesTheV1DomainWhereItWas() throws {
        // Accepted, unchanged: the whole ordinary range the writer ever took.
        for index in [Int.min / 2 + 1, -719_528, -1, 0, 1, 20_707, Int.max / 2 - 1] {
            let day = Day(index: index)
            let node = try CanonicalProjectionV1.node(day)
            XCTAssertEqual(node, .record("day", [.integer(Int64(index))]))
            XCTAssertEqual(try CanonicalProjectionV1.readDay(node), day)
        }

        // Rejected, unchanged: the writer's own index half-range guard.
        for index in [Int.min / 2, Int.max / 2] {
            XCTAssertThrowsError(try CanonicalProjectionV1.node(Day(index: index))) {
                XCTAssertEqual($0 as? SemanticProjectionFormatError, .invalidDay)
            }
        }

        // Rejected, unchanged: a structural year V1 never encoded. These are
        // exactly the days whose ordinal is now nil, and the year guard still
        // refuses them first — the domain did not widen because index became
        // checked, and it did not narrow either.
        for year in [Int.min, Int.min + 1, Int.max - 1, Int.max] {
            let day = Day(year: year, month: 6, day: 1)
            XCTAssertNil(day.index)
            XCTAssertThrowsError(try CanonicalProjectionV1.node(day)) {
                XCTAssertEqual($0 as? SemanticProjectionFormatError, .invalidDay)
            }
        }

        // And the frozen vector is byte- and digest-identical through it all.
        let payload = try CanonicalSemanticPeriodProjection(fixture())
        XCTAssertEqual(payload.bytes, Array(Self.golden.utf8))
        XCTAssertEqual(payload.digest.diagnosticHex, Self.goldenDigest)
    }

    func testFormatAndSemanticValidation() throws {
        let node = try CanonicalProjectionV1.node(fixture())
        var fields = try node.fields("semantic-period-projection", 8)
        fields[0] = .string("v2")
        XCTAssertThrowsError(try CanonicalSemanticPeriodProjection(bytes: W.record("semantic-period-projection", fields).bytes)) {
            XCTAssertEqual($0 as? SemanticProjectionFormatError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try SemanticPeriodProjectionFormat(token: "v99"))
        XCTAssertThrowsError(try CanonicalProjectionV1.readSemanticInterval(.record("interval", [try CanonicalProjectionV1.node(Day(index: 2)), try CanonicalProjectionV1.node(day)])))
        for code in ["eur", "EU", "EURO", "ÉUR", "E1R"] {
            XCTAssertThrowsError(try CanonicalProjectionV1.readMoney(.record("money", [.integer(1), .string(code), .integer(2)])))
        }
        for digits: Int64 in [-1, 7, .max] {
            XCTAssertThrowsError(try CanonicalProjectionV1.readMoney(.record("money", [.integer(1), .string("EUR"), .integer(digits)])))
        }
        XCTAssertThrowsError(try CanonicalProjectionV1.readDay(.record("day", [.integer(.max)])))
        XCTAssertThrowsError(try CanonicalProjectionV1.projection(.record("semantic-period-projection", fields + [fields[0]])))
        XCTAssertThrowsError(try CanonicalProjectionV1.readBasis(.record("_0", [.string("x")])) )
        XCTAssertThrowsError(try CanonicalProjectionV1.readExpectationStatus(.record("unknown", [])))
        XCTAssertThrowsError(try SemanticProjectionDigest(bytes: Array(repeating: 0, count: 31)))
        XCTAssertThrowsError(try SemanticProjectionDigest(bytes: Array(repeating: 0, count: 33)))
        let digest = try SemanticProjectionDigest(bytes: Array(repeating: 0, count: 32))
        XCTAssertEqual(digest.diagnosticHex, String(repeating: "0", count: 64))
        XCTAssertEqual(Set([digest, digest]).count, 1)
    }

    func testNestedOptionalsAndUnicode() throws {
        let values: [W] = [.absent, .present(.absent), .present(.present(.string("")))]
        XCTAssertEqual(Set(values.map(\.bytes)).count, 3)
        for value in values {
            var reader = CheckpointWireReader(bytes: value.bytes)
            XCTAssertEqual(try reader.value(), value)
        }
        XCTAssertEqual(W.string("é").bytes, W.string("e\u{301}").bytes)
        XCTAssertNotEqual(W.string("n").bytes, W.absent.bytes)
        XCTAssertNotEqual(W.array([.string("a"), .string("bc")]).bytes, W.array([.string("ab"), .string("c")]).bytes)
    }
}

extension CanonicalProjectionTests {
    // Walk every positional semantic field, replacing exactly one leaf, case,
    // optional presence or collection membership per variant. Structural tags
    // and the format version are separately tested as validation failures.
    func mutations(_ value: W, context: String = "", index: Int = 0) -> [W] {
        switch value {
        case let .string(s):
            if s == "v1" { return [] }
            if ["EUR", "XAF", "KWD"].contains(s) { return [.string("USD")] }
            return [.string(s + ":changed")]
        case let .integer(i): return [.integer(i == 0 && context == "day" ? -1 : i + 1)]
        case let .bool(b): return [.bool(!b)]
        case .absent:
            let child: W
            switch (context, index) {
            case ("transaction", 7): child = .integer(0)
            case ("observation", 8): child = .record("day", [.integer(0)])
            case ("observation", 10): child = .record("aggregate", [.record("structuralCandidateOnly", []), .array([])])
            default: child = .string("new")
            }
            return [.present(child)]
        case let .present(child):
            return [.absent] + mutations(child, context: context, index: index).map(W.present)
        case let .array(values):
            var result: [W] = values.isEmpty ? [] : [.array(Array(values.dropFirst()))]
            for (i, child) in values.enumerated() {
                for mutation in mutations(child) {
                    var copy = values; copy[i] = mutation; result.append(.array(copy))
                }
            }
            return result
        case let .record(tag, fields):
            var result: [W] = []
            let alternatives: [String: W] = [
                "monthly": .record("weekly", []), "weekly": .record("monthly", []),
                "expense": .record("income", []), "refund": .record("transfer", []),
                "cleared": .record("pending", []), "reconciled": .record("reversed", []),
                "observed": .record("expected", []), "durable": .record("provisionalSnapshot", []),
                "provisionalSnapshot": .record("durable", []), "linkedToTransaction": .record("unreviewed", []),
                "noEconomicEffect": .record("economicallyIneligible", []),
                "accountMovement": .record("merchantEnrichment", []), "supportingEvidence": .record("accountMovement", []),
                "structuralCandidateOnly": .record("sourceEstablishedAggregateRelationship", []),
                "paid": .record("skipped", []), "overdue": .record("due", []),
                "unattributed": .record("category", [.string("food")]),
                "linked-refund": .record("settled-obligation", fields),
                "category": .record("linked-refund", fields), "settled-obligation": .record("category", fields),
                "complete": .record("incomplete", [.record("partial", []), .array([]), .array([])]),
                "partial": .record("insufficient", []),
                "sourceGap": .record("missingLiveInterval", []),
                "archiveHistoryAbsent": .record("coverageMetadataAbsent", [])
            ]
            if let replacement = alternatives[tag] { result.append(replacement) }
            for (i, child) in fields.enumerated() {
                for mutation in mutations(child, context: tag, index: i) {
                    var copy = fields; copy[i] = mutation; result.append(.record(tag, copy))
                }
            }
            return result
        }
    }

    func testEverySemanticFieldAffectsPayloadAndDigest() throws {
        let original = try CanonicalProjectionV1.node(fixture())
        var fields = try original.fields("semantic-period-projection", 8)
        fields[3] = .record("incomplete", [.record("partial", []), .array([
            .record("interval", [try CanonicalProjectionV1.node(Day(index: 10)), try CanonicalProjectionV1.node(Day(index: 20))])
        ]), .array([.record("sourceGap", []), .record("archiveHistoryAbsent", [])])])
        var budget = try fields[4].fields("budget", 3)
        var attributions = try budget[2].list { $0 }
        attributions.append(.record("attribution", [.string("settled"), .present(.string("line")), .record("settled-obligation", [.string("obligation")]), try CanonicalProjectionV1.node(money(1))]))
        attributions.append(.record("attribution", [.string("categorized"), .present(.string("line")), .record("category", [.string("food")]), try CanonicalProjectionV1.node(money(2))]))
        budget[2] = .array(attributions)
        fields[4] = .record("budget", budget)
        var count = 0
        for node in [original, W.record("semantic-period-projection", fields)] {
            let baseline = try CanonicalSemanticPeriodProjection(CanonicalProjectionV1.projection(node))
            for variant in mutations(node) {
                let projection = try CanonicalProjectionV1.projection(variant)
                let changed = try CanonicalSemanticPeriodProjection(projection)
                XCTAssertNotEqual(changed.bytes, baseline.bytes)
                XCTAssertNotEqual(changed.digest, baseline.digest)
                XCTAssertEqual(try CanonicalSemanticPeriodProjection(bytes: changed.bytes).projection, changed.projection)
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 200)
    }

    func ready(_ projection: SemanticPeriodProjection, exceptions: [PeriodCheckpointException] = [],
               disposition: PeriodCheckpointDisposition? = nil, blockers: [PeriodCheckpointBlocker] = []) -> PeriodCheckpointReadiness {
        .init(period: projection.period, kind: projection.kind,
              disposition: disposition ?? (exceptions.isEmpty ? .readyClean : .readyWithAcknowledgedExceptions),
              quality: exceptions.isEmpty ? .clean : .withExceptions, blockers: blockers,
              exceptions: exceptions, acknowledgedExceptions: exceptions, undecidedExceptions: [],
              safeClaims: .surviving(exceptions), baselineComparison: .unavailable(.noBaselinePersistence), projection: projection)
    }
    func testRevisionInvariantsAndDecisionDigestSeparation() throws {
        let payload = try CanonicalSemanticPeriodProjection(fixture())
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let prior = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let exception = PeriodCheckpointException(id: "synthetic-limitation", kind: .uncategorizedEconomicSpending)
        let clean = try PeriodCheckpointRevision(id: id, revisionNumber: 1, predecessorID: nil, closedAt: Date(timeIntervalSince1970: 0), readiness: ready(fixture()), canonicalProjection: payload)
        let carried = try PeriodCheckpointRevision(id: id, revisionNumber: 2, predecessorID: prior, closedAt: Date(timeIntervalSince1970: 1), readiness: ready(fixture(), exceptions: [exception]), canonicalProjection: payload)
        XCTAssertEqual(clean.projectionDigest, carried.projectionDigest)
        XCTAssertEqual(clean.canonicalProjection, carried.canonicalProjection)
        XCTAssertNotEqual(clean.quality, carried.quality)
        XCTAssertNotEqual(clean.safeClaims, carried.safeClaims)
        XCTAssertEqual(carried.acknowledgedExceptions.count, 1)
        XCTAssertEqual(clean.projectionFormatVersion, payload.format)
        XCTAssertEqual(clean.period, payload.projection.period)
        XCTAssertEqual(clean.periodKind, payload.projection.kind)
        for (number, predecessor) in [(Int64(0), nil), (-1, nil), (1, prior), (2, nil), (2, id)] {
            XCTAssertThrowsError(try PeriodCheckpointRevision(id: id, revisionNumber: number, predecessorID: predecessor, closedAt: Date(timeIntervalSince1970: 0), readiness: ready(fixture()), canonicalProjection: payload))
        }
        for disposition in [PeriodCheckpointDisposition.blocked, .needsDecisions, .readyWithAcknowledgedExceptions] {
            XCTAssertThrowsError(try PeriodCheckpointRevision(id: id, revisionNumber: 1, predecessorID: nil, closedAt: Date(timeIntervalSince1970: 0), readiness: ready(fixture(), disposition: disposition), canonicalProjection: payload))
        }
        let other = SemanticPeriodProjection(period: SemanticInterval(start: Day(index: -1), end: Day(index: 30)), kind: .weekly, coverage: .complete, budget: fixture().budget, transactions: [], observations: [], expectations: [])
        XCTAssertThrowsError(try PeriodCheckpointRevision(id: id, revisionNumber: 1, predecessorID: nil, closedAt: Date(timeIntervalSince1970: 0), readiness: ready(other), canonicalProjection: payload))
    }
}

extension CanonicalProjectionTests {
    func testEveryClosedEnumToken() throws {
        let valuesReviewPeriodKind: [(ReviewPeriodKind, String)] = [(.weekly, "weekly"), (.monthly, "monthly")]
        for (value, token) in valuesReviewPeriodKind {
            XCTAssertEqual(CanonicalProjectionV1.node(value), .record(token, []))
            XCTAssertEqual(try CanonicalProjectionV1.readReviewPeriodKind(.record(token, [])), value)
        }
        XCTAssertThrowsError(try CanonicalProjectionV1.readReviewPeriodKind(.record("unknown", [])))
        XCTAssertThrowsError(try CanonicalProjectionV1.readReviewPeriodKind(.record("weekly", [.absent])))
        let valuesTransactionKind: [(TransactionKind, String)] = [(.expense, "expense"), (.income, "income"), (.transfer, "transfer"), (.refund, "refund"), (.financingRepayment, "financingRepayment"), (.passThrough, "passThrough"), (.cashWithdrawal, "cashWithdrawal"), (.currencyConversion, "currencyConversion")]
        for (value, token) in valuesTransactionKind {
            XCTAssertEqual(CanonicalProjectionV1.node(value), .record(token, []))
            XCTAssertEqual(try CanonicalProjectionV1.readTransactionKind(.record(token, [])), value)
        }
        XCTAssertThrowsError(try CanonicalProjectionV1.readTransactionKind(.record("unknown", [])))
        XCTAssertThrowsError(try CanonicalProjectionV1.readTransactionKind(.record("expense", [.absent])))
        let valuesTransactionLifecycle: [(TransactionLifecycle, String)] = [(.pending, "pending"), (.cleared, "cleared"), (.reconciled, "reconciled"), (.reversed, "reversed")]
        for (value, token) in valuesTransactionLifecycle {
            XCTAssertEqual(CanonicalProjectionV1.node(value), .record(token, []))
            XCTAssertEqual(try CanonicalProjectionV1.readTransactionLifecycle(.record(token, [])), value)
        }
        XCTAssertThrowsError(try CanonicalProjectionV1.readTransactionLifecycle(.record("unknown", [])))
        XCTAssertThrowsError(try CanonicalProjectionV1.readTransactionLifecycle(.record("pending", [.absent])))
        let valuesFactivity: [(Factivity, String)] = [(.observed, "observed"), (.expected, "expected")]
        for (value, token) in valuesFactivity {
            XCTAssertEqual(CanonicalProjectionV1.node(value), .record(token, []))
            XCTAssertEqual(try CanonicalProjectionV1.readFactivity(.record(token, [])), value)
        }
        XCTAssertThrowsError(try CanonicalProjectionV1.readFactivity(.record("unknown", [])))
        XCTAssertThrowsError(try CanonicalProjectionV1.readFactivity(.record("observed", [.absent])))
        let valuesExternalObservationIdentity: [(ExternalObservationIdentity, String)] = [(.durable, "durable"), (.provisionalSnapshot, "provisionalSnapshot")]
        for (value, token) in valuesExternalObservationIdentity {
            XCTAssertEqual(CanonicalProjectionV1.node(value), .record(token, []))
            XCTAssertEqual(try CanonicalProjectionV1.readExternalObservationIdentity(.record(token, [])), value)
        }
        XCTAssertThrowsError(try CanonicalProjectionV1.readExternalObservationIdentity(.record("unknown", [])))
        XCTAssertThrowsError(try CanonicalProjectionV1.readExternalObservationIdentity(.record("durable", [.absent])))
        let valuesObservationResolutionState: [(ObservationResolutionState, String)] = [(.unreviewed, "unreviewed"), (.linkedToTransaction, "linkedToTransaction"), (.noEconomicEffect, "noEconomicEffect"), (.outsideSyncBoundary, "outsideSyncBoundary"), (.provisional, "provisional"), (.economicallyIneligible, "economicallyIneligible")]
        for (value, token) in valuesObservationResolutionState {
            XCTAssertEqual(CanonicalProjectionV1.node(value), .record(token, []))
            XCTAssertEqual(try CanonicalProjectionV1.readObservationResolutionState(.record(token, [])), value)
        }
        XCTAssertThrowsError(try CanonicalProjectionV1.readObservationResolutionState(.record("unknown", [])))
        XCTAssertThrowsError(try CanonicalProjectionV1.readObservationResolutionState(.record("unreviewed", [.absent])))
        let valuesExternalEvidenceRole: [(ExternalEvidenceRole, String)] = [(.accountMovement, "accountMovement"), (.merchantEnrichment, "merchantEnrichment"), (.supportingEvidence, "supportingEvidence")]
        for (value, token) in valuesExternalEvidenceRole {
            XCTAssertEqual(CanonicalProjectionV1.node(value), .record(token, []))
            XCTAssertEqual(try CanonicalProjectionV1.readExternalEvidenceRole(.record(token, [])), value)
        }
        XCTAssertThrowsError(try CanonicalProjectionV1.readExternalEvidenceRole(.record("unknown", [])))
        XCTAssertThrowsError(try CanonicalProjectionV1.readExternalEvidenceRole(.record("accountMovement", [.absent])))
        let valuesAggregateEvidenceBasis: [(AggregateEvidenceBasis, String)] = [(.sourceEstablishedAggregateRelationship, "sourceEstablishedAggregateRelationship"), (.structuralCandidateOnly, "structuralCandidateOnly")]
        for (value, token) in valuesAggregateEvidenceBasis {
            XCTAssertEqual(CanonicalProjectionV1.node(value), .record(token, []))
            XCTAssertEqual(try CanonicalProjectionV1.readAggregateEvidenceBasis(.record(token, [])), value)
        }
        XCTAssertThrowsError(try CanonicalProjectionV1.readAggregateEvidenceBasis(.record("unknown", [])))
        XCTAssertThrowsError(try CanonicalProjectionV1.readAggregateEvidenceBasis(.record("sourceEstablishedAggregateRelationship", [.absent])))
        let valuesReviewCoverageStatus: [(ReviewCoverageStatus, String)] = [(.complete, "complete"), (.partial, "partial"), (.insufficient, "insufficient")]
        for (value, token) in valuesReviewCoverageStatus {
            XCTAssertEqual(CanonicalProjectionV1.node(value), .record(token, []))
            XCTAssertEqual(try CanonicalProjectionV1.readReviewCoverageStatus(.record(token, [])), value)
        }
        XCTAssertThrowsError(try CanonicalProjectionV1.readReviewCoverageStatus(.record("unknown", [])))
        XCTAssertThrowsError(try CanonicalProjectionV1.readReviewCoverageStatus(.record("complete", [.absent])))
        let valuesReviewCoverageReasonKind: [(ReviewCoverageReasonKind, String)] = [(.coverageMetadataAbsent, "coverageMetadataAbsent"), (.archiveHistoryAbsent, "archiveHistoryAbsent"), (.missingArchiveInterval, "missingArchiveInterval"), (.missingLiveInterval, "missingLiveInterval"), (.sourceGap, "sourceGap")]
        for (value, token) in valuesReviewCoverageReasonKind {
            XCTAssertEqual(CanonicalProjectionV1.node(value), .record(token, []))
            XCTAssertEqual(try CanonicalProjectionV1.readReviewCoverageReasonKind(.record(token, [])), value)
        }
        XCTAssertThrowsError(try CanonicalProjectionV1.readReviewCoverageReasonKind(.record("unknown", [])))
        XCTAssertThrowsError(try CanonicalProjectionV1.readReviewCoverageReasonKind(.record("coverageMetadataAbsent", [.absent])))
        let bases: [MonthlyBudgetEngine.AttributionBasis] = [.category("x"), .settledObligation(obligationID: "x"), .refundOfLinkedTransaction("x"), .unattributed]
        for basis in bases {
            XCTAssertEqual(try CanonicalProjectionV1.readBasis(CanonicalProjectionV1.node(basis)), basis)
        }
        for status in ["due", "overdue", "paid", "skipped", "noLongerDue"] {
            XCTAssertEqual(try CanonicalProjectionV1.readExpectationStatus(CanonicalProjectionV1.expectationStatus(status)), status)
        }
    }

    func testDuplicateIdentityTieBreakAndCoverageOrdering() throws {
        var f = try CanonicalProjectionV1.node(fixture()).fields("semantic-period-projection", 8)
        var transactions = try f[5].list { $0 }
        var duplicate = try transactions[0].fields("transaction", 9)
        duplicate[7] = .present(.integer(999))
        transactions.append(.record("transaction", duplicate))
        f[5] = .array(transactions)
        f[3] = .record("incomplete", [.record("partial", []), .array([
            .record("interval", [try CanonicalProjectionV1.node(Day(index: 10)), try CanonicalProjectionV1.node(Day(index: 11))]),
            .record("interval", [try CanonicalProjectionV1.node(Day(index: 20)), try CanonicalProjectionV1.node(Day(index: 21))])
        ]), .array([.record("sourceGap", []), .record("missingLiveInterval", []), .record("sourceGap", [])])])
        let node = W.record("semantic-period-projection", f)
        let baseline = try CanonicalSemanticPeriodProjection(CanonicalProjectionV1.projection(node))
        for _ in 0..<50 {
            XCTAssertEqual(try CanonicalSemanticPeriodProjection(CanonicalProjectionV1.projection(reorder(node, random: true))), baseline)
        }
        // Unicode equivalence follows Swift semantic String equality.
        var unicode = try CanonicalProjectionV1.node(fixture()).fields("semantic-period-projection", 8)
        var txs = try unicode[5].list { $0 }
        var tx = try txs[0].fields("transaction", 9)
        tx[0] = .string("é")
        txs[0] = .record("transaction", tx); unicode[5] = .array(txs)
        let composed = try CanonicalSemanticPeriodProjection(CanonicalProjectionV1.projection(.record("semantic-period-projection", unicode)))
        tx[0] = .string("e\u{301}")
        txs[0] = .record("transaction", tx); unicode[5] = .array(txs)
        XCTAssertEqual(try CanonicalSemanticPeriodProjection(CanonicalProjectionV1.projection(.record("semantic-period-projection", unicode))), composed)
    }
}

extension CanonicalProjectionTests {
    func testRevisionRejectsForgedReadySnapshots() throws {
        let payload = try CanonicalSemanticPeriodProjection(fixture())
        let exception = PeriodCheckpointException(id: "one", kind: .uncategorizedEconomicSpending)
        func snapshot(
            period: SemanticInterval? = nil, kind: ReviewPeriodKind = .monthly,
            blockers: [PeriodCheckpointBlocker] = [], exceptions: [PeriodCheckpointException] = [],
            acknowledged: [PeriodCheckpointException] = [], undecided: [PeriodCheckpointException] = [],
            quality: PeriodCheckpointQuality = .clean, claims: PeriodCheckpointSafeClaims = .surviving([]),
            projection: SemanticPeriodProjection? = nil
        ) -> PeriodCheckpointReadiness {
            .init(period: period ?? fixture().period, kind: kind, disposition: .readyClean,
                  quality: quality, blockers: blockers, exceptions: exceptions,
                  acknowledgedExceptions: acknowledged, undecidedExceptions: undecided,
                  safeClaims: claims, baselineComparison: .unavailable(.noBaselinePersistence),
                  projection: projection ?? fixture())
        }
        let forged = [
            snapshot(period: .init(start: Day(index: -1), end: Day(index: 30))),
            snapshot(kind: .weekly),
            snapshot(blockers: [.init(kind: .periodNotEnded)]),
            snapshot(exceptions: [exception]),
            snapshot(acknowledged: [exception]),
            snapshot(undecided: [exception]),
            snapshot(quality: .withExceptions),
            snapshot(claims: .blocked),
            snapshot(claims: .surviving([exception]))
        ]
        for readiness in forged {
            XCTAssertThrowsError(try PeriodCheckpointRevision(id: UUID(), revisionNumber: 1, predecessorID: nil,
                closedAt: Date(timeIntervalSince1970: 0), readiness: readiness, canonicalProjection: payload))
        }
        for timestamp in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try PeriodCheckpointRevision(id: UUID(), revisionNumber: 1, predecessorID: nil,
                closedAt: Date(timeIntervalSince1970: timestamp), readiness: ready(fixture()), canonicalProjection: payload))
        }
        let weekly = SemanticPeriodProjection(period: fixture().period, kind: .weekly, coverage: .complete,
            budget: fixture().budget, transactions: [], observations: [], expectations: [])
        let weeklyPayload = try CanonicalSemanticPeriodProjection(weekly)
        XCTAssertNoThrow(try PeriodCheckpointRevision(id: UUID(), revisionNumber: 1, predecessorID: nil,
            closedAt: Date(timeIntervalSince1970: 0), readiness: ready(weekly), canonicalProjection: weeklyPayload))
        var f = try CanonicalProjectionV1.node(fixture()).fields("semantic-period-projection", 8)
        f[3] = .record("incomplete", [.record("partial", []), .array([]), .array([])])
        let incomplete = try CanonicalSemanticPeriodProjection(CanonicalProjectionV1.projection(.record("semantic-period-projection", f)))
        XCTAssertThrowsError(try PeriodCheckpointRevision(id: UUID(), revisionNumber: 1, predecessorID: nil,
            closedAt: Date(timeIntervalSince1970: 0), readiness: ready(incomplete.projection), canonicalProjection: incomplete))
    }
}

extension CanonicalProjectionTests {
    func testSynthesizedDecoderCanBypassSortingButCannotChangeCanonicalBytes() throws {
        // This is an adversarial input constructor ONLY. Canonical code never
        // uses JSON/Codable. Avoid the separately deferred XAF Codable defect
        // while deliberately exercising the sorting-initializer bypass.
        let input = SemanticPeriodProjection(period: fixture().period, kind: .monthly, coverage: .complete,
            budget: .init(periodEconomicSpending: money(-7), uncategorized: money(0), attributions: fixture().budget.attributions),
            transactions: fixture().transactions, observations: fixture().observations, expectations: fixture().expectations)
        let json = try JSONEncoder().encode(input)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        for key in ["transactions", "observations", "expectations"] {
            object[key] = Array(try XCTUnwrap(object[key] as? [Any]).reversed())
        }
        let bypass = try JSONDecoder().decode(SemanticPeriodProjection.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNotEqual(bypass.transactions.map(\.id), input.transactions.map(\.id))
        XCTAssertNotEqual(bypass.observations.map(\.id), input.observations.map(\.id))
        XCTAssertNotEqual(bypass.expectations.map(\.obligationID), input.expectations.map(\.obligationID))
        XCTAssertEqual(try CanonicalSemanticPeriodProjection(bypass), try CanonicalSemanticPeriodProjection(input))
    }
}
