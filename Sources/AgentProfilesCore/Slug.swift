import Foundation

/// Turns a human profile name into the `claude-<slug>` command name.
///
/// Lower-cases, folds Vietnamese diacritics to ASCII (`đ` → `d`), turns every
/// other run of non-alphanumeric characters into a single `-` and trims the
/// leading/trailing dashes.
public enum Slug {
    /// Vietnamese diacritics, folded to their base ASCII letter.
    private static let folding: [(String, Character)] = [
        ("àáạảãâầấậẩẫăằắặẳẵ", "a"),
        ("èéẹẻẽêềếệểễ", "e"),
        ("ìíịỉĩ", "i"),
        ("òóọỏõôồốộổỗơờớợởỡ", "o"),
        ("ùúụủũưừứựửữ", "u"),
        ("ỳýỵỷỹ", "y"),
        ("đ", "d"),
    ]

    /// Folds a single scalar; unknown characters are returned unchanged.
    public static func fold(_ scalar: Unicode.Scalar) -> Character {
        let ch = Character(scalar)
        for (letters, replacement) in folding where letters.contains(ch) {
            return replacement
        }
        return ch
    }

    /// The slug of a profile name.
    public static func slugify(_ name: String) -> String {
        var out = ""
        for scalar in name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars {
            let ch = fold(scalar)
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
            } else if !out.isEmpty && !out.hasSuffix("-") {
                out.append("-")
            }
        }
        while out.hasSuffix("-") {
            out.removeLast()
        }
        return out
    }

    /// A slug is always safe to use as a single path component.
    public static func isSafe(_ slug: String) -> Bool {
        !slug.isEmpty
            && !slug.contains("/")
            && !slug.contains(".")
            && !slug.contains(where: { $0.isWhitespace })
    }
}
