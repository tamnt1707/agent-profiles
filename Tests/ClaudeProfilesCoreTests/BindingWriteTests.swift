import Foundation
import XCTest
@testable import ClaudeProfilesCore

/// A binding must not write a value that is already there.
///
/// SwiftUI writes a binding back with the value it already has. The launcher
/// of the menu bar is inserted by a binding, so the setter of that binding is
/// asked for the value on every pass of the scene. A setter that writes such
/// a value changes the model, the change invalidates the window, the window
/// writes the value back again, and the app saves `profiles.json` in a loop
/// while the user does nothing.
final class BindingWriteTests: XCTestCase {
    /// The setters of the app that a binding uses. Every one of them has to
    /// leave the model alone when the value is already there.
    private static let boundSetters = [
        "setAppearance",
        "setAutoCheckUpdates",
        "setCommandInput",
        "setLanguage",
        "setName",
        "setShowMenuBar",
        "setTerminal",
    ]

    /// Every setter of the app that a binding uses ignores the value that is
    /// already there.
    func testEveryBoundSetterIgnoresTheValueThatIsAlreadyThere() {
        var used: Set<String> = []
        for binding in bindings() {
            for name in SourceScan.calledSetters(in: binding.body) {
                used.insert(name)
                guard let function = SourceScan.function(named: name, in: appSources()) else {
                    XCTFail("\(binding.place): \(name) is used but never defined")
                    continue
                }
                let firstWrite = SourceScan.writes(in: function.body).first
                let guard_ = SourceScan.guards(in: function.body).first { candidate in
                    guard let firstWrite else { return true }
                    return candidate.at < firstWrite
                }
                guard let guard_ else {
                    XCTFail(
                        "\(name) writes before it looks at the value that is already there: "
                        + "\(function.body.trimmingCharacters(in: .whitespacesAndNewlines))"
                    )
                    continue
                }
                XCTAssertTrue(
                    guard_.condition.contains("!=") || guard_.condition.contains("SettingsChange.isDifferent"),
                    "\(name) does not compare the new value with the one that is stored: \(guard_.condition)"
                )
                XCTAssertTrue(
                    guard_.condition.contains(function.parameter),
                    "\(name) does not compare with the value that comes in: \(guard_.condition)"
                )
            }
        }
        // The scan has to find the bindings of the app. Without this check a
        // broken scan would pass the test above without looking at anything.
        XCTAssertTrue(
            Self.boundSetters.allSatisfy { used.contains($0) },
            "the bindings that were found: \(used.sorted())"
        )
    }

    /// Every binding that writes into the model or into the state of a view
    /// ignores the value that is already there.
    func testEveryBindingThatWritesIgnoresTheValueThatIsAlreadyThere() {
        var written = 0
        for binding in bindings() {
            guard let firstWrite = SourceScan.writes(in: binding.body).first else { continue }
            written += 1
            let incoming = SourceScan.incomingName(in: binding.body)
            let guard_ = SourceScan.guards(in: binding.body).first { $0.at < firstWrite }
            guard let guard_ else {
                XCTFail(
                    "\(binding.place) writes before it looks at the value that is already there: "
                    + "\(binding.body.trimmingCharacters(in: .whitespacesAndNewlines))"
                )
                continue
            }
            XCTAssertTrue(
                guard_.condition.contains("!=") || guard_.condition.contains("SettingsChange.isDifferent"),
                "\(binding.place) does not compare the new value with the one that is stored: \(guard_.condition)"
            )
            XCTAssertTrue(
                guard_.condition.contains(incoming),
                "\(binding.place) does not compare with the value that comes in: \(guard_.condition)"
            )
        }
        XCTAssertGreaterThan(written, 0, "no binding that writes was found")
    }

    /// Every binding of the app, with the body of its setter.
    private func bindings() -> [BindingUse] {
        var found: [BindingUse] = []
        for url in PackageLayout.swiftFiles(in: PackageLayout.url("Sources/ClaudeProfiles")) {
            let text = PackageLayout.text(of: url)
            for start in SourceScan.bindingStarts(in: text) {
                guard let arguments = SourceScan.balanced(in: text, from: start) else { continue }
                guard let body = SourceScan.setterBody(in: arguments.content) else { continue }
                found.append(
                    BindingUse(
                        place: "\(url.lastPathComponent):\(SourceScan.line(of: start, in: text))",
                        body: body
                    )
                )
            }
        }
        return found
    }

    /// The source of every file of the app.
    private func appSources() -> String {
        PackageLayout.swiftFiles(in: PackageLayout.url("Sources/ClaudeProfiles"))
            .map { PackageLayout.text(of: $0) }
            .joined(separator: "\n")
    }
}

/// A binding of the app and the body of its setter.
private struct BindingUse {
    /// Where the binding is written.
    let place: String
    /// The body of the setter of the binding.
    let body: String
}

