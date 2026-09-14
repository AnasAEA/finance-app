import XCTest
@testable import FinanceCore

/// Phase 2.7 — interchange persistence of planned purchases and sinking funds.
///
/// Fixtures are synthetic. Nothing here is anybody's financial data.
final class PlanningPersistenceTests: XCTestCase {

    private func euro(_ decimal: String) -> Money { Money(exactDecimal: decimal, currency: .eur)! }
    private func day(_ iso: String) -> Day { Day(isoString: iso)! }

    private let bank = Account(
        id: "bnp", name: "Bank", currency: .eur, kind: .bank,
        supportedRails: PaymentRail.euroBankRails
    )

    private func document(
        version: String = Interchange.currentSchemaVersion,
        purchases: [PlannedPurchase] = [],
        funds: [SinkingFund] = [],
        installments: [InstallmentPlan] = [],
        budgets: [BudgetAllocation] = []
    ) -> FinanceDocument {
        FinanceDocument(
            schemaVersion: version,
            documentKind: "TEST",
            accounts: [bank],
            balances: [AccountBalance(accountID: "bnp", balance: euro("100.00"), asOf: day("2026-09-01"))],
            installments: installments,
            planning: FinanceDocument.Planning(
                budgets: budgets,
                plannedPurchases: purchases,
                sinkingFunds: funds
            )
        )
    }

    private func purchase(
        id: String,
        funding: PlannedPurchaseFunding = .cashOnPurchase,
        reserved: String = "0.00",
        status: PlannedPurchaseStatus = .planned,
        installmentPlanID: String? = nil,
        budgetID: String? = nil
    ) -> PlannedPurchase {
        PlannedPurchase(
            id: id,
            name: id,
            targetAmount: euro("90.00"),
            status: status,
            funding: funding,
            reservedAmount: euro(reserved),
            installmentPlanID: installmentPlanID,
            budgetID: budgetID,
            requirement: .euroBankPayment()
        )
    }

    private func fund(
        id: String,
        reserved: String = "10.00",
        custody: SinkingFundCustody = .virtualReservation,
        goalID: String? = nil
    ) -> SinkingFund {
        SinkingFund(
            id: id,
            name: id,
            goalID: goalID,
            targetAmount: euro("90.00"),
            reservedAmount: euro(reserved),
            custody: custody
        )
    }

    func testOlderDocumentsDecodeWithEmptyPlanningTables() throws {
        let json = """
        {"schemaVersion":"1.5.0","documentKind":"TEST","accounts":[{"id":"bnp","name":"Bank","currency":"EUR","kind":"bank","supportedRails":["sepa_credit_transfer"],"isActive":true,"drawOrder":0}],"balances":[{"accountID":"bnp","balance":"1.00 EUR","asOf":"2026-09-01","status":"observed"}],"transactions":[],"expectedTransactions":[],"incomeSources":[],"installments":[],"debts":[],"planning":{"budgets":[],"recurringObligations":[],"carriedEURValues":[]}}
        """.data(using: .utf8)!
        let decoded = try Interchange.decode(json)
        XCTAssertEqual(decoded.schemaVersion, "1.5.0")
        XCTAssertTrue(decoded.planning.plannedPurchases.isEmpty)
        XCTAssertTrue(decoded.planning.sinkingFunds.isEmpty)
    }

    func testNonEmptyPlanningPromotesWireCopyTo1_6() throws {
        let value = document(version: "1.5.0", purchases: [purchase(id: "p1")], funds: [])
        XCTAssertEqual(try Interchange.decode(Interchange.encode(value)).schemaVersion, "1.6.0")
        XCTAssertEqual(value.schemaVersion, "1.5.0")
        // Which error, not merely that one occurred: production still refuses
        // durable planning state on a version that cannot represent it, and
        // that case is the only thing distinguishing this from any other
        // planning refusal.
        XCTAssertThrowsError(try PlanningValidation.validate(value)) { error in
            XCTAssertEqual(
                error as? PlanningValidationError,
                .schemaVersionTooOldForPlanningState(found: "1.5.0")
            )
        }
    }

