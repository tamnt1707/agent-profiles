import Foundation
import XCTest
@testable import ClaudeProfilesCore

/// The counters of the tokens must never trap: a broken file of the provider
/// must not take the app down.
final class TokenTotalsTests: XCTestCase {
    func testTheSumOfTheFourCountersNeverTraps() {
        let totals = TokenTotals(input: Int.max, output: Int.max, cacheRead: Int.max, cacheWrite: Int.max)
        XCTAssertEqual(totals.total, Int.max)
    }

    func testAddingTotalsNeverTraps() {
        var totals = TokenTotals(input: Int.max, output: 1, cacheRead: 2, cacheWrite: 3)
        totals += TokenTotals(input: 1, output: 1, cacheRead: 1, cacheWrite: 1)
        XCTAssertEqual(totals.input, Int.max)
        XCTAssertEqual(totals.output, 2)
        XCTAssertEqual(totals.cacheRead, 3)
        XCTAssertEqual(totals.cacheWrite, 4)
        XCTAssertEqual(totals.total, Int.max)
    }

    func testAddingTotalsKeepsTheSmallestNumber() {
        var totals = TokenTotals(input: Int.min)
        totals += TokenTotals(input: -1)
        XCTAssertEqual(totals.input, Int.min)
    }

    func testTheEstimateOfHugeTotalsStaysFinite() throws {
        let totals = TokenTotals(input: Int.max, output: Int.max, cacheRead: Int.max, cacheWrite: Int.max)
        let cost = try XCTUnwrap(UsageCost.estimate(totals, inputPerMillion: 3, outputPerMillion: 15))
        XCTAssertTrue(cost.isFinite)
    }

    func testTheEstimateOfAHugePriceStaysFinite() throws {
        let totals = TokenTotals(input: Int.max)
        let cost = try XCTUnwrap(UsageCost.estimate(totals, inputPerMillion: .greatestFiniteMagnitude, outputPerMillion: 0))
        XCTAssertTrue(cost.isFinite)
    }

    /// The larger of two totals, counter by counter.
    func testMergingTakesTheLargerOfEveryCounter() {
        let first = TokenTotals(input: 10, output: 5, cacheRead: 0, cacheWrite: 1)
        let second = TokenTotals(input: 3, output: 50, cacheRead: 7, cacheWrite: 1)
        let merged = first.merged(with: second)
        XCTAssertEqual(merged, TokenTotals(input: 10, output: 50, cacheRead: 7, cacheWrite: 1))
    }
}
