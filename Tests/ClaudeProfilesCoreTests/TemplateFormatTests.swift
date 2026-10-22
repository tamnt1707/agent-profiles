import XCTest
@testable import ClaudeProfilesCore

/// The safe filling of a sentence with placeholders.
///
/// `String(format:)` reads its arguments through pointers: a whole number
/// that is handed to a `%@` is read as an object pointer, and the app crashes.
/// The helper here fills every placeholder with a value of its own kind.
final class TemplateFormatTests: XCTestCase {
    /// A whole number that reaches a `%@` is written as text and is never read
    /// as a pointer.
    func testANumberThatReachesATextIsWrittenAsText() {
        XCTAssertEqual(TemplateFormat.fill("Read %@ files.", [5]), "Read 5 files.")
    }

    /// A text that reaches a `%d` is read as a number when it can be.
    func testATextThatReachesANumberIsReadAsANumber() {
        XCTAssertEqual(TemplateFormat.fill("%d ms", ["42"]), "42 ms")
    }

    /// The placeholders of a template are found in the order they appear.
    func testThePlaceholdersOfATemplateAreFoundInOrder() {
        XCTAssertEqual(TemplateFormat.placeholders(of: "%d of %d checked"),
                       [.integer, .integer])
        XCTAssertEqual(TemplateFormat.placeholders(of: "Connected, %d ms (model %@)"),
                       [.integer, .object])
        XCTAssertEqual(TemplateFormat.placeholders(of: "No placeholders here"), [])
    }

    /// A template that holds only whole numbers is found.
    func testATemplateWithOnlyWholeNumbersIsFound() {
        XCTAssertTrue(TemplateFormat.hasOnlyIntegerPlaceholders("%d files could not be read."))
        XCTAssertTrue(TemplateFormat.hasOnlyIntegerPlaceholders("no placeholder at all"))
        XCTAssertFalse(TemplateFormat.hasOnlyIntegerPlaceholders("Connected, %d ms (model %@)"))
        XCTAssertFalse(TemplateFormat.hasOnlyIntegerPlaceholders("%@ files could not be read."))
    }

    /// A placeholder without an argument keeps its own text, so the sentence
    /// shows where something is missing.
    func testAPlaceholderWithoutAnArgumentKeepsItsText() {
        XCTAssertEqual(TemplateFormat.fill("%d of %d checked", [3]), "3 of %d checked")
    }

    /// The text between the placeholders is kept.
    func testTheTextBetweenThePlaceholdersIsKept() {
        XCTAssertEqual(TemplateFormat.fill("Input %@ · Output %@", ["1", "2"]),
                       "Input 1 · Output 2")
    }

    /// A percent sign that is not a placeholder is text.
    func testAPercentSignThatIsNotAPlaceholderIsText() {
        XCTAssertEqual(TemplateFormat.fill("100 % sure", []), "100 % sure")
        XCTAssertEqual(TemplateFormat.fill("100 % sure", ["now"]), "100 % sure")
    }

    /// Two percent signs are one percent sign.
    func testTwoPercentSignsAreOnePercentSign() {
        XCTAssertEqual(TemplateFormat.fill("100%% sure", []), "100% sure")
    }

    /// A template without arguments is left as it is.
    func testATemplateWithoutArgumentsIsLeftAsItIs() {
        XCTAssertEqual(TemplateFormat.fill("%d files could not be read.", []),
                       "%d files could not be read.")
    }

    /// A decimal number that reaches a `%d` is written as a whole number.
    func testADecimalNumberThatReachesAWholeNumberIsRounded() {
        XCTAssertEqual(TemplateFormat.fill("%d ms", [12.6]), "13 ms")
    }
}
