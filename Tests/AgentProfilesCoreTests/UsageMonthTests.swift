import Foundation
import XCTest
@testable import AgentProfilesCore

/// The "this calendar month" window of the usage summary.
final class UsageMonthTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: Paths!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        paths = temp.paths()
    }

    override func tearDown() {
        temp = nil
        paths = nil
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func reply(_ id: String, at timestamp: String, input: Int) -> String {
        "{\"type\":\"assistant\",\"timestamp\":\"\(timestamp)\",\"requestId\":\"\(id)\","
            + "\"message\":{\"id\":\"\(id)\",\"role\":\"assistant\",\"content\":[],"
            + "\"usage\":{\"input_tokens\":\(input),\"output_tokens\":0,"
            + "\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
    }

    private func month(of lines: [String], now: String, calendar: Calendar) async throws -> UsageSummary {
        let folder = paths.home(for: "work").appendingPathComponent("projects/-p", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: folder.appendingPathComponent("s.jsonl"), atomically: false, encoding: .utf8)
        let result = try await UsageScanner(paths: paths).usage(
            for: Profile.sample(name: "work", slug: "work"),
            now: date(now),
            calendar: calendar
        )
        guard case .available(let summary, _) = result else {
            XCTFail("expected usage, got \(result)")
            return UsageSummary()
        }
        return summary
    }

    func testTheMonthStartsOnTheFirstAndStopsAtToday() async throws {
        let summary = try await month(of: [
            reply("a", at: "2026-09-30T23:59:59Z", input: 1),   // the month before
            reply("b", at: "2026-10-01T00:00:00Z", input: 10),  // first second of the month
            reply("c", at: "2026-10-22T23:59:59Z", input: 100), // later today than now
            reply("d", at: "2026-11-01T00:00:00Z", input: 1000), // the month after
        ], now: "2026-10-22T12:00:00Z", calendar: calendar("UTC"))
        XCTAssertEqual(summary.thisMonth.input, 10 + 100)
        XCTAssertEqual(summary.allTime.input, 1111)
    }

    func testTheMonthIsLongerThanTheWeekEarlyAndShorterLate() async throws {
        let lines = [
            reply("a", at: "2026-10-01T10:00:00Z", input: 1),
            reply("b", at: "2026-10-20T10:00:00Z", input: 10),
        ]
        let late = try await month(of: lines, now: "2026-10-22T12:00:00Z", calendar: calendar("UTC"))
        XCTAssertEqual(late.thisMonth.input, 11)
        XCTAssertEqual(late.last7Days.input, 10)
    }

    /// On the first of the month the week reaches back into the month before, the month does not.
    func testOnTheFirstOfTheMonthOnlyTheNewMonthCounts() async throws {
        let summary = try await month(of: [
            reply("a", at: "2026-09-29T10:00:00Z", input: 1),
            reply("b", at: "2026-10-01T10:00:00Z", input: 10),
        ], now: "2026-10-01T12:00:00Z", calendar: calendar("UTC"))
        XCTAssertEqual(summary.thisMonth.input, 10)
        XCTAssertEqual(summary.last7Days.input, 11)
    }

    func testTheMonthFollowsTheLocalTimeZone() async throws {
        // 2026-09-30 18:00 UTC is already 1 October in Ho Chi Minh (UTC+7), still 30 September in UTC.
        let lines = [reply("a", at: "2026-09-30T18:00:00Z", input: 5)]
        let hcm = try await month(of: lines, now: "2026-10-10T00:00:00Z", calendar: calendar("Asia/Ho_Chi_Minh"))
        XCTAssertEqual(hcm.thisMonth.input, 5)

        temp = try TempDirectory()
        paths = temp.paths()
        let utc = try await month(of: lines, now: "2026-10-10T00:00:00Z", calendar: calendar("UTC"))
        XCTAssertEqual(utc.thisMonth.input, 0)
    }

    func testAYearEndAndALeapDayStayInsideTheirMonth() async throws {
        let december = try await month(of: [
            reply("a", at: "2026-12-31T10:00:00Z", input: 3),
            reply("b", at: "2027-01-01T10:00:00Z", input: 30),
        ], now: "2026-12-31T12:00:00Z", calendar: calendar("UTC"))
        XCTAssertEqual(december.thisMonth.input, 3)

        temp = try TempDirectory()
        paths = temp.paths()
        let february = try await month(of: [
            reply("a", at: "2028-02-29T10:00:00Z", input: 7),
            reply("b", at: "2028-03-01T10:00:00Z", input: 70),
        ], now: "2028-02-29T12:00:00Z", calendar: calendar("UTC"))
        XCTAssertEqual(february.thisMonth.input, 7)
    }

    func testMonthStartKey() {
        XCTAssertEqual(UsageScanner.monthStartKey(date("2026-10-22T12:00:00Z"), calendar("UTC")), "2026-10-01")
        XCTAssertEqual(UsageScanner.monthStartKey(date("2026-01-05T12:00:00Z"), calendar("UTC")), "2026-01-01")
    }
}
