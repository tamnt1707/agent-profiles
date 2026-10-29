import XCTest
@testable import AgentProfilesCore

/// "Fetch models" against the stub transport.
final class ModelFetchTests: XCTestCase {
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

    private func profile(auth: AuthKind = .apiKey, baseURL: String = "https://api.example.com") -> Profile {
        Profile(name: "Test", slug: "test", baseURL: baseURL, auth: auth)
    }

    func testParsesTheDataShapeWithHeaders() async throws {
        StubURLProtocol.answer(.json(#"{"data":[{"id":"zeta"},{"id":"alpha"},{"id":"alpha"}]}"#), for: "\(base)/v1/models")
        let report = try await probe.fetchModels(profile: profile(), key: "sk-SECRET-123")

        XCTAssertEqual(report.outcome.messageKey, "probe.ok")
        XCTAssertEqual(report.models, ["alpha", "zeta"])
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-SECRET-123")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(request.url?.absoluteString.contains("sk-SECRET-123") ?? true)
    }

    func testBearerHeaderOnTheModelList() async throws {
        StubURLProtocol.answer(.json(#"{"models":[{"name":"glm-4.6"}]}"#), for: "\(base)/v1/models")
        let report = try await probe.fetchModels(profile: profile(auth: .bearer), key: "sk-SECRET-123")
        XCTAssertEqual(report.models, ["glm-4.6"])
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-SECRET-123")
    }

    func testFollowsPaginationWithAfterID() async throws {
        StubURLProtocol.answer(.json(#"{"data":[{"id":"b"}],"has_more":true,"last_id":"b"}"#), for: "\(base)/v1/models")
        StubURLProtocol.answer(.json(#"{"data":[{"id":"a"}],"has_more":false,"last_id":"a"}"#), for: "\(base)/v1/models?after_id=b")

        let report = try await probe.fetchModels(profile: profile(), key: "sk-SECRET-123")

        XCTAssertEqual(report.models, ["a", "b"])
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testPaginationStopsAfterFivePages() async throws {
        StubURLProtocol.answer(.json(#"{"data":[{"id":"a"}],"has_more":true,"last_id":"a"}"#))
        let report = try await probe.fetchModels(profile: profile(), key: "sk-SECRET-123")
        XCTAssertEqual(StubURLProtocol.requests.count, 5)
        XCTAssertEqual(report.models, ["a"], "duplicates across pages are removed")
    }

    func testFallsBackToModelsWhenV1ModelsIsNotFound() async throws {
        StubURLProtocol.answer(.json(#"{"error":"nope"}"#, statusCode: 404), for: "\(base)/v1/models")
        StubURLProtocol.answer(.json(#"{"data":[{"id":"m1"}]}"#), for: "\(base)/models")

        let report = try await probe.fetchModels(profile: profile(), key: "sk-SECRET-123")

        XCTAssertEqual(report.models, ["m1"])
        let urls = StubURLProtocol.requests.compactMap { $0.url?.absoluteString }
        XCTAssertEqual(urls, ["\(base)/v1/models", "\(base)/models"])
    }

    func testNoListEndpointIsUnsupported() async throws {
        StubURLProtocol.answer(.json("{}", statusCode: 404))
        var report = try await probe.fetchModels(profile: profile(), key: "sk-SECRET-123")
        XCTAssertEqual(report.outcome, .unsupported)
        XCTAssertTrue(report.models.isEmpty)

        StubURLProtocol.reset()
        StubURLProtocol.answer(.json("{}", statusCode: 405), for: "\(base)/v1/models")
        report = try await probe.fetchModels(profile: profile(), key: "sk-SECRET-123")
        XCTAssertEqual(report.outcome, .unsupported)
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "405 does not trigger the fallback")
    }

    func testBodyThatIsNotAListIsUnsupported() async throws {
        StubURLProtocol.answer(.json(#"{"error":"we have no list"}"#), for: "\(base)/v1/models")
        let report = try await probe.fetchModels(profile: profile(), key: "sk-SECRET-123")
        XCTAssertEqual(report.outcome, .unsupported)
    }

    func testEmptyListIsUnsupported() async throws {
        StubURLProtocol.answer(.json(#"{"data":[]}"#), for: "\(base)/v1/models")
        let report = try await probe.fetchModels(profile: profile(), key: "sk-SECRET-123")
        XCTAssertEqual(report.outcome, .unsupported)
    }

    func testAuthErrorsAreReportedWithRedactedText() async throws {
        StubURLProtocol.answer(.json(#"{"error":{"message":"bad key sk-SECRET-123"}}"#, statusCode: 401), for: "\(base)/v1/models")
        let report = try await probe.fetchModels(profile: profile(), key: "sk-SECRET-123")
        XCTAssertEqual(report.outcome, .unauthorized)
        XCTAssertFalse(report.providerMessage?.contains("sk-SECRET-123") ?? true)
    }

    func testRedirectToAnotherHostIsRefused() async throws {
        StubURLProtocol.answer(.redirect(to: "https://evil.example.net/v1/models"), for: "\(base)/v1/models")
        StubURLProtocol.answer(.json(#"{"data":[{"id":"x"}]}"#), for: "https://evil.example.net/v1/models")
        let report = try await probe.fetchModels(profile: profile(), key: "sk-SECRET-123")
        XCTAssertEqual(report.outcome, .crossHostRedirect)
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.host == "evil.example.net" })
    }

    func testMissingKeyOrInsecureURLSendsNothing() async throws {
        var report = try await probe.fetchModels(profile: profile(), key: "")
        XCTAssertEqual(report.outcome, .missingKey)

        report = try await probe.fetchModels(profile: profile(baseURL: "http://models.example.com"), key: "sk-SECRET-123")
        XCTAssertEqual(report.outcome, .insecureURL)

        report = try await probe.fetchModels(profile: profile(baseURL: "not a url"), key: "sk-SECRET-123")
        XCTAssertEqual(report.outcome, .invalidURL)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }
}
