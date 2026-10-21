import XCTest

/// The English and Vietnamese tables must stay in sync: same keys, same
/// number of placeholders.
final class LocalizationParityTests: XCTestCase {
    /// The root of the package, derived from the location of this file.
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ClaudeProfilesCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    private func table(_ language: String) throws -> [String: String] {
        let url = Self.packageRoot
            .appendingPathComponent("Sources/ClaudeProfiles/Resources")
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.strings")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing \(url.path)")
        guard let contents = NSDictionary(contentsOfFile: url.path) as? [String: String] else {
            XCTFail("\(url.path) is not a valid strings file")
            return [:]
        }
        return contents
    }

    private func placeholders(_ value: String) -> (strings: Int, numbers: Int) {
        var strings = 0
        var numbers = 0
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "%" {
                let next = value.index(after: index)
                if next < value.endIndex {
                    switch value[next] {
                    case "@": strings += 1
                    case "d", "i", "u": numbers += 1
                    default: break
                    }
                }
                index = value.index(after: next)
            } else {
                index = value.index(after: index)
            }
        }
        return (strings, numbers)
    }

    func testBothLanguagesHaveTheSameKeys() throws {
        let english = try table("en")
        let vietnamese = try table("vi")
        XCTAssertFalse(english.isEmpty)
        XCTAssertFalse(vietnamese.isEmpty)

        let missingInVietnamese = Set(english.keys).subtracting(vietnamese.keys).sorted()
        let missingInEnglish = Set(vietnamese.keys).subtracting(english.keys).sorted()
        XCTAssertEqual(missingInVietnamese, [], "keys missing in vi.lproj")
        XCTAssertEqual(missingInEnglish, [], "keys missing in en.lproj")
    }

    func testPlaceholdersMatch() throws {
        let english = try table("en")
        let vietnamese = try table("vi")
        for key in english.keys.sorted() {
            guard let vietnameseValue = vietnamese[key] else { continue }
            let englishPlaceholders = placeholders(english[key] ?? "")
            let vietnamesePlaceholders = placeholders(vietnameseValue)
            XCTAssertEqual(englishPlaceholders.strings, vietnamesePlaceholders.strings,
                           "different number of %@ in \(key)")
            XCTAssertEqual(englishPlaceholders.numbers, vietnamesePlaceholders.numbers,
                           "different number of %d in \(key)")
        }
    }

    func testVietnameseUsesProperDiacritics() throws {
        let vietnamese = try table("vi")
        XCTAssertEqual(vietnamese["sidebar.add"], "Thêm profile")
        XCTAssertEqual(vietnamese["editor.env.help"], "Mỗi dòng một biến KEY=VALUE. Ví dụ: API_TIMEOUT_MS=600000")
        XCTAssertEqual(vietnamese["actions.save"], "Lưu")
        XCTAssertEqual(vietnamese["status.pathHint"], "Thêm %@ vào PATH để gọi claude-<tên> từ mọi terminal.")
    }
}
