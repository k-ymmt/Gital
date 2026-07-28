import Foundation

/// "Viewed" review-progress flags for one pull request.
///
/// Commit-level and file-level flags are linked both ways: marking a commit
/// viewed marks every file inside it viewed, and marking the last remaining
/// file of a commit viewed promotes the commit itself. A commit's file list
/// is only known once its diff has been loaded, so a commit in `commits`
/// counts as "all of its files viewed" without enumerating them.
struct PRViewedState: Codable, Equatable {
    /// Viewed paths in the PR-wide "Files Changed" list.
    var files: Set<String> = []
    /// Fully viewed commits (short hashes).
    var commits: Set<String> = []
    /// Viewed paths per partially viewed commit. Never contains hashes that
    /// are in `commits` — promotion moves them over.
    var commitFiles: [String: Set<String>] = [:]

    var isEmpty: Bool {
        files.isEmpty && commits.isEmpty && commitFiles.isEmpty
    }

    func isCommitViewed(_ hash: String) -> Bool {
        commits.contains(hash)
    }

    func isCommitFileViewed(commit: String, path: String) -> Bool {
        commits.contains(commit) || commitFiles[commit]?.contains(path) == true
    }

    mutating func setCommitViewed(_ viewed: Bool, hash: String) {
        // Either way the per-file record resets: viewed subsumes it, and
        // un-viewing a commit un-views all of its files with it.
        commitFiles.removeValue(forKey: hash)
        if viewed {
            commits.insert(hash)
        } else {
            commits.remove(hash)
        }
    }

    /// Toggles one file inside a commit. `allPaths` is the commit's complete
    /// file list (known because the toggle lives in the loaded diff view);
    /// it drives promotion to and demotion from commit-level viewed.
    mutating func toggleCommitFile(commit: String, path: String, allPaths: [String]) {
        if isCommitFileViewed(commit: commit, path: path) {
            if commits.remove(commit) != nil {
                // Demote: the commit was fully viewed, so every *other* file
                // stays viewed individually.
                commitFiles[commit] = Set(allPaths).subtracting([path])
            } else {
                commitFiles[commit]?.remove(path)
                if commitFiles[commit]?.isEmpty == true {
                    commitFiles.removeValue(forKey: commit)
                }
            }
        } else {
            var viewed = commitFiles[commit] ?? []
            viewed.insert(path)
            if !allPaths.isEmpty, allPaths.allSatisfy(viewed.contains) {
                setCommitViewed(true, hash: commit)
            } else {
                commitFiles[commit] = viewed
            }
        }
    }

    mutating func toggleFile(_ path: String) {
        if files.contains(path) {
            files.remove(path)
        } else {
            files.insert(path)
        }
    }
}

/// Persists `PRViewedState` per (repository, PR number) as JSON in
/// Application Support, so review progress survives app restarts. The on-disk
/// map is keyed by repository path, then by PR number; empty states are
/// pruned so closed-out reviews don't accumulate.
final class PRViewedStore {
    private let repoKey: String
    private let fileURL: URL

    init(repoRoot: URL, fileURL: URL? = nil) {
        self.repoKey = repoRoot.path
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gital/pr-viewed.json")
    }

    func load() -> [Int: PRViewedState] {
        let states = Self.readAll(from: fileURL)[repoKey] ?? [:]
        var result: [Int: PRViewedState] = [:]
        for (key, state) in states {
            if let number = Int(key) { result[number] = state }
        }
        return result
    }

    func save(_ states: [Int: PRViewedState]) {
        // Read-modify-write keeps other repositories' entries intact.
        var all = Self.readAll(from: fileURL)
        let kept = states.filter { !$0.value.isEmpty }
        if kept.isEmpty {
            all.removeValue(forKey: repoKey)
        } else {
            all[repoKey] = Dictionary(uniqueKeysWithValues: kept.map { (String($0.key), $0.value) })
        }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(all).write(to: fileURL, options: .atomic)
        } catch {
            // Losing review progress is annoying but never worth failing an
            // interaction over.
        }
    }

    private static func readAll(from url: URL) -> [String: [String: PRViewedState]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: PRViewedState]].self, from: data)) ?? [:]
    }
}
