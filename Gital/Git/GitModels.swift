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

// MARK: - Branches / tags / stashes

struct Branch: Hashable, Identifiable {
    let name: String
    let isCurrent: Bool
    let upstream: String?
    let tipHash: String

    var id: String { name }
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
