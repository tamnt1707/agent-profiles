import Foundation

/// The entries of the menu bar launcher as plain data. The SwiftUI menu only
/// draws them and forwards the clicks; this decides what is enabled and why.
public enum MenuBarModel {
    /// One entry of the profile list, from the top down.
    public enum Entry: Equatable, Sendable {
        case profile(ProfileEntry)
        /// There is no profile yet. Shown as a disabled item.
        case noProfiles
        /// The message of the last failed launch. Shown as a disabled item.
        case lastError(String)
    }

    /// A profile in the menu.
    public struct ProfileEntry: Equatable, Sendable {
        public var name: String
        public var slug: String
        /// The command the profile is started with, `claude-<slug>`.
        public var command: String
        /// Why the profile cannot be opened, `nil` when it can.
        public var hint: Hint?
        /// The recent folders that still exist, newest first.
        public var recentFolders: [Folder]

        public var isEnabled: Bool { hint == nil }
    }

    /// Why a profile is shown disabled.
    public enum Hint: Equatable, Sendable {
        /// The profile needs an API key and none is stored.
        case noKey
    }

    /// A recent folder: the absolute path, and the text shown in the menu.
    public struct Folder: Equatable, Sendable {
        public var path: String
        public var display: String
    }

    /// The entries for the given profiles.
    ///
    /// - Parameters:
    ///   - hasKey: whether a key is stored for a profile slug. Asked only for
    ///     profiles that need a key; the caller decides how it is looked up.
    ///   - folderExists: whether a recent folder still exists. Folders that do
    ///     not are left out.
    ///   - lastError: the message of the last failed launch, already localized.
    public static func entries(
        profiles: [Profile],
        paths: Paths,
        hasKey: (String) -> Bool,
        folderExists: (String) -> Bool,
        lastError: String?
    ) -> [Entry] {
        var entries: [Entry] = []
        if profiles.isEmpty {
            entries.append(.noProfiles)
        }
        for profile in profiles {
            var recent = RecentFolders(profile.recentDirs)
            recent.prune(exists: folderExists)
            let folders = recent.paths.map { path in
                Folder(path: path, display: RecentFolders.displayPath(path, home: paths.home.path))
            }
            let needsKey = profile.auth != .none
            let hint: Hint? = needsKey && !hasKey(profile.slug) ? .noKey : nil
            entries.append(.profile(ProfileEntry(
                name: profile.name,
                slug: profile.slug,
                command: paths.command(for: profile.slug),
                hint: hint,
                recentFolders: folders
            )))
        }
        if let lastError {
            entries.append(.lastError(lastError))
        }
        return entries
    }
}
