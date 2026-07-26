import Foundation

struct GitError: LocalizedError {
    let command: String
    let exitCode: Int32
    let stderr: String

    var errorDescription: String? {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git \(command) failed (exit \(exitCode))" : message
    }
}

/// Thread-safe accumulation buffer for pipe readability handlers.
private nonisolated final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Runs git as a subprocess against a repository working directory.
/// Commands are serialized: two concurrent index mutations would otherwise
/// race on `.git/index.lock`, and out-of-order completion made "latest state"
/// reads unreliable.
actor GitExecutor {
    let workingDirectory: URL
    private var tail: Task<Void, Never>?

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    @discardableResult
    func run(_ arguments: [String], successCodes: Set<Int32> = [0], stdin: Data? = nil) async throws -> String {
        let data = try await runData(arguments, successCodes: successCodes, stdin: stdin)
        return String(decoding: data, as: UTF8.self)
    }

    /// Like `run`, but reports whether the output was valid UTF-8 so diff
    /// consumers can tell replacement characters from real content.
    func runChecked(_ arguments: [String], successCodes: Set<Int32> = [0]) async throws -> (output: String, validUTF8: Bool) {
        let data = try await runData(arguments, successCodes: successCodes)
        if let strict = String(bytes: data, encoding: .utf8) {
            return (strict, true)
        }
        return (String(decoding: data, as: UTF8.self), false)
    }

    func runData(_ arguments: [String], successCodes: Set<Int32> = [0], stdin: Data? = nil) async throws -> Data {
        let workingDirectory = self.workingDirectory
        let previous = tail
        let task = Task<Data, Error> {
            await previous?.value
            return try await Self.execute(
                arguments,
                workingDirectory: workingDirectory,
                successCodes: successCodes,
                stdin: stdin
            )
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    private static func execute(
        _ arguments: [String],
        workingDirectory: URL,
        successCodes: Set<Int32>,
        stdin: Data?
    ) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // quotepath=false keeps non-ASCII paths raw in diff/log output
        // instead of C-quoted octal escapes.
        process.arguments = ["git", "--no-optional-locks", "-c", "color.ui=false", "-c", "core.quotepath=false"] + arguments
        process.currentDirectoryURL = workingDirectory

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdin != nil {
            stdinPipe = Pipe()
            process.standardInput = stdinPipe
        } else {
            stdinPipe = nil
        }

        // Both pipes are drained continuously via readability handlers; reading
        // them one after the other deadlocks once git blocks on a full stderr
        // pipe buffer while stdout is still open.
        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
        let drained = DispatchGroup()
        for (pipe, buffer) in [(stdoutPipe, stdoutBuffer), (stderrPipe, stderrBuffer)] {
            drained.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    drained.leave()
                } else {
                    buffer.append(chunk)
                }
            }
        }

        do {
            try process.run()
        } catch {
            for pipe in [stdoutPipe, stderrPipe] {
                pipe.fileHandleForReading.readabilityHandler = nil
                drained.leave()
            }
            throw error
        }

        if let stdin, let stdinPipe {
            // Written off-thread with a throwing write: git can exit without
            // consuming stdin (startup failure), and an unguarded blocking
            // write into the closed pipe would raise/SIGPIPE.
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = stdinPipe.fileHandleForWriting
                try? handle.write(contentsOf: stdin)
                try? handle.close()
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                drained.wait()
                if successCodes.contains(process.terminationStatus) {
                    continuation.resume(returning: stdoutBuffer.value)
                } else {
                    continuation.resume(throwing: GitError(
                        command: arguments.joined(separator: " "),
                        exitCode: process.terminationStatus,
                        stderr: String(decoding: stderrBuffer.value, as: UTF8.self)
                    ))
                }
            }
        }
    }
}
