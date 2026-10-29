import XCTest
@testable import AgentProfilesCore

/// The editor counts as clean when it matches the saved profile. A new,
/// untouched draft is clean too; a typed name or key makes it dirty.
final class DraftChangesTests: XCTestCase {
    private func hasChanges(
        draft: Profile,
        command: CommandNameDraft,
        saved: Profile?,
        key: String = ""
    ) -> Bool {
        DraftChanges.hasChanges(draft: draft, command: command, saved: saved, typedKey: key)
    }

    func testNewBlankDraftIsClean() {
        let draft = DraftChanges.blankProfile
        XCTAssertFalse(hasChanges(draft: draft, command: CommandNameDraft(), saved: nil))
    }

    func testTypedNameMakesNewDraftDirty() {
        var command = CommandNameDraft()
        var draft = DraftChanges.blankProfile
        command.setName("Work")
        draft.name = "Work"
        draft.slug = command.slug
        XCTAssertTrue(hasChanges(draft: draft, command: command, saved: nil))
    }

    func testTypedCommandOnlyMakesNewDraftDirty() {
        var command = CommandNameDraft()
        command.setInput("my-cmd")
        var draft = DraftChanges.blankProfile
        draft.slug = command.slug
        XCTAssertTrue(hasChanges(draft: draft, command: command, saved: nil))
    }

    func testTypedKeyMakesNewDraftDirty() {
        XCTAssertTrue(hasChanges(
            draft: DraftChanges.blankProfile,
            command: CommandNameDraft(),
            saved: nil,
            key: "sk-test"
        ))
    }

    func testWhitespaceOnlyKeyIsClean() {
        XCTAssertFalse(hasChanges(
            draft: DraftChanges.blankProfile,
            command: CommandNameDraft(),
            saved: nil,
            key: "  \n "
        ))
    }

    func testUnchangedSavedProfileIsClean() {
        let saved = Profile.sample(name: "Test", slug: "test")
        XCTAssertFalse(hasChanges(draft: saved, command: CommandNameDraft(profile: saved), saved: saved))
    }

    func testEditedSavedProfileIsDirty() {
        let saved = Profile.sample(name: "Test", slug: "test")
        var draft = saved
        draft.model = "other-model"
        XCTAssertTrue(hasChanges(draft: draft, command: CommandNameDraft(profile: saved), saved: saved))
    }

    func testChangedCommandOfSavedProfileIsDirty() {
        let saved = Profile.sample(name: "Test", slug: "test")
        var command = CommandNameDraft(profile: saved)
        command.setInput("renamed")
        var draft = saved
        draft.slug = command.slug
        XCTAssertTrue(hasChanges(draft: draft, command: command, saved: saved))
    }

    func testTypedKeyOnSavedProfileIsDirty() {
        let saved = Profile.sample(name: "Test", slug: "test")
        XCTAssertTrue(hasChanges(
            draft: saved,
            command: CommandNameDraft(profile: saved),
            saved: saved,
            key: "sk-test"
        ))
    }

    func testRevertingToSavedValuesIsClean() {
        let saved = Profile.sample(name: "Test", slug: "test")
        var command = CommandNameDraft(profile: saved)
        var draft = saved

        draft.model = "changed"
        command.setName("Changed")
        draft.name = "Changed"
        draft.slug = command.slug
        XCTAssertTrue(hasChanges(draft: draft, command: command, saved: saved))

        draft = saved
        command = CommandNameDraft(profile: saved)
        XCTAssertFalse(hasChanges(draft: draft, command: command, saved: saved))
    }
}
