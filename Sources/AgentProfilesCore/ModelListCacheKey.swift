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

/// The last finished "model list" request and the provider it was made for.
public struct ModelListCache: Equatable, Sendable {
    public let key: ModelListCacheKey
    public let report: ModelListReport

    public init(key: ModelListCacheKey, report: ModelListReport) {
        self.key = key
        self.report = report
    }

    /// `true` when the answer may be shown again without asking the provider
    /// again: the list worked, or the provider has none. Errors are retried on
    /// the next open.
    public func isReusable(for other: ModelListCacheKey) -> Bool {
        guard key == other else { return false }
        switch report.outcome {
        case .ok, .unsupported: return true
        default: return false
        }
    }
}
