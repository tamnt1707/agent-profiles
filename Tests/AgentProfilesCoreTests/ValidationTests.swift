import XCTest
@testable import AgentProfilesCore

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
            XCTAssertEqual(error as? ProfileError, .duplicateCommand("test", "Test"))
        }
    }

    /// The error names the profile that already uses the command.
    func testTheDuplicateErrorNamesTheOtherProfile() {
        let other = Profile.sample(name: "GLM", slug: "glm")
        let profile = Profile.sample(name: "GLM 4", slug: "glm")
        XCTAssertThrowsError(try store.validate(profile, others: [other])) { error in
            XCTAssertEqual(error as? ProfileError, .duplicateCommand("glm", "GLM"))
        }
    }

    /// Two names that slugify to the same value collide.
    func testTwoNamesWithTheSameSlugCollide() throws {
        XCTAssertEqual(Slug.slugify("GLM"), Slug.slugify("glm "))
        let other = Profile.sample(name: "GLM", slug: "glm")
        let profile = Profile.sample(name: "glm ", slug: "glm")
        XCTAssertThrowsError(try store.validate(profile, others: [other])) { error in
            XCTAssertEqual(error as? ProfileError, .duplicateCommand("glm", "GLM"))
        }
    }

    /// A profile is never a duplicate of itself.
    func testEditingAProfileWithoutChangingItsSlugIsNoDuplicate() throws {
        let profile = Profile.sample(name: "Test", slug: "test")
        XCTAssertNoThrow(try store.validate(profile, others: []))
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
