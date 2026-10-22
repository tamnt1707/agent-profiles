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
        let shapes = ["", "a", "a\n", "a\n\n\n", "a\r\n", "a\r", "\n", "# mine\nexport X=1\n\n", "héllo wörld\n"]
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
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: home.path)
            .filter { $0.hasPrefix(".zshrc.") }
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
}
