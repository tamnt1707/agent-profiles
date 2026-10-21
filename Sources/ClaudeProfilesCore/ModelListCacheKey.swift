import Foundation

/// Identifies the provider a fetched model list belongs to: its Base URL and
/// its auth kind. A list is reused only while both stay the same.
public struct ModelListCacheKey: Hashable, Sendable {
    /// The Base URL without surrounding spaces and without trailing slashes.
    public let baseURL: String
    public let auth: AuthKind

    public init(baseURL: String, auth: AuthKind) {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        self.baseURL = trimmed
        self.auth = auth
    }
}
