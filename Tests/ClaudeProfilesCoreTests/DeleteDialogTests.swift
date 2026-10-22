import XCTest
@testable import ClaudeProfilesCore

/// The delete confirmation must not ask the file system while it is drawn.
///
/// The size of the config folder is measured away from the main thread, so
/// the answer can come back late. The state decides whether a late answer
/// still belongs to the question that is open: an answer of another profile
/// or of a question that was closed must not change the text under the
/// cursor.
final class DeleteDialogTests: XCTestCase {
    private var temp: TempDirectory!
    private var paths: Paths!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        paths = temp.paths()
    }

    override func tearDown() {
        temp = nil
        paths = nil
    }

    /// The items of a question about the profile "work".
    private func items() -> [DeleteTarget.Item] {
        let data = AppData(profiles: [Profile.sample(name: "Work", slug: "work")])
        let target = DeleteTarget(index: 0, in: data, paths: paths, measure: { _ in nil })
        return target?.items ?? []
    }

    /// The answer of a measurement that was made for the open question.
    func testTheAnswerOfTheOpenQuestionIsUsed() {
        var state = DeleteDialogState()
        let token = state.begin(slug: "work", items: items())

        XCTAssertTrue(state.apply(bytes: 4096, for: token))

        guard case .folder(_, let bytes)? = state.items.last else {
            return XCTFail("the last item is the folder")
        }
        XCTAssertEqual(bytes, 4096)
    }

    /// The answer of a measurement that was made for another profile.
    func testALateAnswerForAnotherProfileIsIgnored() {
        var state = DeleteDialogState()
        let old = state.begin(slug: "work", items: items())
        // Another question is open now.
        state.begin(slug: "play", items: items())

        XCTAssertFalse(state.apply(bytes: 4096, for: old))
        XCTAssertFalse(state.accepts(old))

        guard case .folder(_, let bytes)? = state.items.last else {
            return XCTFail("the last item is the folder")
        }
        XCTAssertNil(bytes, "the size of the other profile is shown")
    }

    /// The answer of a measurement that comes after the question was closed.
    func testAnAnswerAfterCancelIsIgnored() {
        var state = DeleteDialogState()
        let token = state.begin(slug: "work", items: items())
        state.cancel()

        XCTAssertFalse(state.apply(bytes: 4096, for: token))
        XCTAssertFalse(state.accepts(token))
        XCTAssertFalse(state.isOpen)
        XCTAssertTrue(state.items.isEmpty)
    }

    /// The answer of a measurement that was made before the question was
    /// closed and a new one was opened.
    func testAnAnswerOfAnOlderQuestionIsIgnored() {
        var state = DeleteDialogState()
        let old = state.begin(slug: "work", items: items())
        state.cancel()
        state.begin(slug: "work", items: items())

        XCTAssertFalse(state.apply(bytes: 4096, for: old))
        XCTAssertFalse(state.accepts(old))
    }

    /// A folder whose size is not known is written without one.
    func testAFolderWithoutASizeIsWrittenWithoutOne() throws {
        let data = AppData(profiles: [Profile.sample(name: "Work", slug: "work")])
        let target = DeleteTarget(index: 0, in: data, paths: paths, measure: { _ in nil })
        let folder = try XCTUnwrap(target?.items.last)

        XCTAssertEqual(folder, .folder(path: paths.home(for: "work").path, bytes: nil))

        let text = DeleteDialogText.itemText(folder, strings: .english)
        XCTAssertEqual(text, "the folder \(paths.home(for: "work").path) (sessions and history)")
        XCTAssertFalse(text.contains("KB"), "the line shows a size that is not known")
        XCTAssertFalse(text.contains("bytes"), "the line shows a size that is not known")
    }

    /// A folder whose size is known is written with it.
    func testAFolderWithASizeIsWrittenWithIt() throws {
        let data = AppData(profiles: [Profile.sample(name: "Work", slug: "work")])
        let target = DeleteTarget(index: 0, in: data, paths: paths, measure: { _ in nil })
        let folder = try XCTUnwrap(target?.items.last)

        let text = DeleteDialogText.itemText(
            .folder(path: paths.home(for: "work").path, bytes: 2048),
            strings: .english,
            sizeText: { _ in "2 KB" }
        )
        XCTAssertEqual(text, "the folder \(paths.home(for: "work").path) (sessions and history, 2 KB)")
        XCTAssertNotEqual(text, DeleteDialogText.itemText(folder, strings: .english))
    }

    /// The message names the profile, lists everything that goes away and
    /// ends with the warning.
    func testTheMessageNamesEverythingThatGoesAway() throws {
        let data = AppData(profiles: [Profile.sample(name: "Work", slug: "work")])
        let target = DeleteTarget(index: 0, in: data, paths: paths, measure: { _ in nil })
        let items = try XCTUnwrap(target?.items)

        let message = DeleteDialogText.message(name: "Work", items: items, strings: .english)

        XCTAssertTrue(message.hasPrefix("Delete \"Work\"?"))
        XCTAssertTrue(message.contains("• the API key in the Keychain"))
        XCTAssertTrue(message.contains("• the command claude-work"))
        XCTAssertTrue(message.contains("• the folder \(paths.home(for: "work").path)"))
        XCTAssertTrue(message.hasSuffix("This cannot be undone."))
    }

    /// The sentences of the core are the ones of the app: the English copy
    /// must not drift away from the shipped string table.
    func testTheEnglishSentencesAreTheOnesOfTheApp() throws {
        let table = try PackageLayout.stringTable("en")

        XCTAssertEqual(DeleteDialogStrings.english.introTemplate, table["delete.dialog.intro"])
        XCTAssertEqual(DeleteDialogStrings.english.warning, table["delete.dialog.warning"])
        XCTAssertEqual(DeleteDialogStrings.english.keyText, table["delete.item.key"])
        XCTAssertEqual(DeleteDialogStrings.english.commandTemplate, table["delete.item.command"])
        XCTAssertEqual(DeleteDialogStrings.english.folderTemplate, table["delete.item.folder"])
        XCTAssertEqual(DeleteDialogStrings.english.folderSizeTemplate, table["delete.item.folderSize"])
    }

    /// The Vietnamese copy is the one of the app as well.
    func testTheVietnameseSentencesAreTheOnesOfTheApp() throws {
        let table = try PackageLayout.stringTable("vi")

        XCTAssertEqual(DeleteDialogStrings.vietnamese.introTemplate, table["delete.dialog.intro"])
        XCTAssertEqual(DeleteDialogStrings.vietnamese.warning, table["delete.dialog.warning"])
        XCTAssertEqual(DeleteDialogStrings.vietnamese.keyText, table["delete.item.key"])
        XCTAssertEqual(DeleteDialogStrings.vietnamese.commandTemplate, table["delete.item.command"])
        XCTAssertEqual(DeleteDialogStrings.vietnamese.folderTemplate, table["delete.item.folder"])
        XCTAssertEqual(DeleteDialogStrings.vietnamese.folderSizeTemplate, table["delete.item.folderSize"])
    }
}
