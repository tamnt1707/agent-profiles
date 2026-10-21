import Foundation

/// What the app knows about the place it was released from.
///
/// The values come from the `Info.plist` that `build-mac.sh` writes:
///
/// - `UpdateRepo` — the GitHub repository, `owner/name`.
/// - `UpdatePublicKey` — the base64 Ed25519 public key of the release key.
/// - `CFBundleShortVersionString` — the version of the installed app.
///
/// A build without a version or without a repository cannot check for
/// updates: `swift run` and a bundle that was built by hand have neither.
/// `disabledReason` then says why, and the app hides the update controls.
public struct UpdateConfiguration: Equatable {
    /// Why the updater cannot work.
    public enum DisabledReason: String, Equatable {
        /// The bundle has no version, so there is nothing to compare with.
        case noVersion
        /// `UpdateRepo` is missing or empty.
        case noRepo
        /// `UpdatePublicKey` is missing or empty.
        case noPublicKey
    }

    /// The GitHub repository, `owner/name`.
    public var repo: String
    /// The base64 Ed25519 public key that signs the releases.
    public var publicKey: String
    /// The version of the installed app.
    public var version: SemVer?
    /// The bundle identifier of the installed app.
    public var bundleIdentifier: String
    /// The `.app` bundle of the running app, when it runs from one.
    public var appBundleURL: URL?

    public init(
        repo: String = "",
        publicKey: String = "",
        version: SemVer? = nil,
        bundleIdentifier: String = "",
        appBundleURL: URL? = nil
    ) {
        self.repo = repo
        self.publicKey = publicKey
        self.version = version
        self.bundleIdentifier = bundleIdentifier
        self.appBundleURL = appBundleURL
    }

    /// Why the updater is turned off, or `nil` when it may run.
    public var disabledReason: DisabledReason? {
        if version == nil { return .noVersion }
        if repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noRepo }
        if publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .noPublicKey }
        return nil
    }

    /// `true` when the app may look for a new version.
    public var isEnabled: Bool { disabledReason == nil }

    /// The configuration of the running app.
    public static func current(bundle: Bundle = .main) -> UpdateConfiguration {
        from(info: bundle.infoDictionary ?? [:], bundleURL: bundle.bundleURL)
    }

    /// The configuration described by an `Info.plist` dictionary.
    public static func from(info: [String: Any], bundleURL: URL?) -> UpdateConfiguration {
        let repo = (info["UpdateRepo"] as? String) ?? ""
        let publicKey = (info["UpdatePublicKey"] as? String) ?? ""
        let identifier = (info["CFBundleIdentifier"] as? String) ?? ""
        let versionText = (info["CFBundleShortVersionString"] as? String) ?? ""
        let version = SemVer(text: versionText)
        // The app bundle is only used when the app really runs from one.
        let appBundle = bundleURL.flatMap { $0.pathExtension == "app" ? $0 : nil }
        return UpdateConfiguration(
            repo: repo,
            publicKey: publicKey,
            version: version,
            bundleIdentifier: identifier,
            appBundleURL: appBundle
        )
    }

    /// The version of the installed app as it is shown to the user.
    public var versionText: String {
        version.map { $0.description } ?? ""
    }
}
