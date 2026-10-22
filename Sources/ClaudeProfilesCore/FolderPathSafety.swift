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
}
