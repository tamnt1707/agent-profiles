import XCTest
@testable import AgentProfilesCore

/// The placeholders of the string tables must fit the values that are put in
/// them.
///
/// `String(format:)` reads a whole number that is handed to a `%@` as a
/// pointer, and the app crashes. The tables are checked here, and every whole
/// number of the app goes through the typed wrapper `Loc.count`.
final class LocalizationPlaceholderTests: XCTestCase {
    // MARK: - The tables

    /// The keys that are filled with a whole number, and the kinds of the
    /// placeholders they hold.
    ///
    /// A key that holds only whole numbers must hold only whole-number
    /// placeholders. A key that holds a whole number and a text holds them in
    /// that order: the number first, the text second.
    private static let wholeNumberKeys: [String: [TemplateFormat.Placeholder]] = [
        "editor.usage.skippedFiles": [.integer],
        "probe.ok": [.integer],
        "probe.ok.model": [.integer, .object],
        "probe.serverError": [.integer],
        "probe.unexpectedStatus": [.integer],
        "sidebar.health.connectedMany": [.integer],
        "sidebar.health.stale": [.integer],
        "sidebar.checkAll.progress": [.integer, .integer],
        "orch.status.partial": [.integer, .integer],
        "terminal.state.exitedCode": [.integer],
        "quit.message": [.integer],
        "terminal.session.label": [.integer],
        "error.envMissingEquals": [.integer, .object],
        "error.invalidEnvName": [.integer, .object],
        "error.update.httpError": [.integer]
    ]

    // MARK: - The two languages

    /// Both languages must fill the same kinds of placeholders, in the same
    /// order: a sentence that reads a number in English must read it in
    /// Vietnamese too.
    func testTheSequenceOfPlaceholderTypesIsTheSameInBothLanguages() throws {
        let english = try PackageLayout.stringTable("en")
        let vietnamese = try PackageLayout.stringTable("vi")
        for key in english.keys.sorted() {
            guard let vietnameseValue = vietnamese[key] else { continue }
            XCTAssertEqual(TemplateFormat.placeholders(of: english[key] ?? ""),
                           TemplateFormat.placeholders(of: vietnameseValue),
                           "different sequence of placeholder types in \(key)")
        }
    }

    /// The sentence about the files that could not be read takes a whole
    /// number, in both languages.
    func testTheSkippedFilesSentenceTakesAWholeNumber() throws {
        let english = try PackageLayout.stringTable("en")
        let vietnamese = try PackageLayout.stringTable("vi")
        let englishText = TemplateFormat.fill(english["editor.usage.skippedFiles"] ?? "", [3])
        let vietnameseText = TemplateFormat.fill(vietnamese["editor.usage.skippedFiles"] ?? "", [3])
        XCTAssertEqual(englishText, "3 files could not be read.")
        XCTAssertEqual(vietnameseText, "Không đọc được 3 tệp.")
        XCTAssertFalse(englishText.contains("%"), "the number did not fill the placeholder")
        XCTAssertFalse(vietnameseText.contains("%"), "the number did not fill the placeholder")
    }

    // MARK: - The whole numbers

    /// Every key that is filled with a whole number holds only whole-number
    /// placeholders, so a number is never read as a pointer.
    func testEveryKeyThatIsFilledWithAWholeNumberHoldsOnlyWholeNumbers() throws {
        let tables = try [
            "en": PackageLayout.stringTable("en"),
            "vi": PackageLayout.stringTable("vi")
        ]
        for (key, kinds) in Self.wholeNumberKeys {
            for (language, table) in tables {
                guard let value = table[key] else {
                    XCTFail("\(key) is missing in \(language).lproj")
                    continue
                }
                XCTAssertEqual(TemplateFormat.placeholders(of: value), kinds,
                               "\(key) in \(language).lproj holds the wrong placeholders")
                if kinds.allSatisfy({ $0 == .integer }) {
                    XCTAssertTrue(TemplateFormat.hasOnlyIntegerPlaceholders(value),
                                  "\(key) in \(language).lproj must hold only whole numbers")
                } else {
                    XCTAssertEqual(TemplateFormat.placeholders(of: value).first, .integer,
                                   "\(key) in \(language).lproj must give the number to a whole-number placeholder")
                }
            }
        }
    }

    /// Every whole number of the app goes through the typed wrapper, and every
    /// key of the wrapper is a key that is really used.
    func testEveryWholeNumberGoesThroughTheTypedWrapper() throws {
        var used: [String: Int] = [:]
        for site in Self.countCallSites() {
            used[site.key, default: 0] += 1
            guard let kinds = Self.wholeNumberKeys[site.key] else {
                XCTFail("\(site.key) is filled with a whole number but is not a known whole-number key")
                continue
            }
            XCTAssertEqual(site.arity, kinds.count,
                           "\(site.key) is filled with \(site.arity) values but holds \(kinds.count) placeholders")
        }
        for key in Self.wholeNumberKeys.keys.sorted() {
            XCTAssertNotNil(used[key], "\(key) is a whole-number key but is never filled")
        }
    }

    /// The places where the app fills a whole number through the typed
    /// wrapper.
    private struct CallSite {
        var key: String
        /// The number of values that are put into the key, without the key.
        var arity: Int
    }

    /// Every call of the typed wrapper with a key that is written as text.
    private static func countCallSites() -> [CallSite] {
        var sites: [CallSite] = []
        for file in PackageLayout.swiftFiles() {
            let text = PackageLayout.text(of: file)
            var searchStart = text.startIndex
            while let found = text.range(of: "count(", range: searchStart..<text.endIndex) {
                searchStart = found.upperBound
                // The name must stand on its own.
                if found.lowerBound > text.startIndex {
                    let before = text[text.index(before: found.lowerBound)]
                    if before.isLetter || before.isNumber || before == "_" { continue }
                }
                // A function that is defined here is not a call.
                let lead = text[text.startIndex..<found.lowerBound].suffix(5)
                if lead.hasSuffix("func ") { continue }
                guard let arguments = arguments(of: text, from: found.upperBound),
                      arguments.count >= 1,
                      let raw = arguments.first
                else { continue }
                let first = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard first.count >= 2, first.hasPrefix("\""), first.hasSuffix("\"") else { continue }
                sites.append(CallSite(key: String(first.dropFirst().dropLast()),
                                      arity: arguments.count - 1))
            }
        }
        return sites
    }

    /// The arguments of a call, split at the commas that are not inside a
    /// bracket or a text.
    private static func arguments(of text: String, from start: String.Index) -> [String]? {
        var arguments: [String] = []
        var current = ""
        var depth = 0
        var inText = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inText {
                current.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inText = false
                }
                index = text.index(after: index)
                continue
            }
            switch character {
            case "\"":
                inText = true
                current.append(character)
            case "(", "[", "{":
                depth += 1
                current.append(character)
            case ")", "]", "}":
                if character == ")" && depth == 0 {
                    if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        arguments.append(current)
                    }
                    return arguments
                }
                depth -= 1
                current.append(character)
            case "," where depth == 0:
                arguments.append(current)
                current = ""
            default:
                current.append(character)
            }
            index = text.index(after: index)
        }
        return nil
    }
}
