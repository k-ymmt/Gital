import Foundation

/// Locates CLI tools (`gh`, `codex`, …) for a GUI app whose environment PATH
/// lacks the user's shell setup. Tools are then executed directly — running
/// them through `zsh -lc` would let login-profile output (nvm banners etc.)
/// pollute stdout and corrupt JSON/protocol streams.
actor ExecutableLocator {
    static let shared = ExecutableLocator()

    private var hits: [String: URL] = [:]
    /// Misses are cached too — without this, every refresh with a tool not
    /// installed re-runs the slow login-shell lookup. They expire so a
    /// mid-session install is picked up on a later retry.
    private var missDeadlines: [String: Date] = [:]
    private static let missTTL: TimeInterval = 30

    func find(_ name: String) async -> URL? {
        if let hit = hits[name] { return hit }
        if let deadline = missDeadlines[name], deadline > Date() { return nil }

        var directories: [String] = []
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            directories += path.split(separator: ":").map(String.init)
        }
        directories += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/bin",
        ]

        let fileManager = FileManager.default
        var found: URL?
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                found = candidate
                break
            }
        }
        if found == nil {
            found = await loginShellLookup(name)
        }
        if let found {
            hits[name] = found
            missDeadlines[name] = nil
        } else {
            missDeadlines[name] = Date().addingTimeInterval(Self.missTTL)
        }
        return found
    }

    /// Last resort: ask a login shell where the tool lives. Only a verified
    /// executable path is taken from the output — profiles may print noise.
    private func loginShellLookup(_ name: String) async -> URL? {
        guard let result = try? await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-lc", "command -v -- " + name]
        ) else { return nil }

        let fileManager = FileManager.default
        for line in String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").reversed() {
            let candidate = String(line).trimmingCharacters(in: .whitespaces)
            if candidate.hasPrefix("/"), fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}
