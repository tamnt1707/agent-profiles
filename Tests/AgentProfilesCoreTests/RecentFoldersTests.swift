import XCTest
@testable import AgentProfilesCore

final class RecentFoldersTests: XCTestCase {
    func testEmptyListHasNoFolders() {
        XCTAssertEqual(RecentFolders().paths, [])
        XCTAssertEqual(RecentFolders([]).paths, [])
    }

    func testAddPutsTheFolderFirst() {
        var recent = RecentFolders(["/a", "/b"])
        recent.add("/c")
        XCTAssertEqual(recent.paths, ["/c", "/a", "/b"])
    }

    func testAddingAListedFolderMovesItToTheFront() {
        var recent = RecentFolders(["/a", "/b", "/c"])
        recent.add("/c")
        XCTAssertEqual(recent.paths, ["/c", "/a", "/b"])
    }

    /// Two spellings of one folder are one entry, compared by the standardized path.
    func testDuplicatesAreDetectedByStandardizedPath() {
        var recent = RecentFolders(["/tmp/a"])
        recent.add("/tmp/a/")
        recent.add("/tmp/a/./")
        XCTAssertEqual(recent.paths, ["/tmp/a"])
        recent.add("/tmp/b/../a")
        XCTAssertEqual(recent.paths, ["/tmp/a"])
    }

    func testTheListIsLimitedToFiveNewestFolders() {
        var recent = RecentFolders()
        for index in 1...7 {
            recent.add("/work/\(index)")
        }
        XCTAssertEqual(RecentFolders.limit, 5)
        XCTAssertEqual(recent.paths, ["/work/7", "/work/6", "/work/5", "/work/4", "/work/3"])
    }

    /// A stored list that is too long is cut when it is read, not only when a folder is added.
    func testAStoredListIsCutToTheLimitWhenRead() {
        let recent = RecentFolders(["/1", "/2", "/3", "/4", "/5", "/6", "/7"])
        XCTAssertEqual(recent.paths, ["/1", "/2", "/3", "/4", "/5"])
    }

    func testAStoredListIsDeduplicatedKeepingTheFirstPlace() {
        let recent = RecentFolders(["/a", "/b/", "/a/", "/c"])
        XCTAssertEqual(recent.paths, ["/a", "/b", "/c"])
    }

    /// Only absolute paths are kept. A `~` written by hand is not expanded here, so it is dropped.
    func testRelativeAndEmptyPathsAreDropped() {
        var recent = RecentFolders(["relative", "", "~/work", "/ok"])
        XCTAssertEqual(recent.paths, ["/ok"])
        recent.add("relative/path")
        recent.add("")
        XCTAssertEqual(recent.paths, ["/ok"])
    }

    func testPruneDropsFoldersThatNoLongerExistAndKeepsTheOrder() {
        var recent = RecentFolders(["/keep1", "/gone", "/keep2", "/also-gone"])
        let existing: Set<String> = ["/keep1", "/keep2"]
        recent.prune { existing.contains($0) }
        XCTAssertEqual(recent.paths, ["/keep1", "/keep2"])
    }

    func testPruneOfAnEmptyListStaysEmpty() {
        var recent = RecentFolders()
        recent.prune { _ in false }
        XCTAssertEqual(recent.paths, [])
    }

    func testPruneWhenNothingExistsEmptiesTheList() {
        var recent = RecentFolders(["/a", "/b"])
        recent.prune { _ in false }
        XCTAssertEqual(recent.paths, [])
    }

    func testDisplayPathWritesTheHomeFolderAsTilde() {
        XCTAssertEqual(RecentFolders.displayPath("/Users/me/work", home: "/Users/me"), "~/work")
        XCTAssertEqual(RecentFolders.displayPath("/Users/me", home: "/Users/me"), "~")
    }

    func testDisplayPathDoesNotMatchAFolderThatOnlyStartsWithTheHomeName() {
        XCTAssertEqual(RecentFolders.displayPath("/Users/meow/work", home: "/Users/me"), "/Users/meow/work")
        XCTAssertEqual(RecentFolders.displayPath("/opt/x", home: "/Users/me"), "/opt/x")
    }

    func testDisplayPathNeverRewritesWhenTheHomeIsRoot() {
        XCTAssertEqual(RecentFolders.displayPath("/tmp/x", home: "/"), "/tmp/x")
    }
}
