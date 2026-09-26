import XCTest
@testable import FinanceCore

final class AllocationHardeningTests: XCTestCase {
    func testUnequalRatiosUseLargestRemainders() {
        XCTAssertEqual(Money(minorUnits: 1, currency: .eur).allocated(ratios: [1, 2]).map(\.minorUnits), [0, 1])
        XCTAssertEqual(Money(minorUnits: -1, currency: .eur).allocated(ratios: [1, 2]).map(\.minorUnits), [0, -1])
        XCTAssertEqual(Money(minorUnits: 2, currency: .eur).allocated(ratios: [1, 1, 1]).map(\.minorUnits), [1, 1, 0])
    }
    func testFullWidthAllocationConservesExtremes() {
        for amount in [Int64.max, Int64.min] {
            let parts = Money(minorUnits: amount, currency: .eur).allocated(ratios: [Int.max - 1, 1])
            XCTAssertEqual(parts.reduce(Int64(0)) { $0 + $1.minorUnits }, amount)
        }
    }
    func testRoundingNearMaximumDoesNotOverflow() {
        XCTAssertEqual(roundDivide(Int64.max - 1, by: Int64.max, rule: .halfUp), 1)
        XCTAssertEqual(roundDivide(-(Int64.max - 1), by: Int64.max, rule: .halfEven), -1)
    }
    func testOwnershipRejectsOverflowWithoutTrapping() {
        let splits = [OwnershipSplit(ownerID: "a", isSelf: true, amount: Money(minorUnits: Int64.max, currency: .eur)), OwnershipSplit(ownerID: "b", isSelf: false, amount: Money(minorUnits: 1, currency: .eur))]
        XCTAssertThrowsError(try OwnershipValidation.validate(splits: splits, against: Money(minorUnits: Int64.max, currency: .eur)))
    }
}
