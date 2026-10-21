import XCTest
@testable import ClaudeProfilesCore

/// Ports the Rust tests and adds the cases the old app never covered.
final class SlugTests: XCTestCase {
    func testSlugFoldsVietnamese() {
        XCTAssertEqual(Slug.slugify("GLM Đẹp Trai!"), "glm-dep-trai")
        XCTAssertEqual(Slug.slugify("  Kimi K2  "), "kimi-k2")
    }

    func testSlugFoldsUppercaseVietnamese() {
        XCTAssertEqual(Slug.slugify("Đỗ Mười"), "do-muoi")
        XCTAssertEqual(Slug.slugify("Êm"), "em")
        XCTAssertEqual(Slug.slugify("ĐỖ MƯỜI"), "do-muoi")
    }

    func testSlugCollapsesSeparators() {
        XCTAssertEqual(Slug.slugify("Mixed  CASE--name__here"), "mixed-case-name-here")
        XCTAssertEqual(Slug.slugify("100% & more?"), "100-more")
    }

    func testSlugOfSymbolsIsEmpty() {
        XCTAssertEqual(Slug.slugify("!!!"), "")
        XCTAssertEqual(Slug.slugify("  "), "")
        XCTAssertEqual(Slug.slugify(""), "")
    }

    func testSlugNeverContainsPathCharacters() {
        let names = [
            "GLM Đẹp Trai!", "a/b", "a.b", "a b", "..", "./..", "a\tb", "a\nb",
            "Đỗ Mười", "  Kimi K2  ", "100% & more?", "🙂 emoji", "a\\b",
        ]
        for name in names {
            let slug = Slug.slugify(name)
            XCTAssertFalse(slug.contains("/"), "\(name) -> \(slug)")
            XCTAssertFalse(slug.contains("."), "\(name) -> \(slug)")
            XCTAssertFalse(slug.contains(where: { $0.isWhitespace }), "\(name) -> \(slug)")
            XCTAssertTrue(Slug.isSafe(slug) || slug.isEmpty, "\(name) -> \(slug)")
        }
    }

    func testSlugMatchesTheRustReference() throws {
        // The reference file was produced by the Rust implementation.
        let reference = try Fixtures.text("rust-slugs", extension: "txt")
        let expected: [String: String] = [
            "GLM Đẹp Trai!": "glm-dep-trai",
            "  Kimi K2  ": "kimi-k2",
            "Đỗ Mười": "do-muoi",
            "Êm": "em",
            "abc": "abc",
            "!!!": "",
            "  ": "",
            "Ünïcödé": "n-c-de",
            "Mixed  CASE--name__here": "mixed-case-name-here",
            "100% & more?": "100-more",
        ]
        for (name, slug) in expected {
            XCTAssertEqual(Slug.slugify(name), slug, "slug of \(name)")
        }
        XCTAssertFalse(reference.isEmpty)
    }
}
