import XCTest
@testable import AgentProfilesCore

/// The menu bar must not keep anything about a profile that is gone.
///
/// A profile that was deleted or renamed leaves nothing behind: the check of
/// its folders is of a profile that does not exist any more, and its answer
/// must not be used for a profile that has the same name later.
final class AppMenuBarStateTests: XCTestCase {
    /// The source of the model of the app.
    private var source: String {
        PackageLayout.text(of: PackageLayout.url("Sources/AgentProfiles/AppModel.swift"))
    }

    /// The text of a function of the model, up to the next one.
    private func body(of function: String) -> String {
        let source = self.source
        guard let start = source.range(of: function) else { return "" }
        let rest = source[start.upperBound...]
        // The function ends where the next one of the file begins.
        let end = rest.range(of: "\n    /// ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// The model forgets the state of the menu bar of a profile that is gone.
    func testTheModelForgetsTheMenuBarStateOfAProfileThatIsGone() {
        let body = self.body(of: "private func forgetMenuBarState(for slug: String)")

        XCTAssertFalse(body.isEmpty, "the model does not forget the state of the menu bar")
        // Everything the menu bar knows about the profile goes away.
        XCTAssertTrue(body.contains("slowFolderChecks[slug] = nil"), "the slow check stays")
        XCTAssertTrue(body.contains("menuBarFolders[slug] = nil"), "the folders stay")
        XCTAssertTrue(body.contains("menuFolderState.forget(slug: slug)"), "the folders of the menu stay")
    }

    /// A deleted profile leaves nothing behind in the menu.
    func testADeletedProfileLeavesNothingBehindInTheMenu() {
        let body = self.body(of: "func deleteCurrent()")

        XCTAssertFalse(body.isEmpty, "the profile is never deleted")
        XCTAssertTrue(
            body.contains("forgetMenuBarState(for: profile.slug)"),
            "the state of the deleted profile stays in the menu"
        )
    }

    /// A renamed profile leaves nothing behind in the menu either.
    func testARenamedProfileLeavesNothingBehindInTheMenu() {
        let body = self.body(of: "func save() -> Bool")

        XCTAssertFalse(body.isEmpty, "the profile is never saved")
        XCTAssertTrue(
            body.contains("forgetMenuBarState(for: previousProfile.slug)"),
            "the state of the old name stays in the menu"
        )
    }
}
