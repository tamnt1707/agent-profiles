import Foundation

/// What the Keychain said about one key.
public enum KeyRead: Equatable, Sendable {
    /// The Keychain was read: the key is there, or it is not.
    case read(Bool)
    /// The Keychain could not be read. Nothing is known about the key.
    case failed
}

/// What is known about the key of a profile.
public enum KeyState: Equatable, Sendable {
    /// The Keychain was read and holds a key.
    case stored
    /// The Keychain was read and holds no key.
    case missing
    /// The Keychain could not be read. Nothing is known about the key.
    case unreadable
    /// The presence was never read.
    case unknown
}

/// The presence of the stored keys, as the Keychain says it.
public enum KeyPresence {
    /// Reads which of the profiles have a key stored. Only the existence is
    /// asked for: no secret is read and no request is sent.
    ///
    /// The Keychain is asked off the main actor, so a long list of profiles
    /// does not freeze the window.
    ///
    /// - Returns: what the Keychain said, per slug.
    public static func read(slugs: [String], keys: KeyStore) async -> [String: KeyRead] {
        await Task.detached(priority: .utility) {
            var read: [String: KeyRead] = [:]
            for slug in slugs {
                do {
                    read[slug] = .read(try keys.hasKey(slug))
                } catch {
                    // A Keychain that cannot be read does not mean that the
                    // key is gone: the caller says that it could not be read.
                    read[slug] = .failed
                }
            }
            return read
        }.value
    }
}

/// What is known about the key of every profile, with the number of the read
/// it comes from.
///
/// Two reads can be on their way at the same time and the older one can come
/// back last. The number of the read says which one is the newest: a read
/// with an older number than the one that is already merged is dropped, so
/// it cannot overwrite a newer answer.
public struct KeyPresenceBook: Equatable, Sendable {
    /// What is known about the key of each slug.
    public private(set) var states: [String: KeyState] = [:]

    /// The number of the newest read that was merged.
    public private(set) var mergedSequence: Int = 0

    /// The number of the last read that was started.
    private var counter: Int = 0

    public init() {}

    /// The number of the next read. It is higher than the number of every read
    /// that was started before it.
    public mutating func nextSequence() -> Int {
        counter += 1
        return counter
    }

    /// Merges what was read into what was known.
    ///
    /// A read whose number is not newer than the one that is already merged is
    /// dropped: it says less about the Keychain than the newer answer, and it
    /// must not overwrite it. A slug that is not in the list any more is not
    /// kept: the profile is gone.
    ///
    /// - Parameters:
    ///   - slugs: the profiles of the list, in order.
    ///   - read: what the Keychain said, per slug.
    ///   - sequence: the number of this read.
    /// - Returns: `false` when the read was dropped.
    @discardableResult
    public mutating func merge(slugs: [String], read: [String: KeyRead], sequence: Int) -> Bool {
        guard sequence > mergedSequence else { return false }
        mergedSequence = sequence
        var merged: [String: KeyState] = [:]
        for slug in slugs {
            switch read[slug] {
            case .read(let value)?:
                merged[slug] = value ? .stored : .missing
            case .failed?:
                // The Keychain could not be read: nothing is known about the
                // key. That is not the same as a key that is not there.
                merged[slug] = .unreadable
            case nil:
                continue
            }
        }
        states = merged
        return true
    }

    /// What is known about the key of a slug. `unknown` when it was never read.
    public func state(for slug: String) -> KeyState {
        states[slug] ?? .unknown
    }
}
