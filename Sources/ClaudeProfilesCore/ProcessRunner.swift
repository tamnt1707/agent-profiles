import Foundation

/// The result of a command that was started and finished.
public struct ProcessResult: Equatable {
    /// The exit status of the command.
    public var status: Int32
    /// Everything the command wrote on stdout and stderr.
    public var output: String

    public init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }

    /// `true` when the command ended with 0.
    public var isSuccess: Bool { status == 0 }
}

/// Runs a command and waits for it. The updater uses it for `ditto` and
/// `codesign`; the tests replace it with a stub.
public protocol ProcessRunner {
    func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult
}

/// Runs the command with `Process`.
public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        // Both streams go into one pipe, so the command never blocks on a
        // full pipe while we are waiting for it.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw UpdateError.installFailed
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
