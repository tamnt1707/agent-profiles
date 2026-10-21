import XCTest
@testable import ClaudeProfilesCore

final class SemVerTests: XCTestCase {
    func testParsesPlainVersions() throws {
        let version = try XCTUnwrap(SemVer(text: "1.2.3"))
        XCTAssertEqual(version.major, 1)
        XCTAssertEqual(version.minor, 2)
        XCTAssertEqual(version.patch, 3)
        XCTAssertTrue(version.prerelease.isEmpty)
        XCTAssertFalse(version.isPrerelease)
        XCTAssertEqual(version.description, "1.2.3")
    }

    func testParsesTheVPrefix() throws {
        let version = try XCTUnwrap(SemVer(text: "v1.2.3"))
        XCTAssertEqual(version.description, "1.2.3")
        XCTAssertEqual(SemVer(text: "V0.1.0")?.description, "0.1.0")
    }

    func testTrimsSpaces() {
        XCTAssertEqual(SemVer(text: "  1.2.3  ")?.description, "1.2.3")
    }

    func testRejectsGarbage() {
        let broken = [
            "",
            "   ",
            "latest",
            "nightly",
            "1",
            "1.2",
            "1.2.3.4",
            "v",
            "1.2.x",
            "1..3",
            "1.2.",
            ".1.2",
            "-1.2.3",
            "1.2.3-",
            "1.2.3-a..b",
            "1.2.3 beta",
            "01.2.3",
            "1.02.3",
        ]
        for text in broken {
            XCTAssertNil(SemVer(text: text), "\"\(text)\" must not be a version")
        }
    }

    func testParsesThePrereleaseSuffix() throws {
        let version = try XCTUnwrap(SemVer(text: "1.2.3-beta.1"))
        XCTAssertEqual(version.prerelease, ["beta", "1"])
        XCTAssertTrue(version.isPrerelease)
        XCTAssertEqual(version.description, "1.2.3-beta.1")
    }

    func testIgnoresTheBuildMetadata() throws {
        let version = try XCTUnwrap(SemVer(text: "1.2.3+build.7"))
        XCTAssertEqual(version.description, "1.2.3")
    }

    func testComparesTheNumbers() {
        XCTAssertLessThan(SemVer(major: 1, minor: 0, patch: 0), SemVer(major: 2, minor: 0, patch: 0))
        XCTAssertLessThan(SemVer(major: 1, minor: 2, patch: 0), SemVer(major: 1, minor: 3, patch: 0))
        XCTAssertLessThan(SemVer(major: 1, minor: 2, patch: 3), SemVer(major: 1, minor: 2, patch: 4))
        XCTAssertGreaterThan(SemVer(major: 2, minor: 0, patch: 0), SemVer(major: 1, minor: 9, patch: 9))
    }

    func testThePrereleaseIsOlderThanTheRelease() throws {
        let beta = try XCTUnwrap(SemVer(text: "1.2.3-beta"))
        let release = try XCTUnwrap(SemVer(text: "1.2.3"))
        XCTAssertLessThan(beta, release)
        XCTAssertGreaterThan(release, beta)
    }

    func testThePrereleasesAreOrdered() throws {
        let alpha = try XCTUnwrap(SemVer(text: "1.0.0-alpha"))
        let beta = try XCTUnwrap(SemVer(text: "1.0.0-beta"))
        let rc = try XCTUnwrap(SemVer(text: "1.0.0-rc"))
        XCTAssertLessThan(alpha, beta)
        XCTAssertLessThan(beta, rc)
        XCTAssertLessThan(rc, try XCTUnwrap(SemVer(text: "1.0.0")))
    }

    func testTheNumericIdentifiersAreSmaller() throws {
        let one = try XCTUnwrap(SemVer(text: "1.0.0-1"))
        let two = try XCTUnwrap(SemVer(text: "1.0.0-2"))
        let word = try XCTUnwrap(SemVer(text: "1.0.0-alpha"))
        XCTAssertLessThan(one, two)
        XCTAssertLessThan(one, word)
    }

    func testMoreIdentifiersAreNewer() throws {
        let short = try XCTUnwrap(SemVer(text: "1.0.0-alpha"))
        let long = try XCTUnwrap(SemVer(text: "1.0.0-alpha.1"))
        XCTAssertLessThan(short, long)
    }

    func testTheSameVersionIsEqual() throws {
        let first = try XCTUnwrap(SemVer(text: "v1.2.3"))
        let second = try XCTUnwrap(SemVer(text: "1.2.3"))
        XCTAssertEqual(first, second)
        XCTAssertFalse(first < second)
        XCTAssertFalse(second < first)
    }
}
