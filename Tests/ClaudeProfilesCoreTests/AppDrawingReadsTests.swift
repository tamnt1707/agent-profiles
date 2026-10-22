import XCTest
@testable import ClaudeProfilesCore

/// The window must not ask the file system while it is drawn.
///
/// SwiftUI builds the message of an alert on every pass of the view that
/// owns it, even when the alert is hidden. A message that walks a folder
/// there blocks the app until the walk is over, so the answers that the
/// window shows are values that are read when something changes.
final class AppDrawingReadsTests: XCTestCase {
    /// The source of the model of the app.
    private var model: String {
        PackageLayout.text(of: PackageLayout.url("Sources/ClaudeProfiles/AppModel.swift"))
    }

    /// The source of the editor of the app.
    private var editor: String {
        PackageLayout.text(of: PackageLayout.url("Sources/ClaudeProfiles/ProfileEditorView.swift"))
    }

    /// The source of the main window of the app.
    private var content: String {
        PackageLayout.text(of: PackageLayout.url("Sources/ClaudeProfiles/ContentView.swift"))
    }

    /// The text of a part of the model, up to the next one.
    private func body(of part: String) -> String {
        let source = self.model
        guard let start = source.range(of: part) else { return "" }
        let rest = source[start.upperBound...]
        // The part ends where the next one of the file begins.
        let end = rest.range(of: "\n    /// ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    /// The text of the delete confirmation is a value that is read when the
    /// question is asked, not something that is built while drawing.
    func testTheTextOfTheConfirmationIsAStoredValue() {
        XCTAssertTrue(
            model.contains("private(set) var deleteDialogText: String = \"\""),
            "the text of the confirmation is not a stored value"
        )
        XCTAssertFalse(
            model.contains("deleteDialogMessage"),
            "the confirmation still builds its text while it is drawn"
        )
        XCTAssertTrue(
            editor.contains("Text(verbatim: model.deleteDialogText)"),
            "the window does not show the stored text"
        )
        XCTAssertFalse(
            editor.contains("deleteDialogMessage"),
            "the window still asks for the text of the confirmation"
        )
    }

    /// The size of the config folder is measured away from the main thread.
    func testTheFolderIsMeasuredAwayFromTheMainThread() {
        let request = body(of: "func requestDelete()")
        XCTAssertFalse(request.isEmpty, "the confirmation is never asked for")
        XCTAssertFalse(
            request.contains("DirectorySize.measure"),
            "the folder is measured on the main thread"
        )
        XCTAssertTrue(
            request.contains("measureFolderSize(for: token)"),
            "the folder is never measured"
        )

        let measure = body(of: "func measureFolderSize(for token:")
        XCTAssertFalse(measure.isEmpty, "the folder is never measured")
        XCTAssertTrue(measure.contains("Task.detached"), "the folder is measured on the main thread")
        XCTAssertTrue(measure.contains("DirectorySize.measure"), "the folder is never measured")
    }

    /// A late answer must not change the text of the question.
    func testALateAnswerDoesNotChangeTheText() {
        let apply = body(of: "func applyFolderSize(")
        XCTAssertFalse(apply.isEmpty, "the size of the folder is never used")
        XCTAssertTrue(
            apply.contains("guard deleteDialog.apply(bytes: bytes, for: token) else { return }"),
            "a late answer changes the text of the question"
        )
    }

    /// The files of the shells are read when the state of the shells is read,
    /// not while the question about them is drawn.
    func testTheFilesOfTheShellsAreNotReadWhileDrawing() {
        XCTAssertTrue(
            model.contains("private(set) var pathFilesText: String = \"\""),
            "the files of the shells are not a stored value"
        )
        XCTAssertFalse(
            model.contains("var pathFilesText: String {"),
            "the files of the shells are still read while the window is drawn"
        )
        XCTAssertTrue(
            content.contains("model.pathFilesText"),
            "the question does not name the files of the shells"
        )
    }

    /// The name of the command is looked up when it changes, not while the
    /// editor is drawn.
    func testTheNameOfTheCommandIsNotLookedUpWhileDrawing() {
        let issue = body(of: "var commandIssue: ProfileError?")
        XCTAssertFalse(issue.isEmpty, "the problem with the command name is never found")
        XCTAssertFalse(
            issue.contains("store.foreignCommandPath"),
            "the name of the command is still looked up while the window is drawn"
        )
        XCTAssertTrue(
            model.contains("private(set) var foreignCommandPath: String?"),
            "the answer about the name of the command is not kept"
        )
    }
}
