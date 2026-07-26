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

/// One-shot latch deciding who finishes a pipe's drain: the EOF handler or
/// the post-exit grace timer. Whichever calls `finish()` first wins; the
/// loser must not touch the DispatchGroup again (a double leave would crash).
nonisolated final class DrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    /// Returns true exactly once, for the first caller.
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
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
    /// How long after process exit to keep waiting for pipe EOF before
    /// finishing with whatever output has been drained. A git child left
    /// running in the background (fsmonitor daemon, credential helpers) can
    /// inherit the pipe write ends and hold EOF back indefinitely — without
    /// this cutoff one such command would wedge the serialized chain and
    /// stop all loading for the repository.
    static let drainGracePeriod: TimeInterval = 2.0

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
        // One group tracks stdout EOF, stderr EOF, and process exit. Exit is
        // observed via `terminationHandler`, never `waitUntilExit`: the latter
        // polls the current thread's run loop, and on a GCD/concurrency worker
        // thread the termination notification can be missed entirely, hanging
        // forever after the process has already exited — which wedges the
        // serialized command chain and stops all loading for the repository.
        let done = DispatchGroup()
        let stdoutGate = DrainGate()
        let stderrGate = DrainGate()
        for (pipe, buffer, gate) in [(stdoutPipe, stdoutBuffer, stdoutGate), (stderrPipe, stderrBuffer, stderrGate)] {
            done.enter()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    if gate.finish() { done.leave() }
                } else {
                    buffer.append(chunk)
                }
            }
        }
        done.enter()
        process.terminationHandler = { _ in
            done.leave()
            // Grace cutoff: a background child of git can inherit the pipe
            // write ends and withhold EOF forever after git itself exited.
            // Finish with the output drained so far instead of wedging the
            // serialized chain (see drainGracePeriod).
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + drainGracePeriod) {
                for (pipe, gate) in [(stdoutPipe, stdoutGate), (stderrPipe, stderrGate)] {
                    if gate.finish() {
                        pipe.fileHandleForReading.readabilityHandler = nil
                        done.leave()
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            for (pipe, gate) in [(stdoutPipe, stdoutGate), (stderrPipe, stderrGate)] {
                pipe.fileHandleForReading.readabilityHandler = nil
                if gate.finish() { done.leave() }
            }
            process.terminationHandler = nil
            done.leave()
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
            done.notify(queue: .global(qos: .userInitiated)) {
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
