import Foundation

/// The file that "Export Profiles…" writes and "Import Profiles…" reads.
///
/// The file holds the settings of the profiles of the user and nothing else:
/// no key, no Claude login, no history, no sessions, no usage, no health and
/// no recent folders. The default setup (`~/.claude`) and the settings of the
/// app are not in it.
///
/// ```json
/// {
///   "format": "agent-profiles-export",
///   "version": 1,
///   "exported_at": "2026-11-11T09:30:00Z",
///   "profiles": [ { "name": "…", "slug": "…", … } ]
/// }
/// ```
public enum ProfileExport {
    /// The value of the `format` key. A file with another value is refused.
    public static let format = "agent-profiles-export"
    /// The version of the format this app writes and reads.
    public static let version = 1
    /// A larger file is not read: an export of a few hundred profiles is far
    /// below this size.
    public static let maxFileSize = 4 * 1024 * 1024

    // MARK: - Writing

    /// The profile as it is written to the file: the default setup is never
    /// exported, and the recent folders of the menu bar stay on this Mac.
    static func exportable(_ profiles: [Profile]) -> [Profile] {
        profiles
            .filter { !$0.isDefaultClaude }
            .map { profile in
                var copy = profile
                copy.recentDirs = []
                return copy
            }
    }

    /// The text of the export file, in the style of `profiles.json`.
    ///
    /// The profile fields are written by the same writer as `profiles.json`,
    /// so a field that is added to a profile ends up in the export as well.
    /// The Keychain is never asked: the file cannot hold a key.
    public static func encode(_ profiles: [Profile], exportedAt: Date) -> String {
        let profiles = exportable(profiles)
        var out = "{\n"
        out += "  \"format\": \(JSONText.escape(format)),\n"
        out += "  \"version\": \(version),\n"
        out += "  \"exported_at\": \(JSONText.escape(Timestamp.string(from: exportedAt))),\n"
        out += "  \"profiles\": "
        if profiles.isEmpty {
            out += "[]\n"
        } else {
            out += "[\n"
            for (index, profile) in profiles.enumerated() {
                out += JSONText.encode(profile, indent: 4)
                out += index == profiles.count - 1 ? "\n" : ",\n"
            }
            out += "  ]\n"
        }
        out += "}\n"
        return out
    }

    /// The name the save panel suggests: `agent-profiles-YYYY-MM-DD.json`, with
    /// the date on the clock of the Mac.
    public static func defaultFileName(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "agent-profiles-\(formatter.string(from: date)).json"
    }

