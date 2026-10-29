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
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            ["/bin/sh", "-c", HeartbeatAgent.runner, "heartbeat", paths.script(for: "work").path, "-p", "ping"]
        )
        let env = try XCTUnwrap(plist["EnvironmentVariables"] as? [String: String])
        XCTAssertEqual(env["HEARTBEAT_RESULT"], agent(LaunchctlStub()).resultURL(for: "work").path)
        XCTAssertNil(plist["StandardOutPath"], "nothing is appended to a log")
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

    // MARK: - Complete removal

    func testRemovingTheAgentDeletesItsLogAndTheEmptyFolder() throws {
        let stub = LaunchctlStub()
        let beat = Heartbeat(enabled: true, times: [time("05:00")])
        let a = agent(stub)
        try a.apply(profile(heartbeat: beat))
        try Data("pong".utf8).write(to: a.resultURL(for: "work"))
        XCTAssertTrue(a.hasTraces(slug: "work"))
        XCTAssertTrue(a.remove(slug: "work"))
        XCTAssertFalse(a.hasTraces(slug: "work"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.resultURL(for: "work").deletingLastPathComponent().path))
    }

    func testSyncDeletesTheLogOfAProfileThatIsGone() throws {
        let stub = LaunchctlStub()
        let a = agent(stub)
        try FileManager.default.createDirectory(at: a.resultURL(for: "gone").deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: a.resultURL(for: "gone"))
        a.sync([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.resultURL(for: "gone").path))
    }

    func testStoreRemoveTakesTheHeartbeatWithIt() throws {
        let stub = LaunchctlStub()
        let store = Store(paths: paths, keys: InMemoryKeyStore(), heartbeatRunner: stub)
        let p = profile(heartbeat: Heartbeat(enabled: true, times: [time("05:00")]))
        try store.materialize(p)
        let a = HeartbeatAgent(paths: paths, runner: stub, userID: 501, searchPath: { "/usr/bin" })
        try a.apply(p)
        let report = try store.remove(p)
        XCTAssertTrue(report.removedHeartbeat)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertFalse(a.hasTraces(slug: "work"))
    }

    func testTheDeleteDialogListsTheScheduleOnlyWhenThereIsOne() {
        var data = AppData()
        data.profiles = [profile("a", heartbeat: .off), profile("b", heartbeat: Heartbeat(enabled: true, times: [time("05:00")]))]
        XCTAssertFalse(DeleteTarget(index: 0, in: data, paths: paths, measure: { _ in nil })!.items.contains(.schedule))
        XCTAssertTrue(DeleteTarget(index: 1, in: data, paths: paths, measure: { _ in nil })!.items.contains(.schedule))
    }

    // MARK: - The default setup

    func testTheDefaultSetupRunsTheCLIItself() throws {
        let a = HeartbeatAgent(paths: paths, runner: LaunchctlStub(), userID: 501, searchPath: { "/usr/bin" }, cliPath: { "/opt/bin/claude" })
        var p = Profile.defaultClaude
        p.heartbeat = Heartbeat(enabled: true, times: [time("05:00")])
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: a.plist(for: p), format: nil) as? [String: Any])
        XCTAssertEqual(Array((plist["ProgramArguments"] as? [String] ?? []).suffix(3)), ["/opt/bin/claude", "-p", "ping"])
    }

    func testTheDefaultSetupWithoutACLIFails() {
        let a = HeartbeatAgent(paths: paths, runner: LaunchctlStub(), userID: 501, searchPath: { "" }, cliPath: { nil })
        var p = Profile.defaultClaude
        p.heartbeat = Heartbeat(enabled: true, times: [time("05:00")])
        XCTAssertThrowsError(try a.plist(for: p))
    }

    func testTheDefaultHeartbeatIsKeptInTheDataFile() throws {
        var data = AppData()
        data.defaultHeartbeat = Heartbeat(enabled: true, times: [time("05:00")], days: [1])
        let text = JSONText.encode(data)
        XCTAssertTrue(text.contains("\"default_heartbeat\""))
        XCTAssertEqual(try JSONDecoder().decode(AppData.self, from: Data(text.utf8)).defaultHeartbeat, data.defaultHeartbeat)
        XCTAssertFalse(JSONText.encode(AppData()).contains("default_heartbeat"))
    }

    // MARK: - The result of the last run

    func testTheResultFileIsParsed() throws {
        let result = try XCTUnwrap(HeartbeatResult(parsing: "1790000000\n0\npong\n"))
        XCTAssertEqual(result.date, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.output, "pong")
        let failed = try XCTUnwrap(HeartbeatResult(parsing: "1790000000\n1\nAPI Error: 401"))
        XCTAssertFalse(failed.isSuccess)
        XCTAssertEqual(failed.output, "API Error: 401")
        XCTAssertEqual(HeartbeatResult(parsing: "1790000000\n0")?.output, "")
    }

    func testABrokenResultFileIsNotAResult() {
        XCTAssertNil(HeartbeatResult(parsing: ""))
        XCTAssertNil(HeartbeatResult(parsing: "soon\n0\nx"))
        XCTAssertNil(HeartbeatResult(parsing: "1790000000\nzero\nx"))
        XCTAssertNil(HeartbeatResult(parsing: "0\n0\nx"))
    }

    func testLastResultReadsTheFileOfTheSlug() throws {
        let a = agent(LaunchctlStub())
        XCTAssertNil(a.lastResult(slug: "work"))
        try FileManager.default.createDirectory(at: a.resultURL(for: "work").deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("1790000000\n0\npong".utf8).write(to: a.resultURL(for: "work"))
        XCTAssertEqual(a.lastResult(slug: "work")?.output, "pong")
    }

    /// The shell of the agent really runs, writes one file and overwrites it on the next run.
    func testTheRunnerWritesOneFileThatIsReplacedEachRun() throws {
        let result = home.appendingPathComponent("last").path
        func run(_ program: String, _ arguments: [String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", HeartbeatAgent.runner, "heartbeat", program] + arguments
            process.environment = ["HEARTBEAT_RESULT": result, "PATH": "/usr/bin:/bin"]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertEqual(try run("/bin/echo", ["-p", "pong"]), 0)
        XCTAssertEqual(HeartbeatResult(parsing: try String(contentsOfFile: result, encoding: .utf8))?.output, "-p pong")

        XCTAssertEqual(try run("/usr/bin/false", []), 1)
        let second = try XCTUnwrap(HeartbeatResult(parsing: try String(contentsOfFile: result, encoding: .utf8)))
        XCTAssertEqual(second.exitCode, 1)
        XCTAssertFalse(second.output.contains("pong"), "only the last run is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: result + ".tmp"))
    }

    func testTheOutputIsCutSoTheFileStaysSmall() throws {
        let result = home.appendingPathComponent("big").path
        let long = String(repeating: "a", count: 10_000)
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/bin/sh")
        run.arguments = ["-c", HeartbeatAgent.runner, "heartbeat", "/usr/bin/printf", long]
        run.environment = ["HEARTBEAT_RESULT": result, "PATH": "/usr/bin:/bin"]
        try run.run()
        run.waitUntilExit()
        let size = (try FileManager.default.attributesOfItem(atPath: result)[.size] as? Int) ?? 0
        XCTAssertLessThan(size, 2100)
    }

    func testApplyDeletesTheOldAppendedLog() throws {
        let a = agent(LaunchctlStub())
        let folder = a.resultURL(for: "work").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = folder.appendingPathComponent("work.log")
        try Data("pong\npong\n".utf8).write(to: old)
        try a.apply(profile(heartbeat: Heartbeat(enabled: true, times: [time("05:00")])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }
}
