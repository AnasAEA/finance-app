import XCTest
@testable import FinanceCore

/// Planning detail: `CommitmentStatus` gating,
/// `dependsOn` certainty propagation, and zero-amount tracked income streams.
final class PlanningDetailTests: XCTestCase {

    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    private func day(_ iso: String) -> Day {
        Day(isoString: iso)!
    }

    private let bank = Account(id: "bnp", name: "Bank", currency: .eur, kind: .bank, supportedRails: PaymentRail.euroBankRails)

    private func compose(_ document: FinanceDocument, from: String = "2026-09-01", to: String = "2026-12-31") -> ForecastRequest {
        ForecastComposer.makeRequest(from: document, startDate: day(from), endDate: day(to), scenario: .base)
    }

    // MARK: - CommitmentStatus: hypothetical never becomes committed

    func testHypotheticalObligationNeverBecomesACommittedOutflow() {
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "hand-built",
            accounts: [bank],
            balances: [AccountBalance(accountID: "bnp", balance: euro("100.00"), asOf: day("2026-09-01"))],
            planning: FinanceDocument.Planning(
                recurringObligations: [
                    RecurringObligation(
                        id: "real-rent", name: "Rent", amount: euro("480.00"),
                        spec: .monthly(onDay: 11, from: MonthKey(year: 2026, month: 9), through: nil),
                        requirement: PaymentRequirement.euroBankPayment(rails: [.sepaDirectDebit]),
                        spendingClass: .essential
                    ),
                    RecurringObligation(
                        id: "maybe-gym", name: "Hypothetical gym", amount: euro("25.00"),
                        spec: .monthly(onDay: 1, from: MonthKey(year: 2026, month: 9), through: nil),
                        requirement: PaymentRequirement.euroBankPayment(),
                        spendingClass: .flexible,
                        commitmentStatus: .hypothetical
                    ),
                ]
            )
        )
        let request = compose(document)
        XCTAssertTrue(request.events.contains { $0.sourceRef == "real-rent" })
        XCTAssertFalse(request.events.contains { $0.id.hasPrefix("maybe-gym") },
                       "a what-if obligation must never drain the committed forecast")
    }

    func testHypotheticalDebtScheduleIsSkippedAndUnscheduledDebtEmitsNothing() {
        // C2 shape one: acknowledged arrears with no agreed schedule.
        let unscheduled = Debt(
            id: "arrears", name: "Rent arrears",
            originalAmount: euro("960.00"),
            paymentSchedule: [],
            paymentRequirement: PaymentRequirement.euroBankPayment(rails: [.sepaDirectDebit])
        )
        // C2 shape two: a *proposed* 4×€218.22 recovery plan — hypothetical.
        let proposed = Debt(
            id: "proposed-plan", name: "Proposed repayment plan",
            originalAmount: euro("960.00"),
            paymentSchedule: (1...4).map { n in
                ScheduledPayment(day: day("2026-10-0\(n)"), amount: euro("218.22"))
            },
            paymentRequirement: PaymentRequirement.euroBankPayment(rails: [.sepaDirectDebit]),
            commitmentStatus: .hypothetical
        )
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "hand-built",
            accounts: [bank],
            balances: [AccountBalance(accountID: "bnp", balance: euro("100.00"), asOf: day("2026-09-01"))],
            debts: [unscheduled, proposed]
        )
        let request = compose(document)
        XCTAssertFalse(request.events.contains { $0.id.hasPrefix("arrears") })
        XCTAssertFalse(request.events.contains { $0.id.hasPrefix("proposed-plan") },
                       "a proposed schedule stays a planning scenario until it is agreed")
        XCTAssertEqual(unscheduled.unscheduledBalance, euro("960.00"))
    }

    // MARK: - dependsOn: certainty propagation

    func testDependsOnPropagatesTheWeakestLink() {
        let job = IncomeSource(
            id: "job", name: "Student job", amount: euro("253.00"), certainty: .target,
            schedule: .monthly(onDay: 5, from: MonthKey(year: 2026, month: 9), through: nil)
        )
        let caf = IncomeSource(
            id: "caf", name: "CAF", amount: euro("190.00"), certainty: .expected,
            schedule: .monthly(onDay: 10, from: MonthKey(year: 2026, month: 9), through: nil),
            dependsOn: ["job"]
        )
        let sources = [job, caf]

        // CAF is "expected", but it cannot exist before the job exists — its
        // effective certainty is the weaker link.
        XCTAssertEqual(caf.effectiveCertainty(in: sources), .target)
        XCTAssertEqual(job.effectiveCertainty(in: sources), .target)
        XCTAssertEqual(caf.certainty, .expected, "the stored certainty is never rewritten")
    }

    func testDependsOnIsTransitiveAndCycleSafe() {
        let a = IncomeSource(
            id: "a", name: "A", amount: euro("1.00"), certainty: .guaranteed,
            schedule: .oneShot(on: day("2026-09-01")), dependsOn: ["b"]
        )
        let b = IncomeSource(
            id: "b", name: "B", amount: euro("1.00"), certainty: .possible,
            schedule: .oneShot(on: day("2026-09-01")), dependsOn: ["a"]
        )
        let c = IncomeSource(
            id: "c", name: "C", amount: euro("1.00"), certainty: .expected,
            schedule: .oneShot(on: day("2026-09-01")), dependsOn: ["b"]
        )
        // a → b → a is a cycle: propagation must terminate.
        XCTAssertEqual(a.effectiveCertainty(in: [a, b, c]), .possible)
        XCTAssertEqual(c.effectiveCertainty(in: [a, b, c]), .possible,
                       "transitively, C rides on a possible resource")
        // Unknown dependency ids are ignored, not fatal.
        XCTAssertEqual(c.effectiveCertainty(in: [c]), c.certainty)
    }

    func testDependsOnScenariosFilterThroughTheWeakLink() throws {
        let job = IncomeSource(
            id: "job", name: "Student job", amount: euro("253.00"), certainty: .target,
            schedule: .monthly(onDay: 5, from: MonthKey(year: 2026, month: 10), through: nil)
        )
        let caf = IncomeSource(
            id: "caf", name: "CAF", amount: euro("190.00"), certainty: .expected,
            schedule: .monthly(onDay: 10, from: MonthKey(year: 2026, month: 10), through: nil),
            dependsOn: ["job"]
        )
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "hand-built",
            accounts: [bank],
            balances: [AccountBalance(accountID: "bnp", balance: euro("100.00"), asOf: day("2026-09-01"))],
            incomeSources: [job, caf]
        )

        // BASE (minimum .expected) excludes the job (target) — and CAF with
        // it, even though CAF's own certainty is expected: its effective
        // certainty is target because the job does not exist yet.
        let base = try ForecastEngine.run(compose(document, from: "2026-10-01", to: "2026-10-31"))
        XCTAssertTrue(base.excludedIncomeEventIDs.contains("caf"))
        XCTAssertFalse(base.includedIncomeEventIDs.contains("caf"))

        // UPSIDE (minimum .target) admits both.
        let upside = try ForecastEngine.run(
            ForecastComposer.makeRequest(from: document, startDate: day("2026-10-01"), endDate: day("2026-10-31"), scenario: .upside)
        )
        XCTAssertTrue(upside.includedIncomeEventIDs.contains("caf"))
        XCTAssertTrue(upside.includedIncomeEventIDs.contains("job"))
    }

    // MARK: - Zero-amount tracked income streams

    func testZeroAmountIncomeStreamIsTrackedButSilent() throws {
        // The electricity reimbursement / chèque énergie: real, tracked, and
        // €0 until a real amount is known. It must never appear as included
        // *or* excluded income, and never emit an event.
        let electricity = IncomeSource(
            id: "elec", name: "Electricity reimbursement", amount: euro("0.00"),
            certainty: .guaranteed,
            schedule: .monthly(onDay: 15, from: MonthKey(year: 2026, month: 9), through: nil)
        )
        let paid = IncomeSource(
            id: "internship", name: "Internship", amount: euro("292.50"), certainty: .expected,
            schedule: .monthly(onDay: 5, from: MonthKey(year: 2026, month: 9), through: nil)
        )
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "hand-built",
            accounts: [bank],
            balances: [AccountBalance(accountID: "bnp", balance: euro("100.00"), asOf: day("2026-09-01"))],
            incomeSources: [electricity, paid]
        )
        let result = try ForecastEngine.run(compose(document))
        XCTAssertTrue(result.includedIncomeEventIDs.contains("internship"))
        XCTAssertFalse(result.includedIncomeEventIDs.contains("elec"))
        XCTAssertFalse(result.excludedIncomeEventIDs.contains("elec"),
                       "a €0 stream is not 'excluded by policy' — it has nothing to add")
        XCTAssertFalse(result.appliedEvents.contains { $0.sourceRef == "elec" })
    }

    // MARK: - Interchange of the new planning fields

    func testCommitmentStatusDefaultsToCommittedAndOmitsWhenDefault() throws {
        let committed = RecurringObligation(
            id: "r", name: "R", amount: euro("5.00"),
            spec: .monthly(onDay: 2, from: MonthKey(year: 2026, month: 9), through: nil),
            requirement: PaymentRequirement.euroBankPayment(),
            spendingClass: .essential
        )
        XCTAssertEqual(committed.commitmentStatus, .committed)

        // Encoding a committed obligation omits the field entirely…
        let encoder = Interchange.encoder()
        let committedJSON = String(data: try encoder.encode(committed), encoding: .utf8)!
        XCTAssertFalse(committedJSON.contains("commitmentStatus"))

        // …and a 1.0.0 document without the field decodes as committed.
        let legacy = """
        {
          "id" : "r", "name" : "R", "amount" : "5.00 EUR",
          "spec" : { "kind" : "monthly", "day" : 2, "from" : "2026-09", "through" : null },
          "requirement" : { "currency" : "EUR", "rails" : [ "card_debit" ] },
          "spendingClass" : "essential"
        }
        """
        let decoded = try legacyMoneyDecoder().decode(RecurringObligation.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.commitmentStatus, .committed)

        // A hypothetical one round-trips explicitly.
        var hypothetical = committed
        hypothetical.commitmentStatus = .hypothetical
        let roundTripped = try Interchange.decoder().decode(RecurringObligation.self, from: try encoder.encode(hypothetical))
        XCTAssertEqual(roundTripped.commitmentStatus, .hypothetical)
    }
}
