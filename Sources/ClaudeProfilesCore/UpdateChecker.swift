import Foundation

/// A new version that is ready to be installed.
public struct UpdateInfo: Equatable {
    /// The version of the release.
    public var version: SemVer
    /// The body of the release, as plain text.
    public var notes: String
    /// The address of the archive.
    public var zipURL: URL
    /// The address of the signature of the archive.
    public var sigURL: URL

    public init(version: SemVer, notes: String, zipURL: URL, sigURL: URL) {
        self.version = version
        self.notes = notes
        self.zipURL = zipURL
        self.sigURL = sigURL
    }
}

/// What the check found.
public enum UpdateCheckResult: Equatable {
    /// The installed version is the newest one.
    case upToDate(SemVer)
    /// A newer version is ready.
    case available(UpdateInfo)
}

/// Looks at the releases of a GitHub repository and tells whether a newer
/// version exists.
///
/// The request is anonymous: no token is sent and nothing is written to the
/// disk. The session is injectable, so the tests answer with their own
/// protocol and never touch the network.
public struct UpdateChecker {
    /// The `User-Agent` of every request. GitHub asks for one.
    public static let userAgent = "ClaudeProfiles"

    /// The repository, `owner/name`.
    public let repo: String

    /// The session used for the request.
    public let session: URLSession

    /// How long the request may take.
    public let timeout: TimeInterval

    public init(repo: String, session: URLSession = .shared, timeout: TimeInterval = 15) {
        self.repo = repo
        self.session = session
        self.timeout = timeout
    }

    /// The address of the newest release of the repository.
    public var latestReleaseURL: URL? {
        guard UpdateChecker.isValidRepo(repo) else { return nil }
        return URL(string: "https://api.github.com/repos/\(repo)/releases/latest")
    }

    /// `true` when the repository name has the form `owner/name`.
    public static func isValidRepo(_ repo: String) -> Bool {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    /// Asks GitHub whether a newer version exists.
    ///
    /// - Throws: `UpdateError` for every failure, so the app can show a
    ///   localized sentence.
    public func check(current: SemVer) async throws -> UpdateCheckResult {
        guard let url = latestReleaseURL else {
            throw UpdateError.notConfigured
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(UpdateChecker.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // No token is sent: the app stays anonymous.

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw UpdateChecker.map(error)
        } catch {
            throw UpdateError.downloadFailed
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.invalidResponse
        }
        switch http.statusCode {
        case 200:
            break
        case 403, 429:
            // GitHub answers with 403 when the anonymous rate limit is used up.
            throw UpdateError.rateLimited
        case 404:
            throw UpdateError.noReleases
        default:
            throw UpdateError.httpError(http.statusCode)
        }

        let payload: ReleasePayload
        do {
            payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
        } catch {
            throw UpdateError.invalidResponse
        }

        // Drafts and pre-releases are never installed.
        guard !payload.draft, !payload.prerelease else {
            throw UpdateError.noReleases
        }
        guard let version = SemVer(text: payload.tagName) else {
            throw UpdateError.invalidResponse
        }
        guard version > current else {
            return .upToDate(current)
        }

        guard let zip = payload.assets.first(where: { $0.name.hasSuffix("-macos.zip") }),
              let signature = payload.assets.first(where: { $0.name.hasSuffix("-macos.zip.sig") }),
              let zipURL = URL(string: zip.browserDownloadURL),
              let sigURL = URL(string: signature.browserDownloadURL)
        else {
            throw UpdateError.invalidResponse
        }

        return .available(
            UpdateInfo(
                version: version,
                notes: payload.body ?? "",
                zipURL: zipURL,
                sigURL: sigURL
            )
        )
    }

    /// Turns a transport error into a case of the update error.
    public static func map(_ error: URLError) -> UpdateError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
            return .networkUnavailable
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        default:
            return .downloadFailed
        }
    }
}

/// The part of the answer of GitHub that the updater needs.
private struct ReleasePayload: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case body
        case draft
        case prerelease
        case assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }
}
