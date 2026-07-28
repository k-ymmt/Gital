import Foundation

/// Review verdict sent when a pending review is submitted, in the GitHub
/// API's `event` spelling.
enum ReviewEvent: String, CaseIterable, Identifiable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .comment: "Comment"
        case .approve: "Approve"
        case .requestChanges: "Request changes"
        }
    }

    var detail: String {
        switch self {
        case .comment: "Submit general feedback without explicit approval."
        case .approve: "Submit feedback and approve merging these changes."
        case .requestChanges: "Submit feedback that must be addressed before merging."
        }
    }
}

/// Where a review comment hangs in the PR diff, in GitHub API terms: file
/// path plus a side (LEFT = old file, RIGHT = new file) and the line number
/// on that side. Anchoring by coordinates instead of `DiffLine.id` lets the
/// same comment surface in both the Files Changed diff and a commit diff,
/// whose parsed line IDs differ for the same physical line.
struct ReviewCommentAnchor: Hashable, Codable {
    enum Side: String, Codable {
        case left = "LEFT"
        case right = "RIGHT"
    }

    let path: String
    let side: Side
    let line: Int

    init(path: String, side: Side, line: Int) {
        self.path = path
        self.side = side
        self.line = line
    }

    /// Deletions anchor to the old side of the diff; additions and context
    /// lines to the new side — the same rule GitHub applies.
    init?(path: String, diffLine: DiffLine) {
        switch diffLine.kind {
        case .deletion:
            guard let old = diffLine.oldNumber else { return nil }
            self.init(path: path, side: .left, line: old)
        case .addition, .context:
            guard let new = diffLine.newNumber else { return nil }
            self.init(path: path, side: .right, line: new)
        }
    }

    /// Whether this anchor points at the given displayed diff line.
    func matches(_ diffLine: DiffLine) -> Bool {
        switch side {
        case .left:
            diffLine.kind == .deletion && diffLine.oldNumber == line
        case .right:
            diffLine.kind != .deletion && diffLine.newNumber == line
        }
    }
}

/// One draft review comment. Drafts stay local (persisted per repo by
/// `PendingReviewStore`) until the review is submitted together with a
/// verdict. `lineText` is the content of the anchored diff line at drafting
/// time — it lets display reject same-number-different-content lines and
/// lets submission re-anchor drafts whose line numbers no longer match the
/// PR's whole diff.
struct PendingReviewComment: Identifiable, Hashable, Codable {
    let id: UUID
    let anchor: ReviewCommentAnchor
    let lineText: String
    var body: String

    init(id: UUID = UUID(), anchor: ReviewCommentAnchor, lineText: String, body: String) {
        self.id = id
        self.anchor = anchor
        self.lineText = lineText
        self.body = body
    }

    /// Whether this draft belongs under the given displayed diff line: the
    /// coordinates must match AND the content must be the one the comment
    /// was written on. Commit diffs and the whole-PR diff number the same
    /// file differently, so a bare coordinate match would hang the comment
    /// under an unrelated line.
    func isAnchored(to diffLine: DiffLine, path: String) -> Bool {
        anchor.path == path && anchor.matches(diffLine) && lineText == diffLine.text
    }

    /// The anchor to submit to GitHub, resolved against the PR's whole
    /// base…head diff. GitHub interprets review coordinates against that
    /// diff, but a draft written on an individual commit's diff carries the
    /// commit's own numbering. Returns the anchor unchanged when it already
    /// points at a line with the drafted content, a re-anchored copy when
    /// the content moved but occurs exactly once on the anchor's side, and
    /// nil when the line can't be found — submitting then would either 422
    /// or silently attach the comment to the wrong line.
    func resolvedAnchor(in diffs: [FileDiff]) -> ReviewCommentAnchor? {
        guard let file = diffs.first(where: { $0.path == anchor.path }) else { return nil }
        let lines = file.hunks.flatMap(\.lines)
        if lines.contains(where: { anchor.matches($0) && $0.text == lineText }) {
            return anchor
        }
        let candidates = lines.filter { line in
            line.text == lineText
                && (anchor.side == .left ? line.kind == .deletion : line.kind != .deletion)
        }
        guard candidates.count == 1 else { return nil }
        return ReviewCommentAnchor(path: file.path, diffLine: candidates[0])
    }
}
