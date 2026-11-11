import Foundation
import XCTest
@testable import AgentProfilesCore

final class CostBudgetTests: XCTestCase {
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

    /// A profile priced at 10 USD per million tokens, both ways, so a million input tokens cost 10.
    private func priced(daily: Double? = nil, monthly: Double? = nil) -> Profile {
        var profile = Profile.sample()
        profile.priceInputPerMillion = 10
        profile.priceOutputPerMillion = 10
        profile.dailyBudgetUSD = daily
        profile.monthlyBudgetUSD = monthly
        return profile
    }

    /// A summary whose day costs `day` USD and whose month costs `month` USD at 10 USD per million.
    private func summary(day: Double, month: Double) -> UsageSummary {
        UsageSummary(
            today: TokenTotals(input: Int(day * 100_000)),
            thisMonth: TokenTotals(input: Int(month * 100_000))
        )
    }

    // MARK: - Levels

    func testTheLevelsChangeAtEightyAndOneHundredPercent() {
        XCTAssertEqual(CostBudget.level(spent: 0, limit: 10), .ok)
        XCTAssertEqual(CostBudget.level(spent: 7.99, limit: 10), .ok)
        XCTAssertEqual(CostBudget.level(spent: 8, limit: 10), .near)
        XCTAssertEqual(CostBudget.level(spent: 9.99, limit: 10), .near)
        XCTAssertEqual(CostBudget.level(spent: 10, limit: 10), .over)
        XCTAssertEqual(CostBudget.level(spent: 500, limit: 10), .over)
    }

    func testBrokenNumbersGiveOk() {
        XCTAssertEqual(CostBudget.level(spent: .nan, limit: 10), .ok)
        XCTAssertEqual(CostBudget.level(spent: .infinity, limit: 10), .ok)
        XCTAssertEqual(CostBudget.level(spent: 5, limit: .nan), .ok)
        XCTAssertEqual(CostBudget.level(spent: 5, limit: .infinity), .ok)
        XCTAssertEqual(CostBudget.level(spent: 5, limit: 0), .ok)
        XCTAssertEqual(CostBudget.level(spent: 5, limit: -3), .ok)
    }

    func testHugeNumbersDoNotTrap() {
        XCTAssertEqual(CostBudget.level(spent: Double.greatestFiniteMagnitude, limit: Double.greatestFiniteMagnitude), .over)
        XCTAssertEqual(CostBudget.level(spent: 1, limit: Double.greatestFiniteMagnitude), .ok)
        XCTAssertEqual(CostBudget.level(spent: Double.greatestFiniteMagnitude, limit: 1), .over)
        XCTAssertEqual(CostBudget.level(spent: 1, limit: Double.leastNonzeroMagnitude), .over)
    }

    func testTheFractionIsAlwaysFinite() {
        let huge = BudgetLimitStatus(limit: Double.leastNonzeroMagnitude, spent: Double.greatestFiniteMagnitude, level: .over)
        XCTAssertTrue(huge.fraction.isFinite)
        XCTAssertEqual(BudgetLimitStatus(limit: 10, spent: 5, level: .ok).fraction, 0.5, accuracy: 1e-12)
        XCTAssertEqual(BudgetLimitStatus(limit: 10, spent: 25, level: .over).fraction, 2.5, accuracy: 1e-12)
    }

    // MARK: - Status of a profile

    func testNoBudgetMeansNoStatus() {
        let status = CostBudget.status(of: priced(), summary: summary(day: 100, month: 1000))
        XCTAssertNil(status.day)
        XCTAssertNil(status.month)
        XCTAssertEqual(status.level, .ok)
    }

    func testNoPricesMeansNoStatusEvenWithABudget() {
        var profile = priced(daily: 1, monthly: 1)
        profile.priceOutputPerMillion = nil
        let status = CostBudget.status(of: profile, summary: summary(day: 100, month: 100))
        XCTAssertEqual(status, BudgetStatus())
        profile.priceOutputPerMillion = 10
        profile.priceInputPerMillion = nil
        XCTAssertEqual(CostBudget.status(of: profile, summary: summary(day: 100, month: 100)), BudgetStatus())
    }