/// The places of the source that the test looks at.
private enum SourceScan {
    /// The places where a binding is built.
    static func bindingStarts(in text: String) -> [String.Index] {
        var found: [String.Index] = []
        var search = text.startIndex
        while let range = text.range(of: "Binding", range: search..<text.endIndex) {
            search = range.upperBound
            // The name of the type is not a binding that is built.
            if range.lowerBound > text.startIndex {
                let before = text.index(before: range.lowerBound)
                if text[before].isLetter || text[before].isNumber || text[before] == "_" {
                    continue
                }
            }
            var index = range.upperBound
            while index < text.endIndex, text[index] == " " || text[index] == "\n" || text[index] == "\t" {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            let char = text[index]
            if char == "(" || char == "{" {
                found.append(index)
            }
        }
        return found
    }

    /// The text inside a pair of brackets, and where the pair ends.
    static func balanced(in text: String, from start: String.Index) -> (content: String, end: String.Index)? {
        let opening = text[start]
        let closing: Character = opening == "(" ? ")" : "}"
        var depth = 0
        var index = start
        var inString = false
        var inComment = false
        while index < text.endIndex {
            let char = text[index]
            let next = text.index(after: index)
            if inComment {
                if char == "\n" { inComment = false }
            } else if inString {
                if char == "\"" { inString = false }
            } else if char == "/", next < text.endIndex, text[next] == "/" {
                inComment = true
            } else if char == "\"" {
                inString = true
            } else if char == opening {
                depth += 1
            } else if char == closing {
                depth -= 1
                if depth == 0 {
                    return (String(text[text.index(after: start)..<index]), index)
                }
            }
            index = next
        }
        return nil
    }

    /// The body of the setter of a binding.
    static func setterBody(in arguments: String) -> String? {
        guard let range = arguments.range(of: "set:") else { return nil }
        guard let brace = arguments.range(of: "{", range: range.upperBound..<arguments.endIndex)?.lowerBound else {
            return nil
        }
        return balanced(in: arguments, from: brace)?.content
    }

    /// The setters of the app that a setter of a binding calls.
    static func calledSetters(in body: String) -> [String] {
        var found: [String] = []
        var search = body.startIndex
        while let range = body.range(of: "set", range: search..<body.endIndex) {
            search = range.upperBound
            if range.lowerBound > body.startIndex {
                let before = body.index(before: range.lowerBound)
                if body[before].isLetter || body[before].isNumber || body[before] == "_" {
                    continue
                }
            }
            var index = range.upperBound
            while index < body.endIndex, body[index].isLetter || body[index].isNumber || body[index] == "_" {
                index = body.index(after: index)
            }
            // The name of a setter starts with a big letter: `setName` is one,
            // `settings` is not.
            guard index > range.upperBound, body[range.upperBound].isUppercase else { continue }
            guard index < body.endIndex, body[index] == "(" else { continue }
            found.append(String(body[range.lowerBound..<index]))
        }
        return found
    }

    /// The body of a function of the app, and the name of its parameter.
    static func function(named name: String, in text: String) -> (body: String, parameter: String)? {
        guard let range = text.range(of: "func \(name)(") else { return nil }
        guard let signature = balanced(in: text, from: text.index(before: range.upperBound)) else { return nil }
        guard let brace = text.range(of: "{", range: signature.end..<text.endIndex)?.lowerBound else { return nil }
        guard let body = balanced(in: text, from: brace) else { return nil }
        return (body.content, parameterName(in: signature.content))
    }

    /// The name of the first parameter of a signature.
    static func parameterName(in signature: String) -> String {
        let first = signature.split(separator: ",").first.map(String.init) ?? ""
        let beforeType = first.split(separator: ":").first.map(String.init) ?? first
        let parts = beforeType.split(whereSeparator: { $0 == " " || $0 == "\t" })
        return parts.last.map(String.init) ?? ""
    }

    /// The guards of a body: where they are and what they compare.
    static func guards(in body: String) -> [(at: String.Index, condition: String)] {
        var found: [(at: String.Index, condition: String)] = []
        var search = body.startIndex
        while let range = body.range(of: "guard ", range: search..<body.endIndex) {
            search = range.upperBound
            let rest = body[range.upperBound...]
            guard let otherwise = rest.range(of: " else ") else { break }
            found.append(
                (
                    range.lowerBound,
                    String(rest[..<otherwise.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }
        return found
    }

    /// The places where a body writes something.
    static func writes(in body: String) -> [String.Index] {
        let markers = [
            " = ",
            "persistSettings()",
            "store.save(",
            "regenerateScripts()",
            "applyAppearance()",
            "syncSlug()",
            "command.set",
            "refreshForeignCommandPath()",
        ]
        var places: [String.Index] = []
        for marker in markers {
            var search = body.startIndex
            while let range = body.range(of: marker, range: search..<body.endIndex) {
                places.append(range.lowerBound)
                search = range.upperBound
            }
        }
        return places.sorted { $0 < $1 }
    }

    /// The name of the value that comes into the setter of a binding.
    static func incomingName(in body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.firstIndex(of: " ") else { return "$0" }
        let name = trimmed[..<space]
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return "$0" }
        guard trimmed[space...].hasPrefix(" in") else { return "$0" }
        return String(name)
    }

    /// The line a place of the source is on.
    static func line(of index: String.Index, in text: String) -> Int {
        text[..<index].reduce(1) { count, char in char == "\n" ? count + 1 : count }
    }
}
