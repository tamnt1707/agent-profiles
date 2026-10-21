import Foundation

/// File helpers that never follow a symbolic link.
///
/// The config folder of a profile holds links to `~/.claude`. Removing such a
/// folder has to take the links away and leave what they point to alone, so
/// every step looks at the link itself (`lstat`) and removes it with `unlink`.
enum SafeFileSystem {
    /// What is at a path, read without following a symbolic link.
    enum Kind {
        /// Nothing there.
        case missing
        /// A symbolic link.
        case link
        /// A folder.
        case directory
        /// A regular file.
        case file
        /// Something else (a socket, a pipe, …).
        case other
    }

    /// What is at the path, without following a symbolic link.
    static func kind(of url: URL) -> Kind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return .missing }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return .link
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        default: return .other
        }
    }

    /// Removes a file, a link or a whole folder.
    ///
    /// Links are removed, never followed, so the files behind them stay
    /// untouched. A folder is emptied first and removed afterwards.
    static func remove(at url: URL) throws {
        switch kind(of: url) {
        case .missing:
            return
        case .link, .file, .other:
            guard unlink(url.path) == 0 else { throw ProfileError.ioFailed(url.path) }
        case .directory:
            let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            for child in children {
                try remove(at: url.appendingPathComponent(child))
            }
            guard rmdir(url.path) == 0 else { throw ProfileError.ioFailed(url.path) }
        }
    }
}
