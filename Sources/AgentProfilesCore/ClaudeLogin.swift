import CryptoKit
import Foundation

/// The Claude Code sign-in of a config folder.
///
/// Claude Code keeps the OAuth login of a `CLAUDE_CONFIG_DIR` in the login
/// Keychain as a generic password: service `Claude Code-credentials-<h>`,
/// account the macOS user name, where `<h>` is the first 8 hex characters of
/// the SHA-256 of the folder path exactly as it is exported. Deleting the
/// folder leaves that item behind, so a profile added again with the same name
/// (same folder, same hash) would be signed in to the old account.
public enum ClaudeLogin {
    /// The service name of Claude Code without `CLAUDE_CONFIG_DIR`: the user's
    /// own login. It is never touched.
    public static let defaultService = "Claude Code-credentials"

    /// The service of the login of a config folder.
    public static func service(forConfigDir path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return defaultService + "-" + hex.prefix(8)
    }
}

/// Removes the Claude Code login of a config folder. Injected by tests.
public protocol ClaudeLoginStore: Sendable {
    /// Removes the login of the folder.
    ///
    /// - Returns: `true` when a login was removed, `false` when there was none.
    /// - Throws: when the Keychain refused the removal.
    @discardableResult
    func removeLogin(configDir: String) throws -> Bool
}

/// Removes the login with `/usr/bin/security`.
///
/// Claude Code writes the item with the `security` tool, so the tool is the
/// program the item trusts: going through it removes the item without a
/// Keychain prompt.
public struct SecurityToolLoginStore: ClaudeLoginStore, @unchecked Sendable {
    /// The macOS user, the account of the item.
    private let account: String
    /// Only folders inside this one are acted on: a profile folder always is.
    private let allowedRoot: URL
    private let runner: ProcessRunner

    public init(
        allowedRoot: URL = Paths().homesDir,
        account: String = NSUserName(),
        runner: ProcessRunner = SystemProcessRunner()
    ) {
        self.allowedRoot = allowedRoot
        self.account = account
        self.runner = runner
    }

    /// The exit status of `security` for an item that does not exist.
    static let itemNotFound: Int32 = 44

    /// At most this many items of one service are removed (a duplicate would
    /// otherwise keep the account signed in).
    static let maxItems = 8

    public func removeLogin(configDir: String) throws -> Bool {
        // A folder outside the profile folders is never acted on: the user's
        // own `~/.claude` keeps its login, and so does any other program.
        let root = allowedRoot.standardizedFileURL.path
        let folder = URL(fileURLWithPath: configDir).standardizedFileURL.path
        guard folder.hasPrefix(root + "/"), folder != root else { return false }

        let service = ClaudeLogin.service(forConfigDir: configDir)
        guard service != ClaudeLogin.defaultService else { return false }

        var removed = false
        for _ in 0..<Self.maxItems {
            let result = try runner.run(
                "/usr/bin/security",
                ["delete-generic-password", "-s", service, "-a", account]
            )
            if result.status == Self.itemNotFound { return removed }
            guard result.isSuccess else { throw ProfileError.keychainWriteFailed }
            removed = true
        }
        return removed
    }
}
