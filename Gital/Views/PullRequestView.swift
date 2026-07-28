import SwiftUI

struct PullRequestView: View {
    @Bindable var model: RepoViewModel

    var body: some View {
        Group {
            if let item = model.prs.selectedItem {
                PullRequestItemDiffView(model: model, item: item)
            } else if let detail = model.prs.detail {
                PullRequestDetailView(model: model, detail: detail)
            } else if model.prs.selectedNumber != nil {
                ProgressView("Loading pull request…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text(model.prs.loadError ?? "Select a pull request")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Entering the tab shows the cached list immediately and re-fetches
        // it in the background (throttled inside).
        .task {
            await model.prs.refreshIfStale()
        }
    }
}

/// Diff pane for a commit or changed file selected in a PR's sidebar rows.
struct PullRequestItemDiffView: View {
    @Bindable var model: RepoViewModel
    let item: PullRequestsModel.ItemSelection

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(horizontalPadding: 14, verticalPadding: 10) {
                Button {
                    model.prs.selectedItem = nil
                } label: {
                    Label("Overview", systemImage: "chevron.left")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to pull request overview")

                Divider().frame(height: 16)

                itemTitle
                Spacer()
                if case .commit(let hash) = item, let number = model.prs.selectedNumber {
                    Toggle("Viewed", isOn: Binding(
                        get: { model.prs.isCommitViewed(hash, in: number) },
                        set: { _ in model.prs.toggleCommitViewed(hash, in: number) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .help("Mark the whole commit as viewed")
                }
                if let number = model.prs.selectedNumber,
                   isOpenPR || !model.prs.pendingComments(for: number).isEmpty {
                    ReviewChangesButton(model: model, number: number)
                }
                DiffModePicker(mode: $model.diffMode)
            }

            if let error = model.prs.itemLoadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.prs.itemDiffs.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(model.prs.itemDiffs) { diff in
                            Section {
                                if let number = model.prs.selectedNumber, !diff.isBinary, !diff.hunks.isEmpty {
                                    reviewableContent(diff, number: number, canComment: isOpenPR)
                                } else {
                                    FileDiffContentView(diff: diff, mode: model.diffMode)
                                }
                            } header: {
                                FileSectionHeader(diff: diff) {
                                    fileViewedToggle(for: diff)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Whether the selected PR accepts new review comments (open, including
    /// draft PRs) — gates the "+" buttons and the composer. Existing drafts
    /// stay visible (and deletable/submittable as a COMMENT review) even
    /// after the PR is closed or merged, so they never become unreachable.
    private var isOpenPR: Bool {
        guard let number = model.prs.selectedNumber else { return false }
        return model.prs.detailsCache[number]?.state == "OPEN"
    }

    @ViewBuilder
    private func reviewableContent(_ diff: FileDiff, number: Int, canComment: Bool) -> some View {
        switch model.diffMode {
        case .unified:
            ForEach(diff.hunks) { hunk in
                HunkHeaderView(text: hunk.header)
                ForEach(hunk.lines) { line in
                    reviewableLine(line, in: diff, number: number, canComment: canComment)
                }
            }
        case .split:
            // Split rows still surface existing drafts below the matching
            // row; composing new comments happens in unified mode.
            ForEach(SplitDiffRow.rows(for: diff.hunks)) { row in
                SplitDiffRowView(row: row)
                ForEach(splitRowComments(row, in: diff, number: number)) { comment in
                    PendingReviewCommentCard(model: model, comment: comment, number: number)
                }
            }
        }
    }

    @ViewBuilder
    private func reviewableLine(_ line: DiffLine, in diff: FileDiff, number: Int, canComment: Bool) -> some View {
        let anchor = ReviewCommentAnchor(path: diff.path, diffLine: line)
        ReviewableDiffLineView(line: line, canComment: canComment && anchor != nil) {
            if let anchor {
                model.prs.openReviewComposer(at: anchor, lineText: line.text)
            }
        }
        if anchor != nil {
            ForEach(model.prs.pendingComments(on: line, path: diff.path, in: number)) { comment in
                PendingReviewCommentCard(model: model, comment: comment, number: number)
            }
            if canComment, model.prs.reviewComposerAnchor == anchor,
               model.prs.reviewComposerLineText == line.text {
                ReviewCommentComposerView(model: model, number: number)
            }
        }
    }

    private func splitRowComments(_ row: SplitDiffRow, in diff: FileDiff, number: Int) -> [PendingReviewComment] {
        guard !row.isHunkHeader else { return [] }
        return model.prs.pendingComments(for: number).filter { comment in
            guard comment.anchor.path == diff.path else { return false }
            switch comment.anchor.side {
            case .left:
                return row.left.kind == .deletion && row.left.number == comment.anchor.line
                    && row.left.text == comment.lineText
            case .right:
                return row.right.kind != nil && row.right.number == comment.anchor.line
                    && row.right.text == comment.lineText
            }
        }
    }

    @ViewBuilder
    private var itemTitle: some View {
        switch item {
        case .commit(let hash):
            Image(systemName: "circle")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text(commitMessage(for: hash) ?? "Commit")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(hash)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
        case .file(let path):
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Per-file "Viewed" checkbox in a diff section header. Inside a commit it
    /// toggles the commit-scoped flag (promoting the commit when its last file
    /// is viewed); on a Files Changed selection it toggles the PR-wide flag.
    @ViewBuilder
    private func fileViewedToggle(for diff: FileDiff) -> some View {
        if let number = model.prs.selectedNumber {
            switch item {
            case .commit(let hash):
                Toggle("Viewed", isOn: Binding(
                    get: { model.prs.isCommitFileViewed(commit: hash, path: diff.path, in: number) },
                    set: { _ in
                        model.prs.toggleCommitFileViewed(
                            commit: hash,
                            path: diff.path,
                            allPaths: model.prs.itemDiffs.map(\.path),
                            in: number
                        )
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
            case .file(let path):
                Toggle("Viewed", isOn: Binding(
                    get: { model.prs.isFileViewed(path, in: number) },
                    set: { _ in model.prs.toggleFileViewed(path, in: number) }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
            }
        }
    }

    private func commitMessage(for hash: String) -> String? {
        guard let number = model.prs.selectedNumber else { return nil }
        return model.prs.detailsCache[number]?.commits.first { $0.hash == hash }?.message
    }
}

struct PullRequestDetailView: View {
    @Bindable var model: RepoViewModel
    let detail: PullRequestDetail

    private var isMerging: Bool { model.prs.mergingNumber == detail.number }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                statusChip

                Text("\(Text(detail.title).fontWeight(.semibold))  \(Text("#\(detail.number)").foregroundStyle(.secondary))")
                    .font(.system(size: 22))
                    .padding(.top, 13)

                mergeSummaryLine
                    .padding(.top, 9)

                metaRow
                    .padding(.top, 16)
                    .padding(.bottom, 18)
                Divider()

                if !detail.labels.isEmpty {
                    labelChips
                        .padding(.top, 16)
                }

                descriptionCard
                    .padding(.top, 16)

                sectionTitle("Reviewers")
                reviewersCard

                // Also shown on closed/merged PRs while drafts remain, so
                // leftover pending comments never become unreachable.
                if detail.state == "OPEN" || !model.prs.pendingComments(for: detail.number).isEmpty {
                    reviewBox
                        .padding(.top, 14)
                }

                sectionTitle("Commits", count: detail.commits.count)
                commitsCard

                mergeBox
                    .padding(.top, 26)
            }
            .frame(maxWidth: 840, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Pieces

    private var statusColor: Color {
        DesignStyle.prStateColor(state: detail.state, isDraft: detail.isDraft)
    }

    private var statusChip: some View {
        Label(detail.statusLabel, systemImage: "arrow.triangle.pull")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(statusColor, in: Capsule())
    }

    private var mergeSummaryLine: some View {
        Text("\(detail.author) wants to merge \(Text("\(detail.commits.count) commits").foregroundStyle(.primary)) into \(refText(detail.base)) from \(refText(detail.head))")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
    }

    private func refText(_ name: String) -> Text {
        Text(name)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(DesignStyle.linkBlue)
    }

    private var metaRow: some View {
        HStack(spacing: 12) {
            AvatarView(name: detail.author, size: 26, url: model.avatarURL(login: detail.authorLogin, size: 26))
            Text("\(detail.author) opened \(detail.createdAt)")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Spacer()
            Text("+\(detail.additions)")
                .font(.system(size: 12))
                .foregroundStyle(DesignStyle.addition)
            Text("−\(detail.deletions)")
                .font(.system(size: 12))
                .foregroundStyle(DesignStyle.deletion)
            Text("\(detail.changedFiles) files")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var labelChips: some View {
        HStack(spacing: 7) {
            ForEach(detail.labels) { label in
                let color = Color(hex: UInt32(label.color, radix: 16) ?? 0x2f6fed)
                Text(label.name)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.18), in: Capsule())
                    .foregroundStyle(color)
            }
        }
    }

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AvatarView(name: detail.author, size: 20, url: model.avatarURL(login: detail.authorLogin, size: 20))
                Text("\(detail.author) commented · \(detail.createdAt)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.3))
            Divider()
            Text(detail.body.isEmpty ? "No description provided." : detail.body)
                .font(.system(size: 13))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .cardStyle()
    }

    private func sectionTitle(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
            if let count {
                Text("\(count)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 26)
        .padding(.bottom, 10)
    }

    private var reviewersCard: some View {
        VStack(spacing: 0) {
            if detail.reviewers.isEmpty {
                Text("No reviewers")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            ForEach(detail.reviewers) { reviewer in
                HStack(spacing: 10) {
                    AvatarView(name: reviewer.name, size: 24, url: model.avatarURL(login: reviewer.login, size: 24))
                    Text(reviewer.name)
                        .font(.system(size: 12.5))
                    Spacer()
                    reviewerState(reviewer.state)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                if reviewer.id != detail.reviewers.last?.id {
                    Divider()
                }
            }
        }
        .cardStyle()
    }

    private func reviewerState(_ state: String) -> some View {
        let (label, color): (String, Color) = switch state {
        case "APPROVED": ("Approved", DesignStyle.addition)
        case "CHANGES_REQUESTED": ("Changes requested", DesignStyle.deletion)
        case "COMMENTED": ("Commented", .secondary)
        default: ("Pending", DesignStyle.tagAmber)
        }
        return Text(label)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var commitsCard: some View {
        VStack(spacing: 0) {
            ForEach(detail.commits) { commit in
                let viewed = model.prs.isCommitViewed(commit.hash, in: detail.number)
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "circle")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text(commit.message)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                        Spacer()
                        Text(commit.author)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Text(commit.hash)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .opacity(viewed ? 0.4 : 1)
                    ViewedToggle(viewed: viewed, size: 12) {
                        model.prs.toggleCommitViewed(commit.hash, in: detail.number)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.prs.selectItem(.commit(hash: commit.hash), in: detail.number)
                }
                .help("Click to show this commit's diff")
                if commit.id != detail.commits.last?.id {
                    Divider()
                }
            }
        }
        .cardStyle()
    }

    /// Overview entry point into the review flow: shows the pending draft
    /// count and the same "Review changes" form the diff header offers.
    private var reviewBox: some View {
        let count = model.prs.pendingComments(for: detail.number).count
        return HStack(spacing: 11) {
            Image(systemName: "text.bubble")
                .font(.system(size: 17))
                .foregroundStyle(count > 0 ? DesignStyle.tagAmber : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(count > 0 ? "Review in progress" : "Review this pull request")
                    .font(.system(size: 13, weight: .semibold))
                Text(count > 0
                    ? "^[\(count) pending comment](inflect: true) will be submitted with your review."
                    : "Comment on diff lines in Commits or Files Changed to draft review comments.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if let error = model.prs.reviewSubmitError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignStyle.deletion)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            ReviewChangesButton(model: model, number: detail.number)
        }
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 12))
    }

    private var canMerge: Bool {
        detail.state == "OPEN" && !detail.isDraft && detail.mergeable == "MERGEABLE"
    }

    private var mergeBox: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 17))
                .foregroundStyle(canMerge ? DesignStyle.addition : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(mergeTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(mergeNote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.prs.merge(detail.number)
            } label: {
                if isMerging {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Merge pull request")
                }
            }
            .buttonStyle(.glassProminent)
            .tint(DesignStyle.addition)
            .disabled(!canMerge || isMerging)
        }
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 12))
    }

    private var mergeTitle: String {
        switch detail.state {
        case "MERGED": return "Pull request merged"
        case "CLOSED": return "Pull request closed"
        default:
            if detail.isDraft { return "Draft pull request" }
            return detail.mergeable == "MERGEABLE"
                ? "No conflicts with the base branch"
                : "Merge state: \(detail.mergeable.lowercased())"
        }
    }

    private var mergeNote: String {
        switch detail.state {
        case "MERGED": return "The changes are already part of \(detail.base)."
        case "CLOSED": return "This pull request was closed without merging."
        default:
            if detail.isDraft { return "Mark as ready for review before merging." }
            return "Merging will create a merge commit on \(detail.base)."
        }
    }
}

// MARK: - Review comments

/// Hoverable unified diff line with a "+" bubble that opens the review
/// comment composer, GitHub-style.
struct ReviewableDiffLineView: View {
    let line: DiffLine
    let canComment: Bool
    let onComment: () -> Void

    @State private var isHovering = false

    var body: some View {
        UnifiedDiffLineView(line: line)
            .background(isHovering && canComment ? Color.primary.opacity(0.04) : .clear)
            .overlay(alignment: .leading) {
                if isHovering && canComment {
                    Button(action: onComment) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 17, height: 17)
                            .background(DesignStyle.linkBlue, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 3)
                    .help("Add a review comment on this line")
                }
            }
            .onHover { isHovering = $0 }
    }
}

/// A draft review comment shown inline under its anchor line. Drafts stay
/// pending until the review is submitted.
struct PendingReviewCommentCard: View {
    var model: RepoViewModel
    let comment: PendingReviewComment
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Pending")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(DesignStyle.tagAmber.opacity(0.18), in: Capsule())
                    .foregroundStyle(DesignStyle.tagAmber)
                Text("Line \(comment.anchor.line)\(comment.anchor.side == .left ? " (old)" : "")")
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
            PlaceholderTextEditor(text: $prs.reviewComposerText, placeholder: "Leave a review comment")
                .focused($focused)
            if let error = model.prs.reviewComposerError {
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
                Button(model.prs.editingCommentID == nil ? "Add review comment" : "Save comment") {
                    model.prs.saveComposerComment(in: number)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(prs.reviewComposerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
