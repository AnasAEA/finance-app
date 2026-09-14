import XCTest
@testable import FinanceCore

/// Proofs #12–#15 — deterministic ordering, correct bridge, safety-floor
/// bridge, same-day determinism — on small hand-checkable scenarios.
final class ForecastEngineTests: XCTestCase {

    private let bank = Account(id: "bnp", name: "Bank", currency: .eur, kind: .bank, supportedRails: PaymentRail.euroBankRails)

    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    private func debit(_ id: String, on date: String, amount: String) -> ForecastEvent {
        ForecastEvent(
            id: id,
            day: Day(isoString: date)!,
            phase: .scheduledDebit,
            effect: .debit(euro(amount), requirement: PaymentRequirement.euroBankPayment(rails: [.sepaDirectDebit]))
        )
    }

    // MARK: - Proof 13: minimum bridge

    func testMinimumBridgeIsExactAndVerifiable() {
        // Start 100; 250 due day 2; 1000 arrives day 3.
        let request = ForecastRequest(
            startDate: Day(isoString: "2026-09-01")!,
            endDate: Day(isoString: "2026-09-30")!,
            accounts: [bank],
            startingBalances: ["bnp": euro("100.00")],
            events: [debit("rent", on: "2026-09-02", amount: "250.00")],
            incomeSources: [IncomeSource(
                id: "support", name: "Support", amount: euro("1000.00"), certainty: .guaranteed,
                schedule: .oneShot(on: Day(isoString: "2026-09-03")!), arrivesOnAccount: "bnp"
            )],
            scenario: .guaranteed
        )
        let result = try! ForecastEngine.run(request)
        XCTAssertEqual(result.firstNegativeDate, Day(isoString: "2026-09-02")!)
        XCTAssertEqual(result.lowestBalance, euro("-150.00"))
        XCTAssertEqual(result.minimumBridgeRequired, euro("150.00"))

        // The definition of the bridge: depositing exactly that amount up
        // front keeps every balance non-negative — one cent less does not.
        var bridged = request
        bridged.startingBalances = ["bnp": euro("250.00")]
        let safe = try! ForecastEngine.run(bridged)
        XCTAssertNil(safe.firstNegativeDate)
        XCTAssertEqual(safe.lowestBalance, euro("0.00"))

        // One cent less than the bridge still goes negative — the bridge is
        // minimal, not a rounded suggestion.
        var oneCentShort = request
        oneCentShort.startingBalances = ["bnp": euro("249.99")]
        let unsafe = try! ForecastEngine.run(oneCentShort)
        XCTAssertEqual(unsafe.firstNegativeDate, Day(isoString: "2026-09-02")!)
        XCTAssertEqual(unsafe.minimumBridgeRequired, euro("0.01"))
    }

    // MARK: - Proof 14: safety-floor bridge

    func testSafetyFloorBridgeHoldsTheFloor() {
        let request = ForecastRequest(
            startDate: Day(isoString: "2026-09-01")!,
            endDate: Day(isoString: "2026-09-30")!,
            accounts: [bank],
            startingBalances: ["bnp": euro("100.00")],
            events: [debit("rent", on: "2026-09-02", amount: "250.00")],
            incomeSources: [IncomeSource(
                id: "support", name: "Support", amount: euro("1000.00"), certainty: .guaranteed,
                schedule: .oneShot(on: Day(isoString: "2026-09-03")!), arrivesOnAccount: "bnp"
            )],
            scenario: .guaranteed,
            safetyFloor: euro("100.00")
        )
        let result = try! ForecastEngine.run(request)
        XCTAssertEqual(result.firstBelowSafetyFloorDate, Day(isoString: "2026-09-02")!)
        // Deepest point is −150; holding floor 100 needs 250.
        XCTAssertEqual(result.minimumBridgeForSafetyFloor, euro("250.00"))

        var bridged = request
        bridged.startingBalances = ["bnp": euro("350.00")]
        let safe = try! ForecastEngine.run(bridged)
        XCTAssertNil(safe.firstBelowSafetyFloorDate,
                     "with the floor bridge deposited, the pool never dips strictly below the floor")
        XCTAssertEqual(safe.lowestBalance, euro("100.00"))
    }

    func testNoFloorMeansNoFloorOutputs() {
        let request = ForecastRequest(
            startDate: Day(isoString: "2026-09-01")!,
            endDate: Day(isoString: "2026-09-02")!,
            accounts: [bank],
            startingBalances: ["bnp": euro("10.00")],
            scenario: .base
        )
        let result = try! ForecastEngine.run(request)
        XCTAssertNil(result.firstBelowSafetyFloorDate)
        XCTAssertEqual(result.minimumBridgeForSafetyFloor, euro("0.00"))
    }

    // MARK: - Proof 15 & 12: same-day ordering is deterministic

