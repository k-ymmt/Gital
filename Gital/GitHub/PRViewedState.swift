import Foundation
import SQLite3

/// "Viewed" review-progress flags for one pull request.
///
/// Commit-level and file-level flags are linked both ways: marking a commit
/// viewed marks every file inside it viewed, and marking the last remaining
/// file of a commit viewed promotes the commit itself. A commit's file list
/// is only known once its diff has been loaded, so a commit in `commits`
/// counts as "all of its files viewed" without enumerating them.
struct PRViewedState: Equatable {
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

/// Persists `PRViewedState` per (repository, PR number) in a SQLite database
/// in Application Support, so review progress survives app restarts. Each
/// flag is one row; saving rewrites only the affected PR's rows inside a
/// transaction, so the cost of a toggle stays constant no matter how many
/// PRs have accumulated. Failures make the store inert rather than surfacing:
/// losing review progress is never worth failing an interaction over.
final class PRViewedStore {
    /// `sqlite3_bind_text` destructor telling SQLite to copy the string —
    /// required because Swift's bridged C strings die when the call returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private enum Kind: Int32 {
        case file = 0        // PR-wide "Files Changed" path (no commit)
        case commit = 1      // fully viewed commit (no path)
        case commitFile = 2  // viewed path inside a partially viewed commit
    }

    private let repoKey: String
    private var db: OpaquePointer?

    init(repoRoot: URL, databaseURL: URL? = nil) {
        repoKey = repoRoot.path
        let url = databaseURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gital/pr-viewed.sqlite")
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch { return }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            // Per SQLite docs the handle must be closed even when open fails.
            sqlite3_close(handle)
            return
        }
        db = handle
        if !execute("""
            CREATE TABLE IF NOT EXISTS viewed (
              repo TEXT NOT NULL,
              pr INTEGER NOT NULL,
              kind INTEGER NOT NULL,
              commit_hash TEXT NOT NULL DEFAULT '',
              path TEXT NOT NULL DEFAULT '',
              PRIMARY KEY (repo, pr, kind, commit_hash, path)
            ) WITHOUT ROWID
            """) {
            sqlite3_close(db)
            db = nil
        }
    }

    deinit {
        sqlite3_close(db)
    }

    func load() -> [Int: PRViewedState] {
        guard let db else { return [:] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT pr, kind, commit_hash, path FROM viewed WHERE repo = ?", -1, &statement, nil
        ) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, repoKey, -1, Self.transient)

        var result: [Int: PRViewedState] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let number = Int(sqlite3_column_int64(statement, 0))
            let hash = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            let path = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            var state = result[number] ?? PRViewedState()
            switch Kind(rawValue: sqlite3_column_int(statement, 1)) {
            case .file: state.files.insert(path)
            case .commit: state.commits.insert(hash)
            case .commitFile: state.commitFiles[hash, default: []].insert(path)
            case nil: continue
            }
            result[number] = state
        }
        return result
    }

    /// Replaces one PR's rows with the given state. An empty state just
    /// deletes, so cleared reviews leave no rows behind.
    func save(_ state: PRViewedState, for number: Int) {
        guard let db else { return }
        guard execute("BEGIN") else { return }

        var ok = false
        defer { _ = execute(ok ? "COMMIT" : "ROLLBACK") }

        var delete: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM viewed WHERE repo = ? AND pr = ?", -1, &delete, nil) == SQLITE_OK
        else { return }
        sqlite3_bind_text(delete, 1, repoKey, -1, Self.transient)
        sqlite3_bind_int64(delete, 2, Int64(number))
        let deleted = sqlite3_step(delete) == SQLITE_DONE
        sqlite3_finalize(delete)
        guard deleted else { return }

        var insert: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "INSERT INTO viewed (repo, pr, kind, commit_hash, path) VALUES (?, ?, ?, ?, ?)", -1, &insert, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(insert) }

        var rows: [(Kind, String, String)] = []
        rows.append(contentsOf: state.files.map { (.file, "", $0) })
        rows.append(contentsOf: state.commits.map { (.commit, $0, "") })
        for (hash, paths) in state.commitFiles {
            rows.append(contentsOf: paths.map { (.commitFile, hash, $0) })
        }
        for (kind, hash, path) in rows {
            sqlite3_reset(insert)
            sqlite3_bind_text(insert, 1, repoKey, -1, Self.transient)
            sqlite3_bind_int64(insert, 2, Int64(number))
            sqlite3_bind_int(insert, 3, kind.rawValue)
            sqlite3_bind_text(insert, 4, hash, -1, Self.transient)
            sqlite3_bind_text(insert, 5, path, -1, Self.transient)
            guard sqlite3_step(insert) == SQLITE_DONE else { return }
        }
        ok = true
    }

    private func execute(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}
