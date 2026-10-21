import Foundation

/// How a check ended, as the user should read it.
public enum ProbeSeverity: Equatable, Sendable {
    case success
    case warning
    case error
}

/// Where a network failure came from, for a short localized sentence.
public enum NetworkProblem: String, Equatable, Sendable {
    case dns
    case offline
    case tls
    case other
}

/// The result of one check. Every case maps to one localized message.
public enum ProbeOutcome: Equatable, Sendable {
    /// The provider answered with a success status.
    case ok(latencyMs: Int, model: String?)
    /// 401: the key was refused.
    case unauthorized
    /// 403: the key may not use this endpoint.
    case forbidden
    /// 404: the Base URL or its path is wrong.
    case notFound
    /// 400 or 404 saying that the model name is unknown.
    case modelNotFound
    /// 429: the key works, the provider is limiting requests.
    case rateLimited
    /// 5xx from the provider.
    case serverError(Int)
    /// Any other status that is not a success.
    case unexpectedStatus(Int)
    /// No answer within the time limit.
    case timeout
    /// No connection, no DNS, or a TLS failure.
    case network(NetworkProblem)
    /// The Base URL is not an http(s) address with a host.
    case invalidURL
    /// The key would travel over plain http to a remote host. Nothing was sent.
    case insecureURL
    /// The auth kind needs a key and none is typed or stored. Nothing was sent.
    case missingKey
    /// The provider redirected to another origin. The redirect was refused.
    case crossHostRedirect
    /// The provider has no model list (or it is not a list).
    case unsupported

    public var severity: ProbeSeverity {
        switch self {
        case .ok: return .success
        case .rateLimited, .unsupported: return .warning
        default: return .error
        }
    }

    /// The key of the localized sentence. Never contains the key itself.
    public var messageKey: String {
        switch self {
        case .ok(_, let model): return model == nil ? "probe.ok" : "probe.ok.model"
        case .unauthorized: return "probe.unauthorized"
        case .forbidden: return "probe.forbidden"
        case .notFound: return "probe.notFound"
        case .modelNotFound: return "probe.modelNotFound"
        case .rateLimited: return "probe.rateLimited"
        case .serverError: return "probe.serverError"
        case .unexpectedStatus: return "probe.unexpectedStatus"
        case .timeout: return "probe.timeout"
        case .network(let problem): return "probe.network.\(problem.rawValue)"
        case .invalidURL: return "probe.invalidURL"
        case .insecureURL: return "probe.insecureURL"
        case .missingKey: return "probe.missingKey"
        case .crossHostRedirect: return "probe.crossHostRedirect"
        case .unsupported: return "probe.unsupported"
        }
    }
}

/// The outcome of "Test connection", with the provider's own words when it gave any.
public struct ProbeReport: Equatable, Sendable {
    public var outcome: ProbeOutcome
    /// A short, redacted excerpt of the provider's error message.
    public var providerMessage: String?

    public init(outcome: ProbeOutcome, providerMessage: String? = nil) {
        self.outcome = outcome
        self.providerMessage = providerMessage
    }
}

/// The outcome of "Fetch models".
public struct ModelListReport: Equatable, Sendable {
    public var outcome: ProbeOutcome
    /// The model ids, sorted and de-duplicated. Empty unless the fetch worked.
    public var models: [String]
    /// A short, redacted excerpt of the provider's error message.
    public var providerMessage: String?

    public init(outcome: ProbeOutcome, models: [String] = [], providerMessage: String? = nil) {
        self.outcome = outcome
        self.models = models
        self.providerMessage = providerMessage
    }
}

/// Makes the small real requests of the editor: one message for "Test connection"
/// and the model list for "Fetch models".
///
/// The session is injectable, so the tests answer with `StubURLProtocol`.
/// The key is only ever placed in the `Authorization` or `x-api-key` header.
public struct ConnectionProbe: Sendable {
    /// How long one request may take.
    public static let timeout: TimeInterval = 20

    /// How many pages of a model list are read at most.
    public static let maxModelPages = 5

    /// The session used when none is given: ephemeral, no cache, no cookies.
    public let session: URLSession

