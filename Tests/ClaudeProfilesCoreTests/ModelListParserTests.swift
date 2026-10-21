import XCTest
@testable import ClaudeProfilesCore

final class ModelListParserTests: XCTestCase {
    private func parse(_ text: String) -> ModelListParser.Page? {
        ModelListParser.parse(Data(text.utf8))
    }

    func testDataShapeAnthropicOpenAIAndOpenRouter() {
        let page = parse(#"{"data":[{"id":"claude-opus-4"},{"id":"claude-haiku-4-5","type":"model"}]}"#)
        XCTAssertEqual(page?.ids, ["claude-haiku-4-5", "claude-opus-4"])
        XCTAssertEqual(page?.hasMore, false)
        XCTAssertNil(page?.lastID)
    }

    func testModelsShapeWithIDOrName() {
        let page = parse(#"{"models":[{"name":"glm-4.6"},{"id":"kimi-k2"}]}"#)
        XCTAssertEqual(page?.ids, ["glm-4.6", "kimi-k2"])
    }

    func testBareListIsAccepted() {
        XCTAssertEqual(parse(#"[{"id":"b"},{"id":"a"}]"#)?.ids, ["a", "b"])
    }

    func testDuplicatesAreRemovedAndIDsSorted() {
        let page = parse(#"{"data":[{"id":"zeta"},{"id":"alpha"},{"id":"zeta"},{"id":" alpha "}]}"#)
        XCTAssertEqual(page?.ids, ["alpha", "zeta"])
    }

    func testBadIDsAreDropped() {
        let page = parse(#"{"data":[{"id":""},{"id":"   "},{"id":"bad\u0007id"},{"id":42},{"name":"ok"}]}"#)
        XCTAssertEqual(page?.ids, ["ok"])
    }

    func testOverlongIDIsDropped() {
        let long = String(repeating: "x", count: ModelListParser.maxIDLength + 1)
        let page = parse(#"{"data":[{"id":"\#(long)"},{"id":"fine"}]}"#)
        XCTAssertEqual(page?.ids, ["fine"])
    }

    func testPaginationFieldsAreRead() {
        let page = parse(#"{"data":[{"id":"a"}],"has_more":true,"last_id":"a"}"#)
        XCTAssertEqual(page?.hasMore, true)
        XCTAssertEqual(page?.lastID, "a")
    }

    func testBodyThatIsNotAListIsNil() {
        XCTAssertNil(parse(#"{"error":"no models here"}"#))
        XCTAssertNil(parse(#"{"data":"not a list"}"#))
        XCTAssertNil(parse(#""just a string""#))
        XCTAssertNil(parse("<html>404</html>"))
        XCTAssertNil(parse(""))
    }

    func testEmptyListIsAValidEmptyPage() {
        XCTAssertEqual(parse(#"{"data":[]}"#)?.ids, [])
    }
}
