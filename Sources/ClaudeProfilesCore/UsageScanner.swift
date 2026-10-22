import Foundation

/// Counts the tokens that Claude Code reported for one profile.
///
/// The sessions of a profile are the `*.jsonl` files under
/// `<config folder>/projects/`. Each line is decoded on its own; only the token
/// numbers and the ids of a reply are kept, never the text of a message.
///
/// The scanner keeps a per-file summary by local day in memory and in
/// `usage-cache.json` under the data root. A file whose size and modification
/// time did not change is not read again. The cache file is only a cache: it
/// can be deleted at any time, and a damaged one is ignored.
public actor UsageScanner {
    /// Calls the body with every line of a file, in order. Injected by tests to count reads.
    public typealias LineReader = @Sendable (URL, (RawLine) throws -> Void) throws -> Void

    /// One line of a session file, as raw bytes.
    public struct RawLine: Sendable {
        /// The bytes of the line, without the newline.
        public let bytes: Data
        /// `true` when the line was longer than the limit and was not read fully.
        public let tooLong: Bool

        public init(bytes: Data = Data(), tooLong: Bool = false) {
            self.bytes = bytes
            self.tooLong = tooLong
        }
    }

    /// The file name of the cache, under the data root.
    public static let cacheFileName = "usage-cache.json"

    /// The biggest line that is read. A longer line is skipped: it cannot be a
    /// usage line and it would fill the memory.
    public static let maxLineBytes = 64 * 1024 * 1024

    /// The number of files that are written to the cache between two writes.
    private static let filesPerSave = 25
    /// The number of seconds after which the cache is written, even when fewer
    /// files were read.
    private static let secondsPerSave: TimeInterval = 5

    private let paths: Paths
    private let readLines: LineReader
    private var cache: [String: FileEntry] = [:]
    private var cacheLoaded = false

    /// The number of lines of the last count that were too long to be read.
    /// It is only a counter: the user is not told about it.
    private(set) var skippedLines: Int = 0

    public init(paths: Paths, readLines: @escaping LineReader = UsageScanner.streamLines) {
        self.paths = paths
        self.readLines = readLines
    }

    /// The usage of a profile. Runs off the main thread and stops when the
    /// calling task is cancelled.
    ///
    /// A file that cannot be read is skipped: the other files are counted and
    /// the number of skipped files is in the result.
    ///
    /// - Parameters:
    ///   - now: the moment the windows are measured from.
    ///   - calendar: decides the local day of every reply and of `now`.
    public func usage(for profile: Profile, now: Date = Date(), calendar: Calendar = .current) throws -> UsageResult {
        guard profile.isolate else { return .unavailable(.notIsolated) }
        guard Slug.isSafe(profile.slug) else { return .unavailable(.folderMissing) }
        let home = paths.home(for: profile.slug)
        guard SafeFileSystem.kind(of: home) == .directory else { return .unavailable(.folderMissing) }

        loadCacheOnce()
        let zone = Self.zoneKey(calendar)
        let todayKey = Self.dayKey(now, calendar)
        // Today and the six days before it.
        let weekStart = Self.dayKey(calendar.date(byAdding: .day, value: -6, to: now) ?? now, calendar)

        var summary = UsageSummary()
        var changed = false
        var skippedFiles = 0
        var skipped = 0
        var seen = Set<String>()
        var filesSinceSave = 0
        var lastSave = Date()
        for file in Self.sessionFiles(in: home, slug: profile.slug) {
            try Task.checkCancellation()
            seen.insert(file.key)
            let entry: FileEntry?
            if let cached = cache[file.key], cached.size == file.size, cached.modified == file.modified, cached.zone == zone {
                entry = cached
            } else {
                do {
                    let scanned = try scan(file, zone: zone, calendar: calendar)
                    entry = scanned.entry
                    skipped += scanned.skippedLines
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The file cannot be read: it is skipped and the other
                    // files are counted as before.
                    entry = nil
                    skippedFiles += 1
                    if cache[file.key] != nil {
                        cache[file.key] = nil
                        changed = true
                    }
                }
                if let entry {
                    cache[file.key] = entry
                    changed = true
                }
            }
            if let entry {
                for (day, totals) in entry.days {
                    summary.allTime += totals
                    if day == todayKey {
                        summary.today += totals
                    }
                    if day >= weekStart && day <= todayKey {
                        summary.last7Days += totals
                    }
                }
                summary.allTime += entry.undated
            }
            // The cache is written from time to time, so that a scan that is
            // stopped keeps the work it has already done.
            filesSinceSave += 1
            if filesSinceSave >= Self.filesPerSave || Date().timeIntervalSince(lastSave) >= Self.secondsPerSave {
                saveCache()
                changed = false
                filesSinceSave = 0
                lastSave = Date()
            }
        }

        // Entries of files that no longer exist leave the cache. Entries of other
        // profiles stay while their files exist.
        for key in Array(cache.keys) where !seen.contains(key) {
            guard let url = fileURL(forKey: key), FileManager.default.fileExists(atPath: url.path) else {
                cache[key] = nil
                changed = true
                continue
            }
        }
        if changed {
            saveCache()
        }
        skippedLines = skipped
        return .available(summary, skippedFiles: skippedFiles)
    }

    // MARK: - Reading one file

    /// Reads a whole file, line by line, into its per-day totals.
    private func scan(_ file: SessionFile, zone: String, calendar: Calendar) throws -> ScanResult {
        var entry = FileEntry(size: file.size, modified: file.modified, zone: zone, days: [:], undated: TokenTotals())
        // The replies of this file, by their id. A reply that is written
        // several times to the same file counts once, with the largest numbers
        // of all its lines.
        var replies: [String: Reply] = [:]
        var skipped = 0
        let dates = TimestampReader()
        let decoder = JSONDecoder()
        do {
            try readLines(file.url) { line in
                try Task.checkCancellation()
                // A line that is longer than the limit is not read.
                guard !line.tooLong, line.bytes.count <= Self.maxLineBytes else {
                    skipped += 1
                    return
                }
                // Most lines of a transcript hold no usage at all. Their bytes
                // are looked at before they become a string.
                guard Self.holds(line.bytes, Self.usageMarker),
                      Self.holds(line.bytes, Self.assistantMarker)
                else {
                    return
                }
                let text = String(decoding: line.bytes, as: UTF8.self)
                guard let record = Self.decode(text, with: decoder),
                      record.type == "assistant",
                      let message = record.message,
                      let usage = message.usage
                else {
                    return
                }
                let totals = Self.tokenTotals(from: usage)
                guard let totals else { return }
                let day = dates.date(record.timestamp).map { Self.dayKey($0, calendar) }
                // Replies without an id cannot be recognised and are counted each time.
                guard let id = message.id else {
                    Self.add(totals, ofDay: day, to: &entry)
                    return
                }
                let key = id + "\u{1F}" + (record.requestId ?? "")
                if let known = replies[key] {
                    // The larger number of every counter wins: a line that was
                    // written completely later is bigger than a partial one.
                    replies[key] = Reply(
                        day: known.day ?? day,
                        totals: known.totals.merged(with: totals)
                    )
                } else {
                    replies[key] = Reply(day: day, totals: totals)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The name of the file is never in the error: it holds the name of
            // a project folder of the user.
            throw UnreadableFile()
        }
        // The replies are added up at the end: a reply that is written again
        // can still change the numbers of the file.
        for reply in replies.values {
            Self.add(reply.totals, ofDay: reply.day, to: &entry)
        }
        return ScanResult(entry: entry, skippedLines: skipped)
    }

    /// What the reading of one file gives.
    private struct ScanResult {
        var entry: FileEntry
        /// The lines that were too long to be read.
        var skippedLines: Int
    }

    /// A file that could not be read. It says nothing about the file itself.
    private struct UnreadableFile: Error {}

    /// One reply of a file: the largest numbers of its lines and the day it
    /// was written on.
    private struct Reply {
        var day: String?
        var totals: TokenTotals
    }

    /// Adds the tokens of a reply to the totals of its day.
    private static func add(_ totals: TokenTotals, ofDay day: String?, to entry: inout FileEntry) {
        guard let day else {
            entry.undated += totals
            return
        }
        entry.days[day, default: TokenTotals()] += totals
    }

    /// The bytes a line must hold to be worth decoding.
    private static let usageMarker = Array("\"usage\"".utf8)
    private static let assistantMarker = Array("\"assistant\"".utf8)

    /// `true` when the raw bytes of a line hold the text.
    private static func holds(_ bytes: Data, _ text: [UInt8]) -> Bool {
        guard !text.isEmpty, bytes.count >= text.count else { return false }
        let first = text[0]
        let last = bytes.count - text.count
        return bytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            let pointer = base.assumingMemoryBound(to: UInt8.self)
            var index = 0
            while index <= last {
                if pointer[index] == first {
                    var offset = 1
                    while offset < text.count, pointer[index + offset] == text[offset] {
                        offset += 1
                    }
                    if offset == text.count { return true }
                }
                index += 1
            }
            return false
        }
    }

    /// The fields of a transcript line that the scanner needs. Every other key is skipped by the decoder.
    private struct Record: Decodable {
        let type: String?
        let timestamp: String?
        let requestId: String?
        let message: Message?

        struct Message: Decodable {
            let id: String?
            let usage: Usage?
        }

        struct Usage: Decodable {
            // The numbers are read as doubles: a number that is too big for an
            // integer must not make the whole line unreadable.
            let inputTokens: Double?
            let outputTokens: Double?
            let cacheCreationInputTokens: Double?
            let cacheReadInputTokens: Double?

            private enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
            }
        }
    }

    /// The biggest counter a line may have. A bigger number means that the
    /// file is broken, not that the tokens were used.
    static let maxCounter: Double = 1e12

    /// The counters of a line, or `nil` when the line is malformed.
    ///
    /// A counter must be a whole number between 0 and `maxCounter`. A negative
    /// number, a fraction and a number that is too big mean that the line is
    /// broken: the whole usage of that line is then ignored, so a broken line
    /// can neither crash the app nor be counted half.
    private static func tokenTotals(from usage: Record.Usage) -> TokenTotals? {
        guard let input = counter(usage.inputTokens),
              let output = counter(usage.outputTokens),
              let cacheRead = counter(usage.cacheReadInputTokens),
              let cacheWrite = counter(usage.cacheCreationInputTokens)
        else {
            return nil
        }
        return TokenTotals(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
    }

    /// One counter of a line: a whole number between 0 and `maxCounter`.
    /// A counter that is not there counts as zero.
    private static func counter(_ value: Double?) -> Int? {
        guard let value else { return 0 }
        guard value.isFinite, value >= 0, value <= maxCounter, value == value.rounded() else { return nil }
        return Int(value)
    }

    /// A malformed line gives `nil`.
    private static func decode(_ line: String, with decoder: JSONDecoder) -> Record? {
        try? decoder.decode(Record.self, from: Data(line.utf8))
    }

    // MARK: - Lines

    /// Calls the body with each line of the file, as raw bytes. The file is
    /// read in chunks of 64 KB, so only one line (plus one chunk) is in memory
    /// at a time.
    ///
    /// A line that is longer than `maxLineBytes` is not handed over: its bytes
    /// are dropped while it is read, so a huge line cannot fill the memory.
    public static let streamLines: LineReader = streamLines(limit: maxLineBytes)

    /// The reader of the lines of a file, with a limit of its own for the
    /// length of a line.
    public static func streamLines(limit: Int) -> LineReader {
        { url, body in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var pending = Data()
            var searched = 0
            var dropping = false
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                var bytes = chunk
                if dropping {
                    // The line is too long: only its end matters.
                    guard let newline = bytes.firstIndex(of: 0x0A) else { continue }
                    try body(RawLine(tooLong: true))
                    dropping = false
                    bytes = bytes[bytes.index(after: newline)...]
                    pending = Data()
                    searched = 0
                }
                pending.append(bytes)
                var lineStart = 0
                while let newline = pending[searched...].firstIndex(of: 0x0A) {
                    if newline - lineStart > limit {
                        // The line is longer than the limit: it is not read.
                        try body(RawLine(tooLong: true))
                    } else {
                        try body(RawLine(bytes: Data(pending[lineStart..<newline])))
                    }
                    lineStart = newline + 1
                    searched = lineStart
                }
                if lineStart > 0 {
                    pending = Data(pending[lineStart...])
                    searched = 0
                }
                if pending.count > limit {
                    // The line is longer than the limit: its bytes are dropped.
                    dropping = true
                    pending = Data()
                    searched = 0
                }
            }
            if dropping {
                try body(RawLine(tooLong: true))
            } else if !pending.isEmpty {
                try body(RawLine(bytes: pending))
            }
        }
    }

    // MARK: - Files

    /// A session transcript on disk, with what the cache checks.
    private struct SessionFile {
        /// The key of the file in the cache.
        let key: String
        let url: URL
        let size: Int64
        let modified: Double
    }

    /// Every `*.jsonl` file under the folder of the profile, sorted by key.
    /// Empty when the folder does not exist.
    ///
    /// Links are never followed: a link could lead to a file outside of the
    /// folder of the profile.
    private static func sessionFiles(in home: URL, slug: String) -> [SessionFile] {
        let root = home.appendingPathComponent("projects", isDirectory: true)
        guard SafeFileSystem.kind(of: root) == .directory else { return [] }
        var files: [SessionFile] = []
        var folders: [URL] = [root]
        while let folder = folders.first {
            folders.removeFirst()
            let children = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in children where !name.hasPrefix(".") {
                let url = folder.appendingPathComponent(name)
                switch SafeFileSystem.kind(of: url) {
                case .directory:
                    folders.append(url)
                case .file:
                    guard url.pathExtension == "jsonl" else { continue }
                    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                    let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    files.append(SessionFile(
                        key: cacheKey(slug: slug, path: relativePath(of: url, in: home)),
                        url: url,
                        size: size,
                        modified: modified
                    ))
                default:
                    continue
                }
            }
        }
        return files.sorted { $0.key < $1.key }
    }

    /// The key of a file in the cache: the slug of the profile and the path of
    /// the file, relative to the config folder of the profile.
    ///
    /// The cache holds no absolute path, and a profile that is renamed keeps
    /// its cache: the name of a project folder of the user is all it can show.
    static func cacheKey(slug: String, path: String) -> String {
        "\(slug)/\(path)"
    }

    /// The path of a file relative to the config folder of the profile.
    private static func relativePath(of url: URL, in home: URL) -> String {
        let prefix = home.path.hasSuffix("/") ? home.path : home.path + "/"
        guard url.path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(url.path.dropFirst(prefix.count))
    }

    /// The file of a key of the cache, or `nil` when the key is not ours.
    private func fileURL(forKey key: String) -> URL? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        let slug = String(key[key.startIndex..<slash])
        let path = String(key[key.index(after: slash)...])
        guard Slug.isSafe(slug), !path.isEmpty else { return nil }
        return paths.home(for: slug).appendingPathComponent(path)
    }

    // MARK: - Days

    /// `yyyy-MM-dd` of a moment in the calendar's time zone. The text sorts like the dates.
    static func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))"
    }

    /// Identifies the calendar and time zone the day keys were made with.
    private static func zoneKey(_ calendar: Calendar) -> String {
        "\(calendar.identifier)|\(calendar.timeZone.identifier)"
    }

    // MARK: - Cache

    private var cacheURL: URL { paths.root.appendingPathComponent(Self.cacheFileName) }

    /// Reads the cache once. A missing, damaged or other-version file gives an empty cache.
    private func loadCacheOnce() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        guard let bytes = try? Data(contentsOf: cacheURL),
              let file = try? JSONDecoder().decode(CacheFile.self, from: bytes),
              file.version == CacheFile.currentVersion
        else {
            return
        }
        cache = file.files
    }

    /// Writes the cache atomically. A failure only means the next scan reads more files.
    ///
    /// The file holds the names of the project folders of the user, so only the
    /// user may read it.
    private func saveCache() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(CacheFile(version: CacheFile.currentVersion, files: cache)) else { return }
        let manager = FileManager.default
        // The name carries the pid, so two running instances never share one file.
        let temporary = paths.root.appendingPathComponent(
            "\(Self.cacheFileName).\(ProcessInfo.processInfo.processIdentifier).tmp"
        )
        do {
            try manager.createDirectory(at: paths.root, withIntermediateDirectories: true)
            try? manager.removeItem(at: temporary)
            try bytes.write(to: temporary, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard rename(temporary.path, cacheURL.path) == 0 else {
                try? manager.removeItem(at: temporary)
                return
            }
        } catch {
            try? manager.removeItem(at: temporary)
            return
        }
    }

    /// The summary of one file. Only numbers and the file identity are stored.
    private struct FileEntry: Codable {
        var size: Int64
        var modified: Double
        /// The calendar and time zone the days were computed with.
        var zone: String
        /// Totals by `yyyy-MM-dd`.
        var days: [String: TokenTotals]
        /// Replies without a usable timestamp.
        var undated: TokenTotals
    }

    private struct CacheFile: Codable {
        // Version 2: the keys of the files are relative to the config folder
        // of the profile. A cache of version 1 is simply dropped.
        static let currentVersion = 2
        var version: Int
        /// By the key of the file: the slug and the relative path.
        var files: [String: FileEntry]
    }
}

/// Parses the ISO-8601 timestamps of transcript lines, with or without fractions of a second.
private final class TimestampReader {
    private let fractional: ISO8601DateFormatter
    private let plain: ISO8601DateFormatter

    init() {
        fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
    }

    func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return fractional.date(from: text) ?? plain.date(from: text)
    }
}
