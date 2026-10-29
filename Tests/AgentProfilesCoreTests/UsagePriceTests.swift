import Foundation
import XCTest
@testable import AgentProfilesCore

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

    /// A price that is not a number is dropped: the list of the profiles still
    /// loads, and the next save writes the file without the price.
    func testABrokenPriceIsDropped() throws {
        let json = #"{ "profiles": [ { "name": "A", "slug": "a", "price_input_per_million": "cheap" } ] }"#
        let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertEqual(data.profiles.count, 1)
        XCTAssertNil(data.profiles[0].priceInputPerMillion)
    }

    /// A price that is negative or not finite is dropped as well.
    func testANegativeOrUnfinitePriceIsDropped() throws {
        for value in ["-3", "1e400"] {
            let json = #"{ "profiles": [ { "name": "A", "slug": "a", "price_output_per_million": \#(value) } ] }"#
            let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
            XCTAssertNil(data.profiles[0].priceOutputPerMillion, "the price \(value) must be dropped")
        }
    }

    /// A broken price in the file must not make the whole list fail, and it
    /// must not stop the saves that come after it.
    func testABadPriceInTheFileDoesNotFailTheLoadAndTheSaveStillWorks() throws {
        let json = """
        {
          "terminal": "Terminal",
          "profiles": [
            {
              "name": "A",
              "slug": "a",
              "isolate": true,
              "price_input_per_million": "cheap",
              "price_output_per_million": -3
            }
          ],
          "language": "system",
          "appearance": "system",
          "auto_check_updates": true
        }
        """
        try FileManager.default.createDirectory(at: store.paths.root, withIntermediateDirectories: true)
        try json.write(to: store.paths.dataFile, atomically: false, encoding: .utf8)

        let loaded = store.load()
        XCTAssertNil(loaded.warning)
        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(loaded.data.profiles.count, 1)
        XCTAssertNil(loaded.data.profiles[0].priceInputPerMillion)
        XCTAssertNil(loaded.data.profiles[0].priceOutputPerMillion)

        // The next save writes the file without the broken prices.
        XCTAssertNoThrow(try store.save(loaded.data))
        let text = try String(contentsOf: store.paths.dataFile, encoding: .utf8)
        XCTAssertFalse(text.contains("price_input_per_million"))
        XCTAssertFalse(text.contains("price_output_per_million"))
    }

    // MARK: - The line of the cost

    /// A normal cost is written as money.
    func testANormalCostIsWrittenAsMoney() {
        let english = Locale(identifier: "en")
        XCTAssertEqual(UsageCost.format(12.5, locale: english), "$12.50")
    }

    /// A cost that is too big is written as a dash: a price of 1e300 would
    /// print three hundred digits, and the line would not fit anywhere.
    func testACostThatIsTooBigIsWrittenAsADash() {
        let english = Locale(identifier: "en")
        for value in [1e300, Double.greatestFiniteMagnitude, Double.infinity, Double.nan] {
            let text = UsageCost.format(value, locale: english)
            XCTAssertEqual(text, UsageCost.tooLargeText, "the cost \(value) was written as \(text)")
            XCTAssertLessThan(text.count, 10, "the line of the cost is too long")
        }
    }

    /// The biggest cost that is still written as money.
    func testTheBiggestCostThatIsStillWrittenAsMoney() {
        let english = Locale(identifier: "en")
        let text = UsageCost.format(UsageCost.maximumWrittenCost, locale: english)
        XCTAssertNotEqual(text, UsageCost.tooLargeText)
        XCTAssertEqual(text, "$1,000,000,000.00")
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

    /// The big numbers are read in billions.
    func testCompactTokenCountsInBillions() {
        XCTAssertEqual(TokenFormat.compact(999_499_999), "999M")
        XCTAssertEqual(TokenFormat.compact(999_500_000), "1B")
        XCTAssertEqual(TokenFormat.compact(999_999_999), "1B")
        XCTAssertEqual(TokenFormat.compact(1_000_000_000), "1B")
        XCTAssertEqual(TokenFormat.compact(1_234_567_890), "1.2B")
        XCTAssertEqual(TokenFormat.compact(12_345_678_901), "12B")
    }

    // MARK: - The language of the user

    /// The full number is written the way the language of the user writes it.
    func testTheFullNumberFollowsTheLanguage() {
        XCTAssertEqual(TokenFormat.number(1_234_567, locale: Locale(identifier: "en")), "1,234,567")
        XCTAssertEqual(TokenFormat.number(1_234_567, locale: Locale(identifier: "vi")), "1.234.567")
    }

    /// The cost is money, written the way the language of the user writes it.
    func testTheCostIsMoneyInTheLanguageOfTheUser() {
        let english = UsageCost.format(1234.56, locale: Locale(identifier: "en"))
        XCTAssertTrue(english.contains("1,234.56"), english)
        XCTAssertTrue(english.contains("$"), english)

        let vietnamese = UsageCost.format(1234.56, locale: Locale(identifier: "vi"))
        XCTAssertTrue(vietnamese.contains("1.234,56"), vietnamese)
    }
}
