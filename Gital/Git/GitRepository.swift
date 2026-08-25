import Foundation

/// Branch/remote operation refused before reaching git — the configuration
/// is ambiguous and guessing would do the wrong thing silently.
struct BranchOperationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) { self.message = message }
}

/// High-level git operations backed by the git CLI. Split by domain into
/// `GitRepository+*.swift` extension files; this file holds the stored
/// state and the few helpers shared across domains.
///
/// `nonisolated`: the app module defaults to MainActor, which put every
/// output parse (log, diffs, status, blame) on the main thread — a 50k-line
/// diff parse stalled the UI for hundreds of milliseconds on every refresh.
/// With the class opted out, awaited calls from the UI run parsing on the
/// concurrent executor and only the results hop back.
nonisolated final class GitRepository: @unchecked Sendable {
    let root: URL
    /// Internal (not private) so the domain extension files can reach it.
    let executor: GitExecutor

    var name: String { root.lastPathComponent }
    var displayPath: String {
        root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    init(root: URL) {
        self.root = root
        self.executor = GitExecutor(workingDirectory: root)
    }

    static func discover(at url: URL) async -> GitRepository? {
        let executor = GitExecutor(workingDirectory: url)
        guard let output = try? await executor.run(["rev-parse", "--show-toplevel"]) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return GitRepository(root: URL(fileURLWithPath: path))
    }

    static func changeStatus(_ char: Character) -> FileChange.Status {
        switch char {
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "U": .conflicted
        default: .modified
        }
    }

    /// Whether HEAD resolves to a commit — false on an unborn branch.
    /// Throws only on cancellation: a cancelled probe must not read as
    /// "unborn HEAD", which would make reflog() return empty and log()
    /// retry a command the caller already abandoned.
    func headExists() async throws -> Bool {
        do {
            _ = try await executor.run(["rev-parse", "--verify", "--quiet", "HEAD"])
            return true
        } catch {
            try Task.checkCancellation()
            return false
        }
    }

    /// Names of configured remotes. Failure degrades to an empty set — refs
    /// then classify as local branches — because log/detail loading must not
    /// fail outright over a broken `git remote`.
    func remoteNames() async -> Set<String> {
        Set(((try? await executor.run(["remote"])) ?? "").split(separator: "\n").map(String.init))
    }
}
