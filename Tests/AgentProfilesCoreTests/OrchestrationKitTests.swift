import XCTest
@testable import AgentProfilesCore

/// The orchestration kit goes into the config folder of one profile and
/// nowhere else: a link to `~/.claude` is never written through.
final class OrchestrationKitTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: Paths!
    private var store: Store!
    private let manager = FileManager.default

    override func setUpWithError() throws {
        temp = try TempDirectory()
        paths = temp.paths()
        store = Store(paths: paths, keys: InMemoryKeyStore())
    }

    override func tearDown() {
        temp = nil
        paths = nil
        store = nil
    }

    private func profile(base: String = "", isolate: Bool = true) -> Profile {
        Profile.sample(slug: "kit", baseURL: base, isolate: isolate)
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The files

    func testEveryAgentAndTheTemplateAreEmbedded() {
        for name in OrchestrationKit.agentNames {
            let text = OrchestrationKit.agentText(name, mode: .tiered)
            XCTAssertNotNil(text, name)
            XCTAssertTrue(text?.hasPrefix("---\nname: \(name)\n") == true, name)
            XCTAssertTrue(text?.hasSuffix("\n") == true, name)
        }
        XCTAssertTrue(OrchestrationKit.block.hasPrefix(OrchestrationKit.beginMark + "\n"))
        XCTAssertTrue(OrchestrationKit.block.hasSuffix(OrchestrationKit.endMark + "\n"))
    }

    func testTieredKeepsTheModelsAndInheritChangesOnlyThatLine() throws {
        let tiered = try XCTUnwrap(OrchestrationKit.agentText("scout", mode: .tiered))
        let inherit = try XCTUnwrap(OrchestrationKit.agentText("scout", mode: .inherit))
        XCTAssertTrue(tiered.contains("\nmodel: haiku\n"))
        XCTAssertTrue(inherit.contains("\nmodel: inherit\n"))
        XCTAssertEqual(tiered.replacingOccurrences(of: "model: haiku", with: "model: inherit"), inherit)
    }

    // MARK: - The model mode

    func testModelMode() {
        XCTAssertEqual(OrchestrationKit.modelMode(for: profile()).mode, .tiered)
        let distinct = Profile.sample(baseURL: "https://api.x.io/anthropic")
        var three = distinct
        three.opusModel = "o"; three.sonnetModel = "s"; three.haikuModel = "h"
        XCTAssertEqual(OrchestrationKit.modelMode(for: three).mode, .tiered)

        XCTAssertEqual(OrchestrationKit.modelMode(for: distinct).reason, .noMapping(host: "api.x.io"))
        var same = distinct
        same.opusModel = "m"; same.sonnetModel = "m"; same.haikuModel = "m"
        XCTAssertEqual(OrchestrationKit.modelMode(for: same).reason, .sameModel("m"))
        var some = distinct
        some.sonnetModel = "s"
        XCTAssertEqual(OrchestrationKit.modelMode(for: some).reason, .partialMapping(host: "api.x.io"))
        XCTAssertEqual(OrchestrationKit.modelMode(for: some).mode, .inherit)
    }

    // MARK: - The block of CLAUDE.md

    func testBlockIsAddedOnceAndReplaced() {
        let mine = "# My rules\n\n- be kind\n"
        let once = OrchestrationKit.addingBlock(to: mine)
        XCTAssertTrue(once.hasPrefix(mine + "\n" + OrchestrationKit.beginMark))
        XCTAssertEqual(OrchestrationKit.addingBlock(to: once), once)
        XCTAssertEqual(once.components(separatedBy: OrchestrationKit.beginMark).count, 2)
    }

    func testRemovingTheBlockGivesBackTheOriginal() {
        for mine in ["", "# My rules\n", "# My rules\n\n- be kind\n", "no newline at the end"] {
            let withBlock = OrchestrationKit.addingBlock(to: mine)
            let expected = mine.isEmpty || mine.hasSuffix("\n") ? mine : mine + "\n"
            XCTAssertEqual(OrchestrationKit.removingBlock(from: withBlock), expected, mine)
        }
    }

    // MARK: - Install

    func testInstallWritesTheAgentsAndTheBlock() throws {
        let report = try store.installOrchestration(for: profile())
        XCTAssertEqual(report.agents, .done(changed: 6))
        XCTAssertEqual(report.claudeMd, .done(changed: 1))

        let home = paths.home(for: "kit")
        for name in OrchestrationKit.agentNames {
            XCTAssertEqual(read(home.appendingPathComponent("agents/\(name).md")),
                           OrchestrationKit.agentText(name, mode: .tiered))
        }
        XCTAssertEqual(read(home.appendingPathComponent("CLAUDE.md")), OrchestrationKit.block)

        let status = store.orchestrationStatus(for: profile())
        XCTAssertEqual(status.agentsPresent, 6)
        XCTAssertTrue(status.isCurrent)
    }

    func testInstallAgainChangesNothing() throws {
        _ = try store.installOrchestration(for: profile())
        let again = try store.installOrchestration(for: profile())
        XCTAssertEqual(again.agents, .done(changed: 0))
        XCTAssertEqual(again.claudeMd, .done(changed: 0))
    }

    func testInstallKeepsTheTextOfTheUserAndBacksUpWhatItReplaces() throws {
        let home = paths.home(for: "kit")
        try manager.createDirectory(at: home.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try "# Mine\n".write(to: home.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "old scout".write(to: home.appendingPathComponent("agents/scout.md"), atomically: true, encoding: .utf8)
        try "my own agent".write(to: home.appendingPathComponent("agents/mine.md"), atomically: true, encoding: .utf8)

        _ = try store.installOrchestration(for: profile(), now: Date(timeIntervalSince1970: 0))

        XCTAssertTrue(read(home.appendingPathComponent("CLAUDE.md"))?.hasPrefix("# Mine\n\n") == true)
        XCTAssertEqual(read(home.appendingPathComponent("agents/mine.md")), "my own agent")
        let names = try manager.contentsOfDirectory(atPath: home.appendingPathComponent("agents").path)
        XCTAssertTrue(names.contains { $0.hasPrefix("scout.md.bak.") })
        let backup = try XCTUnwrap(names.first { $0.hasPrefix("scout.md.bak.") })
        XCTAssertEqual(read(home.appendingPathComponent("agents/\(backup)")), "old scout")
        XCTAssertTrue(names.contains { $0.hasPrefix("CLAUDE.md.bak.") } == false)
        let top = try manager.contentsOfDirectory(atPath: home.path)
        XCTAssertTrue(top.contains { $0.hasPrefix("CLAUDE.md.bak.") })
    }

    func testInstallIntoAProfileThatIsNotIsolatedIsRefused() {
        XCTAssertThrowsError(try store.installOrchestration(for: profile(isolate: false))) {
            XCTAssertEqual($0 as? OrchestrationError, .notIsolated)
        }
    }

    func testInstallNeverWritesThroughALink() throws {
        // `~/.claude` of the test, with the files that a profile shares.
        let shared = temp.url.appendingPathComponent("default-claude")
        try manager.createDirectory(at: shared.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try "global rules\n".write(to: shared.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "global agent".write(to: shared.appendingPathComponent("agents/global.md"), atomically: true, encoding: .utf8)

        let home = paths.home(for: "kit")
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: home.appendingPathComponent("agents"),
                                       withDestinationURL: shared.appendingPathComponent("agents"))
        try manager.createSymbolicLink(at: home.appendingPathComponent("CLAUDE.md"),
                                       withDestinationURL: shared.appendingPathComponent("CLAUDE.md"))

        let report = try store.installOrchestration(for: profile())
        XCTAssertEqual(report.agents, .refused(.shared))
        XCTAssertEqual(report.claudeMd, .refused(.shared))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: shared.appendingPathComponent("agents").path), ["global.md"])
        XCTAssertEqual(read(shared.appendingPathComponent("CLAUDE.md")), "global rules\n")

        let status = store.orchestrationStatus(for: profile())
        XCTAssertEqual(status.agentsRefusal, .shared)
        XCTAssertEqual(status.claudeMdRefusal, .shared)
    }

    // MARK: - Own copy of a shared item

    func testUnshareReplacesTheLinkWithACopyAndLeavesTheTargetAlone() throws {
        let shared = temp.url.appendingPathComponent("default-claude")
        try manager.createDirectory(at: shared.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try "global rules\n".write(to: shared.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "global agent".write(to: shared.appendingPathComponent("agents/global.md"), atomically: true, encoding: .utf8)
        let home = paths.home(for: "kit")
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: home.appendingPathComponent("agents"),
                                       withDestinationURL: shared.appendingPathComponent("agents"))
        try manager.createSymbolicLink(at: home.appendingPathComponent("CLAUDE.md"),
                                       withDestinationURL: shared.appendingPathComponent("CLAUDE.md"))

        try store.unshareOrchestrationItem(.agents, for: profile())
        try store.unshareOrchestrationItem(.claudeMd, for: profile())
        XCTAssertEqual(SafeFileSystem.kind(of: home.appendingPathComponent("agents")), .directory)
        XCTAssertEqual(SafeFileSystem.kind(of: home.appendingPathComponent("CLAUDE.md")), .file)
        XCTAssertEqual(read(home.appendingPathComponent("agents/global.md")), "global agent")

        let report = try store.installOrchestration(for: profile())
        XCTAssertEqual(report.agents, .done(changed: 6))
        XCTAssertEqual(report.claudeMd, .done(changed: 1))
        XCTAssertTrue(read(home.appendingPathComponent("CLAUDE.md"))?.hasPrefix("global rules\n\n") == true)
        // The shared files are the ones they were.
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: shared.appendingPathComponent("agents").path), ["global.md"])
        XCTAssertEqual(read(shared.appendingPathComponent("CLAUDE.md")), "global rules\n")
    }

    // MARK: - Remove

    func testRemoveTakesOnlyWhatTheKitWrote() throws {
        let home = paths.home(for: "kit")
        try manager.createDirectory(at: home.appendingPathComponent("agents"), withIntermediateDirectories: true)
        try "# Mine\n".write(to: home.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        try "my own agent".write(to: home.appendingPathComponent("agents/mine.md"), atomically: true, encoding: .utf8)
        _ = try store.installOrchestration(for: profile())

        let report = try store.removeOrchestration(for: profile())
        XCTAssertEqual(report.agents, .done(changed: 6))
        XCTAssertEqual(report.claudeMd, .done(changed: 1))
        XCTAssertEqual(read(home.appendingPathComponent("CLAUDE.md")), "# Mine\n")
        XCTAssertEqual(read(home.appendingPathComponent("agents/mine.md")), "my own agent")
        XCTAssertTrue(store.orchestrationStatus(for: profile()).isEmpty)
    }

    func testStatusSeesAnOutdatedInstall() throws {
        _ = try store.installOrchestration(for: profile())
        let file = paths.home(for: "kit").appendingPathComponent("agents/builder.md")
        try "changed".write(to: file, atomically: true, encoding: .utf8)
        let status = store.orchestrationStatus(for: profile())
        XCTAssertEqual(status.agentsPresent, 6)
        XCTAssertEqual(status.agentsCurrent, 5)
        XCTAssertFalse(status.isCurrent)
    }
}
