import Foundation

/// Helpers for the tiny bit of shell we generate.
public enum ShellQuote {
    /// Wraps a string in single quotes, escaping embedded single quotes as `'\''`.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `true` for names matching `[A-Za-z_][A-Za-z0-9_]*`.
    public static func isValidEnvName(_ name: String) -> Bool {
        guard let first = name.first else { return false }
        guard first.isASCII, first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// Parses the `KEY=VALUE` block of the "extra environment" field.
    ///
    /// Blank lines and `#` comments are skipped, an optional `export ` prefix is
    /// accepted and one layer of surrounding quotes is stripped from the value.
    /// Errors carry the 1-based line number of the offending line.
    public static func parseExtraEnv(_ text: String) throws -> [(key: String, value: String)] {
        var result: [(key: String, value: String)] = []
        var lineNumber = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count))
            }
            guard let separator = line.firstIndex(of: "=") else {
                throw ProfileError.envMissingEquals(line: lineNumber, text: line)
            }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidEnvName(key) else {
                throw ProfileError.invalidEnvName(line: lineNumber, name: key)
            }
            var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            value = trim(value, character: "\"")
            value = trim(value, character: "'")
            result.append((key, value))
        }
        return result
    }

    /// Removes every leading and trailing occurrence of `character`.
    private static func trim(_ value: String, character: Character) -> String {
        var out = Substring(value)
        while let first = out.first, first == character { out = out.dropFirst() }
        while let last = out.last, last == character { out = out.dropLast() }
        return String(out)
    }
}
