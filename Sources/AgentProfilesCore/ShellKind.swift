import Foundation

/// The shells the app knows, by the name of their login shell (`/bin/zsh` is zsh).
///
/// Supported shells get a managed block or a dedicated file. The others only
/// get a line the user copies by hand.
public enum ShellKind: Equatable, Hashable, Sendable {
    case zsh
    case bash
    case fish
    /// sh, dash, ksh and the other POSIX shells. They read `~/.profile`.
    case posix
    /// nushell. Configured by hand.
    case nushell
    /// tcsh and csh. Configured by hand.
    case csh
    /// Any other shell (elvish, xonsh, …), configured by hand. Carries its name.
    case other(String)

    /// The shells that the app edits itself.
    public static let supported: [ShellKind] = [.zsh, .bash, .fish, .posix]

    /// `true` when the app edits the files of this shell.
    public var isSupported: Bool { Self.supported.contains(self) }

    /// The shell of a login shell path, by its file name.
    public static func from(loginShell path: String) -> ShellKind {
        let name = URL(fileURLWithPath: path).lastPathComponent
        switch name {
        case "zsh": return .zsh
        case "bash": return .bash
        case "fish": return .fish
        case "sh", "dash", "ksh", "ksh93", "mksh", "ash", "posh": return .posix
        case "nu", "nushell": return .nushell
        case "tcsh", "csh": return .csh
        default: return .other(name.isEmpty ? path : name)
        }
    }

    /// The name shown in the interface. Shell names are not translated.
    public var displayName: String {
        switch self {
        case .zsh: return "zsh"
        case .bash: return "bash"
        case .fish: return "fish"
        case .posix: return "sh / ksh"
        case .nushell: return "nushell"
        case .csh: return "tcsh / csh"
        case .other(let name): return name
        }
    }
}