    func testDayAndMonthAreJudgedSeparately() throws {
        let status = CostBudget.status(of: priced(daily: 10, monthly: 100), summary: summary(day: 8, month: 50))
        XCTAssertEqual(try XCTUnwrap(status.day).level, .near)
        XCTAssertEqual(try XCTUnwrap(status.month).level, .ok)
        XCTAssertEqual(try XCTUnwrap(status.day).spent, 8, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(status.month).limit, 100)
        XCTAssertEqual(status.level, .near)

        let over = CostBudget.status(of: priced(daily: 10, monthly: 100), summary: summary(day: 1, month: 100))
        XCTAssertEqual(over.day?.level, .ok)
        XCTAssertEqual(over.month?.level, .over)
        XCTAssertEqual(over.level, .over)
    }

    func testOnlyTheWindowWithALimitIsChecked() {
        let status = CostBudget.status(of: priced(monthly: 10), summary: summary(day: 100, month: 1))
        XCTAssertNil(status.day)
        XCTAssertEqual(status.month?.level, .ok)
    }

    func testAnInvalidLimitIsLeftOut() {
        for bad in [0.0, -1, .nan, .infinity] {
            let status = CostBudget.status(of: priced(daily: bad, monthly: bad), summary: summary(day: 100, month: 100))
            XCTAssertEqual(status, BudgetStatus(), "limit \(bad)")
        }
    }

    func testHugeTokenCountsAndPricesGiveAFiniteStatus() throws {
        var profile = priced(daily: 1, monthly: 1)
        profile.priceInputPerMillion = 1e300
        profile.priceOutputPerMillion = 1e300
        let huge = UsageSummary(today: TokenTotals(input: .max, output: .max), thisMonth: TokenTotals(input: .max))
        let status = CostBudget.status(of: profile, summary: huge)
        XCTAssertEqual(status.day?.level, .over)
        XCTAssertTrue(try XCTUnwrap(status.day).spent.isFinite)
        XCTAssertTrue(try XCTUnwrap(status.month).fraction.isFinite)
    }

    func testTheWorstLevelWins() {
        let near = BudgetStatus(day: BudgetLimitStatus(limit: 10, spent: 9, level: .near), month: nil)
        XCTAssertEqual(near.level, .near)
        let both = BudgetStatus(
            day: BudgetLimitStatus(limit: 10, spent: 9, level: .near),
            month: BudgetLimitStatus(limit: 10, spent: 11, level: .over)
        )
        XCTAssertEqual(both.level, .over)
    }

    // MARK: - Validation and storage

    func testOnlyFiniteLimitsAboveZeroAreValid() {
        XCTAssertTrue(CostBudget.isValidBudget(nil))
        XCTAssertTrue(CostBudget.isValidBudget(0.01))
        XCTAssertTrue(CostBudget.isValidBudget(1e300))
        XCTAssertFalse(CostBudget.isValidBudget(0))
        XCTAssertFalse(CostBudget.isValidBudget(-5))
        XCTAssertFalse(CostBudget.isValidBudget(.nan))
        XCTAssertFalse(CostBudget.isValidBudget(.infinity))
    }

    func testTheStoreRejectsABadLimit() {
        for value in [0.0, -1, .nan, .infinity] {
            var daily = Profile.sample()
            daily.dailyBudgetUSD = value
            XCTAssertThrowsError(try store.validate(daily, others: [])) { error in
                XCTAssertEqual(error as? ProfileError, .invalidBudget)
            }
            var monthly = Profile.sample()
            monthly.monthlyBudgetUSD = value
            XCTAssertThrowsError(try store.validate(monthly, others: [])) { error in
                XCTAssertEqual(error as? ProfileError, .invalidBudget)
            }
        }
        var fine = Profile.sample()
        fine.dailyBudgetUSD = 5
        fine.monthlyBudgetUSD = 100
        XCTAssertNoThrow(try store.validate(fine, others: []))
    }

