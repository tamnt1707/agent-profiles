import Foundation

/// The entries of the menu bar launcher as plain data. The SwiftUI menu only
/// draws them and forwards the clicks; this decides what is enabled and why.
public enum MenuBarModel {
    /// One entry of the menu, from the top down.
    public enum Entry: Equatable, Sendable {
        /// A profile that is opened with one click, in its own folder.
        case profile(ProfileEntry)
        /// The submenu "Open in a folder…": every profile with its folders.
        case openInFolder(FolderMenu)
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
        /// The recent folders that still exist, newest first. The entry of the
        /// profile itself has none: it opens the folder of the profile.
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

    /// The submenu "Open in a folder…".
    public struct FolderMenu: Equatable, Sendable {
        /// The title of the submenu.
        public var title: String
        /// The profiles, each with the folders it was opened in.
        public var profiles: [ProfileEntry]
    }

    /// The entries for the given profiles.
    ///
    /// - Parameters:
    ///   - profiles: the saved profiles.
    ///   - paths: where the profiles live.
    ///   - keyPresence: what is known about the stored key of a profile slug.
    ///     Only a profile whose key is known to be missing is disabled: one
    ///     whose Keychain could not be read is not "without a key", so it
    ///     stays enabled.
    ///   - recentFolders: the recent folders of every profile that still
    ///     exists, newest first. They are looked up when the menu opens, never
    ///     while the menu is drawn.
    ///   - folderTitle: the title of the submenu, already localized.
    ///   - lastError: the message of the last failed launch, already localized.
    public static func entries(
        profiles: [Profile],
        paths: Paths,
        keyPresence: (String) -> KeyState,
        recentFolders: [String: [String]],
        folderTitle: String,
        lastError: String?
    ) -> [Entry] {
        var entries: [Entry] = []
        if profiles.isEmpty {
            entries.append(.noProfiles)
        }
        var folderProfiles: [ProfileEntry] = []
        for profile in profiles {
            let hint = hint(for: profile, keyPresence: keyPresence)
            let folders = (recentFolders[profile.slug] ?? []).map { path in
                Folder(path: path, display: RecentFolders.displayPath(path, home: paths.home.path))
            }
            let command = paths.command(for: profile.slug)
            // The entry of the profile opens it right away, in its own folder.
            entries.append(.profile(ProfileEntry(
                name: profile.name,
                slug: profile.slug,
                command: command,
                hint: hint,
                recentFolders: []
            )))
            // The entry of the submenu opens it in a folder of the user's choice.
            folderProfiles.append(ProfileEntry(
                name: profile.name,
                slug: profile.slug,
                command: command,
                hint: hint,
                recentFolders: folders
            ))
        }
        if !profiles.isEmpty {
            entries.append(.openInFolder(FolderMenu(title: folderTitle, profiles: folderProfiles)))
        }
        if let lastError {
            entries.append(.lastError(lastError))
        }
        return entries
    }

    /// The recent folders of every profile that still exists, newest first.
    ///
    /// The folders that are gone are left out. The list is looked up when the
    /// menu opens, so the menu itself never asks the file system.
    public static func existingFolders(
        profiles: [Profile],
        folderExists: (String) -> Bool
    ) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for profile in profiles {
            var recent = RecentFolders(profile.recentDirs)
            recent.prune(exists: folderExists)
            result[profile.slug] = recent.paths
        }
        return result
    }

    /// Why a profile cannot be opened. A profile that needs a key but has none
    /// stored is disabled; a profile whose Keychain could not be read is not.
    private static func hint(
        for profile: Profile,
        keyPresence: (String) -> KeyState
    ) -> Hint? {
        guard profile.auth != .none else { return nil }
        return keyPresence(profile.slug) == .missing ? .noKey : nil
    }
}
