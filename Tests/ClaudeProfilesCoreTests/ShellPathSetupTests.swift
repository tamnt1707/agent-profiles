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
        // A file the app creates gets no backup: its record says so.
        XCTAssertEqual(backups, [])

        let content = try XCTUnwrap(text(file(".zshrc")))
        XCTAssertTrue(content.hasPrefix(begin + "\n"))
        XCTAssertTrue(content.contains("case \":${PATH-}:\" in *\":$HOME/.claude-profiles/bin:\"*) ;; *) export PATH=\"$HOME/.claude-profiles/bin${PATH:+:$PATH}\" ;; esac"))
        XCTAssertEqual(permissions(file(".zshrc")), 0o644)
        XCTAssertEqual(setup.status(for: .zsh), .configured)

        _ = try setup.remove(for: .zsh)
        XCTAssertFalse(exists(file(".zshrc")))
        XCTAssertFalse(exists(file(".zshrc.claude-profiles.bak")))
    }

    /// Removal gives back the original bytes, for every shape of content.
    func testRemoveRestoresEveryShapeOfOriginalContentExactly() throws {
        // An empty file is in the list too: it existed before, so it stays (empty) after removal.
        let shapes = [
            "", "a", "a\n", "a\n\n\n", "a\r\n", "a\r", "\n", "# mine\nexport X=1\n\n", "héllo wörld\n",
            "a\r\nb\r\n", "a\r\nb\n", "a\nb\r\n", "\r", "\r\n", "\r\n\n", "a\r\n\r\n", "echo a\r\nb\nc\n",
        ]
        for original in shapes {
            try? FileManager.default.removeItem(at: file(".zshrc"))
            try? FileManager.default.removeItem(at: file(".zshrc.claude-profiles.bak"))
            try write(original, to: file(".zshrc"))
            let setup = setup()
            _ = try setup.install(for: .zsh)
            XCTAssertEqual(setup.status(for: .zsh), .configured, "shape \(original.debugDescription)")
            _ = try setup.remove(for: .zsh)
            XCTAssertEqual(bytes(file(".zshrc")), Data(original.utf8), "shape \(original.debugDescription)")
            XCTAssertFalse(exists(file(".zshrc.claude-profiles.bak")), "backup cleaned up, shape \(original.debugDescription)")
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
        // The blank line that install added stays behind.
        XCTAssertEqual(text(file(".zshrc")), "orig\n\nuser line\n")
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
        XCTAssertTrue(content.contains("case \":${PATH-}:\" in *':\(path):'*) ;; *) export PATH='\(path)'\"${PATH:+:$PATH}\" ;; esac"))
        XCTAssertFalse(content.contains("$HOME/"))
    }

    /// A folder name that ends in a line feed is not "home relative": `$` in a regular
    /// expression would match before that line feed, so the anchor is `\z`.
    func testBinFolderNameWithATrailingLineFeedUsesTheAbsoluteQuotedPath() throws {
        let odd = home.appendingPathComponent(".claude-profiles/bin\n", isDirectory: true)
        let setup = setup(binDir: odd)
        _ = try setup.install(for: .zsh)

        let content = try XCTUnwrap(text(file(".zshrc")))
        XCTAssertFalse(content.contains("$HOME/.claude-profiles/bin\n"))
        XCTAssertTrue(content.contains("export PATH=" + ShellQuote.quote(odd.standardizedFileURL.path)))
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

        let report = setup.removeEverything()
        XCTAssertFalse(report.changed.isEmpty)
        XCTAssertEqual(report.skipped, [])
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

        _ = setup.removeEverything()
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
        XCTAssertEqual(setup.manualLine(for: .zsh), "export PATH=\"$HOME/.claude-profiles/bin${PATH:+:$PATH}\"")
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

    // MARK: - Removal keeps the user's lines (I1)

    /// The body the app writes now, and the body the earlier version wrote.
    private let body = "case \":${PATH-}:\" in *\":$HOME/.claude-profiles/bin:\"*) ;; *) export PATH=\"$HOME/.claude-profiles/bin${PATH:+:$PATH}\" ;; esac\n"
    private let legacyBody = "case \":$PATH:\" in *\":$HOME/.claude-profiles/bin:\"*) ;; *) export PATH=\"$HOME/.claude-profiles/bin:$PATH\" ;; esac\n"
    private var block: String { begin + "\n" + body + end + "\n" }

    func testContentAfterTheBlockWithoutTrailingNewlineKeepsTheLinesApart() throws {
        try write("a", to: file(".zshrc"))
        let setup = setup()
        _ = try setup.install(for: .zsh)
        try write((text(file(".zshrc")) ?? "") + "export B=2\n", to: file(".zshrc"))

        _ = try setup.remove(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), "a\nexport B=2\n")
    }

    func testContentAfterTheBlockWithTrailingNewlineLeavesOnlyTheBlankLine() throws {
        try write("a\n", to: file(".zshrc"))
        let setup = setup()
        _ = try setup.install(for: .zsh)
        try write((text(file(".zshrc")) ?? "") + "export B=2\n", to: file(".zshrc"))

        _ = try setup.remove(for: .zsh)
        // The blank line install added stays: a leftover blank line is fine, a joined line is not.
        XCTAssertEqual(text(file(".zshrc")), "a\n\nexport B=2\n")
    }

    func testBlockMovedByHandBetweenTwoUserLinesIsRemovedWithoutJoiningThem() throws {
        try write("A=1\n" + block + "B=2\n", to: file(".zshrc"))
        let setup = setup()
        XCTAssertEqual(setup.status(for: .zsh), .configured)

        _ = try setup.remove(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), "A=1\nB=2\n")
    }

    func testEmptyOriginalFileSurvivesInstallAndRemoveAndIsNeverDeleted() throws {
        try write("", to: file(".zshrc"))
        let setup = setup()
        _ = try setup.install(for: .zsh)
        XCTAssertEqual(setup.status(for: .zsh), .configured)

        _ = try setup.remove(for: .zsh)
        XCTAssertTrue(exists(file(".zshrc")), "a file that existed before install stays")
        XCTAssertEqual(bytes(file(".zshrc")), Data())
        XCTAssertFalse(exists(file(".zshrc.claude-profiles.bak")), "the backup of an unchanged file is cleaned up")
    }

    // MARK: - Only files the app created are deleted (I2)

    /// The files listed as created in `path-setup.json`.
    private func createdRecord() -> [String] {
        let record = home.appendingPathComponent(".claude-profiles/path-setup.json")
        guard let data = bytes(record),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return object["created"] as? [String] ?? []
    }

    func testCreatedFileIsListedInTheDataFolderAndForgottenOnRemove() throws {
        let setup = setup()
        _ = try setup.install(for: .zsh)
        XCTAssertEqual(createdRecord(), [file(".zshrc").path])

        _ = try setup.remove(for: .zsh)
        XCTAssertFalse(exists(file(".zshrc")))
        XCTAssertEqual(createdRecord(), [])
    }

    func testFileEmptiedByTheUserIsNotDeletedUnlessRecordedAsCreated() throws {
        // Only the block is left, and the app did not create this file: it is emptied, never deleted.
        try write(block, to: file(".zshrc"))

        _ = try setup().remove(for: .zsh)
        XCTAssertTrue(exists(file(".zshrc")))
        XCTAssertEqual(bytes(file(".zshrc")), Data())
    }

    func testAnUnreadableRecordCountsAsEmptyAndDeletesNothing() throws {
        try write("not json", to: home.appendingPathComponent(".claude-profiles/path-setup.json"))
        try write(block, to: file(".zshrc"))

        _ = try setup().remove(for: .zsh)
        XCTAssertTrue(exists(file(".zshrc")))
    }

    func testEmptyBashProfileThatShadowsProfileIsNeverDeleted() throws {
        // bash reads .bash_profile first: deleting an empty one would change what bash runs.
        try write("", to: file(".bash_profile"))
        try write("p\n", to: file(".profile"))
        let setup = setup(login: "/bin/bash")

        _ = try setup.install(for: .bash)
        _ = try setup.remove(for: .bash)
        XCTAssertTrue(exists(file(".bash_profile")))
        XCTAssertEqual(bytes(file(".bash_profile")), Data())
        XCTAssertEqual(text(file(".profile")), "p\n")
    }

    func testCreatedFileIsKeptWhenTheUserWroteIntoIt() throws {
        let setup = setup()
        _ = try setup.install(for: .zsh)
        try write(block + "export B=2\n", to: file(".zshrc"))

        _ = try setup.remove(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), "export B=2\n")
    }

    // MARK: - Ownership of the block (I3)

    func testCustomisedBlockBodyIsDamagedAndNeverEdited() throws {
        let content = "keep\n" + begin + "\nexport X=1\n" + end + "\n"
        try write(content, to: file(".zshrc"))
        let setup = setup()

        XCTAssertEqual(setup.status(for: .zsh), .damaged)
        XCTAssertThrowsError(try setup.install(for: .zsh)) { self.assertDamaged($0) }
        XCTAssertThrowsError(try setup.remove(for: .zsh)) { self.assertDamaged($0) }
        XCTAssertEqual(text(file(".zshrc")), content)
    }

    func testIndentedMarkersAreUserTextAndNeverRemoved() throws {
        let original = "  \(begin)\nexport X=1\n  \(end)\n"
        try write(original, to: file(".zshrc"))
        let setup = setup()

        XCTAssertEqual(setup.status(for: .zsh), .notConfigured)
        _ = try setup.install(for: .zsh)
        XCTAssertEqual(setup.status(for: .zsh), .configured)
        _ = try setup.remove(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), original)
    }

    func testMarkersInsideAHereDocAreDamagedAndUntouched() throws {
        let content = "cat <<'EOF'\n\(begin)\nhello\n\(end)\nEOF\n"
        try write(content, to: file(".zshrc"))
        let setup = setup()

        XCTAssertEqual(setup.status(for: .zsh), .damaged)
        XCTAssertThrowsError(try setup.install(for: .zsh)) { self.assertDamaged($0) }
        XCTAssertThrowsError(try setup.remove(for: .zsh)) { self.assertDamaged($0) }
        XCTAssertEqual(text(file(".zshrc")), content)
    }

    func testMarkerLinesEndingInCRLFAreRecognisedWithTheSameBody() throws {
        try write("a\n\n" + begin + "\r\n" + body + end + "\r\n", to: file(".zshrc"))
        let setup = setup()

        XCTAssertEqual(setup.status(for: .zsh), .configured)
        _ = try setup.remove(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), "a\n")
    }

    func testLegacyBlockBodyIsStillConfiguredAndRemovable() throws {
        try write("a\n\n" + begin + "\n" + legacyBody + end + "\n", to: file(".zshrc"))
        let setup = setup()

        XCTAssertEqual(setup.status(for: .zsh), .configured)
        XCTAssertEqual(try setup.install(for: .zsh), .alreadyConfigured(managed: true))
        _ = try setup.remove(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), "a\n")
    }

    // MARK: - Links that lead nowhere (M1)

    func testDanglingSymlinkNamesTheLinkInEveryCall() throws {
        try FileManager.default.createSymbolicLink(
            at: file(".zshrc"),
            withDestinationURL: home.appendingPathComponent("missing/zshrc")
        )
        let setup = setup()

        XCTAssertEqual(setup.status(for: .zsh), .damaged)
        XCTAssertThrowsError(try setup.install(for: .zsh)) { error in
            XCTAssertEqual(error as? ShellPathError, .brokenLink(self.file(".zshrc").path))
        }
        XCTAssertThrowsError(try setup.remove(for: .zsh)) { error in
            XCTAssertEqual(error as? ShellPathError, .brokenLink(self.file(".zshrc").path))
        }
        XCTAssertEqual(SafeFileSystem.kind(of: file(".zshrc")), .link)
    }

    func testLoopingSymlinkNamesTheLink() throws {
        try FileManager.default.createSymbolicLink(at: file(".zshrc"), withDestinationURL: file(".zshrc"))
        let setup = setup()

        XCTAssertEqual(setup.status(for: .zsh), .damaged)
        XCTAssertThrowsError(try setup.install(for: .zsh)) { error in
            XCTAssertEqual(error as? ShellPathError, .brokenLink(self.file(".zshrc").path))
        }
    }

    // MARK: - Files that cannot be written (M4, M12)

    func testReadOnlyFileIsRefusedAndNeverReplaced() throws {
        try write("a\n", to: file(".zshrc"))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file(".zshrc").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file(".zshrc").path) }
        let setup = setup()

        XCTAssertThrowsError(try setup.install(for: .zsh)) { error in
            XCTAssertEqual(error as? ShellPathError, .notWritable(self.file(".zshrc").path))
        }
        XCTAssertEqual(text(file(".zshrc")), "a\n")
        XCTAssertFalse(exists(file(".zshrc.claude-profiles.bak")))
        XCTAssertEqual(setup.status(for: .zsh), .notConfigured)
    }

    func testReadOnlyFolderLeavesNoPartialStateAndNoTemporaryFile() throws {
        let zdot = home.appendingPathComponent("zdot", isDirectory: true)
        try write("a\n", to: zdot.appendingPathComponent(".zshrc"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: zdot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: zdot.path) }
        let setup = setup(env: ["ZDOTDIR": zdot.path])

        XCTAssertThrowsError(try setup.install(for: .zsh)) { error in
            XCTAssertEqual(error as? ShellPathError, .notWritable(zdot.path))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: zdot.path), [".zshrc"])
        XCTAssertEqual(text(zdot.appendingPathComponent(".zshrc")), "a\n")
        XCTAssertFalse(exists(home.appendingPathComponent(".claude-profiles/path-setup.json")))
    }

    /// A rename gives the dotfile a new inode, so the other name of a hard link keeps the old
    /// content. That is expected: the setup still works and nothing else is wrong.
    func testHardLinkedDotfileStillWorksAndTheOtherNameKeepsItsOldContent() throws {
        let other = home.appendingPathComponent("dotfiles/zshrc")
        try write("keep\n", to: other)
        try FileManager.default.linkItem(at: other, to: file(".zshrc"))
        let setup = setup()

        _ = try setup.install(for: .zsh)
        XCTAssertEqual(setup.status(for: .zsh), .configured)
        XCTAssertEqual(text(other), "keep\n")

        _ = try setup.remove(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), "keep\n")
        XCTAssertEqual(setup.status(for: .zsh), .notConfigured)
    }

    // MARK: - A file changed while it is edited (I6)

    func testFileChangedOnceIsReadAgainAndEditedOnce() throws {
        try write("orig\n", to: file(".zshrc"))
        var setup = setup()
        setup.stagingHook = { url, attempt in
            if attempt == 0 { try? Data("changed\n".utf8).write(to: url, options: .atomic) }
        }

        _ = try setup.install(for: .zsh)
        XCTAssertTrue(text(file(".zshrc"))?.hasPrefix("changed\n\n" + begin) ?? false)
        XCTAssertEqual(text(file(".zshrc.claude-profiles.bak")), "changed\n")
    }

    func testFileChangedTwiceThrowsAndWritesNothing() throws {
        try write("orig\n", to: file(".zshrc"))
        var setup = setup()
        setup.stagingHook = { url, attempt in
            try? Data("changed-\(attempt)\n".utf8).write(to: url, options: .atomic)
        }

        XCTAssertThrowsError(try setup.install(for: .zsh)) { error in
            XCTAssertEqual(error as? ShellPathError, .changedWhileEditing)
        }
        XCTAssertEqual(text(file(".zshrc")), "changed-1\n")
        XCTAssertFalse(exists(file(".zshrc.claude-profiles.bak")))
        // Staged names are "..zshrc.<pid>.<uuid>.tmp": a leftover is one of those.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: home.path)
            .filter { $0.hasPrefix("..zshrc.") && $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    // MARK: - ZDOTDIR and XDG_CONFIG_HOME (I4, I5)

    func testRelativeEmptyAndBrokenEnvironmentValuesAreIgnored() throws {
        for value in ["relative/zdot", "", "./here", "/abs\nnewline"] {
            let setup = setup(env: ["ZDOTDIR": value, "XDG_CONFIG_HOME": value])
            _ = try setup.install(for: .zsh)
            _ = try setup.install(for: .fish)
            XCTAssertTrue(exists(file(".zshrc")), value.debugDescription)
            XCTAssertTrue(exists(fishFileURL), value.debugDescription)

            _ = try setup.remove(for: .zsh)
            _ = try setup.remove(for: .fish)
            XCTAssertFalse(exists(file(".zshrc")), value.debugDescription)
            XCTAssertFalse(exists(fishFileURL), value.debugDescription)
        }
    }

    func testZdotdirFromZshenvIsUsedInEachSimpleForm() throws {
        let zdotA = home.appendingPathComponent("zdot-a", isDirectory: true)
        let zdotB = home.appendingPathComponent("zdot-b", isDirectory: true)
        let zdotC = home.appendingPathComponent("zdot-c", isDirectory: true)
        let zdotD = temp.url.appendingPathComponent("zdot-d", isDirectory: true)
        let cases: [(line: String, folder: URL)] = [
            ("export ZDOTDIR=\"$HOME/zdot-a\"", zdotA),
            ("ZDOTDIR=${HOME}/zdot-b", zdotB),
            ("ZDOTDIR=~/zdot-c", zdotC),
            ("export ZDOTDIR=\(zdotD.path)", zdotD),
        ]
        for (line, folder) in cases {
            try write(line + "\n", to: file(".zshenv"))
            let setup = setup()
            _ = try setup.install(for: .zsh)

            XCTAssertEqual(setup.status(for: .zsh), .configured, line)
            XCTAssertTrue(exists(folder.appendingPathComponent(".zshrc")), line)
            XCTAssertFalse(exists(file(".zshrc")), "home/.zshrc is not read when ZDOTDIR moves it: \(line)")
            _ = try setup.remove(for: .zsh)
            XCTAssertFalse(exists(folder.appendingPathComponent(".zshrc")), line)
        }
    }

    func testZdotdirThatCannotBeReadIsReportedAndNothingIsEdited() throws {
        let content = "ZDOTDIR=$(echo \(home.path)/x)\n"
        try write(content, to: file(".zshenv"))
        let setup = setup()

        XCTAssertEqual(setup.status(for: .zsh), .unresolvedZdotdir)
        XCTAssertThrowsError(try setup.install(for: .zsh)) { error in
            XCTAssertEqual(error as? ShellPathError, .zdotdirUnresolved(self.file(".zshenv").path))
        }
        XCTAssertThrowsError(try setup.remove(for: .zsh))
        XCTAssertFalse(exists(file(".zshrc")))
        XCTAssertEqual(text(file(".zshenv")), content)
    }

    func testManualLineIsLookedForWhereInstallWrites() throws {
        let zdot = home.appendingPathComponent("zdot", isDirectory: true)
        let manual = "export PATH=\"$HOME/.claude-profiles/bin${PATH:+:$PATH}\"\n"
        try write(manual, to: zdot.appendingPathComponent(".zprofile"))
        try write(manual, to: file(".zprofile"))
        let setup = setup(env: ["ZDOTDIR": zdot.path])
        XCTAssertEqual(setup.status(for: .zsh), .manual)

        // zsh does not read the home .zprofile when ZDOTDIR points elsewhere.
        try FileManager.default.removeItem(at: zdot.appendingPathComponent(".zprofile"))
        XCTAssertEqual(setup.status(for: .zsh), .notConfigured)
    }

    // MARK: - Remaining cases

    func testOnePartOfABashSetupIsPartlyConfiguredAndInstallCompletesIt() throws {
        try write("bp\n", to: file(".bash_profile"))
        try write("rc\n", to: file(".bashrc"))
        let setup = setup(login: "/bin/bash")
        _ = try setup.install(for: .bash)
        try write("rc\n", to: file(".bashrc"))

        XCTAssertEqual(setup.status(for: .bash), .partlyConfigured)
        _ = try setup.install(for: .bash)
        XCTAssertEqual(setup.status(for: .bash), .configured)
    }

    func testRemoveEverythingLeavesDamagedFilesAloneAndRemovesTheRest() throws {
        let damaged = "keep\n" + begin + "\nexport X=1\n"
        try write(damaged, to: file(".zshrc"))
        try write("p\n", to: file(".profile"))
        let setup = setup()
        _ = try setup.install(for: .posix)

        let report = setup.removeEverything()
        XCTAssertEqual(report.changed.map(\.lastPathComponent), [".profile"])
        XCTAssertEqual(report.skipped.map(\.url.lastPathComponent), [".zshrc"])
        XCTAssertEqual(report.skipped.first?.reason, .damaged(file(".zshrc").path))
        XCTAssertEqual(text(file(".zshrc")), damaged)
        XCTAssertEqual(text(file(".profile")), "p\n")
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

    // MARK: - Relative ZDOTDIR never resolves against the current folder (M-A)

    func testRelativeZdotdirIsUnresolvedAndNothingIsResolvedAgainstTheCurrentFolder() throws {
        let cwd = temp.url.appendingPathComponent("cwd", isDirectory: true)
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let original = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(cwd.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(original) }

        for line in ["ZDOTDIR=zsh", "ZDOTDIR=./z", "ZDOTDIR=../z", "export ZDOTDIR=zsh"] {
            try write(line + "\n", to: file(".zshenv"))
            let setup = setup()
            XCTAssertEqual(setup.status(for: .zsh), .unresolvedZdotdir, line)
            XCTAssertThrowsError(try setup.install(for: .zsh), line) { error in
                XCTAssertEqual(error as? ShellPathError, .zdotdirUnresolved(self.file(".zshenv").path))
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cwd.path), [], line)
            XCTAssertEqual(text(file(".zshenv")), line + "\n", line)
        }
    }

    // MARK: - Only one plain top-level ZDOTDIR assignment is read (M-C)

    func testZdotdirInAnyOtherShapeIsUnresolvedAndNothingIsEdited() throws {
        let zdot = home.path + "/zdot"
        let zdot2 = home.path + "/zdot2"
        let rejected = [
            "if [ -d /x ]; then\n  ZDOTDIR=\(zdot)\nfi\n",
            "case $HOST in\n  a) ZDOTDIR=\(zdot) ;;\nesac\n",
            "for d in /x; do\n  ZDOTDIR=$d\ndone\n",
            "while false; do ZDOTDIR=\(zdot); done\n",
            "f() {\n  ZDOTDIR=\(zdot)\n}\nf\n",
            "{ ZDOTDIR=\(zdot); }\n",
            "cat <<'EOF'\nZDOTDIR=\(zdot)\nEOF\n",
            "ZDOTDIR=\(zdot)\nunset ZDOTDIR\n",
            "ZDOTDIR=\(zdot)\nZDOTDIR=\(zdot2)\n",
            "[ -z \"$ZDOTDIR\" ] && ZDOTDIR=\(zdot)\n",
            ": ${ZDOTDIR:=\(zdot)}\n",
            "typeset ZDOTDIR=\(zdot)\n",
            "export ZDOTDIR\n",
        ]
        for content in rejected {
            try write(content, to: file(".zshenv"))
            let setup = setup()
            XCTAssertEqual(setup.status(for: .zsh), .unresolvedZdotdir, content.debugDescription)
            XCTAssertThrowsError(try setup.install(for: .zsh), content.debugDescription) { error in
                XCTAssertEqual(error as? ShellPathError, .zdotdirUnresolved(self.file(".zshenv").path))
            }
            XCTAssertFalse(exists(file(".zshrc")), content.debugDescription)
            XCTAssertFalse(exists(URL(fileURLWithPath: zdot).appendingPathComponent(".zshrc")), content.debugDescription)
            XCTAssertEqual(text(file(".zshenv")), content, content.debugDescription)
        }
    }

    func testSingleTopLevelZdotdirAssignmentIsStillReadAmongOtherLines() throws {
        let zdot = home.appendingPathComponent("zdot", isDirectory: true)
        let accepted = [
            "if true; then\n  echo hi\nfi\nexport ZDOTDIR=\(zdot.path)\n",
            "# ZDOTDIR=/nowhere\nZDOTDIR=\(zdot.path)\n",
            "export ZDOTDIR=\"$HOME/zdot\"\n",
            "ZDOTDIR=\(zdot.path)\nif true; then\n  echo hi\nfi\n",
        ]
        for content in accepted {
            try write(content, to: file(".zshenv"))
            let setup = setup()
            _ = try setup.install(for: .zsh)
            XCTAssertEqual(setup.status(for: .zsh), .configured, content.debugDescription)
            XCTAssertTrue(exists(zdot.appendingPathComponent(".zshrc")), content.debugDescription)
            _ = try setup.remove(for: .zsh)
            XCTAssertFalse(exists(zdot.appendingPathComponent(".zshrc")), content.debugDescription)
            try FileManager.default.removeItem(at: zdot)
        }
    }

    // MARK: - CRLF files and the damaged message (M-B, M-E)

    private var crlfBlock: String { block.replacingOccurrences(of: "\n", with: "\r\n") }

    /// Our block always has LF line ends: a CRLF block cannot run in a shell.
    func testCRLFFileGetsAnLFBlockAndRemovesToTheOriginalBytes() throws {
        try write("a\r\n", to: file(".zshrc"))
        let setup = setup()

        _ = try setup.install(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), "a\r\n\n" + block)
        XCTAssertEqual(setup.status(for: .zsh), .configured)

        _ = try setup.remove(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), "a\r\n")
    }

    /// A mixed-ending file gets an LF block too, so every shell reads the block (see the runtime tests).
    func testMixedEndingFileGetsAnLFBlockAndRemovesToTheOriginalBytes() throws {
        let original = "echo a\r\nb\nc\n"
        try write(original, to: file(".zshrc"))
        let setup = setup()

        _ = try setup.install(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), original + "\n" + block)
        XCTAssertEqual(setup.status(for: .zsh), .configured)

        _ = try setup.remove(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), original)
    }

    /// A file ending in a bare CR gets exactly one LF after that CR, never a CRLF.
    func testBareCRFileGetsOneLineFeedAfterTheCRAndRemovesBack() throws {
        try write("a\r", to: file(".zshrc"))
        let setup = setup()

        _ = try setup.install(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), "a\r\n" + block)
        XCTAssertEqual(setup.status(for: .zsh), .configured)

        _ = try setup.remove(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), "a\r")
    }

    /// A block that a Windows editor turned into CRLF, after an LF line, is removed without a stray CR.
    func testWindowsEditedBlockAfterAnLFLineIsRemovedCleanly() throws {
        try write("foo\n" + crlfBlock, to: file(".zshrc"))
        _ = try setup().remove(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), "foo")
    }

    func testBlockEditedOnWindowsWithCRLFEverywhereIsRecognisedAndRemovable() throws {
        try write("a\r\n\r\n" + crlfBlock + "b\r\n", to: file(".zshrc"))
        let setup = setup()

        XCTAssertEqual(setup.status(for: .zsh), .configured)
        _ = try setup.remove(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), "a\r\n\r\nb\r\n")
    }

    func testCRLFBlockInTheMiddleKeepsBothSidesIntact() throws {
        try write("a\r\n" + crlfBlock + "b\r\n", to: file(".zshrc"))
        _ = try setup().remove(for: .zsh)
        XCTAssertEqual(text(file(".zshrc")), "a\r\nb\r\n")
    }

    func testCRLFBlockAtTheEndTakesTheLineEndingAsAPair() throws {
        try write("foo\r\n" + crlfBlock, to: file(".zshrc"))
        _ = try setup().remove(for: .zsh)
        // The CR and the LF before the block go together: never a lone CR left behind.
        XCTAssertEqual(text(file(".zshrc")), "foo")
    }

    func testDamagedFileIsNamedSoTheUserKnowsWhichToFix() throws {
        try write("keep\n" + begin + "\nexport X=1\n" + end + "\n", to: file(".zshrc"))
        let setup = setup()
        XCTAssertEqual(setup.damagedFile(for: .zsh)?.path, file(".zshrc").path)
        XCTAssertNil(setup.damagedFile(for: .posix))
    }

    // MARK: - Partial installs say what was already changed (M-D)

    func testPartialInstallReportsTheFilesAlreadyChangedAndKeepsThem() throws {
        try write("bp\n", to: file(".bash_profile"))
        try write("rc\n", to: file(".bashrc"))
        var setup = setup(login: "/bin/bash")
        setup.stagingHook = { url, attempt in
            if url.lastPathComponent == ".bashrc" {
                try? Data("changed-\(attempt)\n".utf8).write(to: url, options: .atomic)
            }
        }

        XCTAssertThrowsError(try setup.install(for: .bash)) { error in
            XCTAssertEqual(
                error as? ShellPathError,
                .partial(changed: [self.file(".bash_profile").path], reason: .changedWhileEditing)
            )
        }
        XCTAssertEqual(occurrences(begin, in: text(file(".bash_profile"))), 1)
        XCTAssertEqual(text(file(".bashrc")), "changed-1\n")
        // The changed file can be undone with Remove.
        let removed = try self.setup(login: "/bin/bash").remove(for: .bash)
        XCTAssertEqual(removed.map(\.lastPathComponent), [".bash_profile"])
        XCTAssertEqual(text(file(".bash_profile")), "bp\n")
    }

    // MARK: - The record is written before a file is created (M-H)

    private var recordPath: String { home.appendingPathComponent(".claude-profiles/path-setup.json").path }

    func testRecordWriteFailureBeforeCreationLeavesNoFileBehind() throws {
        var setup = setup()
        setup.recordWriteHook = { throw CocoaError(.fileWriteUnknown) }

        XCTAssertThrowsError(try setup.install(for: .zsh)) { error in
            XCTAssertEqual(error as? ShellPathError, .ioFailed(self.recordPath))
        }
        XCTAssertFalse(exists(file(".zshrc")))
    }

    func testRecordEntryIsDroppedAgainWhenTheCreationFails() throws {
        var setup = setup()
        setup.stagingHook = { url, _ in
            // Remove the staged file so the rename that creates the file fails.
            let folder = url.deletingLastPathComponent()
            // Staged names are "..zshrc.<pid>.<uuid>.tmp" (a dot, then the target's name).
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.hasPrefix("..zshrc.") && name.hasSuffix(".tmp") {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }

        XCTAssertThrowsError(try setup.install(for: .zsh)) { error in
            XCTAssertEqual(error as? ShellPathError, .ioFailed(self.file(".zshrc").path))
        }
        XCTAssertFalse(exists(file(".zshrc")))
        XCTAssertFalse(createdRecord().contains(file(".zshrc").path), "a file that was not created is not recorded")
    }

    func testRecordWriteFailureOnRemovalIsReportedAndTheOtherFilesAreStillRemoved() throws {
        let setup = setup()
        _ = try setup.install(for: .zsh)
        _ = try setup.install(for: .posix)
        var failing = setup
        failing.recordWriteHook = { throw CocoaError(.fileWriteUnknown) }

        let report = failing.removeEverything()
        XCTAssertEqual(Set(report.changed.map(\.lastPathComponent)), [".zshrc", ".profile"])
        XCTAssertFalse(exists(file(".zshrc")))
        XCTAssertFalse(exists(file(".profile")))
        XCTAssertEqual(report.skipped.map { $0.url.path }, [recordPath])
        XCTAssertEqual(report.skipped.first?.reason, .ioFailed(recordPath))
    }

    // MARK: - Removal reports only what had our block (M-G)

    func testRemoveEverythingSaysNothingAboutAFileThatNeverHadTheBlock() throws {
        try FileManager.default.createSymbolicLink(
            at: file(".profile"),
            withDestinationURL: home.appendingPathComponent("missing/profile")
        )
        let report = setup().removeEverything()

        XCTAssertEqual(report.changed, [])
        XCTAssertEqual(report.skipped, [])
    }

    func testRemoveEverythingReportsOnlyTheDamagedFileAndNotTheUnrelatedLink() throws {
        try write("keep\n" + begin + "\nexport X=1\n", to: file(".zshrc"))
        try FileManager.default.createSymbolicLink(
            at: file(".profile"),
            withDestinationURL: home.appendingPathComponent("missing/profile")
        )
        let report = setup().removeEverything()

        XCTAssertEqual(report.changed, [])
        XCTAssertEqual(report.skipped.map(\.url.lastPathComponent), [".zshrc"])
    }

    func testRemoveEverythingFindsTheZdotdirBlockWrittenBeforeZdotdirBecameUnreadable() throws {
        let zdot = home.appendingPathComponent("zdot-written", isDirectory: true)
        try write("ZDOTDIR=\(zdot.path)\n", to: file(".zshenv"))
        _ = try setup().install(for: .zsh)
        XCTAssertTrue(exists(zdot.appendingPathComponent(".zshrc")))

        try write("ZDOTDIR=$(echo \(zdot.path))\n", to: file(".zshenv"))
        let report = setup().removeEverything()

        XCTAssertEqual(report.changed.map(\.path), [zdot.appendingPathComponent(".zshrc").path])
        XCTAssertFalse(exists(zdot.appendingPathComponent(".zshrc")))
        XCTAssertEqual(report.skipped, [])
    }

    // MARK: - CRLF in ~/.zshenv (I2)

    /// Each line of a CRLF `~/.zshenv` with a ZDOTDIR line is unresolvable: zsh keeps the CR
    /// in the value, and a comment line before it must never hide the assignment.
    func testCRLFZshenvWithZdotdirIsUnresolvedAndNothingIsEdited() throws {
        let zdot = home.appendingPathComponent("zdot", isDirectory: true)
        let cases = [
            "# my zsh setup\r\nexport ZDOTDIR=\(zdot.path)\r\n",
            "export ZDOTDIR=\(zdot.path)\r\n",
            "export ZDOTDIR=\"$HOME/zdot\"\r\nexport FOO=1\r\n",
        ]
        for content in cases {
            try write(content, to: file(".zshenv"))
            let setup = setup()
            XCTAssertEqual(setup.status(for: .zsh), .unresolvedZdotdir, content.debugDescription)
            XCTAssertThrowsError(try setup.install(for: .zsh), content.debugDescription) { error in
                XCTAssertEqual(error as? ShellPathError, .zdotdirUnresolved(self.file(".zshenv").path))
            }
            XCTAssertFalse(exists(file(".zshrc")), content.debugDescription)
            XCTAssertFalse(exists(zdot.appendingPathComponent(".zshrc")), content.debugDescription)
            XCTAssertEqual(text(file(".zshenv")), content, content.debugDescription)
        }
    }

    /// CRLF lines that do not mention ZDOTDIR do not stop a resolvable LF assignment.
    func testMixedEndingZshenvWithLFZdotdirIsStillResolved() throws {
        let zdot = home.appendingPathComponent("zdot", isDirectory: true)
        try write("export FOO=1\r\nexport ZDOTDIR=\(zdot.path)\nexport BAR=2\r\n", to: file(".zshenv"))
        let setup = setup()

        _ = try setup.install(for: .zsh)
        XCTAssertEqual(setup.status(for: .zsh), .configured)
        XCTAssertTrue(exists(zdot.appendingPathComponent(".zshrc")))
    }

    // MARK: - ZDOTDIR forms: trailing comments, XDG_CONFIG_HOME, subshells (M1, M2)

    func testZdotdirWithATrailingCommentIsResolved() throws {
        let zdot = home.appendingPathComponent("zdot", isDirectory: true)
        let cases = [
            "export ZDOTDIR=\"$HOME/zdot\"  # xdg\n",
            "ZDOTDIR=\(zdot.path) # the folder\n",
            "export ZDOTDIR='\(zdot.path)'\t# quoted\n",
        ]
        for content in cases {
            try write(content, to: file(".zshenv"))
            let setup = setup()
            _ = try setup.install(for: .zsh)
            XCTAssertEqual(setup.status(for: .zsh), .configured, content.debugDescription)
            XCTAssertTrue(exists(zdot.appendingPathComponent(".zshrc")), content.debugDescription)
            _ = try setup.remove(for: .zsh)
            try FileManager.default.removeItem(at: zdot)
        }
    }

    /// A `#` inside quotes, or one that is part of a word, is not a comment: the value is refused.
    func testHashInsideAValueIsNotAComment() throws {
        let rejected = [
            "export ZDOTDIR=\"$HOME/a # b\"\n",
            "export ZDOTDIR=$HOME/a#b\n",
            "ZDOTDIR=#\(home.path)/x\n",
        ]
        for content in rejected {
            try write(content, to: file(".zshenv"))
            let setup = setup()
            XCTAssertEqual(setup.status(for: .zsh), .unresolvedZdotdir, content.debugDescription)
            XCTAssertFalse(exists(file(".zshrc")), content.debugDescription)
        }
    }

    /// `${XDG_CONFIG_HOME:-$HOME/.config}/zsh` and `$XDG_CONFIG_HOME/zsh` use the app's environment
    /// only when it is absolute; otherwise `~/.config`.
    func testXdgConfigHomeFormsUseAnAbsoluteEnvironmentValueOnly() throws {
        let xdg = temp.url.appendingPathComponent("xdg", isDirectory: true)
        let forms = [
            "export ZDOTDIR=${XDG_CONFIG_HOME:-$HOME/.config}/zsh\n",
            "export ZDOTDIR=\"${XDG_CONFIG_HOME:-$HOME/.config}/zsh\"  # comment\n",
            "export ZDOTDIR=$XDG_CONFIG_HOME/zsh\n",
            "export ZDOTDIR=\"$XDG_CONFIG_HOME/zsh\"\n",
        ]
        for form in forms {
            try write(form, to: file(".zshenv"))

            let absolute = setup(env: ["XDG_CONFIG_HOME": xdg.path])
            _ = try absolute.install(for: .zsh)
            XCTAssertTrue(exists(xdg.appendingPathComponent("zsh/.zshrc")), form)
            _ = try absolute.remove(for: .zsh)
            try FileManager.default.removeItem(at: xdg)

            for env in [[:], ["XDG_CONFIG_HOME": "relative/xdg"]] {
                let fallback = setup(env: env)
                _ = try fallback.install(for: .zsh)
                let folder = home.appendingPathComponent(".config/zsh", isDirectory: true)
                XCTAssertTrue(exists(folder.appendingPathComponent(".zshrc")), "\(form) \(env)")
                _ = try fallback.remove(for: .zsh)
                try FileManager.default.removeItem(at: home.appendingPathComponent(".config"))
            }
        }
    }

    func testXdgFormsWithCommandSubstitutionAreUnresolved() throws {
        let xdg = temp.url.appendingPathComponent("xdg", isDirectory: true)
        let rejected = [
            "export ZDOTDIR=${XDG_CONFIG_HOME:-$(echo $HOME/.config)}/zsh\n",
            "export ZDOTDIR=\"$XDG_CONFIG_HOME/$(echo zsh)\"\n",
            "export ZDOTDIR=$(echo $XDG_CONFIG_HOME)/zsh\n",
        ]
        for content in rejected {
            try write(content, to: file(".zshenv"))
            let setup = setup(env: ["XDG_CONFIG_HOME": xdg.path])
            XCTAssertEqual(setup.status(for: .zsh), .unresolvedZdotdir, content.debugDescription)
            XCTAssertThrowsError(try setup.install(for: .zsh)) { error in
                XCTAssertEqual(error as? ShellPathError, .zdotdirUnresolved(self.file(".zshenv").path))
            }
            XCTAssertFalse(exists(xdg.appendingPathComponent("zsh/.zshrc")), content.debugDescription)
        }
    }

    /// An assignment inside `( … )` or a `$( … )` is not in effect for the shell: unresolved.
    func testZdotdirInsideParenthesesIsUnresolvedAndNothingIsEdited() throws {
        let zdot = home.path + "/zdot"
        let rejected = [
            "(\nZDOTDIR=\(zdot)\n)\n",
            "( ZDOTDIR=\(zdot) )\n",
            "X=$(\nZDOTDIR=\(zdot)\n)\n",
            // A `#` inside double quotes is text, so the subshell after it is still open.
            "echo \" #\"; (\nZDOTDIR=\(zdot)\n)\n",
        ]
        for content in rejected {
            try write(content, to: file(".zshenv"))
            let setup = setup()
            XCTAssertEqual(setup.status(for: .zsh), .unresolvedZdotdir, content.debugDescription)
            XCTAssertThrowsError(try setup.install(for: .zsh), content.debugDescription)
            XCTAssertFalse(exists(URL(fileURLWithPath: zdot).appendingPathComponent(".zshrc")), content.debugDescription)
            XCTAssertEqual(text(file(".zshenv")), content, content.debugDescription)
        }
    }

    /// A subshell that is closed before the assignment does not hide it.
    func testZdotdirAfterAClosedSubshellIsStillResolved() throws {
        let zdot = home.appendingPathComponent("zdot", isDirectory: true)
        try write("(\n  echo hi\n)\nZDOTDIR=\(zdot.path)\n", to: file(".zshenv"))
        let setup = setup()

        _ = try setup.install(for: .zsh)
        XCTAssertEqual(setup.status(for: .zsh), .configured)
        XCTAssertTrue(exists(zdot.appendingPathComponent(".zshrc")))
    }

    // MARK: - Bash login file drift (M-I)

    func testBlockLeftInProfileIsPartlyConfiguredAndInstallNeverAddsASecondBlock() throws {
        let bash = setup(login: "/bin/bash")
        _ = try setup().install(for: .posix)
        try write("bp\n", to: file(".bash_profile"))

        XCTAssertEqual(bash.status(for: .bash), .partlyConfigured)
        XCTAssertEqual(bash.strayFiles(for: .bash).map(\.path), [file(".profile").path])
        XCTAssertThrowsError(try bash.install(for: .bash)) { error in
            XCTAssertEqual(error as? ShellPathError, .blockElsewhere(self.file(".profile").path))
        }
        XCTAssertEqual(text(file(".bash_profile")), "bp\n")
        XCTAssertEqual(occurrences(begin, in: text(file(".profile"))), 1)

        let removed = try bash.remove(for: .bash)
        XCTAssertEqual(removed.map(\.lastPathComponent), [".profile"])
        XCTAssertFalse(exists(file(".profile")), "created by the app, so it goes with its block")
        XCTAssertEqual(bash.status(for: .bash), .notConfigured)
        _ = try bash.install(for: .bash)
        XCTAssertEqual(bash.status(for: .bash), .configured)
    }

    func testRemoveForBashFindsEveryManagedBlockInAnyLoginFile() throws {
        try write("bp\n", to: file(".bash_profile"))
        try write("p\n", to: file(".profile"))
        let bash = setup(login: "/bin/bash")
        _ = try bash.install(for: .bash)
        _ = try setup().install(for: .posix)
        XCTAssertEqual(occurrences(begin, in: text(file(".profile"))), 1)

        _ = try bash.remove(for: .bash)
        XCTAssertEqual(text(file(".bash_profile")), "bp\n")
        XCTAssertEqual(text(file(".profile")), "p\n")
        XCTAssertEqual(bash.status(for: .bash), .notConfigured)
    }
}
