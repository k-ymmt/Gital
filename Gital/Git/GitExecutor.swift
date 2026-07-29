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

/// Runs git as a subprocess against a repository working directory.
/// Commands are serialized: two concurrent index mutations would otherwise
/// race on `.git/index.lock`, and out-of-order completion made "latest state"
/// reads unreliable.
actor GitExecutor {
    /// Kept as an alias for callers/tests that time out against the drain
    /// cutoff; the actual drain logic lives in `Subprocess`.
    static let drainGracePeriod = Subprocess.drainGracePeriod

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
            // The command task is unstructured, so the caller's cancellation
            // is forwarded explicitly below. Cancelled while queued: skip the
            // spawn entirely. Cancelled while running: Subprocess terminates
            // the child.
            try Task.checkCancellation()
            return try await Self.execute(
                arguments,
                workingDirectory: workingDirectory,
                successCodes: successCodes,
                stdin: stdin
            )
        }
        tail = Task { _ = try? await task.value }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func execute(
        _ arguments: [String],
        workingDirectory: URL,
        successCodes: Set<Int32>,
        stdin: Data?
    ) async throws -> Data {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "en_US.UTF-8"
        // Editor env vars outrank `-c` config, so an inherited value (the
        // app launched from a shell) would silently defeat the pins the app
        // relies on — most critically the sequence.editor that injects the
        // interactive-rebase todo. The app never wants any editor.
        environment["GIT_SEQUENCE_EDITOR"] = nil
        environment["GIT_EDITOR"] = nil

        let result = try await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            // quotepath=false keeps non-ASCII paths raw in diff/log output
            // instead of C-quoted octal escapes.
            arguments: ["git", "--no-optional-locks", "-c", "color.ui=false", "-c", "core.quotepath=false"] + arguments,
            currentDirectory: workingDirectory,
            environment: environment,
            stdin: stdin
        )

        guard successCodes.contains(result.status) else {
            // Death by cancellation-triggered terminate() is not a git
            // failure — surface it as CancellationError so callers can tell
            // "superseded" from "broken".
            try Task.checkCancellation()
            throw GitError(
                command: arguments.joined(separator: " "),
                exitCode: result.status,
                stderr: String(decoding: result.stderr, as: UTF8.self)
            )
        }
        return result.stdout
    }
}
