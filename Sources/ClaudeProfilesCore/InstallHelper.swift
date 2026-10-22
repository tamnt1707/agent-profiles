import Foundation

/// The tools of the helper script, by absolute path.
///
/// The script never looks a tool up in the PATH. A shim, an alias or an
/// exported function must not be able to change what the helper does, so every
/// tool is called by its full path.
public struct ToolPaths: Sendable, Equatable {
    public var rm: String
    public var mv: String
    public var sleep: String
    public var kill: String
    public var mkdir: String
    public var date: String
    public var echo: String
    public var xattr: String
    public var open: String

    public init(
        rm: String = "/bin/rm",
        mv: String = "/bin/mv",
        sleep: String = "/bin/sleep",
        kill: String = "/bin/kill",
        mkdir: String = "/bin/mkdir",
        date: String = "/bin/date",
        echo: String = "/bin/echo",
        xattr: String = "/usr/bin/xattr",
        open: String = "/usr/bin/open"
    ) {
        self.rm = rm
        self.mv = mv
        self.sleep = sleep
        self.kill = kill
        self.mkdir = mkdir
        self.date = date
        self.echo = echo
        self.xattr = xattr
        self.open = open
    }

    /// The tools of the system, used by the app.
    public static let system = ToolPaths()
}

/// The helper that replaces the app bundle after the running app has quit.
///
/// The helper cannot be part of the app itself: the app has to be gone before
/// its bundle can be replaced. So it is a small shell script that is started
/// detached and waits for the process of the app to end.
public enum InstallHelper {
    /// The name of the script inside the working folder.
    public static let scriptName = "install-update.sh"

    /// How long the helper waits for the app to quit, in seconds.
    public static let maximumWaitSeconds = 30

    /// The PATH the script sets for itself: the two folders the tools live in.
    public static let scriptPath = "/usr/bin:/bin"

    /// The log file that receives one line when the update fails.
    public static var defaultLogFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ClaudeProfilesUpdate.log")
    }

    /// Writes the helper script.
    ///
    /// Every path is single quoted, so a bundle in a folder with a space or a
    /// quote in its name is handled as well. The bundle is only swapped when
    /// the app has quit; otherwise nothing is touched and the script fails.
    ///
    /// The script starts with a PATH of its own and drops the aliases and the
    /// exported functions of the shell that starts it, and every tool is
    /// called by its absolute path. Nothing that the environment of the app
    /// carries can change what the helper does.
    public static func script(
        pid: Int32,
        currentBundle: URL,
        newBundle: URL,
        workDirectory: URL,
        waitSeconds: Int = maximumWaitSeconds,
        logFile: URL = defaultLogFile,
        tools: ToolPaths = .system
    ) -> String {
        let backup = backupURL(for: currentBundle)
        return """
        #!/bin/sh
        # The tools are called by their absolute path, so no shim in the PATH,
        # no alias and no exported function can change what this script does.
        PATH=\(scriptPath)
        export PATH
        unset -f 2>/dev/null || true
        unalias -a 2>/dev/null || true

        # Replaces the Claude Profiles bundle after the running app has quit.
        # Written by Claude Profiles; every path is single quoted.

        PID=\(ShellQuote.quote(String(pid)))
        CURRENT=\(ShellQuote.quote(currentBundle.path))
        NEW=\(ShellQuote.quote(newBundle.path))
        WORK=\(ShellQuote.quote(workDirectory.path))
        BACKUP=\(ShellQuote.quote(backup.path))
        LOG=\(ShellQuote.quote(logFile.path))
        LOG_DIR=\(ShellQuote.quote(logFile.deletingLastPathComponent().path))

        # Writes one line to the log, removes the download and stops with an error.
        fail() {
            \(tools.mkdir) -p "$LOG_DIR" 2>/dev/null
            \(tools.echo) "$(\(tools.date) '+%Y-%m-%d %H:%M:%S') update failed: $1" >> "$LOG" 2>/dev/null
            \(tools.rm) -rf "$WORK"
            exit 1
        }

        # Wait until the app has quit (at most \(waitSeconds) seconds).
        waited=0
        limit=\(waitSeconds * 10)
        while \(tools.kill) -0 "$PID" 2>/dev/null && [ "$waited" -lt "$limit" ]; do
            \(tools.sleep) 0.1
            waited=$((waited + 1))
        done
        # The app is still running: nothing is swapped.
        if \(tools.kill) -0 "$PID" 2>/dev/null; then
            fail "the app did not quit in time"
        fi

        # A stale copy from an earlier attempt must not catch the first move.
        \(tools.rm) -rf "$BACKUP"

        # Move the old bundle aside.
        if ! \(tools.mv) "$CURRENT" "$BACKUP" 2>/dev/null; then
            # The bundle is still in place: start it again.
            \(tools.open) "$CURRENT" 2>/dev/null
            fail "the old app could not be moved aside"
        fi

        # Put the new bundle in place.
        if ! \(tools.mv) "$NEW" "$CURRENT" 2>/dev/null; then
            # Remove a partial new bundle, then put the old one back.
            \(tools.rm) -rf "$CURRENT"
            if \(tools.mv) "$BACKUP" "$CURRENT" 2>/dev/null; then
                \(tools.open) "$CURRENT" 2>/dev/null
                fail "the new app could not be moved into place"
            fi
            fail "the old app could not be restored, it is kept at $BACKUP"
        fi

        # The archive was downloaded, so the new app must not be quarantined.
        \(tools.xattr) -dr com.apple.quarantine "$CURRENT" 2>/dev/null

        # Start the new version.
        \(tools.open) "$CURRENT" 2>/dev/null

        # Clean up.
        \(tools.rm) -rf "$BACKUP"
        \(tools.rm) -rf "$WORK"
        exit 0
        """
    }

    /// The name the old bundle is moved to while the new one is put in place.
    public static func backupURL(for bundle: URL) -> URL {
        bundle.deletingLastPathComponent().appendingPathComponent(bundle.lastPathComponent + ".old")
    }
}
