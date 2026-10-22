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

    // MARK: - Hostile arguments

    /// The arguments that must never be read as a template.
    ///
    /// Every one of them holds a percent sign or a line break: a value that
    /// looks like a placeholder, like a number, or like a sentence of its own.
    private static let hostileArguments: [String] = [
        "%@",
        "%d",
        "%%",
        "100%%",
        "50% done",
        "%1$@",
        "%s%s%n",
        "%",
        "a%",
        "%ld",
        String(repeating: "x", count: 10_000),
        "first line\nsecond line",
        "100% hoàn tất",
    ]

    /// A hostile argument is written as it is: it fills nothing but its own
    /// placeholder.
    func testAHostileArgumentIsWrittenVerbatim() {
        for hostile in Self.hostileArguments {
            XCTAssertEqual(
                TemplateFormat.fill("Open %@ in %@", [hostile, hostile]),
                "Open \(hostile) in \(hostile)",
                "the argument was not written as it is"
            )
        }
    }

    /// Two percent signs in an argument stay two percent signs.
    ///
    /// An argument that is read as a template would turn them into one, and
    /// the sentence of the app would show something else than what the user
    /// asked for.
    func testTwoPercentSignsInAnArgumentStayTwoPercentSigns() {
        XCTAssertEqual(TemplateFormat.fill("Open %@ in %@", ["%%", "%%"]), "Open %% in %%")
        XCTAssertEqual(TemplateFormat.fill("Open %@ in %@", ["100%%", "100%%"]), "Open 100%% in 100%%")
        XCTAssertEqual(TemplateFormat.fill("%@", ["%%"]), "%%")
    }

    /// An argument that holds a line break stays one argument: the sentence is
    /// not cut into pieces.
    func testAnArgumentWithALineBreakStaysOneArgument() {
        XCTAssertEqual(
            TemplateFormat.fill("Open %@ in %@", ["first\nsecond", "third\nfourth"]),
            "Open first\nsecond in third\nfourth"
        )
    }

    /// A hostile argument that reaches a whole number is written as zero: a
    /// whole-number slot never shows a text that cannot be read as a number.
    func testAHostileArgumentInAWholeNumberSlotBecomesZero() {
        for hostile in Self.hostileArguments {
            XCTAssertEqual(
                TemplateFormat.fill("%d files", [hostile]),
                "0 files",
                "the argument was not written as a whole number"
            )
        }
    }

    /// The text of a whole number is always a whole number.
    func testAWholeNumberSlotAlwaysHoldsAWholeNumber() {
        let values: [Any] = [
            Double.nan,
            Double.infinity,
            -Double.infinity,
            Float.nan,
            Float.infinity,
            -Float.infinity,
            Double.greatestFiniteMagnitude,
            -Double.greatestFiniteMagnitude,
            Double.greatestFiniteMagnitude * 2,
            "abc",
            "",
            "42",
        ]
        for value in values {
            let text = TemplateFormat.fill("%d", [value])
            XCTAssertNotNil(Int(text), "\(text) is not a whole number")
        }
    }

    /// A number that is not finite has no whole number: it is written as zero.
    func testANumberThatIsNotFiniteBecomesZero() {
        XCTAssertEqual(TemplateFormat.fill("%d", [Double.nan]), "0")
        XCTAssertEqual(TemplateFormat.fill("%d", [Double.infinity]), "0")
        XCTAssertEqual(TemplateFormat.fill("%d", [-Double.infinity]), "0")
        XCTAssertEqual(TemplateFormat.fill("%d", [Float.nan]), "0")
        XCTAssertEqual(TemplateFormat.fill("%d", [Float.infinity]), "0")
        XCTAssertEqual(TemplateFormat.fill("%d", [-Float.infinity]), "0")
    }

    /// A number that is too big is clamped to the biggest one that fits, so
    /// the text is still a whole number.
    func testANumberThatIsTooBigIsClamped() {
        XCTAssertEqual(TemplateFormat.fill("%d", [Double.greatestFiniteMagnitude]), String(Int.max))
        XCTAssertEqual(TemplateFormat.fill("%d", [-Double.greatestFiniteMagnitude]), String(Int.min))
        XCTAssertEqual(TemplateFormat.fill("%d", [Double.greatestFiniteMagnitude * 2]), "0")
        XCTAssertEqual(TemplateFormat.fill("%d", ["99999999999999999999"]), String(Int.max))
    }

    /// A text that is not a number is written as zero.
    func testATextThatIsNotANumberBecomesZero() {
        XCTAssertEqual(TemplateFormat.fill("%d", ["abc"]), "0")
        XCTAssertEqual(TemplateFormat.fill("%d", [""]), "0")
        XCTAssertEqual(TemplateFormat.fill("%d", ["42"]), "42")
        XCTAssertEqual(TemplateFormat.fill("%d", ["-7"]), "-7")
    }

    // MARK: - The strings of the app

    /// The strings of the app are filled with the same helper, through
    /// `Loc.t` and `Loc.count`: a hostile argument is written as it is there
    /// too.
    func testTheStringsOfTheAppTakeHostileArgumentsVerbatim() throws {
        let english = try PackageLayout.stringTable("en")
        let vietnamese = try PackageLayout.stringTable("vi")
        for hostile in Self.hostileArguments {
            XCTAssertEqual(
                TemplateFormat.fill(english["editor.command.normalized"] ?? "", [hostile]),
                "Will be saved as claude-\(hostile)"
            )
            XCTAssertEqual(
                TemplateFormat.fill(vietnamese["editor.command.normalized"] ?? "", [hostile]),
                "Sẽ được lưu thành claude-\(hostile)"
            )
        }
    }

    /// The sentences that take a whole number take it as a whole number, in
    /// both languages.
    func testTheCountSentencesOfTheAppTakeAWholeNumber() throws {
        let english = try PackageLayout.stringTable("en")
        let vietnamese = try PackageLayout.stringTable("vi")
        XCTAssertEqual(
            TemplateFormat.fill(english["sidebar.checkAll.progress"] ?? "", [3, 4]),
            "3 of 4 checked"
        )
        XCTAssertEqual(
            TemplateFormat.fill(vietnamese["sidebar.checkAll.progress"] ?? "", [3, 4]),
            "3/4 đã kiểm tra"
        )
        // A hostile argument in a whole-number slot is written as zero.
        XCTAssertEqual(
            TemplateFormat.fill(english["sidebar.checkAll.progress"] ?? "", ["%%", "100%%"]),
            "0 of 0 checked"
        )
        XCTAssertEqual(
            TemplateFormat.fill(vietnamese["sidebar.checkAll.progress"] ?? "", ["%%", "100%%"]),
            "0/0 đã kiểm tra"
        )
    }

    /// A Vietnamese sentence with a percent sign in it is written as it is.
    func testAVietnameseSentenceWithAPercentSignIsWrittenAsItIs() throws {
        let vietnamese = try PackageLayout.stringTable("vi")
        XCTAssertEqual(
            TemplateFormat.fill(vietnamese["editor.command.normalized"] ?? "", ["100% hoàn tất"]),
            "Sẽ được lưu thành claude-100% hoàn tất"
        )
    }

    // MARK: - The wrappers of the app

    /// The sentences of the app are filled through the safe helper.
    ///
    /// `Loc.t` and `Loc.count` are the two ways the app fills a sentence: both
    /// of them must go through `TemplateFormat`, whose arguments are written as
    /// they are. `String(format:)` reads its arguments through pointers: a
    /// whole number that reaches a `%@` crashes the app.
    ///
    /// The app is an executable and cannot be imported here, so its source is
    /// read instead, the way the other tests of the app read it.
    func testTheWrappersOfTheAppFillThroughTheSafeHelper() {
        let source = PackageLayout.text(of: PackageLayout.url("Sources/ClaudeProfiles/Localization.swift"))

        XCTAssertFalse(
            source.contains("String(format:"),
            "the app still fills its sentences with String(format:)"
        )
        // Every wrapper of the app fills through the helper.
        let wrappers = [
            "func t(_ key: String, _ arguments: CVarArg...)",
            "func count(_ key: String, _ n: Int)",
            "func count(_ key: String, _ n: Int, _ text: String)",
            "func count(_ key: String, _ done: Int, _ total: Int)",
        ]
        for wrapper in wrappers {
            guard let start = source.range(of: wrapper) else {
                XCTFail("\(wrapper) is gone")
                continue
            }
            let body = source[start.upperBound...].prefix(400)
            XCTAssertTrue(
                body.contains("TemplateFormat.fill"),
                "\(wrapper) does not fill through the safe helper"
            )
        }
    }
}
