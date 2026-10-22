import Foundation

/// Opens a terminal window that runs the launcher script of a profile.
public enum Launcher {
    /// The shell command of a profile: `cd '<workdir>' && '<script>'`.
    ///
    /// A working directory that starts with `~` is expanded to the home
    /// directory first, because a quoted `'~/x'` would not be expanded by the shell.
    ///
    /// `workdirOverride` replaces the working directory of the profile for one
    /// launch (the folder chosen from the menu bar). An empty override means no `cd`.
    public static func command(for profile: Profile, paths: Paths, workdirOverride: String? = nil) -> String {
        var command = ""
        let directory = workdirOverride
            ?? profile.workdir.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directory.isEmpty {
            command += "cd \(ShellQuote.quote(expandHome(directory, home: paths.home))) && "
        }
        command += ShellQuote.quote(paths.script(for: profile.slug).path)
        return command
    }

    /// Replaces a leading `~` or `~/` with the home directory. `~user` is left as it is.
    static func expandHome(_ directory: String, home: URL) -> String {
        if directory == "~" {
            return home.path
        }
        if directory.hasPrefix("~/") {
            return home.path + String(directory.dropFirst(1))
        }
        return directory
    }

    /// The AppleScript that opens the terminal and types the command.
    public static func appleScript(command: String, terminal: TerminalApp) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        switch terminal {
        case .terminal:
            return """
            tell application "Terminal"
             activate
             do script "\(escaped)"
            end tell
            """
        case .iTerm:
            return """
            tell application "iTerm"
             activate
             set w to (create window with default profile)
             tell current session of w to write text "\(escaped)"
            end tell
            """
        }
    }

    /// Opens the terminal and waits for `osascript`. Returns the exit status.
    ///
    /// This blocks the calling thread while `osascript` runs. The user interface
    /// should use `launchInBackground`. The runner is injectable for the tests.
    /// When `osascript` fails, its output is part of the thrown error.
    @discardableResult
    public static func launch(
        profile: Profile,
        terminal: TerminalApp,
        paths: Paths,
        workdirOverride: String? = nil,
        runner: ProcessRunner = SystemProcessRunner()
    ) throws -> Int32 {
        let shellCommand = command(for: profile, paths: paths, workdirOverride: workdirOverride)
        let script = appleScript(command: shellCommand, terminal: terminal)
        let result: ProcessResult
        do {
            result = try runner.run("/usr/bin/osascript", ["-e", script])
        } catch {
            throw ProfileError.launcherFailed("osascript could not be started")
        }
        guard result.isSuccess else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = detail.isEmpty
                ? "osascript failed for \(terminal.rawValue)"
                : "osascript failed for \(terminal.rawValue): \(detail)"
            throw ProfileError.launcherFailed(message)
        }
        return result.status
    }

    /// The same as `launch`, run off the calling thread, so that the user
    /// interface stays responsive while the terminal opens.
    @discardableResult
    public static func launchInBackground(
        profile: Profile,
        terminal: TerminalApp,
        paths: Paths,
        workdirOverride: String? = nil,
        runner: ProcessRunner = SystemProcessRunner()
    ) async throws -> Int32 {
        try await Task.detached(priority: .userInitiated) {
            try launch(profile: profile, terminal: terminal, paths: paths, workdirOverride: workdirOverride, runner: runner)
        }.value
    }
}
