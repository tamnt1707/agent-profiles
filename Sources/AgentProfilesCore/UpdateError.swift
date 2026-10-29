import Foundation

/// Everything that can go wrong while checking for or installing an update.
///
/// Like `ProfileError` the cases carry no user facing text: the app maps
/// every case to a localized message, so the core stays free of strings.
public enum UpdateError: LocalizedError, Equatable {
    /// The build does not know which repository to check.
    case notConfigured
    /// No connection to the internet.
    case networkUnavailable
    /// The request took too long.
    case timedOut
    /// GitHub is rate limiting the requests.
    case rateLimited
    /// The repository has no release yet.
    case noReleases
    /// The answer of the server could not be read.
    case invalidResponse
    /// The server answered with an unexpected status code.
    case httpError(Int)
    /// The download failed.
    case downloadFailed
    /// The download is bigger than the limit.
    case fileTooLarge
    /// The user cancelled the download.
    case cancelled
    /// The address points to a host that is not allowed.
    case disallowedHost(String)
    /// The address is not secure.
    case insecureURL
    /// The release has no signature.
    case missingSignature
    /// The signature does not match the download.
    case invalidSignature
    /// The public key of this build is missing or broken.
    case invalidPublicKey
    /// The archive could not be opened.
    case extractionFailed
    /// The archive does not hold exactly one `Agent Profiles.app`.
    case unexpectedBundle
    /// The archive holds something else than this app.
    case bundleMismatch
    /// The archive is not newer than the installed version.
    case notNewer
    /// The archive was signed with a different key.
    case keyMismatch
    /// The signature of the new app could not be verified.
    case codesignFailed
    /// The folder of the app cannot be written.
    case bundleNotWritable
    /// The new version could not be put in place.
    case installFailed

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "the updater is not configured"
        case .networkUnavailable: return "no connection to the internet"
        case .timedOut: return "the request timed out"
        case .rateLimited: return "github is rate limiting the requests"
        case .noReleases: return "there is no release yet"
        case .invalidResponse: return "the answer of the server could not be read"
        case .httpError(let code): return "the server answered with the status \(code)"
        case .downloadFailed: return "the download failed"
        case .fileTooLarge: return "the download is too large"
        case .cancelled: return "the update was cancelled"
        case .disallowedHost(let host): return "the host \(host) is not allowed"
        case .insecureURL: return "the address is not secure"
        case .missingSignature: return "the release has no signature"
        case .invalidSignature: return "the signature does not match"
        case .invalidPublicKey: return "the public key is missing or broken"
        case .extractionFailed: return "the archive could not be opened"
        case .unexpectedBundle: return "the archive does not hold one app"
        case .bundleMismatch: return "the archive is not this app"
        case .notNewer: return "the download is not newer"
        case .keyMismatch: return "the download was signed with another key"
        case .codesignFailed: return "the signature of the new app is broken"
        case .bundleNotWritable: return "the folder of the app cannot be written"
        case .installFailed: return "the new version could not be put in place"
        }
    }
}
