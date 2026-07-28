import Foundation

/// One-shot latch deciding who finishes a pipe's drain: the EOF handler or
/// the post-exit grace timer. Whichever calls `finish()` first wins; the
/// loser must not touch the DispatchGroup again (a double leave would crash).
private nonisolated final class DrainGate: @unchecked Sendable {
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

/// The single subprocess spawn/drain implementation shared by every CLI the
/// app shells out to (git, gh, osascript, …). Callers map the returned exit
/// status and stderr to their own error types.
enum Subprocess {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    /// How long after process exit to keep waiting for pipe EOF before
    /// finishing with whatever output has been drained. A child left running
    /// in the background (git's fsmonitor daemon, credential helpers, gh's
    /// background children) can inherit the pipe write ends and hold EOF back
    /// indefinitely — without this cutoff one such command would hang its
    /// caller forever.
    static let drainGracePeriod: TimeInterval = 2.0

    /// Spawns the process and returns its exit status with fully drained
    /// stdout/stderr. Throws only when the process cannot be launched at all.
    ///
    /// Both pipes are drained continuously via readability handlers; reading
    /// them one after the other deadlocks once the child blocks on a full
    /// stderr pipe buffer while stdout is still open. Exit is observed via
    /// `terminationHandler`, never `waitUntilExit`: the latter polls the
    /// current thread's run loop, and on a GCD/concurrency worker thread the
    /// termination notification can be missed entirely, hanging forever after
    /// the process has already exited.
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        stdin: Data? = nil
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if stdin != nil {
            stdinPipe = Pipe()
            process.standardInput = stdinPipe
        } else {
            // Never inherit the app's stdin: a child that decides to read
            // from a terminal would block forever.
            stdinPipe = nil
            process.standardInput = FileHandle.nullDevice
        }

        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
        // One group tracks stdout EOF, stderr EOF, and process exit.
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
            // Grace cutoff: finish with the output drained so far instead of
            // waiting on a pipe EOF that may never come (see drainGracePeriod).
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
            // Written off-thread with a throwing write: the child can exit
            // without consuming stdin (startup failure), and an unguarded
            // blocking write into the closed pipe would raise/SIGPIPE.
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = stdinPipe.fileHandleForWriting
                try? handle.write(contentsOf: stdin)
                try? handle.close()
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                done.notify(queue: .global(qos: .userInitiated)) {
                    continuation.resume(returning: Output(
                        status: process.terminationStatus,
                        stdout: stdoutBuffer.value,
                        stderr: stderrBuffer.value
                    ))
                }
            }
        } onCancel: {
            // A cancelled caller has no use for the output; kill the child so
            // a long-running command (e.g. a network fetch) stops occupying
            // its caller's queue. Death by signal reaches the caller as a
            // non-zero status through the normal termination path.
            process.terminate()
        }
    }
}
