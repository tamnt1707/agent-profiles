import Foundation

/// Whether a folder path can be typed into a terminal safely.
///
/// The launcher does not run the command itself: it types it into a live
/// interactive shell (Terminal's `do script`, iTerm's `write text`). The
/// terminal hands the bytes to the tty, and the tty acts on the control
/// characters *before* the shell parses the quotes. A folder named
/// `Ctrl-U + "cmd #"` therefore runs `cmd`: the quote is never the problem,
/// the byte in front of it is.
///
/// A path with such a character is refused, everywhere a path is accepted.
public enum FolderPathSafety {
    /// `true` when the path holds no control character at all.
    public static func isSafe(_ path: String) -> Bool {
        firstUnsafeScalar(in: path) == nil
    }

    /// The first control character of the path, `nil` when there is none.
    ///
    /// The scalar is returned so that a message can name what was found.
    public static func firstUnsafeScalar(in path: String) -> Unicode.Scalar? {
        for scalar in path.unicodeScalars where isControl(scalar) {
            return scalar
        }
        return nil
    }

    /// `true` for the scalars a terminal or a shell acts on.
    ///
    /// - C0 controls (U+0000...U+001F): `Tab`, `Line feed`, `Carriage return`,
    ///   `Ctrl-U` and every other `Ctrl` key.
    /// - `Delete` (U+007F).
    /// - C1 controls (U+0080...U+009F).
    /// - `Line separator` and `Paragraph separator` (U+2028, U+2029): they end
    ///   a line for every tool that reads lines.
    public static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F: return true
        case 0x7F: return true
        case 0x80...0x9F: return true
        case 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// The name of a control character, as it is written in a program: `\t`,
    /// `\n`, `\r` and `\u{1B}` for the others.
    ///
    /// The name is written instead of the character, so that the character
    /// cannot act on the terminal that shows it.
    public static func escaped(_ scalar: Unicode.Scalar) -> String {
        switch scalar.value {
        case 0x09: return "\\t"
        case 0x0A: return "\\n"
        case 0x0D: return "\\r"
        default: return "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
        }
    }

    /// The path as it can be shown to the user.
    ///
    /// Every control character is written as its name, so that the user can see
    /// what was found and the terminal that shows the message does not act on
    /// it. A long path is cut in the middle, so that the line stays one line.
    public static func visible(_ path: String) -> String {
        let written = path.unicodeScalars.map { scalar in
            isControl(scalar) ? escaped(scalar) : String(scalar)
        }.joined()
        return truncated(written)
    }

    /// The path, cut in the middle when it is longer than the limit.
    public static func truncated(_ path: String, limit: Int = 80) -> String {
        guard path.count > limit else { return path }
        let head = (limit - 1) / 2
        let tail = limit - 1 - head
        return String(path.prefix(head)) + "…" + String(path.suffix(tail))
    }
}
