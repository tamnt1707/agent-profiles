import XCTest
@testable import ClaudeProfilesCore

/// A reload must never replace an unsaved draft silently. A file that is still
/// broken changes nothing in the editor.
final class ReloadPolicyTests: XCTestCase {
    /// A dirty draft with the file still broken: the draft is kept and nothing is asked.
    func testDirtyDraftWithAStillBrokenFileIsKept() {
        XCTAssertEqual(
            ReloadPolicy.decide(stillBroken: true, hasUnsavedChanges: true),
            .keepEditor
        )
    }

    /// A dirty draft and a file that reads now: the user is asked before the draft is replaced.
    func testDirtyDraftWithAFixedFileNeedsConfirmation() {
        XCTAssertEqual(
            ReloadPolicy.decide(stillBroken: false, hasUnsavedChanges: true),
            .askFirst
        )
    }

    /// A clean editor and a file that reads now: the profiles are loaded.
    func testCleanEditorWithAFixedFileLoads() {
        XCTAssertEqual(
            ReloadPolicy.decide(stillBroken: false, hasUnsavedChanges: false),
            .loadNow
        )
    }

    /// A clean editor and a file that is still broken: only the warning is refreshed.
    func testCleanEditorWithAStillBrokenFileKeepsTheEditor() {
        XCTAssertEqual(
            ReloadPolicy.decide(stillBroken: true, hasUnsavedChanges: false),
            .keepEditor
        )
    }
}
