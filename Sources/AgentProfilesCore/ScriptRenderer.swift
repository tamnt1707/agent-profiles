import Foundation

/// The human readable sentences that end up inside the launcher script.
/// The app fills them from the localized string table so the script always
/// speaks the language that is currently selected in the UI.
public struct ScriptStrings: Equatable, Sendable {
    /// Header comment of the script. Contains one `%@` placeholder for the profile name.
    public var headerTemplate: String
    /// Comment above the `unset` block.
    public var unsetComment: String
    /// Error printed when the Keychain holds no key. Contains one `%@` placeholder.
    public var missingKeyTemplate: String
    /// Error printed when the Keychain could not be read (locked, access denied).
    /// Contains one `%@` placeholder.
    public var accessDeniedTemplate: String

    public init(
        headerTemplate: String,
        unsetComment: String,
        missingKeyTemplate: String,
        accessDeniedTemplate: String = ScriptStrings.english.accessDeniedTemplate
    ) {
        self.headerTemplate = headerTemplate
        self.unsetComment = unsetComment
        self.missingKeyTemplate = missingKeyTemplate
        self.accessDeniedTemplate = accessDeniedTemplate
    }

    public static let english = ScriptStrings(
        headerTemplate: "# Created by Agent Profiles for profile \"%@\". This file is overwritten every time you save.",
        unsetComment: "# Remove leftover provider settings from the shell so profiles do not get mixed up",
        missingKeyTemplate: "No API key for profile %@ in the Keychain. Open the Agent Profiles app to enter it.",
        accessDeniedTemplate: "Could not read the API key for profile %@ from the Keychain. The Keychain may be locked or access was denied. Unlock it, allow access and try again."
    )

    public static let vietnamese = ScriptStrings(
        headerTemplate: "# Tạo bởi Agent Profiles cho profile \"%@\". File này được ghi đè mỗi lần lưu.",
        unsetComment: "# Bỏ cấu hình nhà cung cấp còn sót trong shell để profile không bị lẫn",
        missingKeyTemplate: "Chưa có API key cho profile %@ trong Keychain. Mở app Agent Profiles để nhập.",
        accessDeniedTemplate: "Không đọc được API key của profile %@ từ Keychain. Keychain có thể đang khóa hoặc quyền truy cập bị từ chối. Hãy mở khóa, cho phép truy cập rồi thử lại."
    )
}

/// Renders the launcher script of a profile.
///
/// The script never contains a secret: the API key is read from the Keychain
/// when the script runs.
public enum ScriptRenderer {
    /// Keychain service used for every profile.
    public static let keychainService = "claude-profiles"

    /// The comment that marks a launcher as written by this app.
    ///
    /// It never changes and it always sits on the second line of the script,
    /// so a file in `bin/` that does not carry it was written by something
    /// else. Such a file is never overwritten and never deleted.
    /// The marker keeps the first name of the app on purpose: the launchers that
    /// are already on disk carry it, and a launcher is only ever replaced or
    /// deleted when it does.
    public static let marker = "# Managed by Claude Profiles. Rewritten on every save."

    /// Renders the launcher script.
    public static func render(
        profile: Profile,
        paths: Paths,
        strings: ScriptStrings = .english
    ) throws -> String {
        var script = "#!/bin/zsh\n"
        script += marker + "\n"
        script += substitute(strings.headerTemplate, commentSafe(profile.name)) + "\n\n"

        script += strings.unsetComment + "\n"
        script += "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL \\\n"
        script += "  ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL \\\n"
        script += "  ANTHROPIC_SMALL_FAST_MODEL\n\n"

        if let variable = profile.auth.envVarName {
            // security's own error text is left visible. Its exit status tells
            // "no such item" (44) from "could not read it" (anything else).
            script += "__k=\"$(/usr/bin/security find-generic-password -s "
            script += ShellQuote.quote(keychainService)
            script += " -a " + ShellQuote.quote(profile.slug) + " -w)\"\n"
            script += "__s=$?\n"
            script += "if [[ -z \"$__k\" ]]; then\n"
            script += "  if [[ $__s -eq 44 || $__s -eq 0 ]]; then\n"
            script += "    echo \"" + substitute(strings.missingKeyTemplate, quotedForMessage(profile.name)) + "\" >&2\n"
            script += "  else\n"
            script += "    echo \"" + substitute(strings.accessDeniedTemplate, quotedForMessage(profile.name)) + "\" >&2\n"
            script += "  fi\n"
            script += "  exit 1\n"
            script += "fi\n"
            script += "export \(variable)=\"$__k\"\n"
            script += "unset __k __s\n\n"
        }

        func export(_ key: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                script += "export \(key)=\(ShellQuote.quote(trimmed))\n"
            }
        }

        export("ANTHROPIC_BASE_URL", profile.baseURL)
        export("ANTHROPIC_MODEL", profile.model)
        export("ANTHROPIC_DEFAULT_OPUS_MODEL", profile.opusModel)
        export("ANTHROPIC_DEFAULT_SONNET_MODEL", profile.sonnetModel)
        export("ANTHROPIC_DEFAULT_HAIKU_MODEL", profile.haikuModel)
        if profile.isolate {
            export("CLAUDE_CONFIG_DIR", paths.home(for: profile.slug).path)
        }
        for entry in try ShellQuote.parseExtraEnv(profile.extraEnv) {
            export(entry.key, entry.value)
        }

        script += "\nexec claude \"$@\"\n"
        return script
    }

    /// Replaces the single `%@` placeholder of a template.
    static func substitute(_ template: String, _ value: String) -> String {
        template.replacingOccurrences(of: "%@", with: value)
    }

    /// `true` when the file at the path is a launcher written by this app.
    ///
    /// A symbolic link is never a launcher of this app here: the text is not
    /// read through it, so a link cannot make a foreign file look managed.
    public static func isManagedLauncher(at url: URL) -> Bool {
        guard SafeFileSystem.kind(of: url) == .file else { return false }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return isManagedLauncher(text)
    }

    /// `true` when the script text carries the marker of this app.
    public static func isManagedLauncher(_ script: String) -> Bool {
        let head = script
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(3)
            .joined(separator: "\n")
        return head.contains(marker)
    }

    /// The name as it may appear inside a `#` comment: line breaks would end
    /// the comment, so they become spaces.
    static func commentSafe(_ name: String) -> String {
        name
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// The name as it may appear inside the double quoted `echo` message:
    /// backslashes, quotes, `$` and backticks are escaped so that a profile
    /// name can never run a command.
    static func quotedForMessage(_ name: String) -> String {
        var out = "'"
        for character in commentSafe(name) {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "$": out += "\\$"
            case "`": out += "\\`"
            default: out.append(character)
            }
        }
        out += "'"
        return out
    }
}
