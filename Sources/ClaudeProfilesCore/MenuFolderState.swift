import Foundation

/// The recent folders of the profiles, as the menu bar shows them.
///
/// The menu never asks the file system: it is drawn from this. Every lookup
/// carries the number of the lookup that asked for it, so a lookup that comes
/// back late never replaces a newer answer.
public struct MenuFolderState: Equatable, Sendable {
    /// What one lookup found for one profile.
    public enum Entry: Equatable, Sendable {
        /// The folders of the profile that still exist.
        case checked([String])
        /// The check did not finish in time. The folders of the profile stay
        /// as they are: they are shown, but nobody knows whether they are
        /// still there.
        case unchecked
    }

    /// The answer of one lookup.
    public struct Lookup: Equatable, Sendable {
        /// The number of the lookup that asked for it.
        public var generation: Int
        /// What the lookup found, per profile.
        public var entries: [String: Entry]

        public init(generation: Int, entries: [String: Entry]) {
            self.generation = generation
            self.entries = entries
        }
    }

    /// The number of the newest lookup.
    public private(set) var generation: Int = 0
    /// The folders of every profile, newest first.
    public private(set) var folders: [String: [String]] = [:]

    public init() {}

    /// Starts a lookup and gives back the number that its answer must carry.
    public mutating func begin() -> Int {
        generation += 1
        return generation
    }

    /// Takes the answer of a lookup, when it is the newest one.
    ///
    /// The answer of an older lookup is dropped: it was asked for before the
    /// one that is shown now, and it says less about the file system. A
    /// profile that is not in the list any more is left out. A profile whose
    /// check did not finish in time keeps the folders it had: they are shown
    /// as they are, and nobody drops them.
    ///
    /// - Returns: `false` when the answer was dropped.
    @discardableResult
    public mutating func accept(_ lookup: Lookup, known slugs: Set<String>) -> Bool {
        guard lookup.generation >= generation else { return false }
        generation = lookup.generation
        var merged: [String: [String]] = [:]
        for (slug, entry) in lookup.entries where slugs.contains(slug) {
            switch entry {
            case .checked(let folders):
                merged[slug] = folders
            case .unchecked:
                // The check did not finish in time: the folders stay as they
                // are, so a slow volume does not empty the menu.
                merged[slug] = folders[slug] ?? []
            }
        }
        folders = merged
        return true
    }
}

/// The launches that are on their way.
///
/// A second click on the same item of the menu is ignored while the first
/// click is still on its way: one click opens one terminal.
public struct LaunchGuard: Equatable, Sendable {
    /// The keys of the launches that are on their way.
    private var running: Set<String> = []

    public init() {}

    /// Starts a launch.
    ///
    /// - Returns: `false` when the same launch is already on its way. The
    ///   caller then does nothing: a second terminal is not opened.
    public mutating func begin(_ key: String) -> Bool {
        running.insert(key).inserted
    }

    /// The launch is done: the same item can be clicked again.
    public mutating func end(_ key: String) {
        running.remove(key)
    }

    /// `true` while the launch is on its way.
    public func isRunning(_ key: String) -> Bool {
        running.contains(key)
    }
}
