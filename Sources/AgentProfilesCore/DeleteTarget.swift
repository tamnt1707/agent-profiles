import Foundation

/// What deleting a saved profile removes. Built from the SAVED profile only:
/// the command name typed in the editor is not part of it until a save.
public struct DeleteTarget: Equatable, Sendable {
    /// One thing that goes away, in the order the confirmation lists them.
    public enum Item: Equatable, Sendable {
        /// The Keychain entry of the profile (the account name).
        case key(account: String)
        /// The launcher, as the command the user types (`claude-<slug>`).
        case command(name: String)
        /// The config folder with its size in bytes, when that is cheap to compute.
        case folder(path: String, bytes: Int?)
        /// The heartbeat: its LaunchAgent and its log.
        case schedule
    }

    /// The name of the saved profile.
    public let name: String
    /// The items that are deleted: the key, the command and the folder.
    public let items: [Item]

    /// The saved profile at `index` of `data.profiles`. `nil` when there is no
    /// such profile (for example a new, unsaved draft).
    public init?(
        index: Int?,
        in data: AppData,
        paths: Paths,
        measure: (URL) -> Int? = { DirectorySize.measure(at: $0) }
    ) {
        guard let index, data.profiles.indices.contains(index) else { return nil }
        let saved = data.profiles[index]
        let home = paths.home(for: saved.slug)
        name = saved.name
        var list: [Item] = [
            .key(account: saved.slug),
            .command(name: paths.command(for: saved.slug)),
            .folder(path: home.path, bytes: measure(home)),
        ]
        if saved.heartbeat != .off || HeartbeatAgent(paths: paths).hasTraces(slug: saved.slug) {
            list.append(.schedule)
        }
        items = list
    }
}
