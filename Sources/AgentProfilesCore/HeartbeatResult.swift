import Foundation

/// What the last run of a heartbeat left in its result file.
public struct HeartbeatResult: Equatable, Sendable {
    /// When the run ended.
    public var date: Date
    /// The exit code of the CLI. 0 means the ping got its answer.
    public var exitCode: Int
    /// The beginning of what the CLI printed (the answer, or the error).
    public var output: String

    public init(date: Date, exitCode: Int, output: String) {
        self.date = date
        self.exitCode = exitCode
        self.output = output
    }

    public var isSuccess: Bool { exitCode == 0 }

    /// Reads the file: the time in seconds, the exit code, then the output.
    /// `nil` for anything else, such as a file that is empty or half written.
    public init?(parsing text: String) {
        let lines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard lines.count >= 2,
              let seconds = TimeInterval(lines[0]), seconds > 0,
              let code = Int(lines[1]) else { return nil }
        self.init(
            date: Date(timeIntervalSince1970: seconds),
            exitCode: code,
            output: lines.count == 3 ? String(lines[2]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        )
    }
}
