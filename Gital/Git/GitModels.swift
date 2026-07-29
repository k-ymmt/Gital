import Foundation

// MARK: - Refs

struct GitRef: Hashable, Identifiable {
    enum Kind: Hashable {
        case head          // current branch (HEAD -> ...)
        case branch        // local branch
        case remoteBranch  // origin/...
        case tag
    }

    let kind: Kind
    let name: String

    var id: String { "\(kind)-\(name)" }
}

// MARK: - Commit

struct Commit: Hashable, Identifiable {
    let hash: String
    let parents: [String]
    let author: String
    let authorEmail: String
    let relativeDate: String
    let subject: String
    let body: String
    let refs: [GitRef]

    var id: String { hash }
    var shortHash: String { String(hash.prefix(7)) }

    var authorInitials: String {
        let words = author.split(separator: " ")
        let initials = words.prefix(2).compactMap { $0.first }
        return String(initials).uppercased()
    }
}

/// Full metadata for one commit, loaded on selection: absolute dates, the
/// committer, and the whole message — none of which the log list carries.
struct CommitDetail: Hashable {
    let hash: String
    let parents: [String]
    let author: String
    let authorEmail: String
    let authorDate: String
    let committer: String
    let committerEmail: String
    let committerDate: String
    let refs: [GitRef]
    let message: String

    var shortHash: String { String(hash.prefix(7)) }

    var hasDistinctCommitter: Bool {
        committer != author || committerEmail != authorEmail || committerDate != authorDate
    }
}

// MARK: - Working copy status

struct FileChange: Hashable, Identifiable {
    enum Status: Hashable {
        case modified, added, deleted, renamed, copied, typeChanged, untracked, conflicted

        var badge: String {
            switch self {
            case .modified: "M"
            case .added: "A"
            case .deleted: "D"
            case .renamed: "R"
            case .copied: "C"
            case .typeChanged: "T"
            case .untracked: "A"
            case .conflicted: "U"
            }
        }
    }

    let path: String
    let originalPath: String?
    let status: Status

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

struct WorkingStatus {
    var branch: String?
    var upstream: String?
    var ahead: Int = 0
    var behind: Int = 0
    var staged: [FileChange] = []
    var unstaged: [FileChange] = []

    static let empty = WorkingStatus()
}

// MARK: - Merge / rebase state

/// A multi-step git operation that can stop on conflicts and then must be
/// continued or aborted.
enum RepoOperation: String, Hashable {
    case merge, rebase, cherryPick = "cherry-pick", revert

    var displayName: String {
        switch self {
        case .merge: "Merge"
        case .rebase: "Rebase"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        }
    }

    /// What "--ours" means to the user. During a rebase HEAD points at the
    /// base the branch is replayed onto, so ours/theirs read inverted from
    /// every other operation.
    var oursDescription: String {
        self == .rebase ? "Base Branch" : "Current Branch"
    }

    var theirsDescription: String {
        self == .rebase ? "Rebased Commit" : "Incoming Change"
    }
}

/// Which side of a conflict to take wholesale (`git checkout --ours/--theirs`).
enum ConflictSide: String {
    case ours, theirs
}

// MARK: - Interactive rebase

/// One commit in the span an interactive rebase would rewrite.
struct RebaseCommit: Hashable, Identifiable {
    let hash: String
    let subject: String
    /// Full message (subject + body) — prefills the reword editor and feeds
    /// squash-combined messages.
    let message: String
    let author: String
    let isMerge: Bool

    var id: String { hash }
    var shortHash: String { String(hash.prefix(7)) }
}

/// What to do with one commit in an interactive rebase plan.
enum RebaseAction: String, CaseIterable, Identifiable {
    case pick, reword, squash, fixup, drop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pick: "Pick"
        case .reword: "Reword"
        case .squash: "Squash"
        case .fixup: "Fixup"
        case .drop: "Drop"
        }
    }
}

/// One row of an interactive rebase plan: a commit, the chosen action, and a
/// message draft. The draft is prefilled with the original message; it is
/// consulted for reword (the rewritten message) and squash (appended to the
/// target commit's message), and ignored otherwise.
struct RebaseStep: Hashable, Identifiable {
    let commit: RebaseCommit
    var action: RebaseAction = .pick
    var message: String

    var id: String { commit.id }
}

// MARK: - Branches / tags / stashes

struct Branch: Hashable, Identifiable {
    let name: String
    let isCurrent: Bool
    let upstream: String?
    let tipHash: String
    /// Remote the upstream lives on (`%(upstream:remotename)`): "." for a
    /// branch tracking a local branch, nil when there is no upstream.
    let upstreamRemote: String?

    var id: String { name }

    /// True when the upstream is another local branch — there is nothing to
    /// push, and the sidebar's Push item disables itself on it.
    var tracksLocalBranch: Bool { upstreamRemote == "." }
}

struct RemoteInfo: Hashable, Identifiable {
    let name: String
    let branches: [String]

    var id: String { name }
}

struct Tag: Hashable, Identifiable {
    let name: String
    let tipHash: String

    var id: String { name }
}

struct Stash: Hashable, Identifiable {
    let index: Int
    let reference: String  // stash@{0} — positional, valid only for the list it came from
    /// Commit hash of the stash — the stable identity used to re-resolve the
    /// positional reference right before apply/pop/drop, so an outdated list
    /// can never target the wrong stash.
    let commitHash: String
    let message: String

    var id: String { commitHash }
}

// MARK: - Diff

struct DiffLine: Hashable, Identifiable {
    enum Kind: Hashable {
        case context, addition, deletion
    }

