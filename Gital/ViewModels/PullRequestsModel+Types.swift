import Foundation

// Value types of the PR domain, kept apart from the model's state and
// actions in PullRequestsModel.swift.
extension PullRequestsModel {
    /// A selected row inside a PR's sidebar expansion: one of its commits or
    /// one of its changed files.
    enum ItemSelection: Equatable, Hashable {
        case commit(hash: String)
        case file(path: String)

        /// Stable string identity for agent-card anchoring: cards render
        /// inline only in the item they were asked in, because positional
        /// line IDs (and even ID + text pairs) are not unique across items.
        var agentAnchorKey: String {
            switch self {
            case .commit(let hash): "commit:\(hash)"
            case .file(let path): "file:\(path)"
            }
        }
    }

    enum StateFilter: String, CaseIterable, Identifiable {
        case all, open, draft, awaitingYourReview, merged, closed

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: "All"
            case .open: "Open"
            case .draft: "Draft"
            case .awaitingYourReview: "Awaiting review from you"
            case .merged: "Merged"
            case .closed: "Closed"
            }
        }

        /// Compact variant for the sidebar header chip, where the full
        /// "Awaiting review from you" label would crowd out the section title.
        var shortLabel: String {
            self == .awaitingYourReview ? "Awaiting review" : label
        }

        func matches(_ pr: PullRequestSummary, viewerLogin: String?) -> Bool {
            switch self {
            case .all: true
            // GitHub counts drafts as open, so Open includes them; Draft
            // narrows to drafts only.
            case .open: pr.state == "OPEN"
            case .draft: pr.state == "OPEN" && pr.isDraft
            case .awaitingYourReview:
                pr.state == "OPEN" && viewerLogin.map { login in
                    pr.reviewRequestLogins.contains { $0.caseInsensitiveCompare(login) == .orderedSame }
                } ?? false
            case .merged: pr.state == "MERGED"
            case .closed: pr.state == "CLOSED"
            }
        }
    }

    /// The review-comment composer's whole state as one value: every
    /// open/edit/close transition swaps the value atomically, so a field can
    /// never be updated in one transition and forgotten in another.
    struct ReviewComposer: Equatable {
        /// Anchor the composer is open at (for a multi-line comment, the
        /// range's LAST line, GitHub-style).
        var anchor: ReviewCommentAnchor
        /// Content of the anchored diff line, captured when the composer
        /// opens; stored on the draft for display matching and submit-time
        /// re-anchoring.
        var lineText: String
        /// First line of the range for a multi-line comment; nil while
        /// composing a single-line comment.
        var startAnchor: ReviewCommentAnchor?
        var startLineText: String?
        var text = ""
        /// Save-time validation failure shown inside the composer.
        var error: String?
        /// When set, the composer is editing this existing draft instead of
        /// adding a new one.
        var editingCommentID: UUID?

        /// The place the composer is open at, ignoring what's typed in it.
        var location: ReviewComposerLocation {
            ReviewComposerLocation(
                anchor: anchor, lineText: lineText,
                startAnchor: startAnchor, startLineText: startLineText
            )
        }
    }

    /// Where a composer is (or would be) open. Compares the line TEXTS too,
    /// not just the coordinates: the composer renders only where coordinates
    /// AND content match (commit diffs number files differently than the
    /// whole-PR diff).
    struct ReviewComposerLocation: Equatable {
        var anchor: ReviewCommentAnchor
        var lineText: String
        var startAnchor: ReviewCommentAnchor?
        var startLineText: String?
    }
}
