import Foundation

/// The folders a profile was last opened in from the menu bar: newest first,
/// absolute, without duplicates, at most `limit` of them.
public struct RecentFolders: Equatable, Sendable {
    /// How many folders are remembered.
    public static let limit = 5

    /// Standardized absolute paths, newest first.
    public private(set) var paths: [String]

    /// Starts from a stored list. Entries that are not absolute are dropped,
    /// duplicates keep their first place, and the list is cut to `limit`.
    public init(_ paths: [String] = []) {
        self.paths = Self.normalized(paths)
    }

    /// Puts a folder at the front. A folder that is already listed moves there.
    /// A path that is not absolute is ignored.
    public mutating func add(_ path: String) {
        paths = Self.normalized([path] + paths)
    }

    /// Keeps only the folders that `exists` accepts. The order does not change.
    public mutating func prune(exists: (String) -> Bool) {
        paths = paths.filter(exists)
    }

    /// The path as it is shown to the user: the home folder is written as `~`.
    /// The stored path itself stays absolute.
    public static func displayPath(_ path: String, home: String) -> String {
        guard home.hasPrefix("/"), home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// The standardized form of an absolute path, `nil` for anything else.
    private static func standardized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func normalized(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            guard let folder = standardized(path), !seen.contains(folder) else { continue }
            seen.insert(folder)
            result.append(folder)
            if result.count == limit { break }
        }
        return result
    }
}