    let id: String
    let kind: Kind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
    /// True when git emitted "\ No newline at end of file" after this line —
    /// needed to rebuild an applyable patch for hunk staging.
    var noNewline: Bool = false

    var sign: String {
        switch kind {
        case .context: " "
        case .addition: "+"
        case .deletion: "-"
        }
    }
}

struct DiffHunk: Hashable, Identifiable {
    let id: String
    let header: String
    let oldStart: Int
    let newStart: Int
    let lines: [DiffLine]
}

/// Which comparison a `FileDiff` came from — decides whether hunks can be
/// staged, unstaged, or are read-only.
enum DiffScope: Hashable {
    case unstaged   // worktree vs index (`git diff`)
    case staged     // index vs HEAD (`git diff --cached`)
    case untracked  // synthetic all-additions diff for an untracked file
    case snapshot   // commit / stash / any read-only diff
}

struct FileDiff: Hashable, Identifiable {
    let path: String
    let oldPath: String?
    let isBinary: Bool
    /// True when the raw diff bytes were not valid UTF-8 and line text holds
    /// replacement characters — patches rebuilt from it would never apply, so
    /// hunk/line staging is disabled for such files.
    var containsInvalidUTF8: Bool = false
    /// True for combined (`diff --cc`, `@@@`) output — a conflicted path
    /// during a merge/rebase. Stage/discard affordances must not appear on
    /// such diffs: partial patches can't be built from combined hunks, and
    /// the whole-file fallback would mark the conflict resolved with the
    /// markers still in the file.
    var isCombined: Bool = false
    let hunks: [DiffHunk]
    var scope: DiffScope = .snapshot

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }

    var additions: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count }
    }

    var deletions: Int {
        hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count }
    }
}

// MARK: - File history / blame

/// One commit in a single file's history (`git log --follow`), carrying the
/// path the file had *at that commit* — pathspecs against older commits must
/// use the pre-rename name or the diff comes back empty.
struct FileHistoryEntry: Hashable, Identifiable {
    let hash: String
    let author: String
    let authorEmail: String
    let relativeDate: String
    let subject: String
    let path: String
    /// Pre-rename path when this commit renamed (or copied) the file.
    let previousPath: String?
    /// nil when the commit carried no name-status entry for the file (a
    /// merge kept in the walk) — the row then shows no fabricated badge.
    let status: FileChange.Status?

    var id: String { hash }
    var shortHash: String { String(hash.prefix(7)) }
}

struct BlameLine: Hashable, Identifiable {
    /// Line number in the blamed revision of the file.
    let number: Int
    let hash: String
    /// First line of a contiguous group from the same commit; annotation
    /// columns render only here.
    let isGroupStart: Bool
    let text: String

    var id: Int { number }
    /// All-zero hash: the line is not committed yet (working-tree blame).
    var isUncommitted: Bool { hash.allSatisfy { $0 == "0" } }
}

struct BlameAnnotation: Hashable {
    let author: String
    let date: String
    let summary: String
}

struct BlameFile: Hashable {
    let lines: [BlameLine]
    /// Commit metadata keyed by hash; porcelain output emits it once per
    /// commit, not per line.
    let annotations: [String: BlameAnnotation]
}

struct CommitFileStat: Hashable, Identifiable {
    let path: String
    /// Pre-rename path when status is `.renamed`; needed as a pathspec so the
    /// commit diff for the file isn't empty.
    var oldPath: String? = nil
    let status: FileChange.Status
    let additions: Int
    let deletions: Int

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
}

// MARK: - Split diff rows

struct SplitDiffRow: Hashable, Identifiable {
    struct Side: Hashable {
        let number: Int?
        let text: String?
        let kind: DiffLine.Kind?
    }

    let id: String
    let isHunkHeader: Bool
    let hunkText: String
    let left: Side
    let right: Side

    static func rows(for hunks: [DiffHunk]) -> [SplitDiffRow] {
        var rows: [SplitDiffRow] = []
        var nextID = 0
        let emptySide = Side(number: nil, text: nil, kind: nil)

        for hunk in hunks {
            rows.append(SplitDiffRow(id: "\(hunk.id)#\(nextID)", isHunkHeader: true, hunkText: hunk.header, left: emptySide, right: emptySide))
            nextID += 1

            var pendingDeletions: [DiffLine] = []
            var pendingAdditions: [DiffLine] = []

            func flushPending() {
                let count = max(pendingDeletions.count, pendingAdditions.count)
                for i in 0..<count {
                    let del = i < pendingDeletions.count ? pendingDeletions[i] : nil
                    let add = i < pendingAdditions.count ? pendingAdditions[i] : nil
                    rows.append(SplitDiffRow(
                        id: "\(hunk.id)#\(nextID)",
                        isHunkHeader: false,
                        hunkText: "",
                        left: del.map { Side(number: $0.oldNumber, text: $0.text, kind: .deletion) } ?? emptySide,
                        right: add.map { Side(number: $0.newNumber, text: $0.text, kind: .addition) } ?? emptySide
                    ))
                    nextID += 1
                }
                pendingDeletions.removeAll()
                pendingAdditions.removeAll()
            }

            for line in hunk.lines {
                switch line.kind {
                case .deletion:
                    pendingDeletions.append(line)
                case .addition:
                    pendingAdditions.append(line)
                case .context:
                    flushPending()
                    rows.append(SplitDiffRow(
                        id: "\(hunk.id)#\(nextID)",
                        isHunkHeader: false,
                        hunkText: "",
                        left: Side(number: line.oldNumber, text: line.text, kind: .context),
                        right: Side(number: line.newNumber, text: line.text, kind: .context)
                    ))
                    nextID += 1
                }
            }
            flushPending()
        }
        return rows
    }
}
