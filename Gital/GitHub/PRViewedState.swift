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
                // stays viewed individually. A single-file commit leaves
                // nothing behind — an empty set here would break `isEmpty`.
                let remaining = Set(allPaths).subtracting([path])
                if !remaining.isEmpty {
                    commitFiles[commit] = remaining
                }
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
/// flag is one row, and saving writes only the rows a mutation actually
/// changed (old state vs. new state), inside a transaction — so a toggle's
/// cost is constant no matter how many PRs have accumulated, and a second
/// app instance with a stale in-memory picture can only affect the flags it
/// touched, never wipe another instance's progress wholesale. Failures make
/// the store inert rather than surfacing: losing review progress is never
/// worth failing an interaction over.
final class PRViewedStore: @unchecked Sendable {
    /// `sqlite3_bind_text` destructor telling SQLite to copy the string —
    /// required because Swift's bridged C strings die when the call returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// All SQLite access is confined to this serial queue — a raw sqlite3
    /// handle is not safe for concurrent use, and nothing else pins this
    /// class to one isolation domain. Calls stay synchronous (`queue.sync`)
    /// so callers keep today's ordering guarantees; the documented worst
    /// case remains the 1s busy timeout when a second instance holds the
    /// database.
    private let queue = DispatchQueue(label: "app.kymmt.Gital.PRViewedStore")

    private enum Kind: Int32 {
        case file = 0        // PR-wide "Files Changed" path (no commit)
        case commit = 1      // fully viewed commit (no path)
        case commitFile = 2  // viewed path inside a partially viewed commit
    }

    private struct Row: Hashable {
        let kind: Kind
        let hash: String
        let path: String
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
        // Another app instance (installed copy + DerivedData build) can hold
        // the database briefly; without a timeout any overlap surfaces as an
        // immediate SQLITE_BUSY failure.
        sqlite3_busy_timeout(handle, 1000)
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
        queue.sync { loadLocked() }
    }

    private func loadLocked() -> [Int: PRViewedState] {
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

    /// Writes one mutation as the row delta between the state before and
    /// after it: deletes rows the mutation removed, inserts rows it added,
    /// and touches nothing else — rows another instance wrote for the same
    /// PR survive. INSERT OR IGNORE absorbs the race where both instances
    /// viewed the same flag.
    func apply(from old: PRViewedState, to new: PRViewedState, for number: Int) {
        queue.sync { applyLocked(from: old, to: new, for: number) }
    }

    private func applyLocked(from old: PRViewedState, to new: PRViewedState, for number: Int) {
        guard let db else { return }
        let oldRows = Self.rows(of: old)
        let newRows = Self.rows(of: new)
        let deletes = oldRows.subtracting(newRows)
        let inserts = newRows.subtracting(oldRows)
        guard !deletes.isEmpty || !inserts.isEmpty else { return }

        guard beginTransaction() else { return }
        var ok = false
        // COMMIT can itself fail (e.g. SQLITE_BUSY); without the ROLLBACK the
        // transaction would stay open and every later BEGIN would fail,
        // silently dropping the rest of the session's toggles.
        defer {
            if !ok || !execute("COMMIT") { _ = execute("ROLLBACK") }
        }

        if !deletes.isEmpty {
            var delete: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "DELETE FROM viewed WHERE repo = ? AND pr = ? AND kind = ? AND commit_hash = ? AND path = ?",
                -1, &delete, nil
            ) == SQLITE_OK else { return }
            defer { sqlite3_finalize(delete) }
            for row in deletes {
                sqlite3_reset(delete)
                bind(row, number: number, to: delete)
                guard sqlite3_step(delete) == SQLITE_DONE else { return }
            }
        }

        if !inserts.isEmpty {
            var insert: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "INSERT OR IGNORE INTO viewed (repo, pr, kind, commit_hash, path) VALUES (?, ?, ?, ?, ?)",
                -1, &insert, nil
            ) == SQLITE_OK else { return }
            defer { sqlite3_finalize(insert) }
            for row in inserts {
                sqlite3_reset(insert)
                bind(row, number: number, to: insert)
                guard sqlite3_step(insert) == SQLITE_DONE else { return }
            }
        }
        ok = true
    }

    /// Binds a row to a statement whose first five parameters are
    /// (repo, pr, kind, commit_hash, path) — true for both DELETE and INSERT.
    private func bind(_ row: Row, number: Int, to statement: OpaquePointer?) {
        sqlite3_bind_text(statement, 1, repoKey, -1, Self.transient)
        sqlite3_bind_int64(statement, 2, Int64(number))
        sqlite3_bind_int(statement, 3, row.kind.rawValue)
        sqlite3_bind_text(statement, 4, row.hash, -1, Self.transient)
        sqlite3_bind_text(statement, 5, row.path, -1, Self.transient)
    }

    private static func rows(of state: PRViewedState) -> Set<Row> {
        var rows = Set<Row>()
        for path in state.files { rows.insert(Row(kind: .file, hash: "", path: path)) }
        for hash in state.commits { rows.insert(Row(kind: .commit, hash: hash, path: "")) }
        for (hash, paths) in state.commitFiles {
            for path in paths { rows.insert(Row(kind: .commitFile, hash: hash, path: path)) }
        }
        return rows
    }

    /// BEGIN, self-healing a transaction a failed COMMIT may have left open
    /// (a stuck transaction would otherwise disable saving for the rest of
    /// the session).
    private func beginTransaction() -> Bool {
        if execute("BEGIN") { return true }
        _ = execute("ROLLBACK")
        return execute("BEGIN")
    }

    private func execute(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}
