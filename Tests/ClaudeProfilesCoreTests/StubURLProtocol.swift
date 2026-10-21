import Foundation

/// Answers the requests of the tests without touching the network.
///
/// The stub replaces the whole transport: every request of a session that was
/// made with `StubURLProtocol.session()` is answered here.
final class StubURLProtocol: URLProtocol {
    /// What the stub answers with.
    struct Answer {
        var statusCode = 200
        var headers: [String: String] = [:]
        var body = Data()
        var error: Error?
        /// When it is set, the stub answers with a redirect to this address.
        var redirectTo: String?

        /// A JSON answer.
        static func json(_ text: String, statusCode: Int = 200) -> Answer {
            Answer(
                statusCode: statusCode,
                headers: ["Content-Type": "application/json"],
                body: Data(text.utf8)
            )
        }

        /// A binary answer.
        static func bytes(_ data: Data, statusCode: Int = 200) -> Answer {
            Answer(statusCode: statusCode, body: data)
        }

        /// A transport error.
        static func failure(_ error: Error) -> Answer {
            Answer(error: error)
        }

        /// A redirect to another address.
        static func redirect(to location: String) -> Answer {
            Answer(statusCode: 302, headers: ["Location": location], body: Data())
        }
    }

    private static let lock = NSLock()
    private static var answers: [String: Answer] = [:]
    private static var fallbackAnswer: Answer?
    private static var recorded: [URLRequest] = []

    /// A session that only talks to the stub.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Forgets every answer and every recorded request.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        answers = [:]
        fallbackAnswer = nil
        recorded = []
    }

    /// The answer for an address.
    static func answer(_ answer: Answer, for url: String) {
        lock.lock()
        defer { lock.unlock() }
        answers[url] = answer
    }

    /// The answer for every address that was not named.
    static func answer(_ answer: Answer) {
        lock.lock()
        defer { lock.unlock() }
        fallbackAnswer = answer
    }

    /// The requests the stub has seen.
    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private static func lookup(_ request: URLRequest) -> Answer {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(request)
        guard let url = request.url else { return Answer(statusCode: 404, body: Data()) }
        if let answer = answers[url.absoluteString] { return answer }
        if let answer = fallbackAnswer { return answer }
        return Answer(statusCode: 404, body: Data())
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let answer = StubURLProtocol.lookup(request)

        if let error = answer.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        if let redirect = answer.redirectTo,
           let location = URL(string: redirect),
           let response = HTTPURLResponse(
               url: url,
               statusCode: 302,
               httpVersion: "HTTP/1.1",
               headerFields: ["Location": location.absoluteString]
           ) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        var headerFields = answer.headers
        headerFields["Content-Length"] = String(answer.body.count)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: answer.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !answer.body.isEmpty {
            client?.urlProtocol(self, didLoad: answer.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