    func testShuffledPurchaseAndFundOrderEncodesIdentically() throws {
        let purchases = [purchase(id: "z-goal"), purchase(id: "a-goal")]
        let funds = [fund(id: "z-fund"), fund(id: "a-fund")]
        let forward = document(purchases: purchases, funds: funds)
        let reversed = document(purchases: purchases.reversed(), funds: funds.reversed())
        XCTAssertEqual(try Interchange.encode(forward), try Interchange.encode(reversed))
        let decoded = try Interchange.decode(try Interchange.encode(forward))
        XCTAssertEqual(decoded.planning.plannedPurchases.map(\.id), ["a-goal", "z-goal"])
        XCTAssertEqual(decoded.planning.sinkingFunds.map(\.id), ["a-fund", "z-fund"])
    }

    func testSinkingFundedPurchaseMustNotCarryItsOwnReservation() {
        let document = document(
            purchases: [purchase(id: "p", funding: .sinkingFund(id: "sf"), reserved: "10.00")],
            funds: [fund(id: "sf")]
        )
        XCTAssertThrowsError(try Interchange.encode(document)) { error in
            XCTAssertEqual(
                error as? PlanningValidationError,
                .sinkingFundedPurchaseCarriesOwnReservation(purchaseID: "p")
            )
        }
    }

    func testMissingFundReferenceIsRejected() {
        let document = document(purchases: [purchase(id: "p", funding: .sinkingFund(id: "missing"))])
        XCTAssertThrowsError(try Interchange.encode(document)) { error in
            XCTAssertEqual(
                error as? PlanningValidationError,
                .purchaseReferencesMissingFund(purchaseID: "p", fundID: "missing")
            )
        }
    }

    func testDedicatedFundRequiresMatchingAccount() {
        let missing = document(funds: [
            fund(id: "sf", custody: .dedicatedAccount(accountID: "nope"))
        ])
        XCTAssertThrowsError(try Interchange.encode(missing))

        let madCash = Account(
            id: "cash-mad", name: "MAD", currency: .mad, kind: .cash,
            supportedRails: [.physicalCash]
        )
        var mismatch = document(funds: [
            fund(id: "sf", custody: .dedicatedAccount(accountID: "cash-mad"))
        ])
        mismatch.accounts.append(madCash)
        mismatch.balances.append(
            AccountBalance(accountID: "cash-mad", balance: Money(exactDecimal: "1.00", currency: .mad)!, asOf: day("2026-09-01"))
        )
        XCTAssertThrowsError(try Interchange.encode(mismatch)) { error in
            XCTAssertEqual(
                error as? PlanningValidationError,
                .dedicatedFundAccountCurrencyMismatch(fundID: "sf")
            )
        }
    }

    func testNegativeReservedAmountIsRejected() {
        let document = document(funds: [
            SinkingFund(
                id: "sf", name: "sf", targetAmount: euro("10.00"),
                reservedAmount: Money(minorUnits: -1, currency: .eur)
            )
        ])
        XCTAssertThrowsError(try Interchange.encode(document)) { error in
            XCTAssertEqual(error as? PlanningValidationError, .negativeReservedAmount(id: "sf"))
        }
    }

    func testFinancingMayNameAnExistingPlanAndMustNotInventOne() throws {
        let plan = InstallmentPlan(
            id: "plan", provider: "Test", purchaseDescription: "d",
            originalPurchaseAmount: euro("100.00"),
            installments: [
                Installment(sequence: 1, dueDate: day("2026-10-01"), amount: euro("100.00"))
            ],
            paymentRequirement: .euroBankPayment()
        )
        let ok = document(
            purchases: [purchase(id: "p", funding: .financing, installmentPlanID: "plan")],
            installments: [plan]
        )
        XCTAssertNoThrow(try Interchange.encode(ok))

        let missing = document(
            purchases: [purchase(id: "p", funding: .financing, installmentPlanID: "nope")]
        )
        XCTAssertThrowsError(try Interchange.encode(missing))
    }

    func testEmptyPlanningOn1_5RoundTripsWithoutUpgrade() throws {
        var document = document(version: "1.5.0")
        document.schemaVersion = "1.5.0"
        let decoded = try Interchange.decode(try Interchange.encode(document))
        XCTAssertEqual(decoded.schemaVersion, "1.5.0")
        XCTAssertTrue(decoded.planning.plannedPurchases.isEmpty)
    }
}
