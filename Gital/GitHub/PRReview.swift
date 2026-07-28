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
struct ReviewCommentAnchor: Hashable {
    enum Side: String {
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

/// One draft review comment. Like GitHub's pending reviews, drafts stay
/// local until the review is submitted together with a verdict.
struct PendingReviewComment: Identifiable, Hashable {
    let id: UUID
    let anchor: ReviewCommentAnchor
    var body: String

    init(id: UUID = UUID(), anchor: ReviewCommentAnchor, body: String) {
        self.id = id
        self.anchor = anchor
        self.body = body
    }
}
