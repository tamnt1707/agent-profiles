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

/// The Mermaid diagrams of the two workflows.
final class OrchestrationDiagramTests: XCTestCase {
    func testEveryKeyIsUsedAndEveryAgentIsDrawn() {
        for workflow in OrchestrationKit.Workflow.allCases {
            var asked: Set<String> = []
            let text = OrchestrationKit.diagram(for: workflow) { key in asked.insert(key); return "<\(key)>" }
            XCTAssertTrue(text.hasPrefix("flowchart TD"), "\(workflow)")
            XCTAssertEqual(asked, Set(OrchestrationKit.diagramKeys(for: workflow)), "\(workflow)")
        }
        let queue = OrchestrationKit.diagram(for: .queue) { $0 }
        for name in ["frontend-2d", "frontend-3d", "backend", "secretary", "tester", "reviewer"] {
            XCTAssertTrue(queue.contains(name), name)
        }
        let sequential = OrchestrationKit.diagram(for: .sequential) { $0 }
        XCTAssertTrue(sequential.contains("builder"))
        XCTAssertFalse(sequential.contains("secretary"))
    }

    func testAQuoteInALabelCannotBreakTheDiagram() {
        let text = OrchestrationKit.diagram(for: .sequential) { _ in "a \"b\"\nc" }
        XCTAssertFalse(text.contains("\"b\""))
    }
}

/// Agents that the kit dropped are taken out of `agents/`, with a copy.
final class OrchestrationRetiredTests: XCTestCase {
    func testARetiredAgentIsBackedUpAndRemovedAndOthersStay() throws {
        let temp = try TempDirectory()
        let paths = temp.paths()
        let store = Store(paths: paths, keys: InMemoryKeyStore())
        let profile = Profile.sample(slug: "kit", baseURL: "", isolate: true)
        _ = try store.installOrchestration(for: profile)

        let agents = paths.home(for: "kit").appendingPathComponent("agents")
        try "old kit agent".write(to: agents.appendingPathComponent("oldname.md"), atomically: true, encoding: .utf8)
        try "mine".write(to: agents.appendingPathComponent("mine.md"), atomically: true, encoding: .utf8)

        let report = try store.installOrchestration(for: profile, retired: ["oldname"], now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(report.agents, .done(changed: 1))

        let names = try FileManager.default.contentsOfDirectory(atPath: agents.path)
        XCTAssertFalse(names.contains("oldname.md"))
        XCTAssertTrue(names.contains("mine.md"))
        let backup = try XCTUnwrap(names.first { $0.hasPrefix("oldname.md.bak.") })
        XCTAssertEqual(try String(contentsOf: agents.appendingPathComponent(backup), encoding: .utf8), "old kit agent")
    }

    func testTheQueueOnlyAgentsAreBackedUpWhenTheyLeave() throws {
        let temp = try TempDirectory()
        let paths = temp.paths()
        let store = Store(paths: paths, keys: InMemoryKeyStore())
        let profile = Profile.sample(slug: "kit", baseURL: "", isolate: true)
        _ = try store.installOrchestration(for: profile, workflow: .queue)
        _ = try store.installOrchestration(for: profile, workflow: .sequential)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: paths.home(for: "kit").appendingPathComponent("agents").path)
        XCTAssertFalse(names.contains("secretary.md"))
        XCTAssertTrue(names.contains { $0.hasPrefix("secretary.md.bak.") })
    }
}

/// How a tab starts Claude: the mode and the agents it needs.
final class TerminalLaunchTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: Paths!
    private var store: Store!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        paths = temp.paths()
        store = Store(paths: paths, keys: InMemoryKeyStore())
    }

    private var kit: Profile { Profile.sample(slug: "kit", baseURL: "", isolate: true) }

    func testANormalStartAddsNothing() throws {
        let plain = try EmbeddedTerminalSpec.shellCommand(for: kit, paths: paths)
        XCTAssertEqual(try EmbeddedTerminalSpec.shellCommand(for: kit, paths: paths, mode: .normal), plain)
    }

    func testAnOrchestratorStartUsesOpusMediumAndTheInstructions() throws {
        for workflow in OrchestrationKit.Workflow.allCases {
            let command = try EmbeddedTerminalSpec.shellCommand(for: kit, paths: paths, mode: .orchestrated(workflow))
            XCTAssertTrue(command.contains("claude-kit --model opus --effort medium --append-system-prompt '"), command)
            XCTAssertTrue(command.contains(workflow == .queue ? "queue workflow" : "Default workflow"), "\(workflow)")
            XCTAssertFalse(command.contains("--resume"))
        }
    }

    func testAgentsForASessionGoInWithoutTheBlockAndTakeAnOldBlockOut() throws {
        XCTAssertFalse(store.orchestrationAgentsReady(for: kit, workflow: .queue))
        _ = try store.installOrchestration(for: kit, workflow: .sequential)   // with the block
        let claudeMd = paths.home(for: "kit").appendingPathComponent("CLAUDE.md")
        XCTAssertTrue(OrchestrationKit.hasBlock((try? String(contentsOf: claudeMd, encoding: .utf8)) ?? ""))

        _ = try store.installOrchestration(for: kit, workflow: .queue, withBlock: false)
        XCTAssertFalse(OrchestrationKit.hasBlock((try? String(contentsOf: claudeMd, encoding: .utf8)) ?? ""))
        XCTAssertTrue(store.orchestrationAgentsReady(for: kit, workflow: .queue))
        XCTAssertFalse(store.orchestrationAgentsReady(for: kit, workflow: .sequential))
    }

    func testNoBlockIsCreatedWhenThereIsNoClaudeMd() throws {
        _ = try store.installOrchestration(for: kit, workflow: .queue, withBlock: false)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.home(for: "kit").appendingPathComponent("CLAUDE.md").path))
    }
}
