import XCTest
@testable import AgentProfilesCore

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



    // MARK: - Outcomes









    // MARK: - Request shape and secrets








    // MARK: - Nothing sent








    // MARK: - Redirects



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

    // MARK: - Key choice

    func testTypedKeyWinsOverTheStoredOne() throws {
        let keys = InMemoryKeyStore()
        try keys.set("test", key: "sk-STORED")
        XCTAssertEqual(try ConnectionProbe.key(typed: " sk-TYPED ", auth: .bearer, account: "test", keys: keys), "sk-TYPED")
    }

    func testStoredKeyIsUsedWhenNothingIsTyped() throws {
        let keys = InMemoryKeyStore()
        try keys.set("test", key: "sk-STORED")
        XCTAssertEqual(try ConnectionProbe.key(typed: "  ", auth: .apiKey, account: "test", keys: keys), "sk-STORED")
        XCTAssertEqual(try ConnectionProbe.key(typed: "", auth: .apiKey, account: "other", keys: keys), "")
        XCTAssertEqual(try ConnectionProbe.key(typed: "", auth: .apiKey, account: "", keys: keys), "")
    }

    func testNoAuthNeverReadsTheStore() throws {
        let keys = InMemoryKeyStore()
        try keys.set("test", key: "sk-STORED")
        XCTAssertEqual(try ConnectionProbe.key(typed: "sk-TYPED", auth: .none, account: "test", keys: keys), "")
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
