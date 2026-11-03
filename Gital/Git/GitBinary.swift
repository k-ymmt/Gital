import Foundation
import Synchronization

/// Resolves the `git` executable once instead of going through
/// `/usr/bin/env git` on every command.
///
/// For a GUI app PATH is the system default, so `env` lands on
/// `/usr/bin/git` — the Xcode shim, which runs an `xcrun` lookup before
/// exec'ing the real binary. That indirection measured ~6–10ms per spawn
/// (50 `rev-parse HEAD` runs: 0.61s via the shim vs 0.32s direct), on the
/// serialized local lane, for every one of the dozen-plus git runs a
/// refresh makes. Resolution follows the same PATH walk `env` does, then
/// asks `xcrun` for the shim's target — the lookup the shim itself would
/// make — so the binary that runs is unchanged.
nonisolated enum GitBinary {
    /// The Xcode shim; anything else found on PATH runs as-is.
    static let xcodeShimPath = "/usr/bin/git"

    private static let cache = Mutex<URL?>(nil)

    /// The real git binary, or nil when it can't be resolved (callers then
    /// fall back to `/usr/bin/env git`). A cached path is revalidated on
    /// each use: an Xcode removed or replaced mid-session must not strand
    /// every git command on a path that no longer exists.
    static func resolved() async -> URL? {
        if let hit = cache.withLock({ $0 }) {
            if FileManager.default.isExecutableFile(atPath: hit.path) { return hit }
            invalidate()
        }
        guard let found = await resolve() else { return nil }
        cache.withLock { $0 = found }
        return found
    }

    static func invalidate() {
        cache.withLock { $0 = nil }
    }

    private static func resolve() async -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        guard let onPath = firstExecutable(named: "git", inPATH: path) else { return nil }
        guard onPath.path == xcodeShimPath else { return onPath }
        guard let output = try? await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["--find", "git"]
        ), output.status == 0 else { return onPath }
        let target = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, FileManager.default.isExecutableFile(atPath: target) else { return onPath }
        return URL(fileURLWithPath: target)
    }

    /// `env`'s lookup: the first executable `name` in PATH order. Empty
    /// entries mean the current directory to `env`; a GUI app's cwd is `/`,
    /// so they are skipped rather than resolved against it.
    static func firstExecutable(named name: String, inPATH path: String) -> URL? {
        for directory in path.split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
