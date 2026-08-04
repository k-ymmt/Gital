import Foundation

/// Locates CLI tools (`gh`, `codex`, …) for a GUI app whose environment PATH
/// lacks the user's shell setup. The user's real PATH is captured once from
/// an interactive login shell: version managers (mise, asdf, nvm, …) are
/// activated in .zshrc, which only *interactive* shells source, so a plain
/// `zsh -lc` lookup misses everything they manage. Tools are then executed
/// directly — running them through the shell would let profile output (nvm
/// banners etc.) pollute stdout and corrupt JSON/protocol streams, so the
/// shell is involved only in the one-time PATH capture, whose env dump is
/// fenced by sentinel markers to keep that same noise out.
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

    func find(_ name: String) async -> URL? {
        if let hit = hits[name] { return hit }
        if let deadline = missDeadlines[name], deadline > Date() { return nil }

        var directories: [String] = await shellPathEntries()
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories += path.split(separator: ":").map(String.init)
        }
        // Last-resort fallbacks for when the shell capture fails: common
        // install locations plus version-manager shim directories (the shims
        // are self-contained executables and run fine without the manager's
        // shell environment).
        directories += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/bin",
            NSHomeDirectory() + "/.local/share/mise/shims",
            NSHomeDirectory() + "/.asdf/shims",
        ]

        let fileManager = FileManager.default
        var found: URL?
        var seen = Set<String>()
        for directory in directories where seen.insert(directory).inserted {
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

    // MARK: - Shell PATH capture

    private func shellPathEntries() async -> [String] {
        if let shellPaths { return shellPaths }
        if let deadline = shellPathsRetryDeadline, deadline > Date() { return [] }
        if let task = shellPathsTask { return await task.value ?? [] }

        let task = Task { await Self.captureShellPathEntries() }
        shellPathsTask = task
        let result = await task.value
        shellPathsTask = nil
        if let result {
            shellPaths = result
            shellPathsRetryDeadline = nil
        } else {
            shellPathsRetryDeadline = Date().addingTimeInterval(Self.missTTL)
        }
        return result ?? []
    }

    private static func captureShellPathEntries() async -> [String]? {
        // `-i` is what sources .zshrc; `-l` picks up .zprofile additions.
        // stdin is /dev/null (the Subprocess default), so a profile that
        // tries to read input fails fast instead of blocking — anything that
        // hangs anyway is cut off by the timeout below.
        let command = "echo '\(envBeginMarker)'; /usr/bin/env; echo '\(envEndMarker)'"
        let subprocess = Task {
            try? await Subprocess.run(
                executable: URL(fileURLWithPath: userShell()),
                arguments: ["-i", "-l", "-c", command]
            )
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(shellCaptureTimeout))
            subprocess.cancel()  // Subprocess terminates the child on cancellation
        }
        let result = await subprocess.value
        timeout.cancel()
        // A shell killed by the timeout (or otherwise dying) reports a
        // non-zero status; its partial output must not be trusted.
        guard let result, result.status == 0 else { return nil }
        return parsePathEntries(fromEnvOutput: String(decoding: result.stdout, as: UTF8.self))
    }

    /// Extracts PATH entries from an `env` dump fenced by the sentinel
    /// markers. Only lines inside the fence count — profiles may print
    /// arbitrary noise (including PATH-shaped lines) before it — and only
    /// absolute entries survive. Returns nil when no PATH line is found.
    static func parsePathEntries(fromEnvOutput output: String) -> [String]? {
        var insideFence = false
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if !insideFence {
                if line == envBeginMarker { insideFence = true }
                continue
            }
            if line == envEndMarker { return nil }
            guard line.hasPrefix("PATH=") else { continue }
            let entries = line.dropFirst("PATH=".count)
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
