import XCTest
@testable import AgentProfilesCore

/// The queue workflow: its agents, its block, and the switch between workflows.
final class OrchestrationQueueTests: XCTestCase {
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

    private var kit: Profile { Profile.sample(slug: "kit", baseURL: "", isolate: true) }

    private func agentFile(_ name: String) -> URL {
        paths.home(for: "kit").appendingPathComponent("agents/\(name).md")
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    func testEveryQueueAgentIsEmbeddedWithItsOwnName() {
        for name in OrchestrationKit.queueAgentNames {
            let text = OrchestrationKit.agentText(name, mode: .tiered, workflow: .queue)
            XCTAssertTrue(text?.hasPrefix("---\nname: \(name)\n") == true, name)
        }
    }

    func testTheModelsFollowTheChoiceOfTheUser() throws {
        func model(_ name: String) -> String? {
            OrchestrationKit.agentText(name, mode: .tiered, workflow: .queue)?
                .split(separator: "\n").first { $0.hasPrefix("model:") }.map(String.init)
        }
        XCTAssertEqual(model("frontend-3d"), "model: opus")
        XCTAssertEqual(model("frontend-2d"), "model: sonnet")
        XCTAssertEqual(model("backend"), "model: sonnet")
        XCTAssertEqual(model("secretary"), "model: haiku")
        let inherited = OrchestrationKit.agentText("frontend-3d", mode: .inherit, workflow: .queue)
        XCTAssertTrue(inherited?.contains("model: inherit\n") == true)
    }

    func testTheQueueTesterIsNotTheSequentialOne() {
        XCTAssertNotEqual(
            OrchestrationKit.agentText("tester", mode: .tiered, workflow: .queue),
            OrchestrationKit.agentText("tester", mode: .tiered, workflow: .sequential)
        )
    }

    func testTheBlockIsMarkedAndTheWorkflowIsRead() {
        let queue = OrchestrationKit.block(for: .queue)
        XCTAssertTrue(queue.contains(OrchestrationKit.queueMarker))
        XCTAssertEqual(OrchestrationKit.workflow(ofBlockIn: queue), .queue)
        XCTAssertEqual(OrchestrationKit.workflow(ofBlockIn: OrchestrationKit.block), .sequential)
        XCTAssertNil(OrchestrationKit.workflow(ofBlockIn: "no block"))
        // The text of the template gave the marker no stray characters.
        XCTAssertFalse(queue.contains("\\"))
    }

    func testInstallWritesTheQueueAgentsAndTheBlock() throws {
        let report = try store.installOrchestration(for: kit, workflow: .queue)
        XCTAssertEqual(report.agents, .done(changed: 10))
        for name in OrchestrationKit.queueAgentNames {
            XCTAssertEqual(read(agentFile(name)), OrchestrationKit.agentText(name, mode: .tiered, workflow: .queue), name)
        }
        XCTAssertEqual(read(paths.home(for: "kit").appendingPathComponent("CLAUDE.md")), OrchestrationKit.block(for: .queue))

        let status = store.orchestrationStatus(for: kit)
        XCTAssertEqual(status.workflow, .queue)
        XCTAssertEqual(status.agentsPresent, 10)
        XCTAssertTrue(status.isCurrent)
    }

    func testSwitchingToSequentialTakesTheQueueOnlyAgentsOut() throws {
        _ = try store.installOrchestration(for: kit, workflow: .queue)
        _ = try store.installOrchestration(for: kit, workflow: .sequential)

        for name in ["frontend-2d", "frontend-3d", "backend", "secretary"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: agentFile(name).path), name)
        }
        let status = store.orchestrationStatus(for: kit)
        XCTAssertEqual(status.workflow, .sequential)
        XCTAssertEqual(status.agentsPresent, 6)
        XCTAssertTrue(status.isCurrent)
        XCTAssertEqual(read(agentFile("tester")), OrchestrationKit.agentText("tester", mode: .tiered))
    }

    func testSwitchingToQueueReplacesTheBlock() throws {
        _ = try store.installOrchestration(for: kit, workflow: .sequential)
        _ = try store.installOrchestration(for: kit, workflow: .queue)
        let text = read(paths.home(for: "kit").appendingPathComponent("CLAUDE.md")) ?? ""
        XCTAssertEqual(text, OrchestrationKit.block(for: .queue))
        XCTAssertEqual(text.components(separatedBy: OrchestrationKit.beginMark).count, 2)
    }

    func testRemoveTakesTheAgentsOfBothWorkflows() throws {
        _ = try store.installOrchestration(for: kit, workflow: .queue)
        _ = try store.removeOrchestration(for: kit)
        for name in OrchestrationKit.queueAgentNames {
            XCTAssertFalse(FileManager.default.fileExists(atPath: agentFile(name).path), name)
        }
        XCTAssertTrue(store.orchestrationStatus(for: kit).isEmpty)
    }

    func testAQueueInstallAgainChangesNothing() throws {
        _ = try store.installOrchestration(for: kit, workflow: .queue)
        let again = try store.installOrchestration(for: kit, workflow: .queue)
        XCTAssertEqual(again.agents, .done(changed: 0))
        XCTAssertEqual(again.claudeMd, .done(changed: 0))
    }
}
