import Foundation

/// The rules that every download has to follow.
///
/// Only three hosts may be used and every address has to be secure. A
/// redirect is only followed when it leads to one of those hosts as well.
public enum UpdatePolicy {
    /// The hosts that may serve a download.
    public static let allowedHosts: Set<String> = [
        "api.github.com",
        "github.com",
        "objects.githubusercontent.com",
    ]

    /// Checks a URL before anything is fetched from it.
    public static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw UpdateError.insecureURL
        }
        guard let host = url.host?.lowercased(), allowedHosts.contains(host) else {
            throw UpdateError.disallowedHost(url.host ?? "")
        }
    }

    /// `true` when the URL may be fetched.
    public static func isAllowed(_ url: URL) -> Bool {
        (try? validate(url)) != nil
    }
}
