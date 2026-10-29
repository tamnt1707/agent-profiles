import Foundation

/// The address, the headers and the test model of one provider request.
///
/// Everything here is a pure function, so the tests can check each rule
/// without a network.
public enum ProviderEndpoint {
    /// The Base URL used when the profile leaves the field empty.
    public static let defaultBaseURL = "https://api.anthropic.com"

    /// The hosts that may receive the key over plain http.
    public static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// `true` when the profile has no address and needs no key: Claude Code
    /// signs in by itself, so there is nothing to test from here.
    public static func usesCliLogin(_ profile: Profile) -> Bool {
        profile.auth == .none
            && profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The address of `path` below the Base URL, e.g. `v1/messages`.
    ///
    /// An empty Base URL means the Anthropic API. A Base URL that already ends
    /// in `/v1` is not doubled when the path starts with `v1/`. Runs of slashes
    /// in the Base URL are collapsed to one, so no `//` is ever produced.
    /// Returns `nil` when the Base URL is not an http(s) address with a host,
    /// or when it carries a query, a fragment or user information.
    public static func url(baseURL: String, path: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? defaultBaseURL : trimmed
        guard var components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else { return nil }

        var basePath = components.percentEncodedPath
        while basePath.contains("//") {
            basePath = basePath.replacingOccurrences(of: "//", with: "/")
        }
        while basePath.hasSuffix("/") { basePath.removeLast() }
        var suffix = path
        while suffix.hasPrefix("/") { suffix.removeFirst() }
        if suffix.hasPrefix("v1/"), basePath.hasSuffix("/v1") {
            basePath.removeLast(3)
        }
        components.percentEncodedPath = basePath + "/" + suffix
        return components.url
    }

    /// `true` when the key would travel over plain http to another machine.
    public static func isInsecure(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        let host = (url.host ?? "")
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return !localHosts.contains(host)
    }

    /// The headers that carry the credential, exactly as Claude Code sends them.
    ///
    /// Bearer uses `Authorization: Bearer <key>`, ApiKey uses `x-api-key`, and
    /// None sends no credential header at all.
    public static func headers(auth: AuthKind, key: String, json: Bool) -> [String: String] {
        var headers = ["anthropic-version": "2023-06-01"]
        if json {
            headers["content-type"] = "application/json"
        }
        switch auth {
        case .bearer: headers["Authorization"] = "Bearer \(key)"
        case .apiKey: headers["x-api-key"] = key
        case .none: break
        }
        return headers
    }
}