    public init(session: URLSession = ConnectionProbe.makeSession()) {
        self.session = session
    }

    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return URLSession(configuration: configuration)
    }

    /// Sends one tiny message (`max_tokens` 1, about one token) with the profile's settings.
    ///
    /// Nothing is sent when the URL is invalid, when the key would travel over
    /// plain http to a remote host, or when a key is needed and `key` is empty.
    /// - Throws: `CancellationError` when the task is cancelled.
    public func testConnection(profile: Profile, key: String) async throws -> ProbeReport {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = ProviderEndpoint.url(baseURL: profile.baseURL, path: "v1/messages") else {
            return ProbeReport(outcome: .invalidURL)
        }
        if ProviderEndpoint.isInsecure(url) {
            return ProbeReport(outcome: .insecureURL)
        }
        if profile.auth != .none && trimmedKey.isEmpty {
            return ProbeReport(outcome: .missingKey)
        }

        var request = URLRequest(url: url, timeoutInterval: ConnectionProbe.timeout)
        request.httpMethod = "POST"
        for (name, value) in ProviderEndpoint.headers(auth: profile.auth, key: trimmedKey, json: true) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let body: [String: Any] = [
            "model": ProviderEndpoint.probeModel(for: profile),
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ping"]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let started = ContinuousClock.now
        switch try await send(request) {
        case .failed(let outcome):
            return ProbeReport(outcome: outcome)
        case .answer(let answer):
            let latency = Int(started.duration(to: ContinuousClock.now) / Duration.milliseconds(1))
            return ConnectionProbe.classify(
                status: answer.status,
                body: answer.body,
                key: trimmedKey,
                latencyMs: latency
            )
        }
    }

    /// Reads the model list of the provider: `GET v1/models`, or `models` when
    /// `v1/models` answers 404. Pages are followed up to `maxModelPages`.
    /// - Throws: `CancellationError` when the task is cancelled.
    public func fetchModels(profile: Profile, key: String) async throws -> ModelListReport {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let primary = ProviderEndpoint.url(baseURL: profile.baseURL, path: "v1/models") else {
            return ModelListReport(outcome: .invalidURL)
        }
        if ProviderEndpoint.isInsecure(primary) {
            return ModelListReport(outcome: .insecureURL)
        }
        if profile.auth != .none && trimmedKey.isEmpty {
            return ModelListReport(outcome: .missingKey)
        }
        let fallback = ProviderEndpoint.url(baseURL: profile.baseURL, path: "models")

        var pageURL = primary
        var usedFallback = false
        var fetched = 0
        var collected: [String] = []
        let started = ContinuousClock.now

        while true {
            var request = URLRequest(url: pageURL, timeoutInterval: ConnectionProbe.timeout)
            request.httpMethod = "GET"
            for (name, value) in ProviderEndpoint.headers(auth: profile.auth, key: trimmedKey, json: false) {
                request.setValue(value, forHTTPHeaderField: name)
            }

            switch try await send(request) {
            case .failed(let outcome):
                return ModelListReport(outcome: outcome)
            case .answer(let answer):
                if answer.status == 404, fetched == 0, !usedFallback,
                   let fallback, fallback != primary {
                    usedFallback = true
                    pageURL = fallback
                    continue
                }
                guard (200...299).contains(answer.status) else {
                    let failure = ConnectionProbe.classify(
                        status: answer.status, body: answer.body, key: trimmedKey, latencyMs: 0
                    )
                    // A missing list endpoint is the same as a provider without one.
                    if answer.status == 404 || answer.status == 405 {
                        return ModelListReport(outcome: .unsupported)
                    }
                    return ModelListReport(outcome: failure.outcome, providerMessage: failure.providerMessage)
                }
                guard let page = ModelListParser.parse(answer.body) else {
                    return ModelListReport(outcome: .unsupported)
                }
                collected += page.ids
                fetched += 1
                if page.hasMore, let last = page.lastID, fetched < ConnectionProbe.maxModelPages {
                    pageURL = ConnectionProbe.page(after: last, of: pageURL)
                    continue
                }
                let models = ModelListParser.normalize(collected)
                guard !models.isEmpty else {
                    return ModelListReport(outcome: .unsupported)
                }
                let latency = Int(started.duration(to: ContinuousClock.now) / Duration.milliseconds(1))
                return ModelListReport(outcome: .ok(latencyMs: latency, model: nil), models: models)
            }
        }
    }

    // MARK: - Classification (pure, tested directly)

    /// Turns the status and body of an answer into a report. A success body
    /// may name the model; an error body may carry the provider's message.
    public static func classify(status: Int, body: Data, key: String, latencyMs: Int) -> ProbeReport {
        if (200...299).contains(status) {
            let model = ProviderMessage.modelName(from: body, key: key)
            return ProbeReport(outcome: .ok(latencyMs: latencyMs, model: model))
        }

        let message = ProviderMessage.snippet(from: body, key: key)
        let lowered = (message ?? "").lowercased()
        let outcome: ProbeOutcome
        switch status {
        case 401: outcome = .unauthorized
        case 403: outcome = .forbidden
        case 429: outcome = .rateLimited
        case 500...599: outcome = .serverError(status)
        case 400, 404:
            if mentionsUnknownModel(lowered) {
                outcome = .modelNotFound
            } else {
                outcome = status == 404 ? .notFound : .unexpectedStatus(status)
            }
        default: outcome = .unexpectedStatus(status)
        }
        return ProbeReport(outcome: outcome, providerMessage: message)
    }

    /// `true` for a message that names the model and says it is unknown or wrong.
    static func mentionsUnknownModel(_ lowered: String) -> Bool {
        guard lowered.contains("model") else { return false }
        let phrases = [
            "not found", "not_found", "does not exist", "doesn't exist", "not exist",
            "unknown", "invalid", "no such", "not supported", "unsupported", "not available",
        ]
        return phrases.contains { lowered.contains($0) }
    }

    /// The same URL with the `after_id` query item set to the cursor.
    static func page(after cursor: String, of url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.queryItems = [URLQueryItem(name: "after_id", value: cursor)]
        return components.url ?? url
    }

    // MARK: - Transport

    private struct Answer {
        var status: Int
        var body: Data
    }

    private enum Transport {
        case answer(Answer)
        case failed(ProbeOutcome)
    }

    /// Runs one request. A refused redirect and every transport failure come back as `.failure`.
    private func send(_ request: URLRequest) async throws -> Transport {
        try Task.checkCancellation()
        guard let origin = request.url else { return .failed(.invalidURL) }
        let guardian = RedirectGuard(origin: origin)
        do {
            let (data, response) = try await session.data(for: request, delegate: guardian)
            if guardian.refused {
                return .failed(.crossHostRedirect)
            }
            guard let http = response as? HTTPURLResponse else {
                return .failed(.network(.other))
            }
            return .answer(Answer(status: http.statusCode, body: data))
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            return .failed(ConnectionProbe.map(error))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed(.network(.other))
        }
    }

    /// Turns a transport error into an outcome. No text of the error is kept.
    public static func map(_ error: URLError) -> ProbeOutcome {
        switch error.code {
        case .timedOut:
            return .timeout
        case .cannotFindHost, .dnsLookupFailed:
            return .network(.dns)
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .network(.offline)
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            return .network(.tls)
        default:
            return .network(.other)
        }
    }
}

