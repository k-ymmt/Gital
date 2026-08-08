import SwiftUI

/// Number span of a review comment range: "40–44", "39–41 (old)" when both
/// ends sit on the old side, or "44 (new)–41 (old)" when the range crosses
/// sides — old and new numbers aren't comparable, so a cross-side range can
/// read numerically backwards unless each end names its side.
func reviewRangeText(start: ReviewCommentAnchor, end: ReviewCommentAnchor) -> String {
    guard start.side != end.side else {
        return "\(start.line)–\(end.line)\(end.side == .left ? " (old)" : "")"
    }
    func mark(_ anchor: ReviewCommentAnchor) -> String { anchor.side == .left ? " (old)" : " (new)" }
    return "\(start.line)\(mark(start))–\(end.line)\(mark(end))"
}

/// Label for a draft card rendered under `diff`. The card hangs under its
/// END line, which matched the displayed diff (coordinates + content) or the
/// card wouldn't render — but the START carries drafting-time numbering,
/// which a differently-numbered diff (commit vs whole-PR) may not share. A
/// range label only shows when the start also matches the displayed diff;
/// otherwise it falls back to the end line rather than pairing numbers from
/// two coordinate systems.
func pendingCommentLineLabel(for comment: PendingReviewComment, in diff: FileDiff) -> String {
    guard let start = comment.startAnchor, let startText = comment.startLineText,
          diff.hunks.contains(where: { $0.lines.contains { start.matches($0) && $0.text == startText } })
    else {
        return "Line \(comment.anchor.line)\(comment.anchor.side == .left ? " (old)" : "")"
    }
    return "Lines \(reviewRangeText(start: start, end: comment.anchor))"
}

/// A draft review comment shown inline under its anchor line. Drafts stay
/// pending until the review is submitted.
struct PendingReviewCommentCard: View {
    var model: RepoViewModel
    let comment: PendingReviewComment
    /// The diff the card renders under; see `pendingCommentLineLabel`.
    let diff: FileDiff
    let number: Int

    private var lineLabel: String {
        pendingCommentLineLabel(for: comment, in: diff)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Pending")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(DesignStyle.tagAmber.opacity(0.18), in: Capsule())
                    .foregroundStyle(DesignStyle.tagAmber)
                Text(lineLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Edit") {
                    model.prs.editComment(comment)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(DesignStyle.linkBlue)
                Button("Delete") {
                    model.prs.deleteComment(comment.id, in: number)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(DesignStyle.deletion)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.3))
            Divider()
            Text(comment.body)
                .font(.system(size: 12.5))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .cardStyle()
        .padding(.leading, 60)
        .padding(.trailing, 16)
        .padding(.vertical, 5)
    }
}

/// Inline composer for adding or editing a draft review comment, anchored
/// under the diff line it targets.
struct ReviewCommentComposerView: View {
    var model: RepoViewModel
    let number: Int

    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var prs = model.prs
        VStack(alignment: .leading, spacing: 8) {
            if let start = model.prs.composer?.startAnchor, let end = model.prs.composer?.anchor {
                Text("Commenting on lines \(reviewRangeText(start: start, end: end))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            PlaceholderTextEditor(text: $prs.composerText, placeholder: "Leave a review comment")
                .focused($focused)
            if let error = model.prs.composer?.error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignStyle.deletion)
            }
            HStack(spacing: 8) {
                Text("Drafts are submitted together with your review.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    model.prs.closeReviewComposer()
                }
                .controlSize(.small)
                Button(model.prs.composer?.editingCommentID == nil ? "Add review comment" : "Save comment") {
                    model.prs.saveComposerComment(in: number)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(prs.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .cardStyle()
        .padding(.leading, 60)
        .padding(.trailing, 16)
        .padding(.vertical, 5)
        .onAppear { focused = true }
    }
}

/// "Review changes" button with the pending draft count, opening the review
/// submission form as a popover — the GitHub Files Changed flow.
struct ReviewChangesButton: View {
    var model: RepoViewModel
    let number: Int

    @State private var showForm = false

    var body: some View {
        let count = model.prs.pendingComments(for: number).count
        Button {
            showForm = true
        } label: {
            HStack(spacing: 5) {
                Text("Review changes")
                    .font(.system(size: 12))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.white.opacity(0.25), in: Capsule())
                }
            }
        }
        .buttonStyle(.glassProminent)
        .tint(DesignStyle.addition)
        .controlSize(.small)
        .popover(isPresented: $showForm, arrowEdge: .bottom) {
            ReviewSubmitForm(model: model, number: number, isPresented: $showForm)
        }
    }
}

/// Popover form finishing a review: optional summary, verdict radio group,
/// and the submit action that sends every draft comment along with it.
struct ReviewSubmitForm: View {
    var model: RepoViewModel
    let number: Int
    @Binding var isPresented: Bool

    @State private var event: ReviewEvent = .comment
    @State private var summary = ""

    private var pendingCount: Int {
        model.prs.pendingComments(for: number).count
    }

    /// GitHub rejects APPROVE / REQUEST_CHANGES on the viewer's own PR.
    private var isOwnPR: Bool {
        guard let login = model.prs.viewerLogin,
              let author = model.prs.detailsCache[number]?.authorLogin else { return false }
        return login.caseInsensitiveCompare(author) == .orderedSame
    }

    /// Verdicts the API can accept here: a closed or merged PR only takes
    /// COMMENT reviews (submitting leftover drafts stays possible).
    private var availableEvents: [ReviewEvent] {
        model.prs.detailsCache[number]?.state == "OPEN" ? ReviewEvent.allCases : [.comment]
    }

    private var canSubmit: Bool {
        if model.prs.isSubmittingReview { return false }
        if isOwnPR && event != .comment { return false }
        // The API requires a summary body for COMMENT and REQUEST_CHANGES;
        // only APPROVE may go out bare.
        if event != .approve && summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finish your review")
                .font(.system(size: 13, weight: .bold))

            PlaceholderTextEditor(
                text: $summary,
                placeholder: event == .approve
                    ? "Leave a summary comment (optional)"
                    : "Leave a summary comment (required)",
                height: 84
            )

            Picker("Verdict", selection: $event) {
                ForEach(availableEvents) { event in
                    Text(event.label).tag(event)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(event.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if isOwnPR && event != .comment {
                Text("You can't \(event == .approve ? "approve" : "request changes on") your own pull request.")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignStyle.deletion)
            }

            if let error = model.prs.reviewSubmitError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignStyle.deletion)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text(pendingCount == 0
                    ? "No pending comments"
                    : "^[\(pendingCount) pending comment](inflect: true) will be submitted")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        if await model.prs.submitReview(event, body: summary, for: number) {
                            isPresented = false
                        }
                    }
                } label: {
                    if model.prs.isSubmittingReview {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Submit review")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(!canSubmit)
            }
        }
        .padding(16)
        .frame(width: 380)
        // A submit error is deliberately NOT cleared here: when a submission
        // fails after the popover was dismissed, reopening the form is the
        // only place the user can still read what went wrong. It resets when
        // the next submission starts.
        .onAppear {
            if !availableEvents.contains(event) {
                event = .comment
            }
        }
    }
}
