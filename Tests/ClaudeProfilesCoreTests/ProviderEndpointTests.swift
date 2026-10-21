import XCTest
@testable import ClaudeProfilesCore

final class ProviderEndpointTests: XCTestCase {
    private func url(_ base: String, _ path: String = "v1/messages") -> String? {
        ProviderEndpoint.url(baseURL: base, path: path)?.absoluteString
    }

    func testEmptyBaseURLMeansTheAnthropicAPI() {
        XCTAssertEqual(url(""), "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(url("   "), "https://api.anthropic.com/v1/messages")
    }

    func testTrailingSlashesAreDropped() {
        XCTAssertEqual(url("https://api.anthropic.com/"), "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(url("https://api.anthropic.com//"), "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(url("  https://api.anthropic.com  "), "https://api.anthropic.com/v1/messages")
    }

    func testBaseURLAlreadyEndingInV1IsNotDoubled() {
        XCTAssertEqual(url("https://api.anthropic.com/v1"), "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(url("https://api.anthropic.com/v1/"), "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(url("https://api.anthropic.com/v1", "v1/models"), "https://api.anthropic.com/v1/models")
    }

    func testPathPrefixesAreKept() {
        XCTAssertEqual(url("https://openrouter.ai/api"), "https://openrouter.ai/api/v1/messages")
        XCTAssertEqual(url("https://api.deepseek.com/anthropic/"), "https://api.deepseek.com/anthropic/v1/messages")
        XCTAssertEqual(url("https://api.z.ai/api/anthropic"), "https://api.z.ai/api/anthropic/v1/messages")
        XCTAssertEqual(url("https://gw.example.com/api/anthropic/v1"), "https://gw.example.com/api/anthropic/v1/messages")
    }

    func testModelsFallbackPathUsesTheBaseDirectly() {
        XCTAssertEqual(url("https://gw.example.com/anthropic", "models"), "https://gw.example.com/anthropic/models")
        XCTAssertEqual(url("https://gw.example.com", "models"), "https://gw.example.com/models")
    }

    func testPortIsKept() {
        XCTAssertEqual(url("http://localhost:4000"), "http://localhost:4000/v1/messages")
    }

    func testNoDoubleSlashInThePath() {
        let bases = ["", "https://a.example.com", "https://a.example.com/", "https://a.example.com//x/",
                     "https://a.example.com/v1/", "https://a.example.com/x/v1//"]
        for base in bases {
            guard let result = ProviderEndpoint.url(baseURL: base, path: "v1/messages") else {
                XCTFail("\(base) should be a valid base")
                continue
            }
            XCTAssertFalse(result.path.contains("//"), "double slash in \(result.absoluteString)")
        }
    }

    func testInvalidBaseURLsAreRefused() {
        XCTAssertNil(url("api.example.com"))
        XCTAssertNil(url("ftp://api.example.com"))
        XCTAssertNil(url("https://"))
        XCTAssertNil(url("https://api.example.com/?key=1"))
        XCTAssertNil(url("https://api.example.com/#frag"))
        XCTAssertNil(url("https://user:pass@api.example.com"))
        XCTAssertNil(url("localhost:4000"))
    }

    func testOnlyRemotePlainHTTPIsInsecure() {
        func insecure(_ text: String) -> Bool {
            ProviderEndpoint.isInsecure(URL(string: text)!)
        }
        XCTAssertTrue(insecure("http://api.example.com/v1/messages"))
        XCTAssertTrue(insecure("http://192.168.1.10:4000/v1/messages"))
        XCTAssertFalse(insecure("http://localhost:4000/v1/messages"))
        XCTAssertFalse(insecure("http://127.0.0.1:4000/v1/messages"))
        XCTAssertFalse(insecure("http://[::1]:4000/v1/messages"))
        XCTAssertFalse(insecure("https://api.example.com/v1/messages"))
    }

    func testHeadersPerAuthKind() {
        let bearer = ProviderEndpoint.headers(auth: .bearer, key: "sk-abc", json: true)
        XCTAssertEqual(bearer["Authorization"], "Bearer sk-abc")
        XCTAssertNil(bearer["x-api-key"])
        XCTAssertEqual(bearer["content-type"], "application/json")
        XCTAssertEqual(bearer["anthropic-version"], "2023-06-01")

        let apiKey = ProviderEndpoint.headers(auth: .apiKey, key: "sk-abc", json: true)
        XCTAssertEqual(apiKey["x-api-key"], "sk-abc")
        XCTAssertNil(apiKey["Authorization"])

        let none = ProviderEndpoint.headers(auth: .none, key: "sk-abc", json: false)
        XCTAssertNil(none["Authorization"])
        XCTAssertNil(none["x-api-key"])
        XCTAssertNil(none["content-type"])
    }

    func testProbeModelOrder() {
        XCTAssertEqual(ProviderEndpoint.probeModel(for: Profile()), "claude-haiku-4-5")
        XCTAssertEqual(ProviderEndpoint.probeModel(for: Profile(opusModel: "o")), "o")
        XCTAssertEqual(ProviderEndpoint.probeModel(for: Profile(opusModel: "o", sonnetModel: "s")), "s")
        XCTAssertEqual(ProviderEndpoint.probeModel(for: Profile(sonnetModel: "s", haikuModel: "h")), "h")
        XCTAssertEqual(ProviderEndpoint.probeModel(for: Profile(model: " main ", haikuModel: "h")), "main")
        XCTAssertEqual(ProviderEndpoint.probeModel(for: Profile(model: "  ")), "claude-haiku-4-5")
    }
}
