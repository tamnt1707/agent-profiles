import Foundation

/// Starts the helper script of an update with an empty environment.
///
/// The helper replaces the app bundle, so nothing of the environment of the
/// app may reach it: an exported function of the shell, an alias or a shim in
/// the PATH could change what the helper does. The helper is therefore
/// started through `env -i`, with a PATH of its own and the home folder of
/// the user, and nothing else.
public enum HelperLaunch {
    /// The arguments that start the helper script.
    ///
    /// The list is the one of `env`: an empty environment (`-i`), a PATH of
    /// its own, the home folder of the user, and the script itself.
    ///
    /// - Parameters:
    ///   - script: the script that replaces the bundle.
    ///   - home: the home folder of the user.
    /// - Returns: the arguments of `env`.
    public static func arguments(script: URL, home: URL) -> [String] {
        [
            "-i",
            "PATH=\(InstallHelper.scriptPath)",
            "HOME=\(home.path)",
            "/bin/sh",
            script.path,
        ]
    }

    /// The command that starts the helper script in the background.
    ///
    /// The script is started through `nohup`, so it survives the quit of the
    /// app, and through `env -i`, so it starts with an empty environment. Every
    /// part is quoted: a bundle in a folder with a space or a quote in its
    /// name must not change the command.
    ///
    /// - Parameters:
    ///   - script: the script that replaces the bundle.
    ///   - home: the home folder of the user.
    /// - Returns: the command for the shell.
    public static func command(script: URL, home: URL) -> String {
        let arguments = arguments(script: script, home: home)
            .map(ShellQuote.quote)
            .joined(separator: " ")
        return "/usr/bin/nohup /usr/bin/env \(arguments) >/dev/null 2>&1 &"
    }
}
