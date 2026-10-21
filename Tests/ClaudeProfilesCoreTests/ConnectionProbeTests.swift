import XCTest
@testable import ClaudeProfilesCore

/// The probe against the stub transport: no request ever leaves the machine.
final class ConnectionProbeTests: XCTestCase {
    private var probe: ConnectionProbe!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        probe = ConnectionProbe(session: StubURLProtocol.session())
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private let base = "https://api.example.com"
    private var messagesURL: String { "\(base)/v1/messages" }
    private var modelsURL: String { "\(base)/v1/models" }

    private func profile(
        baseURL: String = "https://api.example.com",
        auth: AuthKind = .bearer,
        model: String = "",
        haiku: String = ""
    ) -> Profile {
        Profile(name: "Test", slug: "test", baseURL: baseURL, auth: auth, model: model, haikuModel: haiku)
    }

    private func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            result.append(buffer, count: read)
        }
        return result
    }

    private func test(_ profile: Profile, key: String = "sk-SECRET-123") async throws -> ProbeReport {
        try await probe.testConnection(profile: profile, key: key)
    }

    private func answerMessages(_ answer: StubURLProtocol.Answer) {
        StubURLProtocol.answer(answer, for: messagesURL)
    }

    // MARK: - Outcomes

    func testSuccessReportsLatencyAndModel() async throws {
        answerMessages(.json(#"{"model":"claude-haiku-4-5","content":[]}"#))
        let report = try await test(profile())
        guard case .ok(let latency, let model) = report.outcome else {
            return XCTFail("expected ok, got \(report.outcome)")
        }
        XCTAssertGreaterThanOrEqual(latency, 0)
        XCTAssertEqual(model, "claude-haiku-4-5")
        XCTAssertEqual(report.outcome.severity, .success)
    }

    func testSuccessWithoutModelNameStillOK() async throws {
        answerMessages(.json("{}"))
        let report = try await test(profile())
        XCTAssertEqual(report.outcome.messageKey, "probe.ok")
    }

    func testStatusCodesMapToOutcomes() async throws {
        let cases: [(Int, ProbeOutcome, ProbeSeverity)] = [
            (401, .unauthorized, .error),
            (403, .forbidden, .error),
            (404, .notFound, .error),
            (429, .rateLimited, .warning),
            (500, .serverError(500), .error),
            (503, .serverError(503), .error),
            (418, .unexpectedStatus(418), .error),
        ]
        for (status, expected, severity) in cases {
            StubURLProtocol.reset()
            answerMessages(.json(#"{"error":{"type":"x","message":"plain"}}"#, statusCode: status))
            let report = try await test(profile())
            XCTAssertEqual(report.outcome, expected, "status \(status)")
            XCTAssertEqual(report.outcome.severity, severity, "severity of \(status)")
        }
    }

    func testModelNotFoundFromNotFoundAndBadRequest() async throws {
        answerMessages(.json(#"{"type":"error","error":{"type":"not_found_error","message":"model: claude-x does not exist"}}"#, statusCode: 404))
        var report = try await test(profile(model: "claude-x"))
        XCTAssertEqual(report.outcome, .modelNotFound)

        StubURLProtocol.reset()
        answerMessages(.json(#"{"error":{"message":"Invalid model name passed in"}}"#, statusCode: 400))
        report = try await test(profile(model: "claude-x"))
        XCTAssertEqual(report.outcome, .modelNotFound)
    }

    func testBadRequestThatIsNotAboutTheModelStaysGeneric() async throws {
        answerMessages(.json(#"{"error":{"message":"max_tokens is too large"}}"#, statusCode: 400))
        let report = try await test(profile())
        XCTAssertEqual(report.outcome, .unexpectedStatus(400))
    }

    func testTimeoutIsReported() async throws {
        StubURLProtocol.answer(.failure(URLError(.timedOut)), for: messagesURL)
        let report = try await test(profile())
        XCTAssertEqual(report.outcome, .timeout)
    }

    func testDNSFailureIsReported() async throws {
        StubURLProtocol.answer(.failure(URLError(.cannotFindHost)), for: messagesURL)
        let report = try await test(profile())
        XCTAssertEqual(report.outcome, .network(.dns))
        XCTAssertEqual(report.outcome.messageKey, "probe.network.dns")
    }

    func testOfflineAndTLSAreReported() async throws {
        StubURLProtocol.answer(.failure(URLError(.notConnectedToInternet)), for: messagesURL)
        var report = try await test(profile())
        XCTAssertEqual(report.outcome, .network(.offline))

        StubURLProtocol.reset()
        StubURLProtocol.answer(.failure(URLError(.serverCertificateUntrusted)), for: messagesURL)
        report = try await test(profile())
        XCTAssertEqual(report.outcome, .network(.tls))
    }

    // MARK: - Request shape and secrets

    func testRequestShapeAndBody() async throws {
        answerMessages(.json("{}"))
        _ = try await test(profile(model: "glm-4.6", haiku: "glm-air"))
        let request = try XCTUnwrap(StubURLProtocol.requests.first { $0.url?.absoluteString == messagesURL })
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body(of: request)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "glm-4.6")
        XCTAssertEqual(json["max_tokens"] as? Int, 1)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": "ping"]])
    }

    func testBearerSendsAuthorizationOnly() async throws {
        answerMessages(.json("{}"))
        _ = try await test(profile(auth: .bearer), key: "sk-SECRET-123")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-SECRET-123")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
    }

    func testAPIKeySendsXApiKeyOnly() async throws {
        answerMessages(.json("{}"))
        _ = try await test(profile(auth: .apiKey), key: "sk-SECRET-123")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-SECRET-123")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testNoneAuthSendsNoCredentialHeader() async throws {
        StubURLProtocol.answer(.json("{}"), for: "http://localhost:4000/v1/messages")
        _ = try await test(profile(baseURL: "http://localhost:4000", auth: .none), key: "sk-SECRET-123")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
    }

    func testKeyNeverAppearsInTheURLOrTheBody() async throws {
        answerMessages(.json("{}"))
        _ = try await test(profile(auth: .apiKey), key: "sk-SECRET-123")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertFalse(request.url?.absoluteString.contains("sk-SECRET-123") ?? true)
        XCTAssertFalse(String(decoding: body(of: request), as: UTF8.self).contains("sk-SECRET-123"))
    }

    func testTypedKeyIsTrimmed() async throws {
        answerMessages(.json("{}"))
        _ = try await test(profile(auth: .bearer), key: "  sk-SECRET-123\n")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-SECRET-123")
    }

    func testProviderTextWithTheKeyIsRedacted() async throws {
        answerMessages(.json(#"{"error":{"message":"Key sk-SECRET-123 is not valid"}}"#, statusCode: 401))
        let report = try await test(profile())
        XCTAssertEqual(report.outcome, .unauthorized)
        let shown = try XCTUnwrap(report.providerMessage)
        XCTAssertFalse(shown.contains("sk-SECRET-123"))
        XCTAssertTrue(shown.contains("[redacted]"))
    }

    // MARK: - Nothing sent

    func testMissingKeySendsNothing() async throws {
        for auth in [AuthKind.bearer, .apiKey] {
            StubURLProtocol.reset()
            answerMessages(.json("{}"))
            let report = try await test(profile(auth: auth), key: "  ")
            XCTAssertEqual(report.outcome, .missingKey)
            XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        }
    }

    func testNoneAuthDoesNotNeedAKey() async throws {
        StubURLProtocol.answer(.json("{}"), for: "http://localhost:4000/v1/messages")
        let report = try await test(profile(baseURL: "http://localhost:4000", auth: .none), key: "")
        XCTAssertEqual(report.outcome.messageKey, "probe.ok")
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testInvalidURLSendsNothing() async throws {
        let report = try await test(profile(baseURL: "api.example.com"))
        XCTAssertEqual(report.outcome, .invalidURL)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testRemotePlainHTTPIsRefusedBeforeAnyRequest() async throws {
        answerMessages(.json("{}"))
        let report = try await test(profile(baseURL: "http://api.example.com"))
        XCTAssertEqual(report.outcome, .insecureURL)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testLocalhostPlainHTTPIsAllowed() async throws {
        for host in ["http://localhost:4000", "http://127.0.0.1:4000", "http://[::1]:4000"] {
            StubURLProtocol.reset()
            StubURLProtocol.answer(.json("{}"), for: host + "/v1/messages")
            let report = try await test(profile(baseURL: host, auth: .none))
            XCTAssertEqual(report.outcome.messageKey, "probe.ok", host)
            XCTAssertEqual(StubURLProtocol.requests.count, 1, host)
        }
    }

    func testCancelledTaskSendsNothingAndThrows() async {
        answerMessages(.json("{}"))
        let probe = self.probe!
        let profile = profile()
        let task = Task { () throws -> ProbeReport in
            while !Task.isCancelled { await Task.yield() }
            return try await probe.testConnection(profile: profile, key: "sk-SECRET-123")
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled check must throw")
        } catch is CancellationError {
            XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - Redirects

    func testCrossHostRedirectIsRefusedAndTheKeyStaysHome() async throws {
        answerMessages(.redirect(to: "https://evil.example.net/v1/messages"))
        StubURLProtocol.answer(.json(#"{"model":"x"}"#), for: "https://evil.example.net/v1/messages")

        let report = try await test(profile(auth: .bearer), key: "sk-SECRET-123")

        XCTAssertEqual(report.outcome, .crossHostRedirect)
        XCTAssertEqual(report.outcome.messageKey, "probe.crossHostRedirect")
        let hosts = StubURLProtocol.requests.compactMap { $0.url?.host }
        XCTAssertFalse(hosts.contains("evil.example.net"), "the second host must never be contacted")
    }

    func testHTTPSDowngradeRedirectIsRefused() async throws {
        answerMessages(.redirect(to: "http://api.example.com/v1/messages"))
        let report = try await test(profile())
        XCTAssertEqual(report.outcome, .crossHostRedirect)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    // MARK: - Provider text

    func testSnippetIsRedactedCleanedAndShort() {
        let long = String(repeating: "word ", count: 100)
        let body = Data(#"{"error":{"message":"bad\u0007 key sk-SECRET-123\nline two \#(long)"}}"#.utf8)
        let snippet = ProviderMessage.snippet(from: body, key: "sk-SECRET-123")
        XCTAssertNotNil(snippet)
        XCTAssertFalse(snippet?.contains("sk-SECRET-123") ?? true)
        XCTAssertFalse(snippet?.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ?? true)
        XCTAssertLessThanOrEqual(snippet?.count ?? 0, ProviderMessage.maxLength)
        XCTAssertTrue(snippet?.hasPrefix("bad key [redacted] line two") ?? false)
    }

    func testSnippetReadsTopLevelMessageAndErrorString() {
        XCTAssertEqual(ProviderMessage.snippet(from: Data(#"{"message":"nope"}"#.utf8), key: "k"), "nope")
        XCTAssertEqual(ProviderMessage.snippet(from: Data(#"{"error":"also nope"}"#.utf8), key: "k"), "also nope")
        XCTAssertNil(ProviderMessage.snippet(from: Data("<html>".utf8), key: "k"))
        XCTAssertNil(ProviderMessage.snippet(from: Data(#"{"other":1}"#.utf8), key: "k"))
    }

    func testSnippetWithoutAKeyKeepsTheText() {
        XCTAssertEqual(ProviderMessage.snippet(from: Data(#"{"message":"plain"}"#.utf8), key: ""), "plain")
    }

    // MARK: - Classification helpers

    func testRateLimitedIsAWarningAndOKIsSuccess() {
        XCTAssertEqual(ProbeOutcome.rateLimited.severity, .warning)
        XCTAssertEqual(ProbeOutcome.unsupported.severity, .warning)
        XCTAssertEqual(ProbeOutcome.ok(latencyMs: 1, model: nil).severity, .success)
        XCTAssertEqual(ProbeOutcome.insecureURL.severity, .error)
    }

    func testTransportErrorsMapToNetworkProblems() {
        XCTAssertEqual(ConnectionProbe.map(URLError(.timedOut)), .timeout)
        XCTAssertEqual(ConnectionProbe.map(URLError(.dnsLookupFailed)), .network(.dns))
        XCTAssertEqual(ConnectionProbe.map(URLError(.networkConnectionLost)), .network(.other))
    }
}
