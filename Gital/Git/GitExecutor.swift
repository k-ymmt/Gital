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
/// Commands are serialized per lane: two concurrent index mutations would
/// otherwise race on `.git/index.lock`, and out-of-order completion made
/// "latest state" reads unreliable. Network commands run on a lane of their
/// own — a fetch hanging on a dead remote used to wedge the single chain and
/// froze every status/diff/log behind it for as long as the remote dangled.
actor GitExecutor {
    /// Serialization lane for a command.
    /// - `local`: everything that reads or mutates the index/worktree/refs;
    ///   one command at a time, as before.
    /// - `network`: fetch/push — can hang on a dead remote, never touches the
    ///   index, and must not stall local reads. Serialized among themselves
    ///   so two fetches can't race on remote-tracking ref locks.
    /// - `exclusive`: pull — mutates the worktree AND talks to the network,
    ///   so it serializes against both lanes.
    enum Lane {
        case local
        case network
        case exclusive
    }

    /// Kept as an alias for callers/tests that time out against the drain
    /// cutoff; the actual drain logic lives in `Subprocess`.
    static let drainGracePeriod = Subprocess.drainGracePeriod

    let workingDirectory: URL
    private var localTail: Task<Void, Never>?
    private var networkTail: Task<Void, Never>?

    init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory
    }

    @discardableResult
    func run(_ arguments: [String], lane: Lane = .local, successCodes: Set<Int32> = [0], stdin: Data? = nil) async throws -> String {
        let data = try await runData(arguments, lane: lane, successCodes: successCodes, stdin: stdin)
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

    func runData(_ arguments: [String], lane: Lane = .local, successCodes: Set<Int32> = [0], stdin: Data? = nil) async throws -> Data {
        let workingDirectory = self.workingDirectory
        // An exclusive command joins the local lane only once the network
        // lane has drained: queued behind a fetch hanging on a dead remote,
        // it would otherwise hold every local command hostage to that fetch.
        // It still claims the local lane before it runs, so local commands
        // queued after the claim wait for it.
        let previousLocal = lane == .local ? localTail : nil
        let previousNetwork = lane == .local ? nil : networkTail
        let (localRelease, releaseLocal) = AsyncStream<Never>.makeStream()
        let task = Task<Data, Error> {
            defer { releaseLocal.finish() }
            await previousLocal?.value
            await previousNetwork?.value
            if lane == .exclusive {
                await self.claimLocalLane(until: localRelease)?.value
            }
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
        let settled = Task { _ = try? await task.value }
        if lane == .local { localTail = settled }
        if lane != .local { networkTail = settled }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Makes the local lane wait until `release` finishes; returns the
    /// previous tail for the claimer to wait on.
    private func claimLocalLane(until release: AsyncStream<Never>) -> Task<Void, Never>? {
        let previous = localTail
        localTail = Task { for await _ in release {} }
        return previous
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

        // quotepath=false keeps non-ASCII paths raw in diff/log output
        // instead of C-quoted octal escapes.
        let gitArguments = ["--no-optional-locks", "-c", "color.ui=false", "-c", "core.quotepath=false"] + arguments
        let result: Subprocess.Output
        if let git = await GitBinary.resolved() {
            do {
                result = try await Subprocess.run(
                    executable: git,
                    arguments: gitArguments,
                    currentDirectory: workingDirectory,
                    environment: environment,
                    stdin: stdin
                )
            } catch {
                // The resolved binary vanished between validation and spawn:
                // re-resolve next time and run this one through env.
                GitBinary.invalidate()
                result = try await runThroughEnv(gitArguments, workingDirectory: workingDirectory, environment: environment, stdin: stdin)
            }
        } else {
            result = try await runThroughEnv(gitArguments, workingDirectory: workingDirectory, environment: environment, stdin: stdin)
        }

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

    /// The unresolved path: `/usr/bin/env git`, PATH lookup per spawn.
    private static func runThroughEnv(
        _ gitArguments: [String],
        workingDirectory: URL,
        environment: [String: String],
        stdin: Data?
    ) async throws -> Subprocess.Output {
        try await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + gitArguments,
            currentDirectory: workingDirectory,
            environment: environment,
            stdin: stdin
        )
    }
}
