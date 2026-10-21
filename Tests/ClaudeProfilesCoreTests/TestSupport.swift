import Foundation
import XCTest
@testable import ClaudeProfilesCore

/// A temporary directory that is removed when the test finishes.
final class TempDirectory {
    let url: URL

    init(name: String = "claude-profiles-test") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// A `Paths` rooted in this directory, with a fake home directory next to it.
    func paths(home: URL? = nil) -> Paths {
        Paths(root: url.appendingPathComponent("root", isDirectory: true), home: home ?? url.appendingPathComponent("home", isDirectory: true))
    }
}

enum Fixtures {
    static func url(_ name: String, extension ext: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            throw XCTSkip("missing fixture \(name).\(ext)")
        }
        return url
    }

    static func text(_ name: String, extension ext: String) throws -> String {
        try String(contentsOf: url(name, extension: ext), encoding: .utf8)
    }

    /// A fixture that contains `%ROOT%` instead of the machine specific root.
    static func script(_ name: String, root: URL) throws -> String {
        try text(name, extension: "txt").replacingOccurrences(of: "%ROOT%", with: root.path)
    }
}

extension Profile {
    static func sample(
        name: String = "Test",
        slug: String = "test",
        baseURL: String = "https://example.com/anthropic",
        auth: AuthKind = .bearer,
        model: String = "m-1",
        extraEnv: String = "API_TIMEOUT_MS=600000\n# comment",
        isolate: Bool = true,
        shareFromDefault: Bool = false
    ) -> Profile {
        Profile(
            name: name,
            slug: slug,
            baseURL: baseURL,
            auth: auth,
            model: model,
            extraEnv: extraEnv,
            isolate: isolate,
            shareFromDefault: shareFromDefault
        )
    }
}
