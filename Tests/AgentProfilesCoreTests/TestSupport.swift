import Foundation
import XCTest
@testable import AgentProfilesCore

/// The places of the package on disk, derived from the location of a test file.
///
/// The tests read the sources and the string tables straight from the package,
/// so they check what is really shipped and not a copy of it.
enum PackageLayout {
    /// The root of the package.
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AgentProfilesCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    /// A file or a folder of the package.
    static func url(_ path: String) -> URL {
        root.appendingPathComponent(path)
    }

    /// The string table of one language.
    static func stringTable(_ language: String) throws -> [String: String] {
        let url = url("Sources/AgentProfiles/Resources")
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.strings")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "missing \(url.path)")
        guard let contents = NSDictionary(contentsOfFile: url.path) as? [String: String] else {
            XCTFail("\(url.path) is not a valid strings file")
            return [:]
        }
        return contents
    }

    /// Every Swift file of the package.
    static func swiftFiles() -> [URL] {
        swiftFiles(in: url("Sources"))
    }

    /// Every Swift file of a folder of the package.
    static func swiftFiles(in directory: URL) -> [URL] {
        var found: [URL] = []
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for item in items {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                found += swiftFiles(in: item)
            } else if item.pathExtension == "swift" {
                found.append(item)
            }
        }
        return found
    }

    /// The text of a file of the package.
    static func text(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

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
