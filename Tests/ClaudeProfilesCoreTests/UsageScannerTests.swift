import Foundation
import XCTest
@testable import ClaudeProfilesCore

/// Counts how many files the scanner read. Calls are sequential inside the actor.
private final class ReadCounter: @unchecked Sendable {
    private(set) var reads: [String] = []

    var count: Int { reads.count }

    func record(_ name: String) { reads.append(name) }

    func reset() { reads = [] }
}

final class UsageScannerTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: Paths!
    private let iso = ISO8601DateFormatter()

    /// `2026-10-22T12:00:00Z`, a fixed "now" for most tests.
    private var noon: Date { date("2026-10-22T12:00:00Z") }

    override func setUpWithError() throws {
        temp = try TempDirectory()
        paths = temp.paths()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    override func tearDown() {
        temp = nil
        paths = nil
    }

    // MARK: - Helpers

    private func date(_ text: String) -> Date {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)!
    }

    private func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func zone(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    /// One assistant line as Claude Code writes it. The text must never reach the summary.
    private func reply(
        id: String? = "msg_1",
        request: String? = "req_1",
        at timestamp: String? = "2026-10-22T05:00:00.000Z",
        input: Int = 10,
        output: Int = 5,
        cacheWrite: Int = 2,
        cacheRead: Int = 3
    ) -> String {
        var fields = ["\"type\":\"assistant\""]
        if let timestamp { fields.append("\"timestamp\":\"\(timestamp)\"") }
        if let request { fields.append("\"requestId\":\"\(request)\"") }
        var message = "\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"secret words\"}]"
        if let id { message = "\"id\":\"\(id)\"," + message }
        message += ",\"usage\":{\"input_tokens\":\(input),\"output_tokens\":\(output),"
        message += "\"cache_creation_input_tokens\":\(cacheWrite),\"cache_read_input_tokens\":\(cacheRead)}"
        fields.append("\"message\":{\(message)}")
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Creates the isolated config folder of the profile and writes one session file.
    @discardableResult
    private func session(_ lines: [String], slug: String = "work", project: String = "-proj-a", name: String = "s1.jsonl") throws -> URL {
        let folder = paths.home(for: slug).appendingPathComponent("projects/\(project)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)
        return url
    }

    private func profile(slug: String = "work", isolate: Bool = true) -> Profile {
        Profile.sample(name: slug, slug: slug, isolate: isolate)
    }

    private func makeScanner(counter: ReadCounter? = nil) -> UsageScanner {
        UsageScanner(paths: paths, readLines: { url, body in
            counter?.record(url.lastPathComponent)
            try UsageScanner.streamLines(url, body)
        })
    }

    private func summary(_ result: UsageResult, file: StaticString = #filePath, line: UInt = #line) -> UsageSummary {
        guard case .available(let summary) = result else {
            XCTFail("expected usage, got \(result)", file: file, line: line)
            return UsageSummary()
        }
        return summary
    }

    // MARK: - Totals and files

    func testSumsEveryFileOfEveryProject() async throws {
        try session([reply(id: "a", request: "r1", input: 1)], project: "-proj-a", name: "one.jsonl")
        try session([reply(id: "b", request: "r2", input: 2)], project: "-proj-a", name: "two.jsonl")
        try session([reply(id: "c", request: "r3", input: 4)], project: "-proj-b", name: "one.jsonl")
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 7)
        XCTAssertEqual(summary(result).allTime.output, 15)
        XCTAssertEqual(summary(result).allTime.cacheRead, 9)
        XCTAssertEqual(summary(result).allTime.cacheWrite, 6)
        XCTAssertEqual(summary(result).allTime.total, 37)
    }

    func testOnlyJsonlFilesUnderProjectsAreRead() async throws {
        try session([reply(id: "a", request: "r1", input: 1)])
        // Same content in files that must be ignored: wrong extension, and outside projects.
        let folder = paths.home(for: "work")
        try (reply(id: "x", request: "x", input: 100) + "\n").write(to: folder.appendingPathComponent("projects/-proj-a/notes.txt"), atomically: false, encoding: .utf8)
        try (reply(id: "y", request: "y", input: 100) + "\n").write(to: folder.appendingPathComponent("elsewhere.jsonl"), atomically: false, encoding: .utf8)
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 1)
    }

    func testAnEmptyProjectsFolderGivesZeros() async throws {
        try FileManager.default.createDirectory(at: paths.home(for: "work"), withIntermediateDirectories: true)
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(result, .available(UsageSummary()))
    }

    // MARK: - De-duplication

    func testTheSameReplyWrittenSeveralTimesCountsOnce() async throws {
        try session([
            reply(id: "msg_1", request: "req_1", input: 10),
            reply(id: "msg_1", request: "req_1", input: 10),
            reply(id: "msg_1", request: "req_1", input: 10),
        ])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 10)
    }

    func testTheSameMessageWithAnotherRequestIdIsCountedAgain() async throws {
        try session([
            reply(id: "msg_1", request: "req_1", input: 10),
            reply(id: "msg_1", request: "req_2", input: 10),
        ])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 20)
    }

    func testDeduplicationIsPerFile() async throws {
        try session([reply(id: "msg_1", request: "req_1", input: 10)], name: "one.jsonl")
        try session([reply(id: "msg_1", request: "req_1", input: 10)], name: "two.jsonl")
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 20)
    }

    // MARK: - Lines that must be skipped

    func testMalformedEmptyAndIrrelevantLinesAreSkipped() async throws {
        try session([
            "",
            "not json at all",
            "{",
            #"{"type":"user","message":{"content":"the word usage is here"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-22T05:00:00Z","message":{"id":"m0"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-22T05:00:00Z","message":{"id":"m9","usage":{"input_tokens":"oops"}}}"#,
            reply(id: "good", request: "r", input: 7),
            "   ",
        ])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 7)
        XCTAssertEqual(summary(result).allTime.output, 5)
    }

    func testAMissingTimestampCountsOnlyInAllTime() async throws {
        try session([reply(id: "nodate", request: "r", at: nil, input: 9)])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 9)
        XCTAssertEqual(summary(result).today.input, 0)
        XCTAssertEqual(summary(result).last7Days.input, 0)
    }

    // MARK: - Days and windows

    /// Two zones give two different "today"s for the same reply, so the injected calendar must decide.
    func testDayBoundariesFollowTheInjectedTimeZone() async throws {
        // now is 2026-10-22 05:00 UTC: 12:00 in Ho Chi Minh (UTC+7), 22:00 the day before in Los Angeles (UTC-7).
        let now = date("2026-10-22T05:00:00Z")
        try session([
            reply(id: "x", request: "x", at: "2026-10-21T18:30:00Z", input: 100), // 01:30 on 22 Oct in HCM
            reply(id: "y", request: "y", at: "2026-10-22T02:00:00Z", input: 1000), // 22 Oct in HCM, UTC; 21 Oct evening in LA
            reply(id: "z", request: "z", at: "2026-10-22T10:00:00Z", input: 10000), // 22 Oct in all three zones except LA (03:00, 22 Oct)
        ])
        let hcm = summary(try await makeScanner().usage(for: profile(), now: now, calendar: zone("Asia/Ho_Chi_Minh")))
        XCTAssertEqual(hcm.today.input, 100 + 1000 + 10000)

        let utcToday = summary(try await makeScanner().usage(for: profile(), now: now, calendar: utc()))
        XCTAssertEqual(utcToday.today.input, 1000 + 10000)

        let la = summary(try await makeScanner().usage(for: profile(), now: now, calendar: zone("America/Los_Angeles")))
        XCTAssertEqual(la.today.input, 100 + 1000)
        XCTAssertEqual(la.allTime.input, 11100)
    }

    func testWindowEdgesOfSevenDays() async throws {
        // now is 2026-10-22 12:00 UTC. The seven days are 16 to 22 October.
        try session([
            reply(id: "first", request: "1", at: "2026-10-16T00:00:00Z", input: 1), // first day of the window
            reply(id: "before", request: "2", at: "2026-10-15T23:59:59Z", input: 2), // one second before it
            reply(id: "lastSecond", request: "3", at: "2026-10-22T23:59:59Z", input: 4), // today, later than now
            reply(id: "todayStart", request: "4", at: "2026-10-22T00:00:00Z", input: 8), // start of today
        ])
        let result = summary(try await makeScanner().usage(for: profile(), now: noon, calendar: utc()))
        XCTAssertEqual(result.today.input, 4 + 8)
        XCTAssertEqual(result.last7Days.input, 1 + 4 + 8)
        XCTAssertEqual(result.allTime.input, 1 + 2 + 4 + 8)
    }

    // MARK: - Large files

    /// A file with 100 000 lines is read through the streaming reader, one line at a time.
    func testAHundredThousandLineFileStreams() async throws {
        var lines: [String] = []
        lines.reserveCapacity(100_000)
        for index in 0..<100_000 {
            lines.append(reply(id: "msg_\(index)", request: "req_\(index)", input: 1, output: 0, cacheWrite: 0, cacheRead: 0))
        }
        try session(lines)

        var streamed = 0
        let url = paths.home(for: "work").appendingPathComponent("projects/-proj-a/s1.jsonl")
        try UsageScanner.streamLines(url) { _ in streamed += 1 }
        XCTAssertEqual(streamed, 100_000)

        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 100_000)
    }

    func testStreamingHandlesLinesLongerThanOneChunk() throws {
        let long = String(repeating: "a", count: 200_000)
        try session([long, "second", ""])
        let url = paths.home(for: "work").appendingPathComponent("projects/-proj-a/s1.jsonl")
        var received: [String] = []
        try UsageScanner.streamLines(url) { received.append($0) }
        XCTAssertEqual(received, [long, "second", ""])
    }

    // MARK: - Cache

    func testAnUnchangedFileIsNotReadAgain() async throws {
        try session([reply(id: "a", request: "r1", input: 1)], name: "one.jsonl")
        try session([reply(id: "b", request: "r2", input: 2)], name: "two.jsonl")
        let counter = ReadCounter()
        let scanner = makeScanner(counter: counter)

        _ = try await scanner.usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(counter.count, 2)

        counter.reset()
        let again = try await scanner.usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(summary(again).allTime.input, 3)
    }

    func testAChangedSizeReadsOnlyThatFile() async throws {
        let changed = try session([reply(id: "a", request: "r1", input: 1)], name: "one.jsonl")
        try session([reply(id: "b", request: "r2", input: 2)], name: "two.jsonl")
        let counter = ReadCounter()
        let scanner = makeScanner(counter: counter)
        _ = try await scanner.usage(for: profile(), now: noon, calendar: utc())

        let handle = try FileHandle(forWritingTo: changed)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((reply(id: "c", request: "r3", input: 4) + "\n").utf8))
        try handle.close()

        counter.reset()
        let result = try await scanner.usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(counter.reads, ["one.jsonl"])
        XCTAssertEqual(summary(result).allTime.input, 1 + 4 + 2)
    }

    func testAChangedModificationTimeAloneReadsTheFileAgain() async throws {
        let url = try session([reply(id: "a", request: "r1", input: 1)])
        let counter = ReadCounter()
        let scanner = makeScanner(counter: counter)
        _ = try await scanner.usage(for: profile(), now: noon, calendar: utc())

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: url.path
        )
        counter.reset()
        _ = try await scanner.usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(counter.count, 1)
    }

    func testTheCacheSurvivesANewScannerAndHoldsNoMessageText() async throws {
        try session([reply(id: "a", request: "r1", input: 5)])
        _ = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())

        let cacheURL = paths.root.appendingPathComponent(UsageScanner.cacheFileName)
        let cacheText = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertFalse(cacheText.contains("secret words"))

        let counter = ReadCounter()
        let result = try await makeScanner(counter: counter).usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(counter.count, 0, "the modification time must survive the JSON round trip")
        XCTAssertEqual(summary(result).allTime.input, 5)
    }

    func testACorruptCacheFileIsIgnored() async throws {
        try session([reply(id: "a", request: "r1", input: 5)])
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try "{ this is not the cache".write(to: paths.root.appendingPathComponent(UsageScanner.cacheFileName), atomically: false, encoding: .utf8)

        let counter = ReadCounter()
        let result = try await makeScanner(counter: counter).usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(summary(result).allTime.input, 5)
    }

    func testADeletedFileLeavesTheSummaryAndTheCache() async throws {
        let gone = try session([reply(id: "a", request: "r1", input: 1)], name: "gone.jsonl")
        try session([reply(id: "b", request: "r2", input: 2)], name: "kept.jsonl")
        let scanner = makeScanner()
        _ = try await scanner.usage(for: profile(), now: noon, calendar: utc())

        try FileManager.default.removeItem(at: gone)
        let result = try await scanner.usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 2)

        let cacheText = try String(contentsOf: paths.root.appendingPathComponent(UsageScanner.cacheFileName), encoding: .utf8)
        XCTAssertFalse(cacheText.contains("gone.jsonl"))
    }

    func testTheCalendarChangeRebuildsTheDays() async throws {
        // 21 Oct 18:30 UTC is 22 Oct in Ho Chi Minh, so the day key differs between the two calendars.
        try session([reply(id: "a", request: "r1", at: "2026-10-21T18:30:00Z", input: 3)])
        let now = date("2026-10-22T05:00:00Z")
        let scanner = makeScanner()
        let inHanoi = summary(try await scanner.usage(for: profile(), now: now, calendar: zone("Asia/Ho_Chi_Minh")))
        XCTAssertEqual(inHanoi.today.input, 3)
        let inUTC = summary(try await scanner.usage(for: profile(), now: now, calendar: utc()))
        XCTAssertEqual(inUTC.today.input, 0)
    }

    // MARK: - Availability

    func testANonIsolatedProfileIsUnavailable() async throws {
        try session([reply(id: "a", request: "r1", input: 1)])
        let result = try await makeScanner().usage(for: profile(isolate: false), now: noon, calendar: utc())
        XCTAssertEqual(result, .unavailable(.notIsolated))
    }

    func testAMissingFolderIsUnavailable() async throws {
        let result = try await makeScanner().usage(for: profile(slug: "nothing-here"), now: noon, calendar: utc())
        XCTAssertEqual(result, .unavailable(.folderMissing))
    }

    func testACancelledScanThrows() async throws {
        try session([reply(id: "a", request: "r1", input: 1)])
        let scanner = makeScanner()
        let work = profile()
        let now = noon
        let calendar = utc()
        let task = Task { try await scanner.usage(for: work, now: now, calendar: calendar) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled scan must not return a result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
