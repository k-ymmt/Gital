import Foundation

/// A published review conversation on a PR diff line, fetched from GitHub
/// (unlike `PendingReviewComment`, which is a local draft). Threads come from
/// the GraphQL API because REST exposes neither the resolved state nor the
/// thread node ID that the resolve/unresolve mutations need.
struct ReviewThread: Identifiable, Hashable {
    struct Comment: Identifiable, Hashable {
        /// REST `databaseId`, the ID the reply endpoint takes.
        let id: Int
        let authorLogin: String
        let body: String
        /// Already formatted for display ("2 days ago").
        let createdAt: String
    }

    /// GraphQL node ID, consumed by the resolve/unresolve mutations.
    let id: String
    let path: String
    let side: ReviewCommentAnchor.Side
    /// Line in the PR's current base…head diff; nil when the thread is
    /// outdated (the code it was written on is gone from the diff).
    let line: Int?
    /// Content of the anchored line, recovered from the anchor comment's
    /// `diffHunk` excerpt. Display requires it to match the shown diff line —
    /// commit diffs number files differently than the whole-PR diff, so a
    /// bare coordinate match would hang the thread under an unrelated line.
    let lineText: String?
    let isResolved: Bool
    let isOutdated: Bool
    let comments: [Comment]

    /// Whether this thread belongs under the given displayed diff line:
    /// coordinates must match AND, when the anchor line's content is known,
    /// the content must match too.
    func isAnchored(to diffLine: DiffLine, path: String) -> Bool {
        guard self.path == path, let line else { return false }
        guard ReviewCommentAnchor(path: path, side: side, line: line).matches(diffLine) else { return false }
        return lineText.map { $0 == diffLine.text } ?? true
    }

    /// The anchored line's content from a GraphQL `diffHunk` excerpt, which
    /// always ends at the comment's line: the last content line, with its
    /// +/-/space prefix stripped (the same normalization `DiffParser`
    /// applies, so the two compare directly). Nil when the excerpt holds no
    /// content line (file-level comments carry only the `@@` header).
    static func lineText(fromDiffHunk hunk: String?) -> String? {
        guard let hunk else { return nil }
        let lines = hunk.split(separator: "\n", omittingEmptySubsequences: false)
        guard let last = lines.last(where: { line in
            guard let first = line.first else { return false }
            return first == "+" || first == "-" || first == " "
        }) else { return nil }
        return String(last.dropFirst())
    }
}
