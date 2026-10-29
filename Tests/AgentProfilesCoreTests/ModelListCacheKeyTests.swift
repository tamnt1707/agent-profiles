import XCTest
@testable import AgentProfilesCore

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

final class ModelListCacheReuseTests: XCTestCase {
    private let key = ModelListCacheKey(baseURL: "https://api.example.com", auth: .bearer)

    func testAWorkingListIsReusedForTheSameProvider() {
        let cache = ModelListCache(key: key, report: ModelListReport(outcome: .ok(latencyMs: 5, model: nil), models: ["a"]))
        XCTAssertTrue(cache.isReusable(for: ModelListCacheKey(baseURL: "https://api.example.com/", auth: .bearer)))
        XCTAssertFalse(cache.isReusable(for: ModelListCacheKey(baseURL: "https://api.example.com", auth: .apiKey)))
    }

    func testAProviderWithoutAListIsReusedButErrorsAreRetried() {
        let unsupported = ModelListCache(key: key, report: ModelListReport(outcome: .unsupported))
        XCTAssertTrue(unsupported.isReusable(for: key))

        let timeout = ModelListCache(key: key, report: ModelListReport(outcome: .timeout))
        XCTAssertFalse(timeout.isReusable(for: key))
        let missingKey = ModelListCache(key: key, report: ModelListReport(outcome: .missingKey))
        XCTAssertFalse(missingKey.isReusable(for: key))
    }
}