    func testLimitsSurviveAWriteAndALoad() throws {
        let profile = priced(daily: 2.5, monthly: 40)
        try store.save(AppData(profiles: [profile]))
        let loaded = store.load()
        XCTAssertNil(loaded.warning)
        XCTAssertEqual(loaded.data.profiles, [profile])
        let text = try String(contentsOf: store.paths.dataFile, encoding: .utf8)
        XCTAssertTrue(text.contains("\"daily_budget_usd\": 2.5"))
        XCTAssertTrue(text.contains("\"monthly_budget_usd\": 40.0"))
    }

    func testAProfileWithoutLimitsIsWrittenWithoutTheKeys() throws {
        try store.save(AppData(profiles: [priced()]))
        let text = try String(contentsOf: store.paths.dataFile, encoding: .utf8)
        XCTAssertFalse(text.contains("budget"))
        // And an older file is written again byte for byte.
        let loaded = store.load()
        try store.save(loaded.data)
        XCTAssertEqual(try String(contentsOf: store.paths.dataFile, encoding: .utf8), text)
    }

    func testABrokenLimitInTheFileIsDroppedNotAnError() throws {
        let json = """
        { "profiles": [ { "name": "A", "slug": "a", "daily_budget_usd": "lots", "monthly_budget_usd": -4 } ] }
        """
        let data = try JSONDecoder().decode(AppData.self, from: Data(json.utf8))
        XCTAssertNil(data.profiles[0].dailyBudgetUSD)
        XCTAssertNil(data.profiles[0].monthlyBudgetUSD)
        let zero = try JSONDecoder().decode(AppData.self, from: Data(#"{ "profiles": [ { "name": "A", "slug": "a", "daily_budget_usd": 0 } ] }"#.utf8))
        XCTAssertNil(zero.profiles[0].dailyBudgetUSD)
    }

    // MARK: - Notices

    private func status(day: Double, month: Double, dayLimit: Double = 10, monthLimit: Double = 100) -> BudgetStatus {
        CostBudget.status(of: priced(daily: dayLimit, monthly: monthLimit), summary: summary(day: day, month: month))
    }

    func testNothingIsDueBelowTheLines() {
        var ledger = BudgetNoticeLedger()
        XCTAssertEqual(ledger.due(slug: "a", status: status(day: 1, month: 1), dayKey: "2026-10-22"), [])
        XCTAssertEqual(ledger.due(slug: "a", status: BudgetStatus(), dayKey: "2026-10-22"), [])
    }

    func testANoticeIsDueOnceForNearAndOnceForOver() {
        var ledger = BudgetNoticeLedger()
        let key = "2026-10-22"
        let near = ledger.due(slug: "a", status: status(day: 8, month: 1), dayKey: key)
        XCTAssertEqual(near.map(\.window), [.daily])
        XCTAssertEqual(near.map(\.level), [.near])
        // The same state again: nothing.
        XCTAssertEqual(ledger.due(slug: "a", status: status(day: 8.5, month: 1), dayKey: key), [])
        let over = ledger.due(slug: "a", status: status(day: 10, month: 1), dayKey: key)
        XCTAssertEqual(over.map(\.level), [.over])
        XCTAssertEqual(ledger.due(slug: "a", status: status(day: 12, month: 1), dayKey: key), [])
    }

    func testJumpingStraightToOverSkipsNear() {
        var ledger = BudgetNoticeLedger()
        let notices = ledger.due(slug: "a", status: status(day: 30, month: 1), dayKey: "2026-10-22")
        XCTAssertEqual(notices.map(\.level), [.over])
        XCTAssertEqual(ledger.due(slug: "a", status: status(day: 9, month: 1), dayKey: "2026-10-22"), [])
    }

    func testCrossingAgainInTheSamePeriodDoesNotNotifyAgain() {
        var ledger = BudgetNoticeLedger()
        let key = "2026-10-22"
        XCTAssertEqual(ledger.due(slug: "a", status: status(day: 9, month: 1), dayKey: key).count, 1)
        // The cost falls (the limit was raised), then comes back.
        XCTAssertEqual(ledger.due(slug: "a", status: status(day: 1, month: 1), dayKey: key), [])
        XCTAssertEqual(ledger.due(slug: "a", status: status(day: 9, month: 1), dayKey: key), [])
    }

    func testANewDayNotifiesAgainButTheMonthDoesNot() {
        var ledger = BudgetNoticeLedger()
        let first = ledger.due(slug: "a", status: status(day: 9, month: 90), dayKey: "2026-10-22")
        XCTAssertEqual(Set(first.map(\.window)), [.daily, .monthly])
        let next = ledger.due(slug: "a", status: status(day: 9, month: 90), dayKey: "2026-10-23")
        XCTAssertEqual(next.map(\.window), [.daily])
        let newMonth = ledger.due(slug: "a", status: status(day: 9, month: 90), dayKey: "2026-11-01")
        XCTAssertEqual(Set(newMonth.map(\.window)), [.daily, .monthly])
    }

    func testProfilesAreIndependent() {
        var ledger = BudgetNoticeLedger()
        XCTAssertEqual(ledger.due(slug: "a", status: status(day: 9, month: 1), dayKey: "2026-10-22").count, 1)
        XCTAssertEqual(ledger.due(slug: "b", status: status(day: 9, month: 1), dayKey: "2026-10-22").count, 1)
        XCTAssertEqual(ledger.due(slug: "a", status: status(day: 9, month: 1), dayKey: "2026-10-22").count, 0)
    }

    func testANoticeCarriesTheNumbers() throws {
        var ledger = BudgetNoticeLedger()
        let notice = try XCTUnwrap(ledger.due(slug: "a", status: status(day: 9, month: 1), dayKey: "2026-10-22").first)
        XCTAssertEqual(notice.slug, "a")
        XCTAssertEqual(notice.limit, 10)
        XCTAssertEqual(notice.spent, 9, accuracy: 1e-9)
    }

    func testForgetAndRetain() {
        var ledger = BudgetNoticeLedger()
        _ = ledger.due(slug: "a", status: status(day: 9, month: 1), dayKey: "2026-10-22")
        _ = ledger.due(slug: "b", status: status(day: 9, month: 1), dayKey: "2026-10-22")
        ledger.forget(slug: "a")
        XCTAssertEqual(ledger.due(slug: "a", status: status(day: 9, month: 1), dayKey: "2026-10-22").count, 1)
        ledger.retain(slugs: ["a"])
        XCTAssertEqual(ledger.due(slug: "b", status: status(day: 9, month: 1), dayKey: "2026-10-22").count, 1)
        XCTAssertEqual(ledger.due(slug: "a", status: status(day: 9, month: 1), dayKey: "2026-10-22").count, 0)
    }

    // MARK: - Ledger file

    func testTheLedgerFileRoundTripsAndIsPrivate() throws {
        let store = BudgetNoticeStore(paths: temp.paths())
        XCTAssertEqual(store.load(), BudgetNoticeLedger())

        var ledger = BudgetNoticeLedger()
        _ = ledger.due(slug: "a", status: status(day: 9, month: 1), dayKey: "2026-10-22")
        store.save(ledger)
        XCTAssertEqual(store.load(), ledger)

        let file = temp.paths().root.appendingPathComponent(BudgetNoticeStore.fileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // A reloaded ledger does not notify again.
        var reloaded = store.load()
        XCTAssertEqual(reloaded.due(slug: "a", status: status(day: 9, month: 1), dayKey: "2026-10-22"), [])
    }

    func testADamagedLedgerFileGivesAnEmptyLedger() throws {
        let paths = temp.paths()
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try "not json".write(
            to: paths.root.appendingPathComponent(BudgetNoticeStore.fileName), atomically: false, encoding: .utf8
        )
        XCTAssertEqual(BudgetNoticeStore(paths: paths).load(), BudgetNoticeLedger())
    }
}
