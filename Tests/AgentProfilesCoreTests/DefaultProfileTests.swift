import XCTest
@testable import AgentProfilesCore

/// The default setup (`~/.claude`) is a profile that lives in memory only.
final class DefaultProfileTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: Paths!
    private var store: Store!

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

    func testNoNameCanProduceTheReservedSlug() {
        XCTAssertNil(Slug.slugify("_default").firstIndex(of: "_"))
        XCTAssertNotEqual(Slug.slugify("default"), Profile.defaultSlug)
        XCTAssertTrue(Profile.defaultClaude.isDefaultClaude)
        XCTAssertFalse(Profile.sample(slug: "default").isDefaultClaude)
    }

    func testItsFolderIsTheClaudeFolderAndItsCommandIsPlainClaude() {
        XCTAssertEqual(paths.home(for: Profile.defaultSlug), paths.defaultClaudeDir)
        XCTAssertEqual(paths.command(for: Profile.defaultSlug), "claude")
        XCTAssertEqual(paths.command(for: "work"), "claude-work")
    }

    func testTheLauncherCommandIsPlainClaude() throws {
        XCTAssertEqual(try Launcher.command(for: .defaultClaude, paths: paths, useShortName: true), "claude")
        let inFolder = try Launcher.command(for: .defaultClaude, paths: paths, workdirOverride: "/tmp/x", useShortName: true)
        XCTAssertEqual(inFolder, "cd '/tmp/x' && claude")
    }

    func testItIsNeverWrittenToTheDataFile() {
        var data = AppData()
        data.profiles = [.defaultClaude, Profile.sample(slug: "work")]
        let text = JSONText.encode(data)
        XCTAssertFalse(text.contains("\"slug\": \"\(Profile.defaultSlug)\""))
        XCTAssertTrue(text.contains("\"work\""))
        data.profiles = [.defaultClaude]
        XCTAssertTrue(JSONText.encode(data).contains("\"profiles\": []"))
    }

    func testMaterializeWritesNothing() throws {
        try store.materialize(.defaultClaude)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.script(for: Profile.defaultSlug).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.binDir.path))
    }

    func testRemoveIsRefusedAndTheFolderStays() throws {
        try FileManager.default.createDirectory(at: paths.defaultClaudeDir, withIntermediateDirectories: true)
        let marker = paths.defaultClaudeDir.appendingPathComponent("keep.txt")
        try Data("x".utf8).write(to: marker)
        XCTAssertThrowsError(try store.remove(.defaultClaude))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testTheKitCanBeInstalledAndRemovedInTheClaudeFolder() throws {
        try FileManager.default.createDirectory(at: paths.defaultClaudeDir, withIntermediateDirectories: true)
        _ = try store.installOrchestration(for: .defaultClaude)
        let agents = paths.defaultClaudeDir.appendingPathComponent("agents")
        XCTAssertTrue(FileManager.default.fileExists(atPath: agents.appendingPathComponent("scout.md").path))
        XCTAssertTrue(store.orchestrationStatus(for: .defaultClaude).isCurrent)
        _ = try store.removeOrchestration(for: .defaultClaude)
        XCTAssertFalse(FileManager.default.fileExists(atPath: agents.appendingPathComponent("scout.md").path))
    }
}
