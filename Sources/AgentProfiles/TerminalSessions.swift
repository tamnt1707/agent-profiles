import AppKit
import Foundation
import Observation
import SwiftTerm
import AgentProfilesCore

/// The embedded terminals of the app: one per profile.
///
/// A session owns its terminal view for as long as it lives, so the window can
/// show another profile and come back: the view is put in the window again with
/// everything it printed and its process still running.
@MainActor
@Observable
final class TerminalSessions {
    /// What each profile's terminal is doing. Read by the sidebar and the detail pane.
    private(set) var book = TerminalSessionBook()

    /// One live terminal: the view, the process in it and what it was started with.
    private final class Run {
        let view: LocalProcessTerminalView
        let delegate: Delegate
        let number: Int
        let folder: String?

        init(view: LocalProcessTerminalView, delegate: Delegate, number: Int, folder: String?) {
            self.view = view
            self.delegate = delegate
            self.number = number
            self.folder = folder
        }
    }

    /// Tells the sessions that the process of a run ended.
    private final class Delegate: NSObject, LocalProcessTerminalViewDelegate {
        let slug: String
        let onExit: @MainActor (Int32?) -> Void

        init(slug: String, onExit: @escaping @MainActor (Int32?) -> Void) {
            self.slug = slug
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

    @ObservationIgnored private var runs: [String: Run] = [:]

    /// The terminal view of a profile, `nil` when it has no session.
    func view(for slug: String) -> LocalProcessTerminalView? {
        runs[slug]?.view
    }

    /// The folder the session of a profile was started in, `nil` for its own folder.
    func folder(for slug: String) -> String? {
        runs[slug]?.folder
    }

    /// How many processes run.
    var runningCount: Int { book.runningSlugs.count }

    /// Starts the profile in a terminal of its own. A session that already runs is kept.
    ///
    /// - Throws: `ProfileError.unsafeFolderToOpen` when a path is not safe.
    func start(_ profile: Profile, paths: Paths, folder: String?) throws {
        let slug = profile.slug
        if book.state(for: slug) == .running { return }
        let command = try EmbeddedTerminalSpec.shellCommand(for: profile, paths: paths, workdirOverride: folder)

        // The old, ended run is replaced by a new view: its text is gone with it.
        runs[slug]?.view.terminate()
        let number = book.started(slug)
        let delegate = Delegate(slug: slug) { [weak self] code in
            self?.ended(slug: slug, number: number, code: code)
        }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.processDelegate = delegate
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        runs[slug] = Run(view: view, delegate: delegate, number: number, folder: folder)
        view.startProcess(
            executable: EmbeddedTerminalSpec.shell,
            args: EmbeddedTerminalSpec.arguments(command: command),
            environment: Self.environment(),
            execName: nil,
            // Like a new window of Terminal: the folder of the user, not `/`.
            // A folder of the profile is entered by the command itself.
            currentDirectory: paths.home.path
        )
    }

    private func ended(slug: String, number: Int, code: Int32?) {
        book.exited(slug, run: number, code: code)
    }

    /// Stops the process of a profile. The text stays, so the end can be read.
    func stop(_ slug: String) {
        guard book.state(for: slug) == .running else { return }
        runs[slug]?.view.terminate()
    }

    /// Stops the process and forgets the terminal of a profile.
    func close(_ slug: String) {
        runs[slug]?.view.terminate()
        runs[slug] = nil
        book.closed(slug)
    }

    /// The profile has a new slug: its terminal follows it.
    func rename(from old: String, to new: String) {
        guard old != new, let run = runs[old] else { return }
        let renamed = Run(view: run.view, delegate: Delegate(slug: new) { [weak self] code in
            self?.ended(slug: new, number: run.number, code: code)
        }, number: run.number, folder: run.folder)
        renamed.view.processDelegate = renamed.delegate
        runs[new] = renamed
        runs[old] = nil
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
