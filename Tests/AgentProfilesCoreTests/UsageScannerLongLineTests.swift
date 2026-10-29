import Foundation
import XCTest
@testable import AgentProfilesCore

/// Counts the bytes that the reader of the lines looks at.
private final class ByteTally: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    func add(_ count: Int) {
        lock.lock()
        total += count
        lock.unlock()
    }

    var bytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}

/// A long line must not be looked at again and again.
///
/// The reader of the lines gets the file in chunks of 64 KB. When a chunk
/// holds no line break, the bytes that were already looked at must not be
/// looked at again: a 40 MB line was read 40 million times before.
final class UsageScannerLongLineTests: XCTestCase {
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

    // MARK: - Helpers

    private func profile(slug: String = "work") -> Profile {
        Profile.sample(name: slug, slug: slug, isolate: true)
    }

    private func utc() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Writes a session file with the given bytes.
    @discardableResult
    private func write(_ bytes: Data, name: String = "s1.jsonl") throws -> URL {
        let folder = paths.home(for: "work").appendingPathComponent("projects/-proj-a", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    /// One assistant reply with a lot of text in it.
    private func longReply(filler: Int) -> Data {
        let head = #"{"type":"assistant","timestamp":"2026-10-22T05:00:00.000Z","requestId":"req_1","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":""#
        let tail = #""}],"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}}"#
        var data = Data(head.utf8)
        data.append(Data(repeating: 0x61, count: filler))
        data.append(Data(tail.utf8))
        data.append(0x0A)
        return data
    }

    /// A long line that holds no usage at all.
    private func longFiller(bytes: Int) -> Data {
        var data = Data(repeating: 0x62, count: bytes)
        data.append(0x0A)
        return data
    }

    /// Counts the usage with a reader that counts the bytes it looks at.
    private func count(_ tally: ByteTally) async throws -> UsageResult {
        let scanner = UsageScanner(
            paths: paths,
            readLines: UsageScanner.streamLines(limit: UsageScanner.maxLineBytes, counted: { tally.add($0) })
        )
        return try await scanner.usage(for: profile(), now: Date(), calendar: utc())
    }

    // MARK: - The tests

    /// A line of 20 MB without a line break is looked at once.
    ///
    /// The number of bytes that are looked at is counted instead of the time:
    /// the count does not depend on how fast the machine is.
    func testALongLineWithoutALineBreakIsLookedAtOnce() async throws {
        let data = longFiller(bytes: 20 * 1024 * 1024)
        try write(data)
        let tally = ByteTally()
        _ = try await count(tally)
        XCTAssertLessThanOrEqual(tally.bytes, data.count * 2,
                                 "the line was looked at \(tally.bytes) times for \(data.count) bytes")
    }

    /// An assistant line of 8 MB is looked at once, and its tokens are counted.
    func testALongAssistantLineIsLookedAtOnceAndCounted() async throws {
        let data = longReply(filler: 8 * 1024 * 1024)
        try write(data)
        let tally = ByteTally()
        let result = try await count(tally)
        XCTAssertLessThanOrEqual(tally.bytes, data.count * 2,
                                 "the line was looked at \(tally.bytes) times for \(data.count) bytes")
        guard case .available(let summary, _) = result else {
            XCTFail("expected usage, got \(result)")
            return
        }
        XCTAssertEqual(summary.allTime.input, 10)
        XCTAssertEqual(summary.allTime.output, 5)
    }

    /// A file of many short lines is looked at once, too.
    func testAManyShortLinesAreLookedAtOnce() async throws {
        var data = Data()
        let line = #"{"type":"assistant","timestamp":"2026-10-22T05:00:00.000Z","requestId":"req_1","message":{"id":"msg_1","role":"assistant","content":[],"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}}"#
        for index in 0..<20_000 {
            let text = String(line).replacingOccurrences(of: "msg_1", with: "msg_\(index)")
            data.append(Data(text.utf8))
            data.append(0x0A)
        }
        try write(data)
        let tally = ByteTally()
        _ = try await count(tally)
        XCTAssertLessThanOrEqual(tally.bytes, data.count * 2,
                                 "the file was looked at \(tally.bytes) times for \(data.count) bytes")
    }
}
