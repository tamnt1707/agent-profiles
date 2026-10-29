import Foundation

/// A test outcome as it is written to the cache file.
///
/// Only the kind and its numbers are kept: nothing the provider said, so the
/// file holds no text that could carry a key.
public struct StoredOutcome: Codable, Equatable, Sendable {
    public var kind: String
    public var code: Int?
    public var model: String?
    public var problem: String?

    init(kind: String, code: Int?, model: String?, problem: String?) {
        self.kind = kind
        self.code = code
        self.model = model
        self.problem = problem
    }

    init(_ outcome: ProbeOutcome) {
        var code: Int?
        var model: String?
        var problem: String?
        let kind: String
        switch outcome {
        case .ok(let latency, let name): kind = "ok"; code = latency; model = name
        case .unauthorized: kind = "unauthorized"
        case .forbidden: kind = "forbidden"
        case .notFound: kind = "notFound"
        case .modelNotFound: kind = "modelNotFound"
        case .rateLimited: kind = "rateLimited"
        case .serverError(let status): kind = "serverError"; code = status
        case .unexpectedStatus(let status): kind = "unexpectedStatus"; code = status
        case .timeout: kind = "timeout"
        case .network(let found): kind = "network"; problem = found.rawValue
        case .invalidURL: kind = "invalidURL"
        case .insecureURL: kind = "insecureURL"
        case .missingKey: kind = "missingKey"
        case .crossHostRedirect: kind = "crossHostRedirect"
        case .unsupported: kind = "unsupported"
        case .cliLogin: kind = "cliLogin"
        case .cliNotFound: kind = "cliNotFound"
        case .notLoggedIn: kind = "notLoggedIn"
        case .cliFailed: kind = "cliFailed"
        }
        self.kind = kind
        self.code = code
        self.model = model
        self.problem = problem
    }

    /// The outcome, `nil` when the kind is not one this version knows.
    var outcome: ProbeOutcome? {
        switch kind {
        case "ok": return .ok(latencyMs: code ?? 0, model: model)
        case "unauthorized": return .unauthorized
        case "forbidden": return .forbidden
        case "notFound": return .notFound
        case "modelNotFound": return .modelNotFound
        case "rateLimited": return .rateLimited
        case "serverError": return code.map { .serverError($0) }
        case "unexpectedStatus": return code.map { .unexpectedStatus($0) }
        case "timeout": return .timeout
        case "network": return NetworkProblem(rawValue: problem ?? "other").map { .network($0) }
        case "invalidURL": return .invalidURL
        case "insecureURL": return .insecureURL
        case "missingKey": return .missingKey
        case "crossHostRedirect": return .crossHostRedirect
        case "unsupported": return .unsupported
        case "cliLogin": return .cliLogin
        case "cliNotFound": return .cliNotFound
        case "notLoggedIn": return .notLoggedIn
        case "cliFailed": return .cliFailed
        default: return nil
        }
    }
}

/// The last test of one profile, as it is written to the cache file.
public struct StoredTest: Codable, Equatable, Sendable {
    /// The settings the test was made with: see `HealthBook.fingerprint(of:)`.
    public var fingerprint: String
    public var outcome: StoredOutcome
    public var testedAt: Date
}

/// The file that keeps the last test of each profile between two runs of the app.
///
/// A result stays until the profile changes (its fingerprint then no longer
/// matches) or it is tested again. The file holds no key and no text of the provider.
public struct HealthCacheStore: Sendable {
    public static let fileName = "health-cache.json"

    private struct File: Codable {
        var version = 1
        var tests: [String: StoredTest] = [:]
    }

    private let url: URL

    public init(paths: Paths) {
        url = paths.root.appendingPathComponent(Self.fileName)
    }

    /// The tests of the file, empty when there is no file or it cannot be read.
    public func load() -> [String: StoredTest] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(File.self, from: data))?.tests ?? [:]
    }

    /// Writes the tests. A failure is not an error: the cache is a convenience.
    public func save(_ tests: [String: StoredTest]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(File(tests: tests)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
