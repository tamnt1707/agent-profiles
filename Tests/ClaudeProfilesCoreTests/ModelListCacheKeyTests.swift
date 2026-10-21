import XCTest
@testable import ClaudeProfilesCore

/// The cached model list is reused only for the same Base URL and auth kind.
final class ModelListCacheKeyTests: XCTestCase {
    func testTrailingSlashesAndSpacesDoNotChangeTheKey() {
        let plain = ModelListCacheKey(baseURL: "https://api.example.com/v1", auth: .bearer)
        XCTAssertEqual(ModelListCacheKey(baseURL: "https://api.example.com/v1/", auth: .bearer), plain)
        XCTAssertEqual(ModelListCacheKey(baseURL: " https://api.example.com/v1//  ", auth: .bearer), plain)
    }

    func testAnotherBaseURLIsAnotherKey() {
        let first = ModelListCacheKey(baseURL: "https://api.example.com", auth: .bearer)
        XCTAssertNotEqual(ModelListCacheKey(baseURL: "https://other.example.com", auth: .bearer), first)
        XCTAssertNotEqual(ModelListCacheKey(baseURL: "https://api.example.com/x", auth: .bearer), first)
    }

    func testAnotherAuthKindIsAnotherKey() {
        let bearer = ModelListCacheKey(baseURL: "https://api.example.com", auth: .bearer)
        XCTAssertNotEqual(ModelListCacheKey(baseURL: "https://api.example.com", auth: .apiKey), bearer)
        XCTAssertNotEqual(ModelListCacheKey(baseURL: "https://api.example.com", auth: .none), bearer)
    }

    func testKeyIsHashableForTheCache() {
        var seen: Set<ModelListCacheKey> = []
        seen.insert(ModelListCacheKey(baseURL: "https://a.example.com/", auth: .apiKey))
        seen.insert(ModelListCacheKey(baseURL: "https://a.example.com", auth: .apiKey))
        XCTAssertEqual(seen.count, 1)
    }
}
