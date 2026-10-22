import Foundation
import XCTest
@testable import ClaudeProfilesCore

final class UsagePriceTests: XCTestCase {
    private var temp: TempDirectory!
    private var store: Store!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        store = Store(paths: temp.paths(), keys: InMemoryKeyStore())
    }

    override func tearDown() {
        temp = nil
        store = nil
    }

    // MARK: - Estimate

    func testTheEstimateNeedsBothPrices() {
        let totals = TokenTotals(input: 1_000_000)
        XCTAssertNil(UsageCost.estimate(totals, inputPerMillion: 3, outputPerMillion: nil))
        XCTAssertNil(UsageCost.estimate(totals, inputPerMillion: nil, outputPerMillion: 15))
        XCTAssertNil(UsageCost.estimate(totals, inputPerMillion: nil, outputPerMillion: nil))
    }

    func testTheEstimatePricesCacheAsInput() throws {
        // 1M input + 1M cache read + 1M cache write are priced at 3 per million; 0.5M output at 15.
        let totals = TokenTotals(input: 1_000_000, output: 500_000, cacheRead: 1_000_000, cacheWrite: 1_000_000)
        let cost = try XCTUnwrap(UsageCost.estimate(totals, inputPerMillion: 3, outputPerMillion: 15))
        XCTAssertEqual(cost, 9 + 7.5, accuracy: 1e-9)
    }

    func testAZeroPriceGivesZeroCost() throws {
        let totals = TokenTotals(input: 500, output: 500)
        XCTAssertEqual(try XCTUnwrap(UsageCost.estimate(totals, inputPerMillion: 0, outputPerMillion: 0)), 0, accuracy: 0)
    }

    // MARK: - Validation

    func testOnlyFiniteNonNegativePricesAreValid() {
        XCTAssertTrue(UsageCost.isValidPrice(nil))
        XCTAssertTrue(UsageCost.isValidPrice(0))
        XCTAssertTrue(UsageCost.isValidPrice(2.5))
        XCTAssertFalse(UsageCost.isValidPrice(-0.01))
        XCTAssertFalse(UsageCost.isValidPrice(.nan))
        XCTAssertFalse(UsageCost.isValidPrice(.infinity))
        XCTAssertFalse(UsageCost.isValidPrice(-.infinity))
    }

    func testTheStoreRejectsABadPriceOnTheInputOrTheOutput() {
        let bad: [Double] = [-1, .nan, .infinity]
        for value in bad {
            var input = Profile.sample()
            input.priceInputPerMillion = value
            XCTAssertThrowsError(try store.validate(input, others: [])) { error in
                XCTAssertEqual(error as? ProfileError, .invalidPrice)
            }
            var output = Profile.sample()
            output.priceOutputPerMillion = value
            XCTAssertThrowsError(try store.validate(output, others: [])) { error in
                XCTAssertEqual(error as? ProfileError, .invalidPrice)
            }
        }
    }

    func testTheStoreAcceptsUnsetAndValidPrices() throws {
        XCTAssertNoThrow(try store.validate(Profile.sample(), others: []))
        var priced = Profile.sample()
        priced.priceInputPerMillion = 0
        priced.priceOutputPerMillion = 15.75
        XCTAssertNoThrow(try store.validate(priced, others: []))
    }

    // MARK: - Storage

    func testPricesSurviveAWriteAndALoad() throws {
        var priced = Profile.sample()
        priced.priceInputPerMillion = 3.5
        priced.priceOutputPerMillion = 15
        try store.save(AppData(profiles: [priced]))

        let loaded = store.load()
        XCTAssertNil(loaded.warning)
        XCTAssertEqual(loaded.data.profiles, [priced])

        let text = try String(contentsOf: store.paths.dataFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"price_input_per_million\": 3.5"))
        XCTAssertTrue(text.contains("\"price_output_per_million\": 15.0"))
    }

    /// A profiles.json written by the app before prices existed loads, and writing it again changes nothing.
    func testAnOldFileWithoutPriceFieldsLoadsAndIsWrittenIdentically() throws {
        let old = """
        {
          "terminal": "Terminal",
          "profiles": [
            {
              "name": "Test",
              "slug": "test",
              "base_url": "https://example.com/anthropic",
              "auth": "Bearer",
              "model": "m-1",
              "opus_model": "",
              "sonnet_model": "",
              "haiku_model": "",
              "extra_env": "API_TIMEOUT_MS=600000",
              "workdir": "",
              "isolate": true,
              "share_from_default": false
            }
          ],
          "language": "system",
          "appearance": "system",
          "auto_check_updates": true
        }
        """
        try FileManager.default.createDirectory(at: store.paths.root, withIntermediateDirectories: true)
        try old.write(to: store.paths.dataFile, atomically: false, encoding: .utf8)

        let loaded = store.load()
        XCTAssertNil(loaded.warning)
        XCTAssertEqual(loaded.data.profiles.count, 1)
        XCTAssertNil(loaded.data.profiles[0].priceInputPerMillion)
        XCTAssertNil(loaded.data.profiles[0].priceOutputPerMillion)

        try store.save(loaded.data)
        XCTAssertEqual(try String(contentsOf: store.paths.dataFile, encoding: .utf8), old)
    }

    func testAPriceMustBeANumber() {
        let json = #"{ "profiles": [ { "name": "A", "slug": "a", "price_input_per_million": "cheap" } ] }"#
        XCTAssertThrowsError(try JSONDecoder().decode(AppData.self, from: Data(json.utf8)))
    }

    // MARK: - Compact numbers

    func testCompactTokenCounts() {
        XCTAssertEqual(TokenFormat.compact(0), "0")
        XCTAssertEqual(TokenFormat.compact(850), "850")
        XCTAssertEqual(TokenFormat.compact(1_000), "1K")
        XCTAssertEqual(TokenFormat.compact(1_234), "1.2K")
        XCTAssertEqual(TokenFormat.compact(12_345), "12K")
        XCTAssertEqual(TokenFormat.compact(850_000), "850K")
        XCTAssertEqual(TokenFormat.compact(999_499), "999K")
        XCTAssertEqual(TokenFormat.compact(999_500), "1M")
        XCTAssertEqual(TokenFormat.compact(1_000_000), "1M")
        XCTAssertEqual(TokenFormat.compact(1_234_567), "1.2M")
        XCTAssertEqual(TokenFormat.compact(12_345_678), "12M")
    }
}
