import XCTest
@testable import ClaudeProfilesCore

/// The keys of the profiles are read again when the app becomes active.
///
/// The app can be used without its window: the menu bar is enough. The model
/// therefore watches the notification itself, and the window does not watch it
/// a second time.
final class AppActivationTests: XCTestCase {
    /// The source of a file of the app.
    private func source(_ path: String) -> String {
        PackageLayout.text(of: PackageLayout.url(path))
    }

    // MARK: - The model

    /// The model watches the app becoming active.
    func testTheModelWatchesTheAppBecomingActive() {
        let source = source("Sources/ClaudeProfiles/AppModel.swift")

        XCTAssertTrue(
            source.contains("NSApplication.didBecomeActiveNotification"),
            "the model does not watch the app becoming active"
        )
        XCTAssertTrue(
            source.contains("NotificationCenter.default.addObserver"),
            "the model does not add the observer"
        )
    }

    /// The observer is added when the model is made and removed when it goes
    /// away, so it does not keep the model alive.
    func testTheObserverIsAddedAndRemovedWithTheModel() {
        let source = source("Sources/ClaudeProfiles/AppModel.swift")

        let initializer = source.range(of: "init(store: Store")
        let deinitializer = source.range(of: "deinit {")
        let add = source.range(of: "NotificationCenter.default.addObserver")
        let remove = source.range(of: "NotificationCenter.default.removeObserver")
        XCTAssertNotNil(initializer)
        XCTAssertNotNil(deinitializer)
        XCTAssertNotNil(add)
        XCTAssertNotNil(remove)
        // The observer is added in the initializer of the model.
        XCTAssertTrue(initializer!.upperBound < add!.lowerBound, "the observer is not added by the initializer")
        // And it is removed in its deinit.
        XCTAssertTrue(deinitializer!.lowerBound < remove!.lowerBound, "the observer is not removed by the deinit")
    }

    /// The keys are read again when the app becomes active: no request is sent.
    func testTheKeysAreReadAgainWhenTheAppBecomesActive() {
        let source = source("Sources/ClaudeProfiles/AppModel.swift")

        let observer = source.range(of: "NSApplication.didBecomeActiveNotification")!
        // The body of the observer reads the keys again.
        let body = source[observer.upperBound...]
        XCTAssertTrue(
            body.prefix(600).contains("refreshStoredKeys()"),
            "the observer does not read the keys again"
        )
    }

    // MARK: - The window

    /// The window does not watch the notification any more: the model does it
    /// once, so the keys are read again even without the window.
    func testTheWindowDoesNotWatchTheAppBecomingActive() {
        let source = source("Sources/ClaudeProfiles/ContentView.swift")

        XCTAssertFalse(
            source.contains("didBecomeActiveNotification"),
            "the window still watches the app becoming active"
        )
        XCTAssertFalse(
            source.contains("refreshStoredKeys"),
            "the window still reads the keys itself"
        )
    }

    // MARK: - The menu

    /// The menu reads the keys again every time it opens, so a key that was
    /// added outside of the app is seen.
    func testTheMenuReadsTheKeysWhenItOpens() {
        let source = source("Sources/ClaudeProfiles/AppModel.swift")

        let prepare = source.range(of: "func prepareMenuBar()")
        XCTAssertNotNil(prepare, "the menu does not prepare anything")
        guard let prepare else { return }
        let body = source[prepare.upperBound...].prefix(400)
        XCTAssertTrue(
            body.contains("refreshStoredKeys()"),
            "the menu does not read the keys when it opens"
        )
    }
}