/// Follows a redirect only to the same origin (scheme, host and port).
///
/// Any other redirect is refused: the request is not repeated, so the
/// `Authorization` header never reaches the second address.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL
    private let lock = NSLock()
    private var refusedFlag = false

    /// `true` once a redirect was refused.
    var refused: Bool { lock.withLock { refusedFlag } }

    init(origin: URL) {
        self.origin = origin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let allowed = request.url.map { RedirectGuard.sameOrigin($0, origin) } ?? false
        if !allowed {
            lock.withLock { refusedFlag = true }
        }
        completionHandler(allowed ? request : nil)
    }

    /// `true` when both addresses have the same scheme, host and port.
    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let leftScheme = lhs.scheme?.lowercased(),
              let rightScheme = rhs.scheme?.lowercased(),
              leftScheme == rightScheme,
              let leftHost = lhs.host?.lowercased(),
              let rightHost = rhs.host?.lowercased(),
              leftHost == rightHost
        else { return false }
        return effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int {
        if let port = url.port { return port }
        return url.scheme?.lowercased() == "https" ? 443 : 80
    }
}

/// Text of a provider answer that is safe to show: redacted, one line, short.
public enum ProviderMessage {
    /// The longest excerpt that is shown.
    public static let maxLength = 160

    /// The `error.message` (or `message`) of a JSON error body, with the key removed.
    /// Returns `nil` when the body is not JSON or has no such text.
    public static func snippet(from body: Data, key: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        var text: String?
        if let error = object["error"] as? [String: Any] {
            text = error["message"] as? String
        } else if let error = object["error"] as? String {
            text = error
        }
        if text == nil {
            text = object["message"] as? String
        }
        guard let raw = text else { return nil }
        return sanitize(raw, key: key, limit: maxLength)
    }

    /// The model name of a success body, cleaned the same way.
    public static func modelName(from body: Data, key: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = object["model"] as? String
        else { return nil }
        return sanitize(model, key: key, limit: 80)
    }

    /// Strips the key, turns control characters into spaces, collapses the
    /// whitespace and cuts the text to `limit` characters.
    static func sanitize(_ text: String, key: String, limit: Int) -> String? {
        var value = collapse(text)
        if !key.isEmpty {
            value = value.replacingOccurrences(of: key, with: "[redacted]")
        }
        value = collapse(value)
        guard !value.isEmpty else { return nil }
        if value.count > limit {
            value = String(value.prefix(limit - 1)) + "…"
        }
        return value
    }

    private static func collapse(_ text: String) -> String {
        let spaced = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar -> Unicode.Scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : scalar
        }))
        return spaced.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