    /// Writes the export file atomically, readable by the user only (mode 0600).
    ///
    /// The text goes to a new file next to the target, created with mode 0600,
    /// which is then renamed over the target. A reader never sees a half
    /// written file, and a symbolic link at the target is replaced, never
    /// written through.
    public static func write(_ text: String, to target: URL) throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(
            ".\(target.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString).tmp"
        )
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw ProfileExportError.writeFailed(target.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            // The umask can only take bits away; the mode is set again anyway.
            guard fchmod(descriptor, 0o600) == 0 else { throw ProfileExportError.writeFailed(target.path) }
            try handle.write(contentsOf: Data(text.utf8))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            unlink(temporary.path)
            throw ProfileExportError.writeFailed(target.path)
        }
        guard rename(temporary.path, target.path) == 0 else {
            unlink(temporary.path)
            throw ProfileExportError.writeFailed(target.path)
        }
    }

    // MARK: - Reading

    /// Reads an export file from the disk. A file that is too large is refused
    /// before it is read.
    public static func read(from url: URL) throws -> ExportDocument {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = (attributes?[.size] as? NSNumber)?.intValue, size > maxFileSize {
            throw ProfileExportError.fileTooLarge
        }
        guard let bytes = try? Data(contentsOf: url) else {
            throw ProfileExportError.unreadable
        }
        return try decode(bytes)
    }

    /// Parses an export file strictly.
    ///
    /// A file that is not JSON, that has another `format`, another `version`,
    /// or a profile that does not read is refused as a whole: nothing of it is
    /// imported. Keys that the format does not know are ignored, the recent
    /// folders included.
    public static func decode(_ bytes: Data) throws -> ExportDocument {
        guard bytes.count <= maxFileSize else { throw ProfileExportError.fileTooLarge }
        guard String(data: bytes, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: bytes),
              object is [String: Any]
        else {
            throw ProfileExportError.notAnExport
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: bytes),
              header.format == format
        else {
            throw ProfileExportError.notAnExport
        }
        guard header.version == version else {
            throw ProfileExportError.unsupportedVersion(header.version.map(String.init) ?? "?")
        }
        guard let body = try? decoder.decode(Body.self, from: bytes) else {
            throw ProfileExportError.notAnExport
        }
        var profiles: [Profile] = []
        var slugs = Set<String>()
        for (index, entry) in body.profiles.enumerated() {
            guard case .success(let strict) = entry.result else {
                throw ProfileExportError.invalidProfile(index + 1)
            }
            let profile = strict.profile
            // The file is one list: two profiles of one command cannot both be
            // what the user meant.
            guard slugs.insert(profile.slug).inserted else {
                throw ProfileExportError.duplicateProfile(profile.slug)
            }
            profiles.append(profile)
        }
        return ExportDocument(
            exportedAt: header.exportedAt.flatMap(Timestamp.date(from:)),
            profiles: profiles
        )
    }

    /// `format`, `version` and `exported_at`, read on their own so a file of
    /// another kind is told apart from a broken one.
    private struct Header: Decodable {
        var format: String?
        var version: Int?
        var exportedAt: String?

        enum CodingKeys: String, CodingKey {
            case format, version
            case exportedAt = "exported_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            format = try? c.decode(String.self, forKey: .format)
            version = try? c.decode(Int.self, forKey: .version)
            exportedAt = try? c.decode(String.self, forKey: .exportedAt)
        }
    }

    /// The list of the profiles. Every entry keeps its own result, so the
    /// error can name the profile that does not read.
    private struct Body: Decodable {
        var profiles: [Entry]
    }

    private struct Entry: Decodable {
        var result: Result<StrictProfile, Error>

        init(from decoder: Decoder) throws {
            result = Result { try StrictProfile(from: decoder) }
        }
    }
}

/// What an export file holds.
public struct ExportDocument: Equatable, Sendable {
    /// When the file was written, when it says so.
    public var exportedAt: Date?
    /// The profiles, in the order of the file.
    public var profiles: [Profile]

    public init(exportedAt: Date?, profiles: [Profile]) {
        self.exportedAt = exportedAt
        self.profiles = profiles
    }
}

/// Why an export file was not written or not read.
public enum ProfileExportError: Error, Equatable, Sendable {
    /// The file is not JSON, or not an export of this app.
    case notAnExport
    /// The file is an export of another version of the format.
    case unsupportedVersion(String)
    /// The profile at this position (counted from 1) does not read.
    case invalidProfile(Int)
    /// Two profiles of the file have this command.
    case duplicateProfile(String)
    /// The file is larger than an export can be.
    case fileTooLarge
    /// The file could not be read.
    case unreadable
    /// The file could not be written.
    case writeFailed(String)
}

/// One profile of an export file, read strictly: a value of the wrong type is
/// an error, never a silent default.
private struct StrictProfile: Decodable {
    let profile: Profile

    enum CodingKeys: String, CodingKey {
        case name
        case slug
        case baseURL = "base_url"
        case auth
        case model
        case opusModel = "opus_model"
        case sonnetModel = "sonnet_model"
        case haikuModel = "haiku_model"
        case extraEnv = "extra_env"
        case workdir
        case isolate
        case shareFromDefault = "share_from_default"
        case priceInputPerMillion = "price_input_per_million"
        case priceOutputPerMillion = "price_output_per_million"
        case agent
        case heartbeat
    }

