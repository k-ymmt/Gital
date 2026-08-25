import Foundation

/// One-shot latch for racing completions: exactly one caller of `claim`
/// wins. Used to resume a continuation from whichever of two unstructured
/// tasks finishes first.
private nonisolated final class FirstWinner: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

/// Locates CLI tools (`gh`, `codex`, …) for a GUI app whose environment PATH
/// lacks the user's shell setup. The user's real PATH is captured once from
/// an interactive login shell: version managers (mise, asdf, nvm, …) are
/// activated in .zshrc, which only *interactive* shells source, so a plain
/// `zsh -lc` lookup misses everything they manage. Tools are then executed
/// directly — running them through the shell would let profile output (nvm
/// banners etc.) pollute stdout and corrupt JSON/protocol streams, so the
/// shell is involved only in the one-time PATH capture, whose env dump is
/// fenced by sentinel markers to keep that same noise out.
///
/// Locating a tool is not always enough to run it: asdf ≥0.16 shims are
/// `#!/usr/bin/env bash` scripts that need `asdf` on the child's PATH, and
/// npm-installed CLIs are `#!/usr/bin/env node` launchers that need `node`.
/// Call sites therefore spawn located tools with `toolEnvironment()`, which
/// carries the captured PATH along.
actor ExecutableLocator {
    static let shared = ExecutableLocator()

    private var hits: [String: URL] = [:]
    /// Misses are cached too — without this, every refresh with a tool not
    /// installed re-runs the tool search. They expire so a mid-session
    /// install is picked up on a later retry.
    private var missDeadlines: [String: Date] = [:]
    private static let missTTL: TimeInterval = 30

    /// PATH entries captured from the user's shell; nil until the first
    /// successful capture.
    private var shellPaths: [String]?
    /// Set after a failed capture so the (potentially slow) shell spawn is
    /// not retried on every lookup; expires like a tool miss.
    private var shellPathsRetryDeadline: Date?
    /// Single-flight: concurrent `find` calls await one capture.
    private var shellPathsTask: Task<[String]?, Never>?

    static let envBeginMarker = "<<GITAL-ENV-BEGIN>>"
    static let envEndMarker = "<<GITAL-ENV-END>>"
    /// Interactive shells can hang on a profile that prompts or blocks;
    /// after this long the capture is abandoned (and retried later).
    static let shellCaptureTimeout: TimeInterval = 10
    /// How long a lookup waits for the capture before falling through to the
    /// fallback directories: the capture's own timeout, plus the
    /// SIGTERM→SIGKILL escalation and post-exit drain windows, plus margin.
    /// If the capture is still unresolved past that point, the shell could
    /// not be reaped even by SIGKILL (e.g. wedged in uninterruptible disk
    /// wait) — lookups must proceed without it rather than hang.
    static let captureWaitLimit: TimeInterval =
        shellCaptureTimeout + Subprocess.terminateGracePeriod + Subprocess.drainGracePeriod + 2

    func find(_ name: String) async -> URL? {
        // A hit is revalidated before reuse: an upgrade/uninstall can remove
        // the cached binary mid-session, and a stale path would fail every
        // spawn until app restart.
        if let hit = hits[name] {
            if FileManager.default.isExecutableFile(atPath: hit.path) { return hit }
            hits[name] = nil
        }
        if let deadline = missDeadlines[name], deadline > Date() { return nil }

        let fileManager = FileManager.default
        var found: URL?
        for directory in await searchDirectories() {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                found = candidate
                break
            }
        }
        if let found {
            hits[name] = found
            missDeadlines[name] = nil
        } else {
            missDeadlines[name] = Date().addingTimeInterval(Self.missTTL)
        }
        return found
    }

    /// The environment to spawn a located tool with: the app's own
    /// environment, with PATH widened to the full search list. Required for
    /// PATH-dependent launchers (asdf shims, `#!/usr/bin/env node` scripts),
    /// and it also lets the tools' own children (git, editors, helpers)
    /// resolve the way they do in the user's terminal.
    func toolEnvironment() async -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = await searchDirectories().joined(separator: ":")
        return environment
    }

    /// Deduplicated search list: the captured shell PATH first, then the
    /// app's launch PATH, then last-resort fallbacks for when the capture
    /// fails — common install locations plus version-manager shim
    /// directories.
    private func searchDirectories() async -> [String] {
        var directories: [String] = await shellPathEntries()
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories += path.split(separator: ":").map(String.init)
        }
        directories += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/bin",
            NSHomeDirectory() + "/.local/share/mise/shims",
            NSHomeDirectory() + "/.asdf/shims",
        ]
        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
    }

    // MARK: - Shell PATH capture

    private func shellPathEntries() async -> [String] {
        if let shellPaths { return shellPaths }
        if let deadline = shellPathsRetryDeadline, deadline > Date() { return [] }

        let task: Task<[String]?, Never>
        if let existing = shellPathsTask {
            task = existing
        } else {
            let capture = Task { await Self.captureShellPathEntries() }
            shellPathsTask = capture
            task = capture
            // Bookkeeping runs off the caller: the result must be recorded
            // (and the single-flight slot freed) even when every original
            // caller gave up waiting below.
            Task { await self.recordCapture(of: capture) }
        }
        // Deadline-bounded wait — the second line of defense after the
        // subprocess-level kill escalation. A capture that outlives the
        // limit is abandoned by its waiters, and lookups proceed with the
        // fallback directories.
        return await Self.value(of: task, within: Self.captureWaitLimit) ?? []
    }

    /// Waits out the capture with no deadline and records its result. Only
    /// ever running for the task in `shellPathsTask` — creation is gated on
    /// the slot being empty, and only this method clears it.
    private func recordCapture(of task: Task<[String]?, Never>) async {
        let result = await task.value
        shellPathsTask = nil
        if let result {
            shellPaths = result
            shellPathsRetryDeadline = nil
        } else {
            shellPathsRetryDeadline = Date().addingTimeInterval(Self.missTTL)
        }
    }

    /// Awaits the task's value, giving up after `limit`. `value` on a
    /// never-failing Task does not respond to cancellation, so a task group
    /// would hang with it — the race uses two unstructured tasks and a
    /// first-wins latch instead. On timeout the small awaiting task is
    /// abandoned; it retains only the capture task and dies with it.
    private static func value<T: Sendable>(of task: Task<T?, Never>, within limit: TimeInterval) async -> T? {
        await withCheckedContinuation { continuation in
            let winner = FirstWinner()
            Task {
                let value = await task.value
                if winner.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(limit))
                if winner.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private static func captureShellPathEntries() async -> [String]? {
        let shell = userShell()
        // `-i` is what sources .zshrc; `-l` picks up .zprofile additions —
        // except in csh/tcsh, which reject `-l` combined with any other flag
        // (their interactive setup lives in ~/.tcshrc, which `-i` covers).
        // `env -0` separates entries with NUL, which no value can contain;
        // newline-separated output is ambiguous because multiline values
        // (e.g. exported bash functions) can forge PATH-shaped lines.
        // stdin is /dev/null (the Subprocess default), so a profile that
        // tries to read input fails fast instead of blocking — anything that
        // hangs anyway is cut off by the timeout below.
        let command = "echo '\(envBeginMarker)'; /usr/bin/env -0; echo '\(envEndMarker)'"
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        let arguments = shellName == "csh" || shellName == "tcsh"
            ? ["-i", "-c", command]
            : ["-i", "-l", "-c", command]
        let subprocess = Task {
            try? await Subprocess.run(
                executable: URL(fileURLWithPath: shell),
                arguments: arguments
            )
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(shellCaptureTimeout))
            // Cancellation SIGTERMs the shell and escalates to SIGKILL —
            // interactive shells ignore plain SIGTERM.
            subprocess.cancel()
        }
        let result = await subprocess.value
        timeout.cancel()
        // A shell reaped by the kill escalation dies by signal (non-zero
        // status) and is rejected here. A shell that unblocked after the
        // SIGTERM and still exited 0 produced a complete dump; either way a
        // truncated dump is never trusted, because the parser also requires
        // the closing marker.
        guard let result, result.status == 0 else { return nil }
        return parsePathEntries(fromEnvOutput: String(decoding: result.stdout, as: UTF8.self))
    }

    /// Extracts PATH entries from a NUL-separated `env -0` dump fenced by
    /// the sentinel markers. Both markers are required — a dump cut off
    /// before the closing marker is never trusted. Only a NUL-delimited
    /// entry that itself starts with `PATH=` counts: values may contain
    /// anything but NUL (including newlines and `PATH=` text), so no value
    /// can forge an entry. Relative entries are dropped. Returns nil when no
    /// PATH is found.
    static func parsePathEntries(fromEnvOutput output: String) -> [String]? {
        guard let fenceStart = output.range(of: envBeginMarker + "\n"),
              let fenceEnd = output.range(of: envEndMarker, range: fenceStart.upperBound..<output.endIndex)
        else { return nil }
        for entry in output[fenceStart.upperBound..<fenceEnd.lowerBound].split(separator: "\0") {
            guard entry.hasPrefix("PATH=") else { continue }
            let entries = entry.dropFirst("PATH=".count)
                .split(separator: ":")
                .map(String.init)
                .filter { $0.hasPrefix("/") }
            return entries.isEmpty ? nil : entries
        }
        return nil
    }

    /// The user's login shell: $SHELL when the launch environment provides
    /// one, else the account's shell from the user database.
    private static func userShell() -> String {
        let fileManager = FileManager.default
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           shell.hasPrefix("/"), fileManager.isExecutableFile(atPath: shell) {
            return shell
        }
        if let passwd = getpwuid(getuid()), let raw = passwd.pointee.pw_shell {
            let shell = String(cString: raw)
            if fileManager.isExecutableFile(atPath: shell) { return shell }
        }
        return "/bin/zsh"
    }
}
