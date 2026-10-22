import XCTest
@testable import ClaudeProfilesCore

/// The PATH setup of each shell, in temporary homes only. Real files of the user are never touched.
final class ShellPathSetupTests: XCTestCase {
    private var temp: TempDirectory!
    private var home: URL!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        home = temp.url.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        temp = nil
        home = nil
    }

    private var bin: URL { home.appendingPathComponent(".claude-profiles/bin", isDirectory: true) }
    private let begin = ShellPathSetup.beginMarker
    private let end = ShellPathSetup.endMarker

    private func setup(login: String = "/bin/zsh", env: [String: String] = [:], binDir: URL? = nil) -> ShellPathSetup {
        ShellPathSetup(home: home, binDir: binDir ?? bin, loginShell: login, environment: env)
    }

    private func file(_ name: String) -> URL { home.appendingPathComponent(name) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    private func text(_ url: URL) -> String? {
        bytes(url).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func exists(_ url: URL) -> Bool {
        SafeFileSystem.kind(of: url) != .missing
    }

    private func permissions(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    private func occurrences(_ needle: String, in haystack: String?) -> Int {
        guard let haystack else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    private func assertDamaged(_ error: Error, line: UInt = #line) {
        guard let shellError = error as? ShellPathError, case .damaged = shellError else {
            return XCTFail("expected damaged, got \(error)", line: line)
        }
    }

    // MARK: - zsh

    func testInstallIntoMissingZshrcCreatesItAndRemoveDeletesItAndItsBackup() throws {
        let setup = setup()
        XCTAssertEqual(setup.status(for: .zsh), .notConfigured)

        guard case .added(let files, let backups) = try setup.install(for: .zsh) else {
            return XCTFail("expected an install")
        }
        XCTAssertEqual(files.map(\.lastPathComponent), [".zshrc"])
        XCTAssertEqual(backups.map(\.lastPathComponent), [".zshrc.claude-profiles.bak"])

        let content = try XCTUnwrap(text(file(".zshrc")))
        XCTAssertTrue(content.hasPrefix(begin + "\n"))
        XCTAssertTrue(content.contains("case \":$PATH:\" in *\":$HOME/.claude-profiles/bin:\"*) ;; *) export PATH=\"$HOME/.claude-profiles/bin:$PATH\" ;; esac"))
        XCTAssertEqual(permissions(file(".zshrc")), 0o644)
        XCTAssertEqual(setup.status(for: .zsh), .configured)

        _ = try setup.remove(for: .zsh)
        XCTAssertFalse(exists(file(".zshrc")))
        XCTAssertFalse(exists(file(".zshrc.claude-profiles.bak")))
    }

    /// Removal gives back the original bytes, for every shape of content.
    func testRemoveRestoresEveryShapeOfOriginalContentExactly() throws {
        // An empty file is not in this list: the app treats an empty file as one it created.
        let shapes = ["a", "a\n", "a\n\n\n", "a\r\n", "a\r", "\n", "# mine\nexport X=1\n\n", "héllo wörld\n"]
        for original in shapes {
            try? FileManager.default.removeItem(at: file(".zshrc"))
            try? FileManager.default.removeItem(at: file(".zshrc.claude-profiles.bak"))
            try write(original, to: file(".zshrc"))
            let setup = setup()
            _ = try setup.install(for: .zsh)
            XCTAssertEqual(setup.status(for: .zsh), .configured, "shape \(original.debugDescription)")
            _ = try setup.remove(for: .zsh)
            XCTAssertEqual(bytes(file(".zshrc")), Data(original.utf8), "shape \(original.debugDescription)")
        }
    }

    func testInstallTwiceDoesNotDuplicateTheBlock() throws {
        try write("a\n", to: file(".zshrc"))
        let setup = setup()
        _ = try setup.install(for: .zsh)
        let once = bytes(file(".zshrc"))

        XCTAssertEqual(try setup.install(for: .zsh), .alreadyConfigured(managed: true))
        XCTAssertEqual(bytes(file(".zshrc")), once)
        XCTAssertEqual(occurrences(begin, in: text(file(".zshrc"))), 1)
    }

    func testManualLineInZshrcIsConfiguredAndNeverEdited() throws {
        let original = "export PATH=\"$HOME/.claude-profiles/bin:$PATH\"\n"
        try write(original, to: file(".zshrc"))
        let setup = setup()

        XCTAssertEqual(setup.status(for: .zsh), .manual)
        XCTAssertEqual(try setup.install(for: .zsh), .alreadyConfigured(managed: false))
        XCTAssertEqual(try setup.remove(for: .zsh), [])
        XCTAssertEqual(text(file(".zshrc")), original)
        XCTAssertFalse(exists(file(".zshrc.claude-profiles.bak")))
    }

    func testManualLineInZprofileIsConfiguredAndInstallDoesNothing() throws {
        try write("export PATH=$HOME/.claude-profiles/bin:$PATH\n", to: file(".zprofile"))
        let setup = setup()

        XCTAssertEqual(setup.status(for: .zsh), .manual)
        XCTAssertEqual(try setup.install(for: .zsh), .alreadyConfigured(managed: false))
        XCTAssertFalse(exists(file(".zshrc")))
    }

    func testCommentedManualLineDoesNotCount() throws {
        try write("# export PATH=\"$HOME/.claude-profiles/bin:$PATH\"\n", to: file(".zshrc"))
        XCTAssertEqual(setup().status(for: .zsh), .notConfigured)
    }

    func testDamagedMarkersRefuseInstallAndRemoveAndLeaveTheFileAlone() throws {
        let block = begin + "\nexport X=1\n" + end + "\n"
        let cases = [
            "keep\n" + begin + "\nexport X=1\n",                   // no end marker
            "keep\n" + end + "\n",                                 // no start marker
            "keep\n" + block + block,                              // duplicated block
            "keep\n" + end + "\n" + begin + "\n",                  // wrong order
        ]
        for content in cases {
            try? FileManager.default.removeItem(at: file(".zshrc"))
            try write(content, to: file(".zshrc"))
            let setup = setup()

            XCTAssertEqual(setup.status(for: .zsh), .damaged, content.debugDescription)
            XCTAssertThrowsError(try setup.install(for: .zsh)) { self.assertDamaged($0) }
            XCTAssertThrowsError(try setup.remove(for: .zsh)) { self.assertDamaged($0) }
            XCTAssertEqual(text(file(".zshrc")), content, content.debugDescription)
            XCTAssertFalse(exists(file(".zshrc.claude-profiles.bak")))
        }
    }

    func testSymlinkedZshrcKeepsTheLinkAndEditsTheTarget() throws {
        let target = home.appendingPathComponent("dotfiles/zshrc")
        try write("keep\n", to: target)
        try FileManager.default.createSymbolicLink(at: file(".zshrc"), withDestinationURL: target)
        let setup = setup()

        _ = try setup.install(for: .zsh)
        XCTAssertEqual(SafeFileSystem.kind(of: file(".zshrc")), .link)
        XCTAssertTrue(text(target)?.hasPrefix("keep\n\n" + begin) ?? false)
        XCTAssertTrue(exists(target.deletingLastPathComponent().appendingPathComponent("zshrc.claude-profiles.bak")))

        _ = try setup.remove(for: .zsh)
        XCTAssertEqual(SafeFileSystem.kind(of: file(".zshrc")), .link)
        XCTAssertEqual(bytes(target), Data("keep\n".utf8))
    }

    func testPermissionsArePreserved() throws {
        try write("a\n", to: file(".zshrc"))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(".zshrc").path)
        let setup = setup()

        _ = try setup.install(for: .zsh)
        XCTAssertEqual(permissions(file(".zshrc")), 0o600)
        _ = try setup.remove(for: .zsh)
        XCTAssertEqual(permissions(file(".zshrc")), 0o600)
    }

    func testBackupIsMadeOnceAndKeptWhileTheFileDiffers() throws {
        try write("orig\n", to: file(".zshrc"))
        let setup = setup()
        _ = try setup.install(for: .zsh)
        XCTAssertEqual(text(file(".zshrc.claude-profiles.bak")), "orig\n")

        // The user adds a line after the block: removal no longer matches the backup, so it is kept.
        try write((text(file(".zshrc")) ?? "") + "user line\n", to: file(".zshrc"))
        _ = try setup.remove(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), "orig\nuser line\n")
        XCTAssertEqual(text(file(".zshrc.claude-profiles.bak")), "orig\n")

        // A second install never overwrites that backup.
        _ = try setup.install(for: .zsh)
        XCTAssertEqual(text(file(".zshrc.claude-profiles.bak")), "orig\n")
    }

    func testExistingBackupIsNeverOverwritten() throws {
        try write("OLD", to: file(".zshrc.claude-profiles.bak"))
        try write("new\n", to: file(".zshrc"))
        _ = try setup().install(for: .zsh)
        XCTAssertEqual(text(file(".zshrc.claude-profiles.bak")), "OLD")
    }

    func testZdotdirIsRespected() throws {
        let zdot = home.appendingPathComponent("zdot", isDirectory: true)
        let setup = setup(env: ["ZDOTDIR": zdot.path])

        _ = try setup.install(for: .zsh)
        XCTAssertTrue(exists(zdot.appendingPathComponent(".zshrc")))
        XCTAssertFalse(exists(file(".zshrc")))
    }

    func testBinOutsideHomeUsesTheAbsoluteQuotedPath() throws {
        let outside = temp.url.appendingPathComponent("elsewhere/bin", isDirectory: true)
        let setup = setup(binDir: outside)
        _ = try setup.install(for: .zsh)

        let path = outside.standardizedFileURL.path
        let content = try XCTUnwrap(text(file(".zshrc")))
        XCTAssertTrue(content.contains("case \":$PATH:\" in *':\(path):'*) ;; *) export PATH='\(path)':\"$PATH\" ;; esac"))
        XCTAssertFalse(content.contains("$HOME/"))
    }

    // MARK: - bash

    func testBashWithOnlyBashProfileEditsItAndLeavesProfileAlone() throws {
        try write("bp\n", to: file(".bash_profile"))
        _ = try setup(login: "/bin/bash").install(for: .bash)

        XCTAssertTrue(text(file(".bash_profile"))?.contains(begin) ?? false)
        XCTAssertFalse(exists(file(".profile")))
        XCTAssertFalse(exists(file(".bashrc")))
    }

    func testBashWithOnlyProfileEditsProfile() throws {
        try write("p", to: file(".profile"))
        _ = try setup(login: "/bin/bash").install(for: .bash)

        XCTAssertTrue(text(file(".profile"))?.contains(begin) ?? false)
        XCTAssertFalse(exists(file(".bash_profile")))
    }

    func testBashWithNoLoginFileCreatesBashProfile() throws {
        let setup = setup(login: "/bin/bash")
        _ = try setup.install(for: .bash)

        XCTAssertTrue(text(file(".bash_profile"))?.contains(begin) ?? false)
        XCTAssertFalse(exists(file(".profile")))
        XCTAssertEqual(setup.status(for: .bash), .configured)
    }

    func testBashrcGetsTheBlockWhenItExistsAndRemovalRestoresBoth() throws {
        try write("bp\n", to: file(".bash_profile"))
        try write("rc\n", to: file(".bashrc"))
        let setup = setup(login: "/bin/bash")

        _ = try setup.install(for: .bash)
        XCTAssertTrue(text(file(".bashrc"))?.contains(begin) ?? false)
        XCTAssertTrue(text(file(".bash_profile"))?.contains(begin) ?? false)

        _ = try setup.remove(for: .bash)
        XCTAssertEqual(text(file(".bashrc")), "rc\n")
        XCTAssertEqual(text(file(".bash_profile")), "bp\n")
    }

    // MARK: - posix (sh, ksh)

    func testProfileIsSharedByBashAndPosixWithoutDuplicates() throws {
        try write("p", to: file(".profile"))
        let bash = setup(login: "/bin/bash")
        _ = try bash.install(for: .bash)

        XCTAssertEqual(bash.status(for: .posix), .configured)
        XCTAssertEqual(try bash.install(for: .posix), .alreadyConfigured(managed: true))
        XCTAssertEqual(occurrences(begin, in: text(file(".profile"))), 1)
    }

    func testPosixCreatesProfileAndRemovalDeletesIt() throws {
        let setup = setup(login: "/bin/sh")
        _ = try setup.install(for: .posix)
        XCTAssertTrue(exists(file(".profile")))

        _ = try setup.remove(for: .posix)
        XCTAssertFalse(exists(file(".profile")))
        XCTAssertFalse(exists(file(".profile.claude-profiles.bak")))
    }

    // MARK: - fish

    private var fishFileURL: URL {
        home.appendingPathComponent(".config/fish/conf.d/claude-profiles.fish")
    }

    func testFishGetsADedicatedFileAndRemovalDeletesOnlyIt() throws {
        let setup = setup(login: "/opt/homebrew/bin/fish")
        let other = home.appendingPathComponent(".config/fish/conf.d/other.fish")
        try write("set -x KEEP 1\n", to: other)

        _ = try setup.install(for: .fish)
        let content = try XCTUnwrap(text(fishFileURL))
        XCTAssertTrue(content.hasPrefix(begin + "\n"))
        XCTAssertTrue(content.contains("fish_add_path -g \"$HOME/.claude-profiles/bin\""))
        XCTAssertTrue(content.contains("set -gx PATH"))
        XCTAssertEqual(setup.status(for: .fish), .configured)

        _ = try setup.remove(for: .fish)
        XCTAssertFalse(exists(fishFileURL))
        XCTAssertEqual(text(other), "set -x KEEP 1\n")
    }

    func testFishRefusesAForeignFileWithTheSameName() throws {
        let setup = setup(login: "/usr/bin/fish")
        try write("set -x FOREIGN 1\n", to: fishFileURL)

        XCTAssertEqual(setup.status(for: .fish), .damaged)
        XCTAssertThrowsError(try setup.install(for: .fish)) { self.assertDamaged($0) }
        XCTAssertThrowsError(try setup.remove(for: .fish)) { self.assertDamaged($0) }
        XCTAssertEqual(text(fishFileURL), "set -x FOREIGN 1\n")
    }

    func testFishHonoursXdgConfigHome() throws {
        let xdg = temp.url.appendingPathComponent("xdg", isDirectory: true)
        let setup = setup(login: "/usr/bin/fish", env: ["XDG_CONFIG_HOME": xdg.path])

        _ = try setup.install(for: .fish)
        XCTAssertTrue(exists(xdg.appendingPathComponent("fish/conf.d/claude-profiles.fish")))
        XCTAssertFalse(exists(home.appendingPathComponent(".config")))
    }

    // MARK: - Every shell, unsupported shells, manual lines

    func testInstallForEveryShellThenRemoveRestoresEveryFileExactly() throws {
        try write("z", to: file(".zshrc"))
        try write("bp\n", to: file(".bash_profile"))
        try write("rc\n", to: file(".bashrc"))
        try write("p", to: file(".profile"))
        let setup = setup(login: "/bin/zsh")

        for shell in ShellKind.supported {
            _ = try setup.install(for: shell)
        }
        for shell in ShellKind.supported {
            XCTAssertEqual(setup.status(for: shell), .configured, "\(shell)")
        }

        let changed = try setup.removeEverything()
        XCTAssertFalse(changed.isEmpty)
        XCTAssertEqual(text(file(".zshrc")), "z")
        XCTAssertEqual(text(file(".bash_profile")), "bp\n")
        XCTAssertEqual(text(file(".bashrc")), "rc\n")
        XCTAssertEqual(text(file(".profile")), "p")
        XCTAssertFalse(exists(home.appendingPathComponent(".config/fish/conf.d/claude-profiles.fish")))
        for shell in ShellKind.supported {
            XCTAssertEqual(setup.status(for: shell), .notConfigured, "\(shell)")
        }
        XCTAssertEqual(setup.managedFiles(), [])
    }

    func testRemoveEverythingKeepsManualLines() throws {
        let manual = "export PATH=\"$HOME/.claude-profiles/bin:$PATH\"\n"
        try write(manual, to: file(".zprofile"))
        let setup = setup()
        _ = try setup.install(for: .posix)

        _ = try setup.removeEverything()
        XCTAssertEqual(text(file(".zprofile")), manual)
    }

    func testUnsupportedShellWritesNothingAndGivesTheManualLine() throws {
        let setup = setup(login: "/opt/homebrew/bin/nu")
        XCTAssertEqual(setup.loginStatus(), .unsupported)
        XCTAssertThrowsError(try setup.install(for: setup.loginKind)) { error in
            XCTAssertEqual(error as? ShellPathError, .unsupported)
        }
        XCTAssertFalse(exists(file(".zshrc")))
        XCTAssertFalse(exists(file(".profile")))

        XCTAssertEqual(
            setup.manualLine(for: .nushell),
            "$env.PATH = ($env.PATH | prepend ($nu.home-path | path join \".claude-profiles\" \"bin\"))"
        )
        XCTAssertEqual(setup.manualLine(for: .csh), "setenv PATH \"$HOME/.claude-profiles/bin:$PATH\"")
        XCTAssertEqual(setup.manualLine(for: .fish), "fish_add_path -g \"$HOME/.claude-profiles/bin\"")
        XCTAssertEqual(setup.manualLine(for: .zsh), "export PATH=\"$HOME/.claude-profiles/bin:$PATH\"")
        XCTAssertEqual(setup.manualLine(for: .other("elvish")), bin.standardizedFileURL.path)
    }

    func testShellKindFromLoginShellPath() {
        XCTAssertEqual(ShellKind.from(loginShell: "/bin/zsh"), .zsh)
        XCTAssertEqual(ShellKind.from(loginShell: "/bin/bash"), .bash)
        XCTAssertEqual(ShellKind.from(loginShell: "/usr/local/bin/fish"), .fish)
        XCTAssertEqual(ShellKind.from(loginShell: "/bin/sh"), .posix)
        XCTAssertEqual(ShellKind.from(loginShell: "/bin/dash"), .posix)
        XCTAssertEqual(ShellKind.from(loginShell: "/bin/tcsh"), .csh)
        XCTAssertEqual(ShellKind.from(loginShell: "/opt/homebrew/bin/nu"), .nushell)
        XCTAssertEqual(ShellKind.from(loginShell: "/usr/bin/elvish"), .other("elvish"))
    }

    // MARK: - Empty shared folders

    func testEmptyBinAndHomesFoldersAreRemovedButNotTheRootOrFullFolders() throws {
        let paths = temp.paths(home: home)
        let store = Store(paths: paths, keys: InMemoryKeyStore())
        let manager = FileManager.default
        try manager.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        try manager.createDirectory(at: paths.homesDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: paths.dataFile)

        store.removeEmptySharedFolders()
        XCTAssertFalse(exists(paths.binDir))
        XCTAssertFalse(exists(paths.homesDir))
        XCTAssertTrue(exists(paths.root), "the root stays")
        XCTAssertTrue(exists(paths.dataFile))

        // A folder with content stays.
        try manager.createDirectory(at: paths.homesDir.appendingPathComponent("alice"), withIntermediateDirectories: true)
        try manager.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: paths.binDir.appendingPathComponent("claude-x"))
        store.removeEmptySharedFolders()
        XCTAssertTrue(exists(paths.homesDir.appendingPathComponent("alice")))
        XCTAssertTrue(exists(paths.binDir.appendingPathComponent("claude-x")))
    }
}
