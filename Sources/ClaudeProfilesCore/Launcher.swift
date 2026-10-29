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
    ///
    /// With `useShortName` the command is the name the user types
    /// (`claude-<slug>`, the one that "Copy command" copies) and not the full
    /// path of the script. That works only when `bin/` is on the PATH of the
    /// shell that receives the command.
    ///
    /// - Throws: `ProfileError.unsafeFolderToOpen` when the folder, the script
    ///   or the home folder of the profile holds a control character. The
    ///   command is typed into a live shell, which acts on such a character
    ///   before the shell parses the quotes, so nothing is built from an unsafe
    ///   path.
    public static func command(
        for profile: Profile,
        paths: Paths,
        workdirOverride: String? = nil,
        useShortName: Bool = false
    ) throws -> String {
        var command = ""
        let directory = workdirOverride
            ?? profile.workdir.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directory.isEmpty {
            let expanded = expandHome(directory, home: paths.home)
            guard FolderPathSafety.isSafe(expanded) else {
                throw ProfileError.unsafeFolderToOpen(directory)
            }
            command += "cd \(ShellQuote.quote(expanded)) && "
        }
        // The script of the profile and the home folder of the profile go into
        // the command as well: a path with a control character in it is
        // refused there too.
        let script = paths.script(for: profile.slug).path
        guard FolderPathSafety.isSafe(script) else {
            throw ProfileError.unsafeFolderToOpen(script)
        }
        guard FolderPathSafety.isSafe(paths.home.path) else {
            throw ProfileError.unsafeFolderToOpen(paths.home.path)
        }
        // The slug is a safe path component: the short name needs no quoting.
        command += useShortName && Slug.isSafe(profile.slug)
            ? paths.command(for: profile.slug)
            : ShellQuote.quote(script)
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
    ///
    /// The command stands in one string of the script. A quote and a
    /// backslash are escaped, and so is every control character: a control
    /// character in the text of the script would end the string, and the rest
    /// of the command would be a second statement of the script.
    public static func appleScript(command: String, terminal: TerminalApp) -> String {
        let escaped = escapeForAppleScript(command)
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

    /// The text of the command, as it can stand inside an AppleScript string.
    ///
    /// A backslash and a quote are escaped, and a control character is written
    /// as its name: nothing that is left can end the string of the script.
    static func escapeForAppleScript(_ command: String) -> String {
        var out = ""
        for character in command {
            switch character {
            case "\\":
                out += "\\\\"
            case "\"":
                out += "\\\""
            default:
                for scalar in character.unicodeScalars {
                    out += FolderPathSafety.isControl(scalar)
                        ? FolderPathSafety.escaped(scalar)
                        : String(scalar)
                }
            }
        }
        return out
    }

    /// Opens the terminal and waits for `osascript`. Returns the exit status.
    ///
    /// This blocks the calling thread while `osascript` runs. The user interface
    /// should use `launchInBackground`. The runner is injectable for the tests.
    /// When `osascript` fails, its output is part of the thrown error.
    ///
    /// - Throws: `ProfileError.unsafeFolderToOpen` when the path is not safe.
    ///   The terminal is never opened and `osascript` is never run.
    @discardableResult
    public static func launch(
        profile: Profile,
        terminal: TerminalApp,
        paths: Paths,
        workdirOverride: String? = nil,
        useShortName: Bool = false,
        runner: ProcessRunner = SystemProcessRunner()
    ) throws -> Int32 {
        let shellCommand = try command(
            for: profile, paths: paths, workdirOverride: workdirOverride, useShortName: useShortName
        )
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
    ///
    /// - Throws: `ProfileError.unsafeFolderToOpen` when the path is not safe.
    @discardableResult
    public static func launchInBackground(
        profile: Profile,
        terminal: TerminalApp,
        paths: Paths,
        workdirOverride: String? = nil,
        useShortName: Bool = false,
        runner: ProcessRunner = SystemProcessRunner()
    ) async throws -> Int32 {
        try await Task.detached(priority: .userInitiated) {
            try launch(
                profile: profile, terminal: terminal, paths: paths,
                workdirOverride: workdirOverride, useShortName: useShortName, runner: runner
            )
        }.value
    }
}
