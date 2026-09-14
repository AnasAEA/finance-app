import XCTest
@testable import FinanceCore

/// Defect D5 — explicit ownership splits must satisfy
/// `sum(shares) == economic amount`, exactly, in exact integer arithmetic.
/// Under-allocation, over-allocation and wrong-currency splits are malformed
/// financial data and are rejected at construction and at decode.
final class OwnershipSplitValidationTests: XCTestCase {

    private func euro(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .eur)!
    }

    private func dirham(_ decimal: String) -> Money {
        Money(exactDecimal: decimal, currency: .mad)!
    }

    private func day(_ iso: String) -> Day {
        Day(isoString: iso)!
    }

    private func arrivalLegs(_ gross: String) -> [AccountLeg] {
        [AccountLeg(accountID: "pocket", amount: euro(gross))]
    }

    private let exactSplit = { () -> [OwnershipSplit] in
        [
            OwnershipSplit(ownerID: "holder", isSelf: true, amount: Money(exactDecimal: "800.00", currency: .eur)!),
            OwnershipSplit(ownerID: "co-resident", isSelf: false, amount: Money(exactDecimal: "800.00", currency: .eur)!),
        ]
    }()

    // MARK: - The mandated case matrix

    func testExact800Plus800IsValid() {
        XCTAssertNil(OwnershipValidation.validationProblem(splits: exactSplit, legs: arrivalLegs("1600.00")))
        // And a fully-constructed transaction is accepted.
        let transaction = Transaction(
            id: "ok", date: day("2026-09-16"), kind: .passThrough,
            legs: arrivalLegs("1600.00"), ownership: exactSplit,
            factivity: .expected
        )
        XCTAssertEqual(Economics.ownedShare(of: transaction, currency: .eur), euro("800.00"))
    }

    func testUnderAllocation700Plus800IsRejected() {
        let splits = [
            OwnershipSplit(ownerID: "holder", isSelf: true, amount: euro("700.00")),
            OwnershipSplit(ownerID: "co-resident", isSelf: false, amount: euro("800.00")),
        ]
        XCTAssertEqual(
            OwnershipValidation.validationProblem(splits: splits, legs: arrivalLegs("1600.00")),
            .underAllocation(allocated: euro("1500.00"), base: euro("1600.00")),
            "1500 of ownership against a 1600 movement leaves 100 ownerless — rejected, never normalized"
        )
    }

    func testOverAllocation800Plus900IsRejected() {
        let splits = [
            OwnershipSplit(ownerID: "holder", isSelf: true, amount: euro("800.00")),
            OwnershipSplit(ownerID: "co-resident", isSelf: false, amount: euro("900.00")),
        ]
        XCTAssertEqual(
            OwnershipValidation.validationProblem(splits: splits, legs: arrivalLegs("1600.00")),
            .overAllocation(allocated: euro("1700.00"), base: euro("1600.00")),
            "1700 of ownership against a 1600 movement invents 100 out of thin air — rejected"
        )
    }

    func testCurrencyMismatchIsRejected() {
        let splits = [
            OwnershipSplit(ownerID: "holder", isSelf: true, amount: euro("800.00")),
            OwnershipSplit(ownerID: "co-resident", isSelf: false, amount: dirham("800.00")),
        ]
        XCTAssertEqual(
            OwnershipValidation.validationProblem(splits: splits, legs: arrivalLegs("1600.00")),
            .currencyMismatch(splitCurrency: "MAD", baseCurrency: "EUR")
        )
    }

    func testSplitsOnAnOutflowOnlyTransactionAreRejected() {
        // A disposal must not carry ownership: its economic base is zero, so
        // any positive split is an over-allocation.
        let legs = [AccountLeg(accountID: "bnp", amount: euro("-800.00"))]
        XCTAssertEqual(
            OwnershipValidation.validationProblem(splits: exactSplit, legs: legs),
            .overAllocation(allocated: euro("1600.00"), base: euro("0.00"))
        )
    }

    // Negative/zero shares are rejected structurally by `OwnershipSplit.init`
    // (a precondition on positive magnitudes) — a trap, not a catchable
    // error, so they cannot appear in any test-constructed or decoded split.

    // MARK: - Interchange: untrusted input throws instead of trapping

    func testDecodeRejectsUnderAllocatedOwnership() throws {
        let json = """
        {
          "id" : "bad-arrival",
          "date" : "2026-09-16",
          "kind" : "passThrough",
          "legs" : [ { "accountID" : "pocket", "amount" : "1600.00 EUR" } ],
          "ownership" : [
            { "ownerID" : "holder", "isSelf" : true, "amount" : "700.00 EUR" },
            { "ownerID" : "co-resident", "isSelf" : false, "amount" : "800.00 EUR" }
          ],
          "factivity" : "expected",
          "provenance" : { "source" : "DEV-FIXTURE", "evidenceGrade" : "unresolved" }
        }
        """
        XCTAssertThrowsError(try legacyMoneyDecoder().decode(Transaction.self, from: Data(json.utf8))) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("expected dataCorrupted, got \(error)")
            }
        }
    }

    func testDecodeRejectsOverAllocatedOwnership() {
        let json = """
        {
          "id" : "bad-arrival",
          "date" : "2026-09-16",
          "kind" : "passThrough",
          "legs" : [ { "accountID" : "pocket", "amount" : "1600.00 EUR" } ],
          "ownership" : [
            { "ownerID" : "holder", "isSelf" : true, "amount" : "800.00 EUR" },
            { "ownerID" : "co-resident", "isSelf" : false, "amount" : "900.00 EUR" }
          ],
          "factivity" : "expected",
          "provenance" : { "source" : "DEV-FIXTURE", "evidenceGrade" : "unresolved" }
        }
        """
        XCTAssertThrowsError(try legacyMoneyDecoder().decode(Transaction.self, from: Data(json.utf8)))
    }

    // MARK: - The conservative default: no split means nothing is mine

    func testUnsplitPassThroughContributesZeroPersonalIncome() {
        // A pass-through with no explicit ownership statement is 0% mine —
        // a temporary bank balance must never become income by default.
        let transaction = Transaction(
            id: "stranger", date: day("2026-09-16"), kind: .passThrough,
            legs: arrivalLegs("1600.00"),
            factivity: .observed
        )
        let effect = Economics.effect(of: transaction, currency: .eur)
        XCTAssertEqual(effect.income, euro("0.00"))
        XCTAssertEqual(effect.passThroughNotMine, euro("1600.00"))
        XCTAssertEqual(Economics.totals(for: [transaction], currency: .eur).personalIncome, euro("0.00"))
    }
}
