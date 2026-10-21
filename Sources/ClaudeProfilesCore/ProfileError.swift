import Foundation

/// Everything that can go wrong inside the core. The app maps every case to a
/// localized message, so the core itself stays free of user facing strings.
public enum ProfileError: LocalizedError, Equatable {
    /// The profile has no name.
    case emptyName
    /// The profile name does not contain a single letter or digit.
    case emptySlug
    /// Another profile already uses this command name.
    case duplicateSlug(String)
    /// The base URL does not start with `http://` or `https://`.
    case invalidBaseURL
    /// An environment line is missing the `=`.
    case envMissingEquals(line: Int, text: String)
    /// An environment variable name is not a valid identifier.
    case invalidEnvName(line: Int, name: String)
    /// A key is required for this authentication kind.
    case missingAPIKey
    /// The Keychain could not be read.
    case keychainReadFailed
    /// The Keychain could not be written.
    case keychainWriteFailed
    /// The Keychain entry could not be deleted.
    case keychainDeleteFailed
    /// A file could not be read or written.
    case ioFailed(String)
    /// `profiles.json` was unreadable and has been copied aside.
    case corruptFileBackedUp(path: String)
    /// The terminal could not be opened.
    case launcherFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "profile name is empty"
        case .emptySlug: return "profile slug is empty"
        case .duplicateSlug(let slug): return "duplicate slug: \(slug)"
        case .invalidBaseURL: return "base url is not http(s)"
        case .envMissingEquals(let line, let text): return "line \(line) has no '=': \(text)"
        case .invalidEnvName(let line, let name): return "invalid variable name on line \(line): \(name)"
        case .missingAPIKey: return "api key required"
        case .keychainReadFailed: return "keychain read failed"
        case .keychainWriteFailed: return "keychain write failed"
        case .keychainDeleteFailed: return "keychain delete failed"
        case .ioFailed(let path): return "io error: \(path)"
        case .corruptFileBackedUp(let path): return "corrupt data file backed up to \(path)"
        case .launcherFailed(let message): return "could not open terminal: \(message)"
        }
    }
}
