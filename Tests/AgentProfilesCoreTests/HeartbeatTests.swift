import XCTest
@testable import AgentProfilesCore

/// A `launchctl` that records what it is asked and answers with a fixed status
/// for `print` (is the agent loaded).
private final class LaunchctlStub: ProcessRunner {
    var printStatus: Int32 = 1
    var bootstrapStatus: Int32 = 0
    private(set) var calls: [[String]] = []

    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        calls.append(arguments)
        switch arguments.first {
        case "print": return ProcessResult(status: printStatus)
        case "bootstrap": return ProcessResult(status: bootstrapStatus, output: "boom")
        default: return ProcessResult(status: 0)
        }
    }

    func commands() -> [String] { calls.compactMap(\.first) }
}

final class HeartbeatTests: XCTestCase {
    private var home: URL!
    private var paths: Paths!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("heartbeat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = Paths(home: home)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
    }

    private func profile(_ slug: String = "work", heartbeat: Heartbeat) -> Profile {
        Profile(name: slug, slug: slug, heartbeat: heartbeat)
    }

    private func agent(_ stub: LaunchctlStub) -> HeartbeatAgent {
        HeartbeatAgent(paths: paths, runner: stub, userID: 501, searchPath: { "/opt/bin:/usr/bin" })
    }

    private func time(_ text: String) -> ClockTime { ClockTime(text: text)! }

    // MARK: - ClockTime

    func testClockTimeParsesAndPrints() {
        XCTAssertEqual(ClockTime(text: "05:00")?.text, "05:00")
        XCTAssertEqual(ClockTime(text: "5:07")?.text, "05:07")
        XCTAssertNil(ClockTime(text: "24:00"))
        XCTAssertNil(ClockTime(text: "12:60"))
        XCTAssertNil(ClockTime(text: "12:5"))
        XCTAssertNil(ClockTime(text: "noon"))
        XCTAssertNil(ClockTime(hour: -1, minute: 0))
    }

    func testWindowEndIsFiveHoursLaterAndWrapsMidnight() {
        XCTAssertEqual(time("05:00").windowEnd.text, "10:00")
        XCTAssertEqual(time("22:30").windowEnd.text, "03:30")
    }

    // MARK: - Heartbeat

    func testTimesAreSortedWithoutDuplicatesAndCut() {
        let beat = Heartbeat(enabled: true, times: [time("10:00"), time("05:00"), time("10:00")])
        XCTAssertEqual(beat.times.map(\.text), ["05:00", "10:00"])
        let many = (0..<12).map { ClockTime(hour: $0, minute: 0)! }
        XCTAssertEqual(Heartbeat(times: many).times.count, Heartbeat.maxTimes)
    }

    func testInvalidDaysAreDropped() {
        XCTAssertEqual(Heartbeat(days: [0, 1, 7, 8]).days, [1, 7])
    }

    func testActiveNeedsEnabledAndATime() {
        XCTAssertFalse(Heartbeat(enabled: true).isActive)
        XCTAssertFalse(Heartbeat(enabled: false, times: [time("05:00")]).isActive)
        XCTAssertTrue(Heartbeat(enabled: true, times: [time("05:00")]).isActive)
    }

    // MARK: - The file

    func testOffIsNotWrittenAndOldFilesStayTheSame() throws {
        let json = JSONText.encode(profile(heartbeat: .off), indent: 0)
        XCTAssertFalse(json.contains("heartbeat"))
        let decoded = try JSONDecoder().decode(Profile.self, from: Data("{\"name\":\"a\",\"slug\":\"a\"}".utf8))
        XCTAssertEqual(decoded.heartbeat, .off)
    }

