import Foundation

/// A version number in the `MAJOR.MINOR.PATCH` form of semver.
///
/// The parser is strict on purpose: a tag that is not a version (`latest`,
/// `nightly`, `v1.2`) must never be mistaken for one, because the updater
/// would then compare nonsense with the installed version.
public struct SemVer: Comparable, Hashable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The identifiers of the pre-release suffix (`beta.1` → `["beta", "1"]`).
    public let prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Parses `1.2.3`, `v1.2.3` or `1.2.3-beta.1`.
    ///
    /// Returns `nil` for everything that is not a version. Build metadata
    /// (`1.2.3+abc`) is accepted and ignored, as the semver specification says.
    public init?(text: String) {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        if rest.hasPrefix("v") || rest.hasPrefix("V") {
            rest.removeFirst()
        }
        // Build metadata does not take part in the comparison.
        if let plus = rest.firstIndex(of: "+") {
            rest = String(rest[rest.startIndex..<plus])
        }

        var prerelease: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            let suffix = rest[rest.index(after: dash)...]
            rest = String(rest[rest.startIndex..<dash])
            prerelease = suffix.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            // "1.2.3-" and "1.2.3-a..b" are not versions.
            guard !prerelease.isEmpty else { return nil }
            for identifier in prerelease {
                guard !identifier.isEmpty,
                      identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
                else { return nil }
            }
        }

        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            guard let number = Int(part) else { return nil }
            // No leading zeros, as in the semver specification.
            guard part.count == 1 || part.first != "0" else { return nil }
            numbers.append(number)
        }

        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: prerelease)
    }

    /// `true` when the version carries a pre-release suffix.
    public var isPrerelease: Bool { !prerelease.isEmpty }

    public var description: String {
        let base = "\(major).\(minor).\(patch)"
        guard isPrerelease else { return base }
        return base + "-" + prerelease.joined(separator: ".")
    }

    /// The order of the semver specification: a pre-release is older than the
    /// release itself and numeric identifiers are older than words.
    public static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty != rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            if left == right { continue }
            switch (Int(left), Int(right)) {
            case let (leftNumber?, rightNumber?): return leftNumber < rightNumber
            case (_?, nil): return true      // 1.0.0-1 is older than 1.0.0-alpha
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