    struct Invalid: Error {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        let slug = try c.decode(String.self, forKey: .slug)
        // The name is shown and the slug becomes a file name and a command:
        // an empty name, or a slug the app could not have made, is refused.
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Slug.isSafe(slug), Slug.slugify(slug) == slug
        else { throw Invalid() }
        let input = try c.decodeIfPresent(Double.self, forKey: .priceInputPerMillion)
        let output = try c.decodeIfPresent(Double.self, forKey: .priceOutputPerMillion)
        guard UsageCost.isValidPrice(input), UsageCost.isValidPrice(output) else { throw Invalid() }
        profile = Profile(
            name: name,
            slug: slug,
            baseURL: try c.decodeIfPresent(String.self, forKey: .baseURL) ?? "",
            auth: try c.decodeIfPresent(AuthKind.self, forKey: .auth) ?? .bearer,
            model: try c.decodeIfPresent(String.self, forKey: .model) ?? "",
            opusModel: try c.decodeIfPresent(String.self, forKey: .opusModel) ?? "",
            sonnetModel: try c.decodeIfPresent(String.self, forKey: .sonnetModel) ?? "",
            haikuModel: try c.decodeIfPresent(String.self, forKey: .haikuModel) ?? "",
            extraEnv: try c.decodeIfPresent(String.self, forKey: .extraEnv) ?? "",
            workdir: try c.decodeIfPresent(String.self, forKey: .workdir) ?? "",
            isolate: try c.decodeIfPresent(Bool.self, forKey: .isolate) ?? false,
            shareFromDefault: try c.decodeIfPresent(Bool.self, forKey: .shareFromDefault) ?? false,
            recentDirs: [],
            priceInputPerMillion: input,
            priceOutputPerMillion: output,
            agent: try c.decodeIfPresent(AgentKind.self, forKey: .agent) ?? .default,
            heartbeat: try c.decodeIfPresent(StrictHeartbeat.self, forKey: .heartbeat)?.heartbeat ?? .off
        )
    }
}

/// A schedule of an export file, read strictly.
private struct StrictHeartbeat: Decodable {
    let heartbeat: Heartbeat

    enum CodingKeys: String, CodingKey { case enabled, times, days }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let texts = try c.decodeIfPresent([String].self, forKey: .times) ?? []
        let times = texts.compactMap { ClockTime(text: $0) }
        let days = try c.decodeIfPresent([Int].self, forKey: .days) ?? []
        guard times.count == texts.count, times.count <= Heartbeat.maxTimes,
              days.allSatisfy({ (1...7).contains($0) })
        else { throw StrictProfile.Invalid() }
        heartbeat = Heartbeat(enabled: enabled, times: times, days: Set(days))
    }
}

// MARK: - Import planning

/// How one profile of the file relates to the profiles that already exist.
public enum ImportStatus: Equatable, Sendable {
    /// Nothing uses its name or its command: it is imported as it is.
    case new
    /// A profile with the same name exists.
    case nameExists
    /// The command (`claude-<slug>`) is taken by a profile or a file on disk.
    case commandExists
    /// Both the name and the command are taken.
    case nameAndCommandExist

    public var isConflict: Bool { self != .new }
}

/// What the user chose for a profile that conflicts. Nothing is ever overwritten.
public enum ImportChoice: Equatable, Sendable {
    /// The profile is not imported. The default.
    case skip
    /// The profile is imported under a free name and command, like `Work (2)`.
    case importAsCopy
}

/// One profile of the file, with what it would collide with.
public struct ImportCandidate: Equatable, Sendable, Identifiable {
    /// The position in the file.
    public var id: Int
    public var profile: Profile
    public var status: ImportStatus

    public init(id: Int, profile: Profile, status: ImportStatus) {
        self.id = id
        self.profile = profile
        self.status = status
    }
}

/// What the import does with one profile of the file.
public enum ImportAction: Equatable, Sendable {
    /// The profile is created as given: already renamed for a copy, its
    /// heartbeat off and without recent folders.
    case create(Profile)
    case skip
}

/// The pure part of the import: who collides with whom, the free names of the
/// copies and the profiles that are created.
public enum ImportPlanner {
    /// Compares the profiles of the file with the existing ones.
    ///
    /// - Parameters:
    ///   - imported: the profiles of the file.
    ///   - existing: the profiles of the app, the default setup included.
    ///   - isCommandTaken: whether a file on disk takes the command of a slug
    ///     (a launcher, or a config folder that would be adopted).
    public static func candidates(
        for imported: [Profile],
        existing: [Profile],
        isCommandTaken: (String) -> Bool = { _ in false }
    ) -> [ImportCandidate] {
        let names = Set(existing.map { nameKey($0.name) })
        let slugs = Set(existing.map(\.slug))
        return imported.enumerated().map { index, profile in
            let nameTaken = names.contains(nameKey(profile.name))
            let commandTaken = slugs.contains(profile.slug) || isCommandTaken(profile.slug)
            let status: ImportStatus
            switch (nameTaken, commandTaken) {
            case (false, false): status = .new
            case (true, false): status = .nameExists
            case (false, true): status = .commandExists
            case (true, true): status = .nameAndCommandExist
            }
            return ImportCandidate(id: index, profile: profile, status: status)
        }
    }

