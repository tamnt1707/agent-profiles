import Foundation

extension OrchestrationKit {
    /// The labels a diagram asks for. The app maps each key to a text in its language.
    public static func diagramKeys(for workflow: Workflow) -> [String] {
        switch workflow {
        case .sequential:
            return ["goal", "plan", "code", "test", "review", "commit", "bug", "changes", "done"]
        case .queue:
            return ["goal", "plan", "worktrees", "lint", "merge", "queue", "tests", "idle", "suite",
                    "fix", "review", "upper", "wait", "red"]
        }
    }

    /// The workflow as a Mermaid flowchart. `text` turns a label key into the words shown in the box.
    public static func diagram(for workflow: Workflow, text: (String) -> String) -> String {
        func label(_ key: String) -> String {
            text(key).replacingOccurrences(of: "\"", with: "'")
                .replacingOccurrences(of: "\n", with: " ")
        }
        switch workflow {
        case .sequential:
            return """
            flowchart TD
              U(["\(label("goal"))"]) --> O["orchestrator<br/>\(label("plan"))"]
              O --> S["scout / researcher"]
              S --> B["builder<br/>\(label("code"))"]
              B --> T["tester<br/>\(label("test"))"]
              T -- "\(label("bug"))" --> B
              T --> R["reviewer<br/>\(label("review"))"]
              R -- "\(label("changes"))" --> B
              R --> C["committer<br/>\(label("commit"))"]
              C --> M(["\(label("done"))"])
            """
        case .queue:
            return """
            flowchart TD
              U(["\(label("goal"))"]) --> O["orchestrator<br/>\(label("plan"))"]
              O --> W["\(label("worktrees"))"]
              W --> F2["frontend-2d"]
              W --> F3["frontend-3d"]
              W --> BE["backend"]
              F2 --> L{"\(label("lint"))"}
              F3 --> L
              BE --> L
              L --> MB[("\(label("merge"))")]
              MB --> SE["secretary<br/>\(label("queue"))"]
              SE --> Q[".orchestra/queue<br/>0001, 0002, ..."]
              Q --> TE["tester<br/>\(label("tests"))"]
              TE --> I{"\(label("idle"))"}
              I -- "\(label("wait"))" --> W
              I --> SU["tester<br/>\(label("suite"))"]
              SU -- "\(label("red"))" --> FX["\(label("fix"))"]
              FX --> W
              SU --> RV["reviewer<br/>\(label("review"))"]
              RV --> UP(["\(label("upper"))"])
            """
        }
    }
}
