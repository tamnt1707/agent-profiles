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

    /// One assistant line whose usage is written as it is, so that a broken
    /// number can be tried.
    private func rawReply(
        usage: String,
        id: String = "msg_1",
        request: String? = "req_1",
        at timestamp: String? = "2026-10-22T05:00:00.000Z"
    ) -> String {
        var fields = ["\"type\":\"assistant\""]
        if let timestamp { fields.append("\"timestamp\":\"\(timestamp)\"") }
        if let request { fields.append("\"requestId\":\"\(request)\"") }
        fields.append("\"message\":{\"id\":\"\(id)\",\"role\":\"assistant\",\"content\":[],\"usage\":{\(usage)}}")
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
        guard case .available(let summary, _) = result else {
            XCTFail("expected usage, got \(result)", file: file, line: line)
            return UsageSummary()
        }
        return summary
    }

    /// The number of files that could not be read during the last count.
    private func skippedFiles(_ result: UsageResult, file: StaticString = #filePath, line: UInt = #line) -> Int {
        guard case .available(_, let skipped) = result else {
            XCTFail("expected usage, got \(result)", file: file, line: line)
            return 0
        }
        return skipped
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
        XCTAssertEqual(result, .available(UsageSummary(), skippedFiles: 0))
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

    // MARK: - A reply that is written again

    /// A reply that is written to the same file twice counts once, with the
    /// largest numbers of its lines: a complete line wins over a partial one.
    func testARepeatedReplyCountsTheLargestOfItsLines() async throws {
        try session([
            rawReply(usage: "\"input_tokens\":10,\"output_tokens\":5", id: "m", request: "r"),
            rawReply(usage: "\"input_tokens\":40,\"output_tokens\":7,\"cache_read_input_tokens\":3", id: "m", request: "r"),
        ])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 40)
        XCTAssertEqual(summary(result).allTime.output, 7)
        XCTAssertEqual(summary(result).allTime.cacheRead, 3)
        XCTAssertEqual(summary(result).allTime.cacheWrite, 0)
    }

    /// Every counter is compared on its own: the smaller number of one counter
    /// does not make the larger number of another one smaller.
    func testEveryCounterOfARepeatedReplyIsComparedOnItsOwn() async throws {
        try session([
            rawReply(usage: "\"input_tokens\":40,\"output_tokens\":2,\"cache_creation_input_tokens\":0", id: "m", request: "r"),
            rawReply(usage: "\"input_tokens\":10,\"output_tokens\":9,\"cache_creation_input_tokens\":5", id: "m", request: "r"),
        ])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 40)
        XCTAssertEqual(summary(result).allTime.output, 9)
        XCTAssertEqual(summary(result).allTime.cacheWrite, 5)
    }

    /// A repeated reply keeps the day of its first line.
    func testARepeatedReplyKeepsTheDayOfItsFirstLine() async throws {
        try session([
            rawReply(usage: "\"input_tokens\":10", id: "m", request: "r", at: "2026-10-20T05:00:00.000Z"),
            rawReply(usage: "\"input_tokens\":40", id: "m", request: "r", at: "2026-10-21T05:00:00.000Z"),
        ])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).today.input, 0)
        XCTAssertEqual(summary(result).last7Days.input, 40)
        XCTAssertEqual(summary(result).allTime.input, 40)
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

    // MARK: - Broken numbers

    /// The reproduction of the crash: two lines with the biggest number a
    /// machine can hold used to trap the app when the totals were added up.
    func testTwoLinesWithTheBiggestNumberDoNotCrash() async throws {
        try session([
            rawReply(usage: "\"input_tokens\":9223372036854775807", id: "a", request: "r1"),
            rawReply(usage: "\"input_tokens\":9223372036854775807", id: "b", request: "r2"),
        ])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 0)
        XCTAssertEqual(summary(result).allTime.total, 0)
    }

    func testANegativeCounterIgnoresTheWholeLine() async throws {
        try session([
            rawReply(usage: "\"input_tokens\":-1,\"output_tokens\":5", id: "a", request: "r1"),
            reply(id: "b", request: "r2", input: 7),
        ])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 7)
        XCTAssertEqual(summary(result).allTime.output, 5)
    }

    func testAFractionalCounterIgnoresTheWholeLine() async throws {
        try session([
            rawReply(usage: "\"input_tokens\":1.5,\"output_tokens\":5", id: "a", request: "r1"),
            reply(id: "b", request: "r2", input: 7),
        ])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 7)
        XCTAssertEqual(summary(result).allTime.output, 5)
    }

    /// A number written as `1e3` is a whole number and counts.
    func testAWholeNumberInTheExponentFormCounts() async throws {
        try session([
            rawReply(usage: "\"input_tokens\":1e3,\"output_tokens\":2e1", id: "a", request: "r1"),
        ])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 1000)
        XCTAssertEqual(summary(result).allTime.output, 20)
    }

    /// A number that is bigger than the limit is a broken file, not usage.
    func testACounterAboveTheLimitIgnoresTheWholeLine() async throws {
        try session([
            rawReply(usage: "\"input_tokens\":1000000000001,\"output_tokens\":5", id: "a", request: "r1"),
            reply(id: "b", request: "r2", input: 7),
        ])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 7)
        XCTAssertEqual(summary(result).allTime.output, 5)
    }

    /// The biggest number that is still allowed counts.
    func testACounterAtTheLimitCounts() async throws {
        try session([
            rawReply(usage: "\"input_tokens\":1000000000000", id: "a", request: "r1"),
        ])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 1_000_000_000_000)
    }

    /// A number that does not fit into an integer at all is ignored, not counted half.
    func testACounterThatIsTooBigForAnIntegerIgnoresTheLine() async throws {
        try session([
            rawReply(usage: "\"input_tokens\":1e30,\"output_tokens\":3", id: "a", request: "r1"),
        ])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 0)
        XCTAssertEqual(summary(result).allTime.output, 0)
    }

    /// A broken counter is not counted half: the other counters of the line are
    /// dropped with it.
    func testABrokenCounterDropsTheOtherCountersOfTheLine() async throws {
        try session([
            rawReply(usage: "\"input_tokens\":10,\"output_tokens\":-2,\"cache_read_input_tokens\":99", id: "a", request: "r1"),
        ])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 0)
        XCTAssertEqual(summary(result).allTime.output, 0)
        XCTAssertEqual(summary(result).allTime.cacheRead, 0)
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
        try UsageScanner.streamLines(url) { line in
            received.append(String(decoding: line.bytes, as: UTF8.self))
        }
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

    // MARK: - Files that cannot be read

    /// A file that cannot be read is skipped: the other files are counted and
    /// the number of skipped files is reported.
    func testAFileThatCannotBeReadIsSkippedAndTheRestIsCounted() async throws {
        let locked = try session([reply(id: "a", request: "r1", input: 100)], name: "locked.jsonl")
        try session([reply(id: "b", request: "r2", input: 7)], name: "open.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path)
        }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: locked.path),
                      "the file is still readable: the test cannot lock it")

        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 7)
        XCTAssertEqual(skippedFiles(result), 1)
    }

    /// A file that is deleted between the listing and the reading is skipped
    /// as well. The name of the file never reaches the result.
    func testAFileThatDisappearsDuringTheScanIsSkipped() async throws {
        try session([reply(id: "a", request: "r1", input: 100)], name: "gone.jsonl")
        try session([reply(id: "b", request: "r2", input: 7)], name: "kept.jsonl")
        let scanner = UsageScanner(paths: paths, readLines: { url, body in
            if url.lastPathComponent == "gone.jsonl" {
                throw ProfileError.ioFailed("/Users/somebody/project/gone.jsonl")
            }
            try UsageScanner.streamLines(url, body)
        })

        let result = try await scanner.usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 7)
        XCTAssertEqual(skippedFiles(result), 1)
        // The result holds no text at all, so no path can be in it.
        XCTAssertFalse(String(describing: result).contains("gone.jsonl"))
        XCTAssertFalse(String(describing: result).contains("/Users/"))
    }

    /// A file that cannot be read is tried again at the next count.
    func testAFileThatCannotBeReadIsTriedAgain() async throws {
        try session([reply(id: "a", request: "r1", input: 100)], name: "gone.jsonl")
        let scanner = UsageScanner(paths: paths, readLines: { _, _ in
            throw ProfileError.ioFailed("/Users/somebody/project/gone.jsonl")
        })

        let first = try await scanner.usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(skippedFiles(first), 1)
        let second = try await scanner.usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(skippedFiles(second), 1)
    }

    // MARK: - The bytes of the lines

    /// Only the lines that can hold a usage are worth decoding.
    func testOnlyTheLinesWithAUsageAreCounted() async throws {
        try session([
            // A line with a usage but without an assistant reply.
            #"{"type":"user","message":{"id":"b","usage":{"input_tokens":100}}}"#,
            // An assistant reply without a usage.
            #"{"type":"assistant","message":{"id":"a"}}"#,
            reply(id: "c", request: "r", input: 7),
        ])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 7)
    }

    /// A line that is longer than the limit is not read and not counted.
    func testALineThatIsTooLongIsNotCounted() async throws {
        let long = String(repeating: "a", count: 5_000)
        try session([long, reply(id: "a", request: "r", input: 7)])
        let scanner = UsageScanner(paths: paths, readLines: UsageScanner.streamLines(limit: 1_000))
        let result = try await scanner.usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 7)
        let skipped = await scanner.skippedLines
        XCTAssertEqual(skipped, 1)
    }

    /// The reader hands the line that is too long over as "too long" and keeps
    /// reading the lines that follow it.
    func testTheReaderSkipsALineThatIsTooLongAndKeepsTheRest() throws {
        let long = String(repeating: "a", count: 5_000)
        try session([long, "second", "third"])
        let url = paths.home(for: "work").appendingPathComponent("projects/-proj-a/s1.jsonl")
        var received: [UsageScanner.RawLine] = []
        try UsageScanner.streamLines(limit: 1_000)(url) { received.append($0) }
        XCTAssertEqual(received.count, 3)
        XCTAssertTrue(received[0].tooLong)
        XCTAssertFalse(received[1].tooLong)
        XCTAssertFalse(received[2].tooLong)
        XCTAssertEqual(String(decoding: received[1].bytes, as: UTF8.self), "second")
        XCTAssertEqual(String(decoding: received[2].bytes, as: UTF8.self), "third")
    }

    // MARK: - The cache file

    /// The cache holds no absolute path: the name of a project folder of the
    /// user is all it can show.
    func testTheCacheHoldsNoAbsolutePath() async throws {
        try session([reply(id: "a", request: "r1", input: 5)])
        _ = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())

        let cacheURL = paths.root.appendingPathComponent(UsageScanner.cacheFileName)
        let bytes = try Data(contentsOf: cacheURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let files = try XCTUnwrap(object["files"] as? [String: Any])
        XCTAssertEqual(Array(files.keys), ["work/projects/-proj-a/s1.jsonl"])
        // The folder of the profile is nowhere in the file.
        let text = try String(contentsOf: cacheURL, encoding: .utf8)
        XCTAssertFalse(text.contains("homes"))
        XCTAssertFalse(text.contains(paths.root.lastPathComponent))
    }

    /// The cache holds the names of the project folders of the user: only the
    /// user may read it.
    func testTheCacheFileIsOnlyReadableByTheUser() async throws {
        try session([reply(id: "a", request: "r1", input: 5)])
        _ = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())

        let cacheURL = paths.root.appendingPathComponent(UsageScanner.cacheFileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions, 0o600)
    }

    /// The cache is written while the scan runs: a scan that is stopped keeps
    /// the work it has already done.
    func testTheCacheIsWrittenWhileTheScanRuns() async throws {
        for index in 0..<30 {
            try session([reply(id: "m\(index)", request: "r\(index)", input: 1)], name: "f\(index).jsonl")
        }
        let counter = ReadCounter()
        let scanner = UsageScanner(paths: paths, readLines: { url, body in
            counter.record(url.lastPathComponent)
            // The scan is stopped after 25 files.
            if counter.count == 26 { throw CancellationError() }
            try UsageScanner.streamLines(url, body)
        })
        do {
            _ = try await scanner.usage(for: profile(), now: noon, calendar: utc())
            XCTFail("the scan must be stopped")
        } catch is CancellationError {
            // expected
        }

        let cacheURL = paths.root.appendingPathComponent(UsageScanner.cacheFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        let bytes = try Data(contentsOf: cacheURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let files = try XCTUnwrap(object["files"] as? [String: Any])
        XCTAssertEqual(files.count, 25)
    }

    // MARK: - Files that are not session files

    /// A link is not followed: it could lead to a file outside of the folder of
    /// the profile.
    func testALinkedSessionFileIsNotRead() async throws {
        let home = paths.home(for: "work")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let outside = home.appendingPathComponent("elsewhere.jsonl")
        try (reply(id: "a", request: "r1", input: 100) + "\n").write(to: outside, atomically: false, encoding: .utf8)
        let folder = home.appendingPathComponent("projects/-proj-a", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("linked.jsonl"),
            withDestinationURL: outside
        )

        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 0)
        XCTAssertEqual(skippedFiles(result), 0)
    }

    /// A linked folder of sessions is not read either.
    func testALinkedProjectsFolderIsNotRead() async throws {
        let real = paths.root.appendingPathComponent("real-projects", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try (reply(id: "a", request: "r1", input: 100) + "\n")
            .write(to: real.appendingPathComponent("s1.jsonl"), atomically: false, encoding: .utf8)
        let home = paths.home(for: "work")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("projects"),
            withDestinationURL: real
        )

        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 0)
    }

    /// A slug that is not a safe file name reads nothing.
    func testAHostileSlugReadsNothing() async throws {
        let outside = paths.root.appendingPathComponent("x/projects", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try (reply(id: "a", request: "r1", input: 100) + "\n")
            .write(to: outside.appendingPathComponent("s1.jsonl"), atomically: false, encoding: .utf8)

        let counter = ReadCounter()
        let scanner = makeScanner(counter: counter)
        let result = try await scanner.usage(for: profile(slug: "../x"), now: noon, calendar: utc())
        XCTAssertEqual(result, .unavailable(.folderMissing))
        XCTAssertEqual(counter.count, 0)
    }

    /// A folder that is named like a session file is not read.
    func testAFolderNamedLikeASessionFileIsSkipped() async throws {
        try session([reply(id: "a", request: "r1", input: 7)])
        let folder = paths.home(for: "work").appendingPathComponent("projects/-proj-a/x.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 7)
        XCTAssertEqual(skippedFiles(result), 0)
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

    // MARK: - The mode of the cache file

    /// The mode of a file, as the system sees it.
    private func mode(of url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }

    /// The temporary file of the cache is only readable by the user from the
    /// very moment it is made.
    ///
    /// The umask of the process is set to 0 for the test: a file that is made
    /// without a mode of its own is then readable by everyone.
    func testTheTemporaryCacheFileIsOnlyReadableByTheUserFromTheStart() async throws {
        let previous = umask(0)
        defer { umask(previous) }
        try session([reply(id: "a", request: "r1", input: 5)])

        let modes = ModeTally()
        let scanner = UsageScanner(
            paths: paths,
            readLines: UsageScanner.streamLines,
            afterTemporaryFileWritten: { url in modes.add(self.mode(of: url)) }
        )
        _ = try await scanner.usage(for: profile(), now: noon, calendar: utc())

        XCTAssertFalse(modes.values.isEmpty, "the cache was never written")
        for value in modes.values {
            XCTAssertEqual(value, 0o600, "the temporary file was readable by others")
        }
        let cacheURL = paths.root.appendingPathComponent(UsageScanner.cacheFileName)
        XCTAssertEqual(mode(of: cacheURL), 0o600)
    }

    // MARK: - A count that is stopped

    /// A reader that stops the count after a number of lines.
    ///
    /// The count is stopped by cancelling the task that runs it, and not by
    /// throwing: the real path of a stopped count is the one of a cancelled
    /// task.
    private func cancellingReader(after lines: Int) -> UsageScanner.LineReader {
        let counter = LineTally()
        return { url, body in
            try UsageScanner.streamLines(url) { line in
                let seen = counter.add(1)
                try body(line)
                if seen >= lines {
                    // The count is stopped in the middle of the file.
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
    }

    /// The keys of the files that are in the cache.
    private func cachedFiles() throws -> Set<String> {
        let cacheURL = paths.root.appendingPathComponent(UsageScanner.cacheFileName)
        let bytes = try Data(contentsOf: cacheURL)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let files = try XCTUnwrap(object["files"] as? [String: Any])
        return Set(files.keys)
    }

    /// A count that is stopped in the middle of a file keeps the files that
    /// were read whole.
    func testACountThatIsStoppedKeepsOnlyTheWholeFiles() async throws {
        try session([reply(id: "a1", request: "r1", input: 1), reply(id: "a2", request: "r2", input: 1)], name: "a.jsonl")
        try session([reply(id: "b1", request: "r3", input: 1), reply(id: "b2", request: "r4", input: 1)], name: "b.jsonl")
        try session([reply(id: "c1", request: "r5", input: 1), reply(id: "c2", request: "r6", input: 1)], name: "c.jsonl")

        let scanner = UsageScanner(paths: paths, readLines: cancellingReader(after: 3))
        let task = Task { try await scanner.usage(for: profile(), now: noon, calendar: utc()) }
        do {
            _ = try await task.value
            XCTFail("the count must be stopped")
        } catch is CancellationError {
            // expected
        }

        // The first file was read whole, the second one was not.
        XCTAssertEqual(try cachedFiles(), ["work/projects/-proj-a/a.jsonl"])
    }

    /// The work of a count that was stopped is not thrown away: the next count
    /// reads only the files that are not in the cache yet.
    func testTheNextCountReadsOnlyTheFilesThatAreNotCached() async throws {
        try session([reply(id: "a1", request: "r1", input: 1), reply(id: "a2", request: "r2", input: 1)], name: "a.jsonl")
        try session([reply(id: "b1", request: "r3", input: 1), reply(id: "b2", request: "r4", input: 1)], name: "b.jsonl")
        try session([reply(id: "c1", request: "r5", input: 1), reply(id: "c2", request: "r6", input: 1)], name: "c.jsonl")

        let scanner = UsageScanner(paths: paths, readLines: cancellingReader(after: 3))
        let task = Task { try await scanner.usage(for: profile(), now: noon, calendar: utc()) }
        do {
            _ = try await task.value
            XCTFail("the count must be stopped")
        } catch is CancellationError {
            // expected
        }

        let counter = ReadCounter()
        let second = makeScanner(counter: counter)
        _ = try await second.usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(Set(counter.reads), ["b.jsonl", "c.jsonl"],
                       "the file that was already counted was read again")
    }

    // MARK: - A link inside the projects folder

    /// A link that stands for a project folder is not followed: it could lead
    /// to a folder outside of the folder of the profile.
    func testALinkedProjectSubfolderIsNotRead() async throws {
        let real = paths.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try (reply(id: "a", request: "r1", input: 100) + "\n")
            .write(to: real.appendingPathComponent("s1.jsonl"), atomically: false, encoding: .utf8)
        let projects = paths.home(for: "work").appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: projects.appendingPathComponent("-linked"),
            withDestinationURL: real
        )

        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 0)
        XCTAssertEqual(skippedFiles(result), 0)
    }

    // MARK: - Times that do not exist

    /// A time like 24:00:00 or 23:60:00 is not a time that was ever written.
    /// The line counts in "All time" only.
    func testATimeThatDoesNotExistCountsOnlyInAllTime() async throws {
        try session([
            reply(id: "a", request: "r1", at: "2026-10-22T24:00:00Z", input: 10),
            reply(id: "b", request: "r2", at: "2026-10-22T23:60:00Z", input: 20),
            reply(id: "c", request: "r3", at: "2026-10-22T12:60:00Z", input: 40),
            reply(id: "d", request: "r4", at: "2026-10-22T12:00:60Z", input: 80),
            reply(id: "e", request: "r5", at: "2026-10-22T12:00:00Z", input: 160)
        ])
        let result = try await makeScanner().usage(for: profile(), now: noon, calendar: utc())
        XCTAssertEqual(summary(result).allTime.input, 310)
        XCTAssertEqual(summary(result).today.input, 160, "only the real time belongs to today")
        XCTAssertEqual(summary(result).last7Days.input, 160)
    }

    /// The parser of the timestamps refuses the times that do not exist.
    func testTheTimestampParserRefusesTheTimesThatDoNotExist() {
        let reader = TimestampReader()
        XCTAssertNil(reader.date("2026-10-22T24:00:00Z"))
        XCTAssertNil(reader.date("2026-10-22T25:30:00Z"))
        XCTAssertNil(reader.date("2026-10-22T23:60:00Z"))
        XCTAssertNil(reader.date("2026-10-22T12:00:60Z"))
        XCTAssertNotNil(reader.date("2026-10-22T23:59:59Z"))
        XCTAssertNotNil(reader.date("2026-10-22T00:00:00Z"))
        XCTAssertNotNil(reader.date("2026-10-22T12:00:00.123Z"))
    }
}

/// Collects the modes of the temporary files of the cache.
private final class ModeTally: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [Int?] = []

    func add(_ value: Int?) {
        lock.lock()
        found.append(value)
        lock.unlock()
    }

    var values: [Int?] {
        lock.lock()
        defer { lock.unlock() }
        return found
    }
}

/// Counts the lines that the reader of the lines has seen.
private final class LineTally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// The number of the line, the first one is 1.
    func add(_ lines: Int) -> Int {
        lock.lock()
        count += lines
        let total = count
        lock.unlock()
        return total
    }
}
