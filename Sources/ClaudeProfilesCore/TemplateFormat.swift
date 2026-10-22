import Foundation

/// The placeholders of a localized sentence, and a safe way to fill them.
///
/// `String(format:)` reads its arguments through pointers: a whole number that
/// is handed to a `%@` is read as an object pointer, and the app crashes. The
/// helper here never lets that happen. Every placeholder is filled with a
/// value of its own kind, so a sentence that is written for a number is safe
/// even when the number is handed to it by mistake.
public enum TemplateFormat {
    /// The kind of a placeholder.
    public enum Placeholder: Equatable, Sendable {
        /// `%@`: a text, written as it is.
        case object
        /// `%d` and its friends: a whole number.
        case integer
        /// `%f` and its friends: a decimal number.
        case real
    }

    /// One piece of a template.
    private enum Segment {
        /// Text that is written as it is.
        case literal(String)
        /// A placeholder, with the text that stands for it.
        case placeholder(spec: String, kind: Placeholder)
    }

    /// The placeholders of a template, in the order they appear.
    public static func placeholders(of template: String) -> [Placeholder] {
        segments(of: template).compactMap { segment in
            if case .placeholder(_, let kind) = segment { return kind }
            return nil
        }
    }

    /// `true` when every placeholder of the template is a whole number.
    ///
    /// A key that is filled with a number must hold only whole-number
    /// placeholders: a `%@` would read the number as a pointer.
    public static func hasOnlyIntegerPlaceholders(_ template: String) -> Bool {
        placeholders(of: template).allSatisfy { $0 == .integer }
    }

    /// Fills a template with the given arguments.
    ///
    /// The arguments are matched to the placeholders by kind, not by position
    /// alone: a whole number that reaches a `%@` becomes its text, and a text
    /// that reaches a `%d` becomes a number when it can be read as one. A
    /// placeholder without an argument keeps its own text, so a sentence is
    /// never left with a hole in it.
    public static func fill(_ template: String, _ arguments: [Any]) -> String {
        var out = ""
        var next = 0
        for segment in segments(of: template) {
            switch segment {
            case .literal(let text):
                out += text
            case .placeholder(let spec, let kind):
                guard next < arguments.count else {
                    out += spec
                    continue
                }
                let argument = arguments[next]
                next += 1
                switch kind {
                case .object: out += objectText(argument)
                case .integer: out += integerText(argument)
                case .real: out += realText(argument)
                }
            }
        }
        return out
    }

    /// The text of a value that is written as it is.
    private static func objectText(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let text = value as? Substring { return String(text) }
        return String(describing: value)
    }

    /// The text of a value that is written as a whole number.
    private static func integerText(_ value: Any) -> String {
        if let number = value as? Int { return String(number) }
        if let number = value as? Int64 { return String(number) }
        if let number = value as? UInt { return String(number) }
        if let number = value as? Double { return String(Int(number.rounded())) }
        if let number = value as? Float { return String(Int(number.rounded())) }
        if let text = value as? String, let number = Int(text) { return String(number) }
        return String(describing: value)
    }

    /// The text of a value that is written as a decimal number.
    private static func realText(_ value: Any) -> String {
        if let number = value as? Double { return String(number) }
        if let number = value as? Float { return String(number) }
        if let number = value as? Int { return String(number) }
        if let text = value as? String { return text }
        return String(describing: value)
    }

    /// The pieces of a template, in the order they appear.
    private static func segments(of template: String) -> [Segment] {
        let characters = Array(template)
        var segments: [Segment] = []
        var literal = ""

        func flush() {
            if !literal.isEmpty {
                segments.append(.literal(literal))
                literal = ""
            }
        }

        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character == "%" else {
                literal.append(character)
                index += 1
                continue
            }

            // The flags, the width and the precision of the placeholder.
            var cursor = index + 1
            while cursor < characters.count, "-+ #0123456789.*".contains(characters[cursor]) {
                cursor += 1
            }
            guard cursor < characters.count else {
                // A percent sign at the end of the text is text.
                literal.append(character)
                index += 1
                continue
            }

            let conversion = characters[cursor]
            let kind: Placeholder
            switch conversion {
            case "@": kind = .object
            case "d", "i", "o", "u", "x", "X": kind = .integer
            case "e", "E", "f", "g", "G", "a", "A": kind = .real
            case "%":
                // Two percent signs are one percent sign.
                flush()
                segments.append(.literal("%"))
                index = cursor + 1
                continue
            default:
                // Not a placeholder at all: it stays text.
                literal.append(character)
                index += 1
                continue
            }

            flush()
            let spec = String(characters[index...cursor])
            segments.append(.placeholder(spec: spec, kind: kind))
            index = cursor + 1
        }
        flush()
        return segments
    }
}
