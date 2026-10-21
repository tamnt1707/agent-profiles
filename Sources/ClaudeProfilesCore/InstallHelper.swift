import Foundation

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
    public static func script(
        pid: Int32,
        currentBundle: URL,
        newBundle: URL,
        workDirectory: URL,
        waitSeconds: Int = maximumWaitSeconds,
        logFile: URL = defaultLogFile
    ) -> String {
        let backup = backupURL(for: currentBundle)
        return """
        #!/bin/sh
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
            mkdir -p "$LOG_DIR" 2>/dev/null
            echo "$(date '+%Y-%m-%d %H:%M:%S') update failed: $1" >> "$LOG" 2>/dev/null
            rm -rf "$WORK"
            exit 1
        }

        # Wait until the app has quit (at most \(waitSeconds) seconds).
        waited=0
        limit=\(waitSeconds * 10)
        while kill -0 "$PID" 2>/dev/null && [ "$waited" -lt "$limit" ]; do
            sleep 0.1
            waited=$((waited + 1))
        done
        # The app is still running: nothing is swapped.
        if kill -0 "$PID" 2>/dev/null; then
            fail "the app did not quit in time"
        fi

        # A stale copy from an earlier attempt must not catch the first move.
        rm -rf "$BACKUP"

        # Move the old bundle aside.
        if ! mv "$CURRENT" "$BACKUP" 2>/dev/null; then
            # The bundle is still in place: start it again.
            open "$CURRENT" 2>/dev/null
            fail "the old app could not be moved aside"
        fi

        # Put the new bundle in place.
        if ! mv "$NEW" "$CURRENT" 2>/dev/null; then
            # Remove a partial new bundle, then put the old one back.
            rm -rf "$CURRENT"
            if mv "$BACKUP" "$CURRENT" 2>/dev/null; then
                open "$CURRENT" 2>/dev/null
                fail "the new app could not be moved into place"
            fi
            fail "the old app could not be restored, it is kept at $BACKUP"
        fi

        # The archive was downloaded, so the new app must not be quarantined.
        xattr -dr com.apple.quarantine "$CURRENT" 2>/dev/null

        # Start the new version.
        open "$CURRENT" 2>/dev/null

        # Clean up.
        rm -rf "$BACKUP"
        rm -rf "$WORK"
        exit 0
        """
    }

    /// The name the old bundle is moved to while the new one is put in place.
    public static func backupURL(for bundle: URL) -> URL {
        bundle.deletingLastPathComponent().appendingPathComponent(bundle.lastPathComponent + ".old")
    }
}