    func testSameDayOrderingDebitsBeforeCreditsThenDependentDisposals() {
        let request = ForecastRequest(
            startDate: Day(isoString: "2026-09-10")!,
            endDate: Day(isoString: "2026-09-10")!,
            accounts: [bank],
            startingBalances: ["bnp": euro("100.00")],
            events: [
                ForecastEvent(id: "b-co-resident-out", day: Day(isoString: "2026-09-10")!, phase: .dependentDisposal,
                              effect: .directedDebit(euro("50.00"), fromAccount: "bnp")),
                ForecastEvent(id: "a-rent", day: Day(isoString: "2026-09-10")!, phase: .scheduledDebit, priority: 1,
                              effect: .debit(euro("30.00"), requirement: PaymentRequirement.euroBankPayment())),
                ForecastEvent(id: "a-fee", day: Day(isoString: "2026-09-10")!, phase: .scheduledDebit, priority: 0,
                              effect: .debit(euro("10.00"), requirement: PaymentRequirement.euroBankPayment())),
                ForecastEvent(id: "c-support", day: Day(isoString: "2026-09-10")!, phase: .credit,
                              effect: .credit(euro("200.00"), toAccount: "bnp")),
            ],
            incomeSources: [],
            scenario: .base
        )
        let result = try! ForecastEngine.run(request)
        XCTAssertEqual(result.appliedEvents.map(\.id),
                       ["a-fee", "a-rent", "c-support", "b-co-resident-out"],
                       "scheduled debits by (priority, id), then credits, then dependent disposals")

        // Intraday trace: 100 −10 −30 +200 −50 = 210; the disposal only runs
        // after its arrival.
        XCTAssertEqual(result.dailyBalances.first?.endOfDay["bnp"], euro("210.00"))
        XCTAssertEqual(result.projectedEndBalance, euro("210.00"))

        // Debit-first means a same-day credit does not rescue a same-day debit:
        // the intraday minimum reflects the debit, not the close.
        XCTAssertEqual(result.lowestBalance, euro("60.00"),
                       "100 − 10 − 30 intraday, before the credit lands")
    }

    func testShuffledInputsProduceIdenticalResults() {
        func make(_ seed: Int) -> ForecastRequest {
            var events = [
                debit("rent", on: "2026-09-11", amount: "480.00"),
                debit("financing", on: "2026-09-11", amount: "26.00"),
                ForecastEvent(id: "co-resident-out", day: Day(isoString: "2026-09-16")!, phase: .dependentDisposal,
                              effect: .directedDebit(euro("800.00"), fromAccount: "bnp")),
            ]
            var sources = [
                IncomeSource(id: "parents", name: "P", amount: euro("800.00"), certainty: .expected,
                             schedule: .oneShot(on: Day(isoString: "2026-09-16")!), arrivesOnAccount: "bnp"),
                IncomeSource(id: "job", name: "J", amount: euro("253.00"), certainty: .target,
                             schedule: .oneShot(on: Day(isoString: "2026-09-20")!)),
            ]
            // Deterministic shuffle by seed — different collection orders.
            var state = UInt64(seed)
            func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
            for _ in 0..<(seed % 7 + 1) {
                if next() % 2 == 0 { events.shuffle() }
                if next() % 2 == 0 { sources.shuffle() }
            }
            return ForecastRequest(
                startDate: Day(isoString: "2026-09-01")!,
                endDate: Day(isoString: "2026-09-30")!,
                accounts: [bank],
                startingBalances: ["bnp": euro("396.00")],
                events: events,
                incomeSources: sources,
                scenario: .base
            )
        }
        let reference = try! ForecastEngine.run(make(1))
        for seed in 2...12 {
            let shuffled = try! ForecastEngine.run(make(seed))
            XCTAssertEqual(shuffled, reference, "seed \(seed) changed the result")
            XCTAssertEqual(shuffled.appliedEvents.map(\.id), reference.appliedEvents.map(\.id))
        }
    }

    func testStructuralValidation() {
        XCTAssertThrowsError(
            try ForecastEngine.run(ForecastRequest(
                startDate: Day(isoString: "2026-09-30")!,
                endDate: Day(isoString: "2026-09-01")!,
                accounts: [bank],
                startingBalances: ["bnp": euro("0.00")],
                scenario: .base
            ))
        ) { error in
            XCTAssertEqual(error as? ForecastError, .emptyHorizon)
        }

        XCTAssertThrowsError(
            try ForecastEngine.run(ForecastRequest(
                startDate: Day(isoString: "2026-09-01")!,
                endDate: Day(isoString: "2026-09-02")!,
                accounts: [bank],
                startingBalances: [:], // missing balance
                scenario: .base
            ))
        ) { error in
            XCTAssertEqual(error as? ForecastError, .missingBalance(accountID: "bnp"))
        }

        // A MAD debit against a EUR requirement is a structural error, not a
        // silent cross-currency payment.
        XCTAssertThrowsError(
            try ForecastEngine.run(ForecastRequest(
                startDate: Day(isoString: "2026-09-01")!,
                endDate: Day(isoString: "2026-09-02")!,
                accounts: [bank],
                startingBalances: ["bnp": euro("0.00")],
                events: [ForecastEvent(
                    id: "mad-debit",
                    day: Day(isoString: "2026-09-01")!,
                    phase: .scheduledDebit,
                    effect: .debit(Money(exactDecimal: "200.00", currency: .mad)!,
                                   requirement: PaymentRequirement.euroBankPayment())
                )],
                scenario: .base
            ))
        ) { error in
            XCTAssertEqual(error as? ForecastError,
                           .eventCurrencyMismatch(eventID: "mad-debit", expected: "EUR", got: "MAD"))
        }
    }
}
