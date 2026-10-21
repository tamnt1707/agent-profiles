import XCTest
@testable import ClaudeProfilesCore

/// The rules of the model suggestions: order, case, spaces, duplicates and the limit.
final class ModelSuggestionsTests: XCTestCase {
    private let models = ["glm-4.6", "claude-opus-4", "GLM-4.5-air", "claude-haiku-4", "glm-4.6v", "gpt-4o"]

    func testExactMatchComesFirstThenPrefixThenSubstring() {
        let result = ModelSuggestions.filter(query: "glm-4.6", in: models)
        XCTAssertEqual(result.items, ["glm-4.6", "glm-4.6v"])
        XCTAssertFalse(result.more)

        let mixed = ModelSuggestions.filter(query: "4", in: ["x-4", "4-pro", "a4b", "4"])
        XCTAssertEqual(mixed.items, ["4", "4-pro", "a4b", "x-4"])
    }

    func testEachGroupIsSortedAlphabetically() {
        let result = ModelSuggestions.filter(query: "claude", in: ["claude-b", "claude-a", "x-claude-c", "claude-c"])
        XCTAssertEqual(result.items, ["claude-a", "claude-b", "claude-c", "x-claude-c"])
    }

    func testMatchingIgnoresCaseAndSurroundingSpaces() {
        XCTAssertEqual(ModelSuggestions.filter(query: "  GLM-4.5 ", in: models).items, ["GLM-4.5-air"])
        XCTAssertEqual(ModelSuggestions.filter(query: "OPUS", in: models).items, ["claude-opus-4"])
    }

    func testEmptyQueryReturnsTheWholeListSorted() {
        let result = ModelSuggestions.filter(query: "   ", in: models)
        XCTAssertEqual(result.items, models.sorted())
        XCTAssertFalse(result.more)
    }

    func testDuplicatesAreDropped() {
        let result = ModelSuggestions.filter(query: "glm", in: ["glm-1", "glm-1", "glm-2"])
        XCTAssertEqual(result.items, ["glm-1", "glm-2"])
    }

    func testLimitCutsTheListAndSetsTheMoreFlag() {
        let many = (1...120).map { String(format: "model-%03d", $0) }
        let first = ModelSuggestions.filter(query: "", in: many)
        XCTAssertEqual(first.items.count, ModelSuggestions.defaultLimit)
        XCTAssertTrue(first.more)
        XCTAssertEqual(first.items.first, "model-001")

        let exact = ModelSuggestions.filter(query: "model-005", in: many, limit: 1)
        XCTAssertEqual(exact.items, ["model-005"])
        XCTAssertFalse(exact.more)

        let cut = ModelSuggestions.filter(query: "model-00", in: many, limit: 1)
        XCTAssertEqual(cut.items, ["model-001"])
        XCTAssertTrue(cut.more)

        let all = ModelSuggestions.filter(query: "model-", in: many, limit: 200)
        XCTAssertEqual(all.items.count, 120)
        XCTAssertFalse(all.more)
    }

    func testNoMatchKeepsTheTypedTextOutOfTheList() {
        // A typed name that the provider does not list is simply not suggested.
        // The query itself is never returned as a model.
        let query = "my-private-model"
        let result = ModelSuggestions.filter(query: query, in: models)
        XCTAssertEqual(result.items, [])
        XCTAssertFalse(result.more)
        XCTAssertFalse(result.items.contains(query))
    }

    func testEmptyListGivesNoSuggestions() {
        XCTAssertEqual(ModelSuggestions.filter(query: "a", in: []), ModelSuggestions.Result(items: [], more: false))
    }
}