    /// What is done with every candidate. A new profile is created; a
    /// conflicting one is skipped unless the user chose a copy, which gets the
    /// first free `<name> (n)` and `<slug>-n`.
    ///
    /// A copy never takes the name or the command of an existing profile, of
    /// another profile of the file, or of an earlier copy.
    public static func actions(
        for candidates: [ImportCandidate],
        choices: [Int: ImportChoice],
        existing: [Profile],
        isCommandTaken: (String) -> Bool = { _ in false }
    ) -> [ImportAction] {
        var names = Set(existing.map { nameKey($0.name) })
        var slugs = Set(existing.map(\.slug))
        for candidate in candidates {
            names.insert(nameKey(candidate.profile.name))
            slugs.insert(candidate.profile.slug)
        }
        return candidates.map { candidate in
            var profile = prepared(candidate.profile)
            if candidate.status.isConflict {
                guard choices[candidate.id] == .importAsCopy else { return .skip }
                let base = profile.name
                var number = 2
                while names.contains(nameKey("\(base) (\(number))"))
                    || slugs.contains("\(profile.slug)-\(number)")
                    || isCommandTaken("\(profile.slug)-\(number)") {
                    number += 1
                }
                profile.name = "\(base) (\(number))"
                profile.slug = "\(profile.slug)-\(number)"
                names.insert(nameKey(profile.name))
                slugs.insert(profile.slug)
            }
            return .create(profile)
        }
    }

    /// The profile as it is created: the name trimmed, the heartbeat off (a
    /// schedule from another Mac must not start sending requests on its own)
    /// and no recent folders.
    static func prepared(_ profile: Profile) -> Profile {
        var copy = profile
        copy.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.recentDirs = []
        copy.heartbeat = Heartbeat(enabled: false, times: profile.heartbeat.times, days: profile.heartbeat.days)
        return copy
    }

    /// Names are compared without the case and the surrounding spaces.
    static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Saving an imported profile

extension Store {
    /// `true` when something on disk already uses the command of `slug`: a
    /// launcher (ours or not) or a config folder. An imported profile never
    /// takes either, so it can never adopt the login or the history of another
    /// profile.
    public func isCommandTakenOnDisk(_ slug: String) -> Bool {
        SafeFileSystem.kind(of: paths.script(for: slug)) != .missing
            || SafeFileSystem.kind(of: paths.home(for: slug)) != .missing
    }

    /// Saves a profile that comes from an export file: its launcher and its
    /// config folder. Only for the import.
    ///
    /// Unlike `saveProfile`, a profile that needs a key is saved without one:
    /// an export never holds a key, so the user adds it in the editor, which
    /// shows the profile as "no key stored" until then. The Keychain is not
    /// touched at all.
    ///
    /// The profile must be new: the same checks as a save are made, and a
    /// launcher or a config folder of its command that already exists refuses
    /// the save. Refused while `profiles.json` is unread. A failure takes away
    /// what this call wrote. `profiles.json` itself is written by the caller,
    /// once for the whole import.
    public func saveImportedProfile(
        _ profile: Profile,
        others: [Profile],
        strings: ScriptStrings = .english
    ) throws {
        guard !loadFailed else { throw StoreError.dataFileNotLoaded(paths.dataFile.path) }
        guard !profile.isDefaultClaude else { throw StoreError.unsafeSlug(profile.slug) }
        try validate(profile, others: others)
        try validateCommandFile(profile.slug, ownedBy: nil)
        let script = paths.script(for: profile.slug)
        let home = paths.home(for: profile.slug)
        guard SafeFileSystem.kind(of: script) == .missing else {
            throw ProfileError.foreignCommandExists(profile.slug, script.path)
        }
        guard SafeFileSystem.kind(of: home) == .missing else {
            throw StoreError.targetHomeExists(home.path)
        }
        do {
            try materialize(profile, strings: strings)
        } catch {
            // Both were missing before: what is there now was written here.
            try? SafeFileSystem.remove(at: script)
            try? SafeFileSystem.remove(at: home)
            throw error
        }
    }
}
