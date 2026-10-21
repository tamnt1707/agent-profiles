import XCTest
@testable import ClaudeProfilesCore

final class ValidationTests: XCTestCase {
    private var temp: TempDirectory!
    private var store: Store!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        store = Store(paths: temp.paths(), keys: InMemoryKeyStore())
    }

    override func tearDown() {
        temp = nil
        store = nil
    }

    func testValidProfilePasses() throws {
        XCTAssertNoThrow(try store.validate(Profile.sample(), others: []))
    }

    func testNameIsRequired() {
        var profile = Profile.sample()
        profile.name = "   "
        XCTAssertThrowsError(try store.validate(profile, others: [])) { error in
            XCTAssertEqual(error as? ProfileError, .emptyName)
        }
    }

    func testSlugMustNotBeEmpty() {
        var profile = Profile.sample()
        profile.slug = ""
        XCTAssertThrowsError(try store.validate(profile, others: [])) { error in
            XCTAssertEqual(error as? ProfileError, .emptySlug)
        }
    }

    func testSlugMustBeUnique() {
        let other = Profile.sample(slug: "test")
        XCTAssertThrowsError(try store.validate(Profile.sample(), others: [other])) { error in
            XCTAssertEqual(error as? ProfileError, .duplicateSlug("test"))
        }
    }

    func testBaseUrlMustBeHttp() {
        var profile = Profile.sample()
        profile.baseURL = "ftp://example.com"
        XCTAssertThrowsError(try store.validate(profile, others: [])) { error in
            XCTAssertEqual(error as? ProfileError, .invalidBaseURL)
        }

        profile.baseURL = "https://example.com"
        XCTAssertNoThrow(try store.validate(profile, others: []))

        profile.baseURL = "http://localhost:4000"
        XCTAssertNoThrow(try store.validate(profile, others: []))

        profile.baseURL = ""
        XCTAssertNoThrow(try store.validate(profile, others: []))
    }

    func testExtraEnvMustParse() {
        var profile = Profile.sample()
        profile.extraEnv = "NOT VALID"
        XCTAssertThrowsError(try store.validate(profile, others: [])) { error in
            guard case ProfileError.envMissingEquals = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }
}
