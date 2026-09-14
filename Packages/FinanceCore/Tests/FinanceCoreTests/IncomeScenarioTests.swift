import XCTest
@testable import FinanceCore

/// Proofs #9–#11 — the income-certainty ladder and scenario semantics:
/// a TARGET job is not guaranteed income, POSSIBLE aid is not BASE cash, and
/// RECEIVED facts are scenario-independent.
final class IncomeScenarioTests: XCTestCase {

    private func engineReadySources() -> [IncomeSource] {
        [
            IncomeSource(
                id: "recv-scholarship",
                name: "Already-received scholarship payment",
                amount: Money(exactDecimal: "50.00", currency: .eur)!,
                certainty: .received,
                schedule: .oneShot(on: Day(isoString: "2026-09-10")!),
                arrivesOnAccount: "bnp"
            ),
            IncomeSource(
                id: "guar-grant",
                name: "Contractually secured grant",
                amount: Money(exactDecimal: "100.00", currency: .eur)!,
                certainty: .guaranteed,
                schedule: .oneShot(on: Day(isoString: "2026-09-20")!),
                arrivesOnAccount: "bnp"
            ),
            IncomeSource(
                id: "exp-parents",
                name: "Planned parental support",
                amount: Money(exactDecimal: "800.00", currency: .eur)!,
                certainty: .expected,
                schedule: .oneShot(on: Day(isoString: "2026-09-16")!),
                arrivesOnAccount: "bnp"
            ),
            IncomeSource(
                id: "tgt-student-job",
                name: "Student job (unsigned)",
                amount: Money(exactDecimal: "253.00", currency: .eur)!,
                certainty: .target,
                schedule: .oneShot(on: Day(isoString: "2026-09-25")!),
                arrivesOnAccount: "bnp"
            ),
            IncomeSource(
                id: "pos-crous",
                name: "CROUS emergency aid",
                amount: Money(exactDecimal: "300.00", currency: .eur)!,
                certainty: .possible,
                schedule: .oneShot(on: Day(isoString: "2026-09-28")!),
                arrivesOnAccount: "bnp"
            ),
        ]
    }

    private func request(scenario: Scenario, policy: ScenarioPolicy? = nil, sources: [IncomeSource]) -> ForecastRequest {
        ForecastRequest(
            startDate: Day(isoString: "2026-09-01")!,
            endDate: Day(isoString: "2026-09-30")!,
            accounts: [Account(id: "bnp", name: "Bank", currency: .eur, kind: .bank, supportedRails: PaymentRail.euroBankRails)],
            startingBalances: ["bnp": Money(exactDecimal: "0.00", currency: .eur)!],
            incomeSources: sources,
            scenario: scenario,
            policy: policy
        )
    }

    /// Proof 9: TARGET income does not enter the GUARANTEED forecast.
    func testTargetIncomeExcludedFromGuaranteed() {
        let result = try! ForecastEngine.run(request(scenario: .guaranteed, sources: engineReadySources()))
        XCTAssertFalse(result.includedIncomeEventIDs.contains("tgt-student-job"))
        XCTAssertTrue(result.excludedIncomeEventIDs.contains("tgt-student-job"))
        // GUARANTEED keeps only secured + received.
        XCTAssertEqual(result.includedIncomeEventIDs, ["guar-grant", "recv-scholarship"])

        // And in BASE too: a target is a target, not a realistic plan.
        let base = try! ForecastEngine.run(request(scenario: .base, sources: engineReadySources()))
        XCTAssertFalse(base.includedIncomeEventIDs.contains("tgt-student-job"))
        // UPSIDE is where the intended job may be explored.
        let upside = try! ForecastEngine.run(request(scenario: .upside, sources: engineReadySources()))
        XCTAssertTrue(upside.includedIncomeEventIDs.contains("tgt-student-job"))
    }

    /// Proof 10: POSSIBLE income does not enter BASE unless explicitly allowed.
    func testPossibleIncomeExcludedFromBaseByDefault() {
        let base = try! ForecastEngine.run(request(scenario: .base, sources: engineReadySources()))
        XCTAssertFalse(base.includedIncomeEventIDs.contains("pos-crous"))
        XCTAssertTrue(base.excludedIncomeEventIDs.contains("pos-crous"))
        XCTAssertEqual(base.projectedEndBalance, Money(exactDecimal: "950.00", currency: .eur)!) // 50 + 100 + 800

        // Not even UPSIDE includes it implicitly.
        let upside = try! ForecastEngine.run(request(scenario: .upside, sources: engineReadySources()))
        XCTAssertFalse(upside.includedIncomeEventIDs.contains("pos-crous"))

        // An explicit policy may opt in — and only then does it become cash.
        let allowed = try! ForecastEngine.run(
            request(scenario: .base, policy: ScenarioPolicy(minimumCertainty: .expected, includesPossible: true), sources: engineReadySources())
        )
        XCTAssertTrue(allowed.includedIncomeEventIDs.contains("pos-crous"))
        XCTAssertEqual(allowed.projectedEndBalance, Money(exactDecimal: "1250.00", currency: .eur)!) // 950 + 300
    }

    /// Proof 11: RECEIVED facts are scenario-independent.
    func testReceivedIncomeEntersEveryScenarioIdentically() {
        for scenario in Scenario.allCases {
            let result = try! ForecastEngine.run(request(scenario: scenario, sources: engineReadySources()))
            XCTAssertTrue(result.includedIncomeEventIDs.contains("recv-scholarship"),
                          "received money is a fact in \(scenario)")
            XCTAssertFalse(result.excludedIncomeEventIDs.contains("recv-scholarship"))
            // The received event is on day 10 — its balance shows in every scenario.
            let day10 = result.dailyBalances.first { $0.day == Day(isoString: "2026-09-10")! }!
            XCTAssertEqual(day10.spendablePool, Money(exactDecimal: "50.00", currency: .eur)!)
        }
    }

    func testScenarioPolicyOrdering() {
        // The ladder is totally ordered.
        XCTAssertTrue(IncomeCertainty.possible < IncomeCertainty.target)
        XCTAssertTrue(IncomeCertainty.target < IncomeCertainty.expected)
        XCTAssertTrue(IncomeCertainty.expected < IncomeCertainty.guaranteed)
        XCTAssertTrue(IncomeCertainty.guaranteed < IncomeCertainty.received)

        // Default policies of the three named scenarios.
        XCTAssertTrue(Scenario.guaranteed.defaultPolicy.includes(.guaranteed))
        XCTAssertFalse(Scenario.guaranteed.defaultPolicy.includes(.expected))
        XCTAssertTrue(Scenario.base.defaultPolicy.includes(.expected))
        XCTAssertFalse(Scenario.base.defaultPolicy.includes(.target))
        XCTAssertTrue(Scenario.upside.defaultPolicy.includes(.target))
        XCTAssertFalse(Scenario.upside.defaultPolicy.includes(.possible))
        // Every policy includes received facts.
        for scenario in Scenario.allCases {
            XCTAssertTrue(scenario.defaultPolicy.includes(.received))
        }
    }
}
