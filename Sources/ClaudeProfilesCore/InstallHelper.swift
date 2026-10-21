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

    /// Writes the helper script.
    ///
    /// Every path is single quoted, so a bundle in a folder with a space or a
    /// quote in its name is handled as well.
    public static func script(
        pid: Int32,
        currentBundle: URL,
        newBundle: URL,
        workDirectory: URL
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

        # Wait until the app has quit (at most \(maximumWaitSeconds) seconds).
        waited=0
        limit=\(maximumWaitSeconds * 10)
        while kill -0 "$PID" 2>/dev/null; do
            if [ "$waited" -ge "$limit" ]; then
                break
            fi
            sleep 0.1
            waited=$((waited + 1))
        done

        # Move the old bundle aside.
        if ! mv "$CURRENT" "$BACKUP" 2>/dev/null; then
            # The bundle could not be moved: keep it and start it again.
            open "$CURRENT" 2>/dev/null
            rm -rf "$WORK"
            exit 0
        fi

        # Put the new bundle in place.
        if ! mv "$NEW" "$CURRENT" 2>/dev/null; then
            # Put the old bundle back and start it again.
            mv "$BACKUP" "$CURRENT" 2>/dev/null
            open "$CURRENT" 2>/dev/null
            rm -rf "$WORK"
            exit 0
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