    func testScheduleSurvivesTheCustomWriterAndTheDecoder() throws {
        let beat = Heartbeat(enabled: true, times: [time("05:00"), time("10:30")], days: [1, 3, 5])
        let json = JSONText.encode(profile(heartbeat: beat), indent: 0)
        XCTAssertTrue(json.contains("\"heartbeat\""))
        let decoded = try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.heartbeat, beat)
    }

    func testCodableRoundTrip() throws {
        let beat = Heartbeat(enabled: true, times: [time("05:00")])
        let data = try JSONEncoder().encode(profile(heartbeat: beat))
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: data).heartbeat, beat)
    }

    func testBrokenScheduleIsDroppedAndTheProfileLoads() throws {
        let text = "{\"name\":\"a\",\"slug\":\"a\",\"heartbeat\":{\"enabled\":\"yes\",\"times\":[\"25:99\",\"06:00\"],\"days\":[9]}}"
        let decoded = try JSONDecoder().decode(Profile.self, from: Data(text.utf8))
        XCTAssertEqual(decoded.heartbeat.times.map(\.text), ["06:00"])
        XCTAssertFalse(decoded.heartbeat.enabled)
        XCTAssertTrue(decoded.heartbeat.days.isEmpty)
    }

    // MARK: - The plist

    func testCalendarEntriesCrossTimesAndDays() {
        let beat = Heartbeat(enabled: true, times: [time("05:00"), time("10:00")], days: [1, 2])
        XCTAssertEqual(HeartbeatAgent.calendarEntries(for: beat).count, 4)
        let every = Heartbeat(enabled: true, times: [time("05:00")])
        XCTAssertEqual(HeartbeatAgent.calendarEntries(for: every), [["Hour": 5, "Minute": 0]])
    }

    func testPlistRunsTheLauncherWithPing() throws {
        let beat = Heartbeat(enabled: true, times: [time("05:00")], days: [2])
        let data = try agent(LaunchctlStub()).plist(for: profile(heartbeat: beat))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "com.agentprofiles.heartbeat.work")
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [paths.script(for: "work").path, "-p", "ping"])
        XCTAssertEqual((plist["EnvironmentVariables"] as? [String: String])?["PATH"], "/opt/bin:/usr/bin")
        let entries = try XCTUnwrap(plist["StartCalendarInterval"] as? [[String: Int]])
        XCTAssertEqual(entries, [["Hour": 5, "Minute": 0, "Weekday": 2]])
    }

    func testPlistHoldsNoKey() throws {
        let beat = Heartbeat(enabled: true, times: [time("05:00")])
        var p = profile(heartbeat: beat)
        p.extraEnv = "SECRET=abc"
        let text = String(decoding: try agent(LaunchctlStub()).plist(for: p), as: UTF8.self)
        XCTAssertFalse(text.contains("abc"))
    }

    // MARK: - Install and remove

    func testApplyWritesThePlistAndLoadsIt() throws {
        let stub = LaunchctlStub()
        let beat = Heartbeat(enabled: true, times: [time("05:00")])
        try agent(stub).apply(profile(heartbeat: beat))
        XCTAssertTrue(FileManager.default.fileExists(atPath: agent(stub).plistURL(for: "work").path))
        XCTAssertTrue(stub.commands().contains("bootstrap"))
        XCTAssertTrue(stub.calls.contains { $0 == ["bootstrap", "gui/501", agent(stub).plistURL(for: "work").path] })
    }

    func testApplyDoesNothingWhenUnchangedAndLoaded() throws {
        let stub = LaunchctlStub()
        let beat = Heartbeat(enabled: true, times: [time("05:00")])
        try agent(stub).apply(profile(heartbeat: beat))
        stub.printStatus = 0
        let before = stub.calls.count
        try agent(stub).apply(profile(heartbeat: beat))
        XCTAssertEqual(stub.calls.dropFirst(before).compactMap(\.first), ["print"])
    }

    func testApplyReloadsWhenTheScheduleChanges() throws {
        let stub = LaunchctlStub()
        stub.printStatus = 0
        try agent(stub).apply(profile(heartbeat: Heartbeat(enabled: true, times: [time("05:00")])))
        let before = stub.calls.count
        try agent(stub).apply(profile(heartbeat: Heartbeat(enabled: true, times: [time("06:00")])))
        let commands = stub.calls.dropFirst(before).compactMap(\.first)
        XCTAssertTrue(commands.contains("bootout"))
        XCTAssertTrue(commands.contains("bootstrap"))
    }

    func testApplyReportsAFailedBootstrap() {
        let stub = LaunchctlStub()
        stub.bootstrapStatus = 5
        XCTAssertThrowsError(try agent(stub).apply(profile(heartbeat: Heartbeat(enabled: true, times: [time("05:00")]))))
    }

    func testTurningTheScheduleOffRemovesTheAgent() throws {
        let stub = LaunchctlStub()
        try agent(stub).apply(profile(heartbeat: Heartbeat(enabled: true, times: [time("05:00")])))
        try agent(stub).apply(profile(heartbeat: Heartbeat(enabled: false, times: [time("05:00")])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent(stub).plistURL(for: "work").path))
        XCTAssertTrue(stub.commands().contains("bootout"))
    }

    func testSyncRemovesTheAgentsOfProfilesThatAreGone() throws {
        let stub = LaunchctlStub()
        let beat = Heartbeat(enabled: true, times: [time("05:00")])
        try agent(stub).apply(profile("old", heartbeat: beat))
        let failed = agent(stub).sync([profile("new", heartbeat: beat)])
        XCTAssertTrue(failed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: agent(stub).plistURL(for: "old").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: agent(stub).plistURL(for: "new").path))
    }

    func testSyncNeverTouchesFilesOfOtherPrograms() throws {
        let dir = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let foreign = dir.appendingPathComponent("com.other.tool.plist")
        try Data("x".utf8).write(to: foreign)
        agent(LaunchctlStub()).sync([])
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path))
    }

    func testRunNowKickstartsTheAgent() throws {
        let stub = LaunchctlStub()
        try agent(stub).runNow(slug: "work")
        XCTAssertEqual(stub.calls.last, ["kickstart", "gui/501/com.agentprofiles.heartbeat.work"])
    }
}
