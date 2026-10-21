import XCTest
@testable import ClaudeProfilesCore

final class ShellQuoteTests: XCTestCase {
    func testQuoting() {
        XCTAssertEqual(ShellQuote.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(ShellQuote.quote("a b"), "'a b'")
        XCTAssertEqual(ShellQuote.quote("$HOME"), "'$HOME'")
    }

    func testQuotingMatchesTheRustReference() throws {
        let reference = try Fixtures.text("rust-shquote", extension: "txt")
        XCTAssertEqual(ShellQuote.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(ShellQuote.quote("back\\slash"), #"'back\slash'"#)
        XCTAssertFalse(reference.isEmpty)
    }

    func testValidEnvNames() {
        XCTAssertTrue(ShellQuote.isValidEnvName("FOO"))
        XCTAssertTrue(ShellQuote.isValidEnvName("_foo1"))
        XCTAssertFalse(ShellQuote.isValidEnvName("1BAD"))
        XCTAssertFalse(ShellQuote.isValidEnvName(""))
        XCTAssertFalse(ShellQuote.isValidEnvName("A-B"))
        XCTAssertFalse(ShellQuote.isValidEnvName("A B"))
    }

    func testParseExtraEnv() throws {
        let parsed = try ShellQuote.parseExtraEnv("API_TIMEOUT_MS=600000")
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].key, "API_TIMEOUT_MS")
        XCTAssertEqual(parsed[0].value, "600000")
    }

    func testParseExtraEnvSkipsCommentsAndBlankLines() throws {
        let parsed = try ShellQuote.parseExtraEnv("# comment\nexport FOO=bar\n\nBAR=baz")
        XCTAssertEqual(parsed.map(\.key), ["FOO", "BAR"])
        XCTAssertEqual(parsed.map(\.value), ["bar", "baz"])
    }

    func testParseExtraEnvStripsOneLayerOfQuotes() throws {
        let parsed = try ShellQuote.parseExtraEnv("A = ' spaced '")
        XCTAssertEqual(parsed[0].value, " spaced ")

        let quoted = try ShellQuote.parseExtraEnv("B=\"quoted\"")
        XCTAssertEqual(quoted[0].value, "quoted")

        let mixed = try ShellQuote.parseExtraEnv("C=\"mix'")
        XCTAssertEqual(mixed[0].value, "mix")

        let empty = try ShellQuote.parseExtraEnv("D=")
        XCTAssertEqual(empty[0].value, "")
    }

    func testParseExtraEnvRejectsBadInput() {
        XCTAssertThrowsError(try ShellQuote.parseExtraEnv("1BAD=x")) { error in
            guard case ProfileError.invalidEnvName(let line, let name) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(line, 1)
            XCTAssertEqual(name, "1BAD")
        }

        XCTAssertThrowsError(try ShellQuote.parseExtraEnv("NOEQUALS")) { error in
            guard case ProfileError.envMissingEquals(let line, let text) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(line, 1)
            XCTAssertEqual(text, "NOEQUALS")
        }

        XCTAssertThrowsError(try ShellQuote.parseExtraEnv("=novalue")) { error in
            guard case ProfileError.invalidEnvName(let line, let name) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(line, 1)
            XCTAssertEqual(name, "")
        }
    }

    func testParseExtraEnvReportsTheLineNumber() {
        XCTAssertThrowsError(try ShellQuote.parseExtraEnv("A=1\nB=2\nBAD LINE\n")) { error in
            guard case ProfileError.envMissingEquals(let line, _) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(line, 3)
        }
    }
}
