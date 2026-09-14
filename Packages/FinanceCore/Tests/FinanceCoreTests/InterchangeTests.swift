import XCTest
@testable import FinanceCore

/// Proof #17 — the versioned JSON interchange round-trips deterministically.
final class InterchangeTests: XCTestCase {

    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    private func fixtureData() throws -> Data {
        let url = Bundle.module.url(forResource: "sample-scenario", withExtension: "fixture.json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    func testFixtureDecodesAndIsMarkedAsDevelopmentData() throws {
        let document = try Interchange.decode(try fixtureData())
        XCTAssertEqual(document.schemaVersion, Interchange.currentSchemaVersion)
        XCTAssertTrue(document.documentKind.contains("DEV-FIXTURE"),
                      "the fixture must be clearly marked as development data, not financial evidence")
        XCTAssertEqual(document.accounts.count, 5)
        XCTAssertEqual(document.balances.count, 5)
        XCTAssertEqual(document.transactions.count, 6)
        XCTAssertEqual(document.expectedTransactions.count, 3)
        XCTAssertEqual(document.incomeSources.count, 6)
        XCTAssertEqual(document.installments.count, 4)
        XCTAssertEqual(document.debts.count, 1)

        // Lifecycle and ownership decode as stated: the reversed housing debit
        // decodes with lifecycle "reversed" (its economics are void), and the
        // ownership split lives on the arrival.
        let reversed = document.transactions.first { $0.id == "tx-housing-reversed-2027-02-10" }
        XCTAssertNotNil(reversed)
        XCTAssertEqual(reversed?.lifecycle, .reversed)
        XCTAssertEqual(Economics.totals(for: [reversed!], currency: .eur).economicSpending, euro("0.00"))
        let arrival = document.expectedTransactions.first { $0.id == "pot-arrival" }
        XCTAssertNotNil(arrival)
        XCTAssertEqual(arrival?.incomeSourceID, "inc-trip-pot")
        XCTAssertEqual(arrival?.ownership?.count, 2)
        XCTAssertEqual(document.planning.recurringObligations.count, 5)
        XCTAssertEqual(document.planning.safetyFloor, Money(exactDecimal: "80.00", currency: .eur)!)
        XCTAssertEqual(document.planning.carriedEURValues["pocket-chf"], Money(exactDecimal: "30.00", currency: .eur)!)

        // The fixture's observed facts decode with certainty "received".
        XCTAssertEqual(document.transactions.first?.certainty, .received)
    }

    func testRoundTripPreservesTheDocumentExactly() throws {
        let data = try fixtureData()
        let first = try Interchange.decode(data)
        let reencoded = try Interchange.encode(first)
        let second = try Interchange.decode(reencoded)
        XCTAssertEqual(first, second, "decode → encode → decode must be lossless")
    }

    func testEncodingIsByteDeterministic() throws {
        let document = try Interchange.decode(try fixtureData())
        let once = try Interchange.encode(document)
        let twice = try Interchange.encode(document)
        XCTAssertEqual(once, twice, "identical documents must encode to identical bytes on every machine")

        // And re-encoding a decoded document reproduces the same bytes again.
        let again = try Interchange.encode(try Interchange.decode(once))
        XCTAssertEqual(again, once)
    }

    func testSchemaVersionIsSemver() {
        let parts = Interchange.currentSchemaVersion.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        for part in parts {
            XCTAssertFalse(part.isEmpty)
            XCTAssertTrue(part.allSatisfy(\.isNumber), "version segments must be numeric, got \(part)")
        }
    }

    func testHandBuiltDocumentRoundTrips() throws {
        // A minimal document exercising every collection kind — not just the
        // fixture's shape.
        let document = FinanceDocument(
            schemaVersion: Interchange.currentSchemaVersion,
            documentKind: "hand-built",
            accounts: [
                Account(id: "z-bank", name: "Bank", currency: .eur, kind: .bank, supportedRails: PaymentRail.euroBankRails),
                Account(id: "a-cash", name: "Cash", currency: .mad, kind: .cash, supportedRails: [.physicalCash]),
            ],
            balances: [
                AccountBalance(accountID: "z-bank", balance: Money(exactDecimal: "12.34", currency: .eur)!, asOf: Day(isoString: "2026-09-01")!),
                AccountBalance(accountID: "a-cash", balance: Money(exactDecimal: "250.00", currency: .mad)!, asOf: Day(isoString: "2026-09-01")!),
            ],
            transactions: [
                Transaction(
                    id: "t", date: Day(isoString: "2026-09-02")!, kind: .cashWithdrawal,
                    legs: [
                        AccountLeg(accountID: "z-bank", amount: Money(exactDecimal: "-17.50", currency: .eur)!),
                        AccountLeg(accountID: "a-cash", amount: Money(exactDecimal: "250.00", currency: .mad)!),
                    ],
                    factivity: .observed
                ),
            ],
            expectedTransactions: [],
            incomeSources: [
                IncomeSource(id: "s", name: "S", amount: Money(exactDecimal: "10.00", currency: .eur)!, certainty: .guaranteed,
                             schedule: .monthly(onDay: 5, from: MonthKey(year: 2026, month: 9), through: nil)),
            ],
            installments: [
                InstallmentPlan(
                    id: "plan", provider: "Test", purchaseDescription: "d",
                    purchaseDate: Day(isoString: "2026-09-01")!,
                    originalPurchaseAmount: Money(exactDecimal: "100.00", currency: .eur)!,
                    installments: [Installment(sequence: 1, dueDate: Day(isoString: "2026-10-01")!,
                                               amount: Money(exactDecimal: "100.00", currency: .eur)!)],
                    paymentRequirement: PaymentRequirement.euroBankPayment()
                ),
            ],
            debts: [
                Debt(
                    id: "d", name: "D", originalAmount: Money(exactDecimal: "50.00", currency: .eur)!,
                    paymentSchedule: [ScheduledPayment(day: Day(isoString: "2026-11-01")!,
                                                        amount: Money(exactDecimal: "50.00", currency: .eur)!)],
                    paymentRequirement: PaymentRequirement.euroBankPayment(rails: [.sepaDirectDebit])
                ),
            ],
            planning: FinanceDocument.Planning(
                defaultScenario: .base,
                safetyFloor: Money(exactDecimal: "10.00", currency: .eur)!,
                budgets: [BudgetAllocation(id: "b", name: "B", spendingClass: .flexible,
                                           monthlyAmount: Money(exactDecimal: "90.00", currency: .eur)!,
                                           effectiveFrom: MonthKey(year: 2026, month: 9))],
                recurringObligations: [
                    RecurringObligation(id: "r", name: "R", amount: Money(exactDecimal: "5.00", currency: .eur)!,
                                        spec: .monthly(onDay: 2, from: MonthKey(year: 2026, month: 9), through: nil),
                                        requirement: PaymentRequirement.euroBankPayment(rails: [.sepaDirectDebit]),
                                        spendingClass: .essential),
                ],
                carriedEURValues: ["a-cash": Money(exactDecimal: "17.50", currency: .eur)!]
            )
        )

        let decoded = try Interchange.decode(try Interchange.encode(document))
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.planning.carriedEURValues["a-cash"], Money(exactDecimal: "17.50", currency: .eur)!)
    }
}
