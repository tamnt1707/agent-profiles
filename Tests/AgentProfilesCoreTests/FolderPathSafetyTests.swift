import XCTest
@testable import AgentProfilesCore

/// The rule that decides whether a folder path may be typed into a terminal.
final class FolderPathSafetyTests: XCTestCase {
    /// Every C0 control character, from NUL to the unit separator.
    func testEveryC0ControlCharacterIsRefused() {
        for value in 0x00...0x1F {
            let scalar = Unicode.Scalar(value)!
            XCTAssertFalse(FolderPathSafety.isSafe("/tmp/a\(scalar)b"),
                           "U+\(String(value, radix: 16, uppercase: true)) was accepted")
            XCTAssertTrue(FolderPathSafety.isControl(scalar))
        }
    }

    /// The delete key.
    func testTheDeleteCharacterIsRefused() {
        XCTAssertFalse(FolderPathSafety.isSafe("/tmp/a\u{7F}b"))
        XCTAssertTrue(FolderPathSafety.isControl("\u{7F}"))
    }

    /// The C1 controls, from PAD to the application programming command.
    func testEveryC1ControlCharacterIsRefused() {
        for value in 0x80...0x9F {
            let scalar = Unicode.Scalar(value)!
            XCTAssertFalse(FolderPathSafety.isSafe("/tmp/a\(scalar)b"),
                           "U+\(String(value, radix: 16, uppercase: true)) was accepted")
            XCTAssertTrue(FolderPathSafety.isControl(scalar))
        }
    }

    /// The line separator and the paragraph separator end a line for every tool
    /// that reads lines.
    func testTheLineAndParagraphSeparatorAreRefused() {
        XCTAssertFalse(FolderPathSafety.isSafe("/tmp/a\u{2028}b"))
        XCTAssertFalse(FolderPathSafety.isSafe("/tmp/a\u{2029}b"))
        XCTAssertTrue(FolderPathSafety.isControl("\u{2028}"))
        XCTAssertTrue(FolderPathSafety.isControl("\u{2029}"))
    }

    /// A newline and a carriage return are the everyday case.
    func testANewlineAndACarriageReturnAreRefused() {
        XCTAssertFalse(FolderPathSafety.isSafe("/tmp/a\nb"))
        XCTAssertFalse(FolderPathSafety.isSafe("/tmp/a\rb"))
        XCTAssertFalse(FolderPathSafety.isSafe("/tmp/a\r\nb"))
    }

    /// The character of the reproduced attack: Ctrl-U clears the line, so what
    /// follows is run.
    func testTheCtrlUOfTheReproducedAttackIsRefused() {
        XCTAssertFalse(FolderPathSafety.isSafe("/tmp/\u{15}rm -rf ~ #"))
    }

    /// A normal folder name holds no control character.
    func testNormalFolderNamesAreAccepted() {
        XCTAssertTrue(FolderPathSafety.isSafe("/tmp/work"))
        XCTAssertTrue(FolderPathSafety.isSafe("/tmp/My Projects/app"))
        XCTAssertTrue(FolderPathSafety.isSafe("/Users/me/Việt Nam"))
        XCTAssertTrue(FolderPathSafety.isSafe("/Users/me/thư mục tiếng Việt"))
        XCTAssertTrue(FolderPathSafety.isSafe("/Users/me/🚀 rocket"))
        XCTAssertTrue(FolderPathSafety.isSafe("/Users/me/日本語"))
        XCTAssertTrue(FolderPathSafety.isSafe(""))
    }

    /// A tab is a control character too.
    func testATabIsRefused() {
        XCTAssertFalse(FolderPathSafety.isSafe("/tmp/a\tb"))
    }

    /// The first control character of the path is named, so a message can say
    /// what was found.
    func testTheFirstUnsafeScalarIsFound() {
        XCTAssertEqual(FolderPathSafety.firstUnsafeScalar(in: "/tmp/a\u{1}b"), "\u{1}")
        XCTAssertEqual(FolderPathSafety.firstUnsafeScalar(in: "/tmp/a\u{2028}b"), "\u{2028}")
        XCTAssertNil(FolderPathSafety.firstUnsafeScalar(in: "/tmp/normal"))
    }

    /// The other characters are not control characters.
    func testOtherSpecialCharactersAreAccepted() {
        XCTAssertTrue(FolderPathSafety.isSafe("/tmp/a'b\"c\\d"))
        XCTAssertTrue(FolderPathSafety.isSafe("/tmp/a$b`c"))
        XCTAssertTrue(FolderPathSafety.isSafe("/tmp/100%"))
        XCTAssertTrue(FolderPathSafety.isSafe("/tmp/naïve—dash"))
    }

    // MARK: - The path as it is shown

    /// The control characters of a path are written as their names, so that the
    /// message cannot act on the terminal that shows it.
    func testTheVisiblePathWritesTheControlCharactersOut() {
        XCTAssertEqual(FolderPathSafety.visible("/tmp/a\tb"), #"/tmp/a\tb"#)
        XCTAssertEqual(FolderPathSafety.visible("/tmp/a\nb"), #"/tmp/a\nb"#)
        XCTAssertEqual(FolderPathSafety.visible("/tmp/a\rb"), #"/tmp/a\rb"#)
        XCTAssertEqual(FolderPathSafety.visible("/tmp/a\u{1B}b"), #"/tmp/a\u{1B}b"#)
        XCTAssertEqual(FolderPathSafety.visible("/tmp/a\u{2028}b"), #"/tmp/a\u{2028}b"#)
    }

    /// A path without a control character is shown as it is.
    func testTheVisiblePathOfANormalPathIsThePath() {
        XCTAssertEqual(FolderPathSafety.visible("/tmp/plain"), "/tmp/plain")
        XCTAssertEqual(FolderPathSafety.visible("/Users/me/Việt Nam"), "/Users/me/Việt Nam")
    }

    /// A long path is cut in the middle, so that the line stays one line.
    func testTheVisiblePathIsCutInTheMiddle() {
        let long = "/" + String(repeating: "x", count: 200)
        let visible = FolderPathSafety.visible(long)
        XCTAssertEqual(visible.count, 80)
        XCTAssertTrue(visible.contains("…"))
        XCTAssertTrue(visible.hasPrefix("/"))
        XCTAssertTrue(visible.hasSuffix("x"))
    }

    /// A path of exactly the limit is not cut.
    func testAPathOfTheLimitIsNotCut() {
        let exact = String(repeating: "x", count: 80)
        XCTAssertEqual(FolderPathSafety.visible(exact), exact)
    }
}
