import AppKit
import Foundation
import Observation
import SwiftTerm
import AgentProfilesCore

/// The embedded terminals of the app: any number of tabs for each profile.
///
/// A tab owns its terminal view for as long as it lives, so the window can show
/// another profile and come back: the view is put in the window again with
/// everything it printed and its process still running.
@MainActor
@Observable
final class TerminalSessions {
    /// What each tab is doing. Read by the sidebar and the detail pane.
    private(set) var book = TerminalSessionBook()

    /// One live terminal: the view, the process in it and the folder it was started in.
    private final class Run {
        let view: LocalProcessTerminalView
        let delegate: Delegate
        let folder: String?

        init(view: LocalProcessTerminalView, delegate: Delegate, folder: String?) {
            self.view = view
            self.delegate = delegate
            self.folder = folder
        }
    }

    /// Tells the sessions that the process of a run ended.
    private final class Delegate: NSObject, LocalProcessTerminalViewDelegate {
        let onExit: @MainActor (Int32?) -> Void

        init(onExit: @escaping @MainActor (Int32?) -> Void) {
            self.onExit = onExit
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { [onExit] in
                MainActor.assumeIsolated { onExit(exitCode) }
            }
        }
    }

    /// The live terminal of each tab, by the identity of the tab.
    @ObservationIgnored private var runs: [Int: Run] = [:]

    /// The mode each tab was started in. Read by the bar of the tab.
    private(set) var modes: [Int: TerminalMode] = [:]

    /// The mode a tab runs in.
    func mode(for id: Int) -> TerminalMode {
        modes[id] ?? .normal
    }

    /// The terminal view of a tab, `nil` when it does not exist.
    func view(for id: Int) -> LocalProcessTerminalView? {
        runs[id]?.view
    }

    /// The folder a tab was started in, `nil` for the folder of its profile.
    func folder(for id: Int) -> String? {
        runs[id]?.folder
    }

    /// How many processes run, in all profiles.
    var runningCount: Int { book.runningCount }

    /// Opens a new tab for the profile and starts it. Returns the identity of the tab.
    ///
    /// - Throws: `ProfileError.unsafeFolderToOpen` when a path is not safe.
    @discardableResult
    func open(_ profile: Profile, paths: Paths, folder: String?, mode: TerminalMode = .normal) throws -> Int {
        let command = try EmbeddedTerminalSpec.shellCommand(
            for: profile, paths: paths, workdirOverride: folder, mode: mode
        )
        let tab = book.open(profile.slug)
        modes[tab.id] = mode
        run(id: tab.id, run: tab.run, command: command, folder: folder, start: Self.startFolder(paths))
        return tab.id
    }

    /// Starts a tab again: its process ends if it runs, and a new one starts in
    /// a new, empty terminal, in the folder the tab had, with a new conversation.
    /// The mode stays the one the tab was opened in.
    func restart(_ id: Int, profile: Profile, paths: Paths) throws {
        let folder = runs[id]?.folder
        let newMode = modes[id] ?? .normal
        let command = try EmbeddedTerminalSpec.shellCommand(
            for: profile, paths: paths, workdirOverride: folder, mode: newMode
        )
        runs[id]?.view.terminate()
        guard let number = book.restart(id) else { return }
        modes[id] = newMode
        run(id: id, run: number, command: command, folder: folder, start: Self.startFolder(paths))
    }

    /// The folder a shell starts in: an empty folder of the app, never the home
    /// folder. The folder of the profile is entered by the command itself.
    private static func startFolder(_ paths: Paths) -> String {
        try? FileManager.default.createDirectory(at: paths.workspaceDir, withIntermediateDirectories: true)
        return paths.workspaceDir.path
    }

    private func run(id: Int, run number: Int, command: String, folder: String?, start: String) {
        let delegate = Delegate { [weak self] code in
            self?.book.exited(id, run: number, code: code)
        }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.processDelegate = delegate
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        runs[id] = Run(view: view, delegate: delegate, folder: folder)
        view.startProcess(
            executable: EmbeddedTerminalSpec.shell,
            args: EmbeddedTerminalSpec.arguments(command: command),
            environment: Self.environment(),
            execName: nil,
            // Not the home folder: Claude Code would read Photos, Music and the
            // volumes from there, and macOS would ask this app for those rights.
            // A folder of the profile is entered by the command itself.
            currentDirectory: start
        )
    }

    /// Ends the process of a tab and closes it.
    func close(_ id: Int) {
        runs[id]?.view.terminate()
        runs[id] = nil
        modes[id] = nil
        book.close(id)
    }

    /// Ends every process of a profile and closes its tabs.
    func closeAll(_ slug: String) {
        for id in book.closeAll(slug) {
            runs[id]?.view.terminate()
            runs[id] = nil
            modes[id] = nil
        }
    }

    /// The profile has a new slug: its tabs follow it.
    func rename(from old: String, to new: String) {
        book.renamed(from: old, to: new)
    }

    /// Ends every process, when the app quits.
    func terminateAll() {
        for run in runs.values { run.view.terminate() }
    }

    /// The environment of the shell: what a terminal needs, and nothing of the
    /// app itself. The login shell adds the PATH of the user.
    private static func environment() -> [String] {
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let process = ProcessInfo.processInfo.environment
        env.append("SHELL=\(EmbeddedTerminalSpec.shell)")
        env.append("TERM_PROGRAM=AgentProfiles")
        env.append("PATH=\(process["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")")
        if let tmp = process["TMPDIR"] { env.append("TMPDIR=\(tmp)") }
        return env
    }
}
