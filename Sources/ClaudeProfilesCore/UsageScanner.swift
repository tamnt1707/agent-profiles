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
    public typealias LineReader = @Sendable (URL, (String) throws -> Void) throws -> Void

    /// The file name of the cache, under the data root.
    public static let cacheFileName = "usage-cache.json"

    private let paths: Paths
    private let readLines: LineReader
    private var cache: [String: FileEntry] = [:]
    private var cacheLoaded = false

    public init(paths: Paths, readLines: @escaping LineReader = UsageScanner.streamLines) {
        self.paths = paths
        self.readLines = readLines
    }

    /// The usage of a profile. Runs off the main thread and stops when the
    /// calling task is cancelled.
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
        var seen = Set<String>()
        for file in Self.sessionFiles(in: home.appendingPathComponent("projects", isDirectory: true)) {
            try Task.checkCancellation()
            seen.insert(file.path)
            let entry: FileEntry
            if let cached = cache[file.path], cached.size == file.size, cached.modified == file.modified, cached.zone == zone {
                entry = cached
            } else {
                do {
                    entry = try scan(file, zone: zone, calendar: calendar)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The file cannot be read: it is skipped and the other
                    // files are counted as before.
                    skippedFiles += 1
                    if cache[file.path] != nil {
                        cache[file.path] = nil
                        changed = true
                    }
                    continue
                }
                cache[file.path] = entry
                changed = true
            }
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

        // Entries of files that no longer exist leave the cache. Entries of other
        // profiles stay while their files exist. (Paths are not compared as text:
        // the enumerator and `resolvingSymlinksInPath` spell /var and /private/var differently.)
        for path in Array(cache.keys) where !seen.contains(path) && !FileManager.default.fileExists(atPath: path) {
            cache[path] = nil
            changed = true
        }
        if changed {
            saveCache()
        }
        return .available(summary, skippedFiles: skippedFiles)
    }

    // MARK: - Reading one file

    /// Reads a whole file, line by line, into its per-day totals.
    private func scan(_ file: SessionFile, zone: String, calendar: Calendar) throws -> FileEntry {
        var entry = FileEntry(size: file.size, modified: file.modified, zone: zone, days: [:], undated: TokenTotals())
        // The replies of this file, by their id. A reply that is written
        // several times to the same file counts once, with the largest numbers
        // of all its lines.
        var replies: [String: Reply] = [:]
        let dates = TimestampReader()
        let decoder = JSONDecoder()
        do {
            try readLines(file.url) { line in
                try Task.checkCancellation()
                guard let record = Self.decode(line, with: decoder),
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
        return entry
    }

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

    /// A file that could not be read. It says nothing about the file itself.
    private struct UnreadableFile: Error {}

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

    /// A malformed line gives `nil`. A line without a `usage` key is skipped before decoding.
    private static func decode(_ line: String, with decoder: JSONDecoder) -> Record? {
        guard line.contains("\"usage\"") else { return nil }
        return try? decoder.decode(Record.self, from: Data(line.utf8))
    }

    // MARK: - Lines

    /// Calls the body with each line of the file. The file is read in chunks of
    /// 64 KB, so only one line (plus one chunk) is in memory at a time.
    public static let streamLines: LineReader = { url, body in
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            // `pending` always starts at index 0; only the new bytes are searched for a newline.
            var searchFrom = pending.count
            pending.append(chunk)
            var lineStart = 0
            while let newline = pending[searchFrom...].firstIndex(of: 0x0A) {
                try body(String(decoding: pending[lineStart..<newline], as: UTF8.self))
                lineStart = newline + 1
                searchFrom = lineStart
            }
            if lineStart > 0 {
                pending = Data(pending[lineStart...])
            }
        }
        if !pending.isEmpty {
            try body(String(decoding: pending, as: UTF8.self))
        }
    }

    // MARK: - Files

    /// A session transcript on disk, with what the cache checks.
    private struct SessionFile {
        let path: String
        let url: URL
        let size: Int64
        let modified: Double
    }

    /// Every `*.jsonl` file under the folder, sorted by path. Empty when the folder does not exist.
    private static func sessionFiles(in root: URL) -> [SessionFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [SessionFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            files.append(SessionFile(
                path: url.path,
                url: url,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
        }
        return files.sorted { $0.path < $1.path }
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
    private func saveCache() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(CacheFile(version: CacheFile.currentVersion, files: cache)) else { return }
        do {
            try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
            try bytes.write(to: cacheURL, options: .atomic)
        } catch {
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
        static let currentVersion = 1
        var version: Int
        /// By absolute file path.
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
