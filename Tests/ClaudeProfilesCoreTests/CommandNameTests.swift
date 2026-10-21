import XCTest
@testable import ClaudeProfilesCore

/// The command name of a profile: it follows the name until the user types a
/// name of their own.
final class CommandNameTests: XCTestCase {
    func testANewProfileFollowsTheName() {
        var draft = CommandNameDraft()
        XCTAssertEqual(draft.mode, .auto)
        XCTAssertEqual(draft.slug, "")

        draft.setName("GLM")
        XCTAssertEqual(draft.input, "glm")
        XCTAssertEqual(draft.slug, "glm")
    }

    func testTypingInTheFieldMakesTheCommandCustom() {
        var draft = CommandNameDraft()
        draft.setName("GLM")
        draft.setInput("my-glm")

        XCTAssertEqual(draft.mode, .custom)
        XCTAssertEqual(draft.input, "my-glm")
        XCTAssertEqual(draft.slug, "my-glm")
    }

    /// A custom command does not follow the name anymore.
    func testACustomCommandDoesNotFollowTheName() {
        var draft = CommandNameDraft()
        draft.setName("GLM")
        draft.setInput("my-glm")
        draft.setName("GLM 4")

        XCTAssertEqual(draft.input, "my-glm")
        XCTAssertEqual(draft.slug, "my-glm")
    }

    func testResetToAutoFollowsTheNameAgain() {
        var draft = CommandNameDraft()
        draft.setName("GLM")
        draft.setInput("my-glm")
        draft.resetToAuto()

        XCTAssertEqual(draft.mode, .auto)
        XCTAssertEqual(draft.input, "glm")
        XCTAssertEqual(draft.slug, "glm")
    }

    /// An existing profile whose slug matches its name stays in auto mode.
    func testAnExistingProfileWithAMatchingSlugIsAuto() {
        let draft = CommandNameDraft(profile: Profile.sample(name: "Test", slug: "test"))
        XCTAssertEqual(draft.mode, .auto)
        XCTAssertEqual(draft.input, "test")
        XCTAssertEqual(draft.slug, "test")
    }

    /// An existing profile with a slug of its own is custom.
    func testAnExistingProfileWithADifferentSlugIsCustom() {
        let draft = CommandNameDraft(profile: Profile.sample(name: "Test", slug: "my-test"))
        XCTAssertEqual(draft.mode, .custom)
        XCTAssertEqual(draft.input, "my-test")
        XCTAssertEqual(draft.slug, "my-test")
    }

    /// A typed slug is stored normalized.
    func testATypedSlugIsNormalized() {
        let draft = CommandNameDraft(name: "Anything", input: " My Cmd! ", mode: .custom)
        XCTAssertEqual(draft.slug, "my-cmd")
        XCTAssertEqual(draft.normalizedInput, "my-cmd")
        XCTAssertTrue(draft.hasNormalizedPreview)
    }

    /// A value that normalizes to nothing falls back to the name.
    func testAnEmptySlugFallsBackToTheName() {
        let draft = CommandNameDraft(name: "GLM", input: "   ", mode: .custom)
        XCTAssertEqual(draft.slug, "glm")
        XCTAssertFalse(draft.hasNormalizedPreview)
    }

    /// When the name is empty too, the profile has no command at all.
    func testAnEmptyNameAndAnEmptySlugStayEmpty() {
        let draft = CommandNameDraft(name: "   ", input: "!!!", mode: .custom)
        XCTAssertEqual(draft.slug, "")
    }

    /// A slug that is already normal shows no preview.
    func testANormalSlugShowsNoPreview() {
        let draft = CommandNameDraft(name: "Test", input: "test", mode: .custom)
        XCTAssertFalse(draft.hasNormalizedPreview)
    }

    /// The profile that already uses the command is found.
    func testTheDuplicateOwnerIsFound() {
        let draft = CommandNameDraft(name: "GLM 4", input: "glm", mode: .custom)
        let other = Profile.sample(name: "GLM", slug: "glm")
        XCTAssertEqual(draft.duplicateOwner(among: [other])?.name, "GLM")
        XCTAssertNil(draft.duplicateOwner(among: []))
    }

    /// Two names that slugify to the same value use the same command.
    func testTwoNamesWithTheSameSlugUseTheSameCommand() {
        XCTAssertEqual(Slug.slugify("GLM"), "glm")
        XCTAssertEqual(Slug.slugify("glm "), "glm")
        XCTAssertEqual(CommandNameDraft(name: "GLM").slug, CommandNameDraft(name: "glm ").slug)
    }

    /// A Vietnamese name is folded to ASCII.
    func testAVietnameseNameIsFolded() {
        var draft = CommandNameDraft()
        draft.setName("GLM Đẹp Trai!")
        XCTAssertEqual(draft.slug, "glm-dep-trai")
    }
}
