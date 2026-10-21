import Foundation

/// Opens a terminal window that runs the launcher script of a profile.
public enum Launcher {
    /// The shell command of a profile: `cd '<workdir>' && '<script>'`.
    public static func command(for profile: Profile, paths: Paths) -> String {
        var command = ""
        let directory = profile.workdir.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directory.isEmpty {
            command += "cd \(ShellQuote.quote(directory)) && "
        }
        command += ShellQuote.quote(paths.script(for: profile.slug).path)
        return command
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

    /// Opens the terminal. Returns the exit status of `osascript`.
    @discardableResult
    public static func launch(profile: Profile, terminal: TerminalApp, paths: Paths) throws -> Int32 {
        let script = appleScript(command: command(for: profile, paths: paths), terminal: terminal)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
        } catch {
            throw ProfileError.launcherFailed("osascript could not be started")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProfileError.launcherFailed("osascript failed for \(terminal.rawValue)")
        }
        return process.terminationStatus
    }
}
