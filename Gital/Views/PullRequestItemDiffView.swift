import SwiftUI

/// Diff pane for a commit or changed file selected in a PR's sidebar rows.
struct PullRequestItemDiffView: View {
    @Bindable var model: RepoViewModel
    let item: PullRequestsModel.ItemSelection

    /// Collapses the lower commit-details pane down to its header row.
    /// Owned here, not by the pane, so it survives the pane leaving the
    /// hierarchy while the next commit's details load.
    @State private var commitInfoCollapsed = false
    /// Height of the expanded message area, adjusted by dragging the pane's
    /// top divider. Display and drag both clamp it to the window (see
    /// `PRCommitInfoPane`), so a tall setting can't starve the diff.
    @State private var commitInfoHeight: CGFloat = 150

    /// Vertical space reserved for everything that isn't the pane's message
    /// area: a usable diff (matching the old VSplitView minimum) plus the
    /// handle and header rows.
    private static let commitInfoReservedHeight: CGFloat = 280

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
                    viewedCheckbox(
                        fontSize: 12,
                        isViewed: { model.prs.isCommitViewed(hash, in: number) },
                        toggle: { model.prs.toggleCommitViewed(hash, in: number) }
                    )
                    .help("Mark the whole commit as viewed")
                }
                if let number = model.prs.selectedNumber,
                   isOpenPR || !model.prs.pendingComments(for: number).isEmpty {
                    ReviewChangesButton(model: model, number: number)
                }
                DiffModePicker(mode: $model.diffMode)
            }

            // A commit shows History-style: the changed files' diff on top
            // and a pane with just the commit's details below. Files (and a
            // commit whose details couldn't load) keep the full-height diff.
            // Not a VSplitView: a fixed-height pane with a draggable top
            // divider keeps the diff's identity stable across collapse
            // toggles and lets the collapse animate.
            if case .commit = item, let commit = model.prs.itemCommitDetail {
                // The geometry clamp keeps the pane from starving the diff:
                // a height dragged tall in a big window (or the 150 default
                // in a tiny one) caps to what the window can actually spare.
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        diffContent
                        PRCommitInfoPane(
                            commit: commit,
                            avatarURL: model.avatarURL(email: commit.authorEmail, size: 30),
                            maxBodyHeight: max(60, geo.size.height - Self.commitInfoReservedHeight),
                            isCollapsed: $commitInfoCollapsed,
                            height: $commitInfoHeight
                        )
                    }
                }
            } else {
                diffContent
            }
        }
    }

    @ViewBuilder
    private var diffContent: some View {
        // The empty/error states still append the trailing agent cards: a
        // question's answer (or the half-typed composer) must stay reachable
        // while an empty commit or a failed load is selected, not vanish
        // until the user happens to pick a diff-bearing item.
        if let error = model.prs.itemLoadError {
            VStack(spacing: 0) {
                EmptyStateView(error, maxTextWidth: 460, systemImage: "exclamationmark.triangle", iconSize: 30)
                trailingAgentCards
            }
        } else if model.prs.itemDiffs.isEmpty {
            // Details loaded with no diffs = a genuinely empty commit
            // (--allow-empty, or a merge empty against its first parent) —
            // a plain note, not the error triangle and not a stuck spinner.
            VStack(spacing: 0) {
                if model.prs.itemCommitDetail != nil {
                    Text("No changes in this commit.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                trailingAgentCards
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(model.prs.itemDiffs) { diff in
                        Section {
                            if let number = model.prs.selectedNumber, !diff.isBinary, !diff.hunks.isEmpty {
                                reviewableContent(diff, number: number, canComment: isOpenPR)
                            } else {
                                // No imageContext: PR diffs come from
                                // `gh pr diff` and neither side's blob is
                                // guaranteed to exist locally.
                                FileDiffContentView(diff: diff)
                            }
                        } header: {
                            FileSectionHeader(diff: diff) {
                                fileViewedToggle(for: diff)
                            }
                        }
                    }
                    trailingAgentCards
                }
            }
        }
    }

    /// `ItemSelection.agentAnchorKey` of the item this view shows — the
    /// identity agent cards anchor to alongside line ID and content.
    private var agentItemKey: String { item.agentAnchorKey }

    /// Agent threads of this PR that the inline interleave doesn't render
    /// (asked in another commit/file view, split mode, or an anchor line the
    /// displayed diff no longer contains) must stay reachable — the answer
    /// would otherwise vanish. Same for the open composer. Both render below
    /// the diff, like the Working Copy's orphaned cards.
    @ViewBuilder
    private var trailingAgentCards: some View {
        if let number = model.prs.selectedNumber {
            ForEach(orphanedAgentThreads(in: number)) { thread in
                AgentThreadView(model: model, thread: thread)
            }
            if let composer = model.prAgentComposer, composer.number == number,
               !cardIsInline(itemKey: composer.itemKey, anchorID: composer.anchorLineID, anchorText: composer.anchorLineText) {
                prAgentComposerCard(composer)
            }
        }
    }

    private func orphanedAgentThreads(in number: Int) -> [AgentThread] {
        let threads = model.prAgentThreads.filter { $0.prNumber == number }
        guard !threads.isEmpty else { return [] }
        return threads.filter {
            !cardIsInline(itemKey: $0.prItemKey, anchorID: $0.anchorLineID, anchorText: $0.anchorLineText ?? "")
        }
    }

    /// Whether the inline interleave renders a card here: unified mode, the
    /// same item the question was asked in, and an anchor line (ID AND
    /// content, like review comments) present in the displayed diffs. The
    /// trailing section takes exactly the cards this returns false for.
    private func cardIsInline(itemKey: String?, anchorID: String, anchorText: String) -> Bool {
        guard model.diffMode == .unified, itemKey == agentItemKey else { return false }
        return model.prs.itemDiffs.contains { diff in
            diff.hunks.contains { hunk in
                hunk.lines.contains { $0.id == anchorID && $0.text == anchorText }
            }
        }
    }

    private func prAgentComposerCard(_ composer: RepoViewModel.PRAgentComposer) -> some View {
        PRAgentComposerCard(model: model, composer: composer)
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
            PRReviewFileView(
                model: model,
                diff: diff,
                number: number,
                canComment: canComment,
                itemKey: agentItemKey,
                onAction: { handleReview($0, in: diff) }
            )
        case .split:
            // Split rows still surface existing drafts below the matching
            // row; composing new comments happens in unified mode.
            ForEach(splitSegments(for: diff, number: number)) { segment in
                WebDiffChunkView(
                    html: DiffHTMLBuilder.reviewSplitPage(
                        rows: segment.rows,
                        language: DiffSyntaxHighlighting.language(for: diff)
                    ),
                    estimatedHeight: CGFloat(segment.rows.count) * DiffHTMLBuilder.rowHeight,
                    onAction: { _ in }
                )
                ForEach(segment.threads) { thread in
                    ReviewThreadCard(model: model, thread: thread, number: number)
                }
                ForEach(segment.comments) { comment in
                    PendingReviewCommentCard(model: model, comment: comment, diff: diff, number: number)
                }
            }
        }
    }

    /// Bridge actions a PR page emits (height reports are consumed by the
    /// chunk itself): `commentLine` from a line's hover "+" opens the
    /// composer at that line, and `commentRange` from the selection frame's
    /// corner "+" opens it for the whole selected range — the composer (and
    /// the eventual comment) anchors to the range's LAST line, GitHub-style,
    /// with the first line carried as the range start. `askLine` / `askRange`
    /// are the hover "✦"'s agent-question counterparts.
    private func handleReview(_ action: WebDiffAction, in diff: FileDiff) {
        switch action {
        case .hunk(let act, let id) where act == "commentLine":
            guard let line = diff.line(withID: id),
                  let anchor = ReviewCommentAnchor(path: diff.path, diffLine: line) else { return }
            model.prs.openReviewComposer(at: anchor, lineText: line.text)
        case .lines(let act, let startID, let endID) where act == "commentRange":
            guard let end = diff.line(withID: endID),
                  let endAnchor = ReviewCommentAnchor(path: diff.path, diffLine: end) else { return }
            guard startID != endID else {
                model.prs.openReviewComposer(at: endAnchor, lineText: end.text)
                return
            }
            guard let start = diff.line(withID: startID),
                  let startAnchor = ReviewCommentAnchor(path: diff.path, diffLine: start) else { return }
            model.prs.openReviewComposer(
                at: endAnchor,
                lineText: end.text,
                startAnchor: startAnchor,
                startLineText: start.text
            )
        case .hunk(let act, let id) where act == "askLine":
            guard let line = diff.line(withID: id) else { return }
            openAskComposer(start: line, end: line, in: diff)
        case .askRange(let startID, let endID):
            guard let start = diff.line(withID: startID), let end = diff.line(withID: endID) else { return }
            openAskComposer(start: start, end: end, in: diff)
        default:
            break
        }
    }

    /// Opens the agent composer for a line span, anchored at the range's
    /// LAST line so it sits right below the selection — the same anchoring
    /// as review comments and the Working Copy ask. The prompt's diff
    /// context is captured HERE, from the diff the click resolved against:
    /// by send time `itemDiffs` may hold another item's diffs.
    private func openAskComposer(start: DiffLine, end: DiffLine, in diff: FileDiff) {
        guard let number = model.prs.selectedNumber else { return }
        let first = diff.newFileLineNumber(of: start)
        let last = diff.newFileLineNumber(of: end)
        let range = min(first, last)...max(first, last)
        model.openPRAgentComposer(
            number: number,
            itemKey: agentItemKey,
            file: diff.path,
            range: range,
            anchorID: end.id,
            anchorText: end.text,
            diffContext: RepoViewModel.diffContext(in: diff, range: range)
        )
    }

    // MARK: - Web chunk segmentation (split mode)

    private struct ReviewSplitSegment: Identifiable {
        let id: String
        let rows: [SplitDiffRow]
        /// Cards anchored to this chunk's last row, rendered right after it.
        let threads: [ReviewThread]
        let comments: [PendingReviewComment]
    }

    private func splitSegments(for diff: FileDiff, number: Int) -> [ReviewSplitSegment] {
        var segments: [ReviewSplitSegment] = []
        var rows: [SplitDiffRow] = []
        var firstID = ""

        for row in SplitDiffRow.rows(for: diff.hunks) {
            if rows.isEmpty { firstID = row.id }
            rows.append(row)
            let threads = splitRowThreads(row, in: diff, number: number)
            let comments = splitRowComments(row, in: diff, number: number)
            if !threads.isEmpty || !comments.isEmpty {
                segments.append(ReviewSplitSegment(id: "\(firstID)→\(row.id)", rows: rows, threads: threads, comments: comments))
                rows = []
                firstID = ""
            }
        }
        if !rows.isEmpty {
            segments.append(ReviewSplitSegment(id: "\(firstID)→end", rows: rows, threads: [], comments: []))
        }
        return segments
    }

    // Both matchers delegate to the same coordinates-AND-content rule the
    // unified pane uses (`isAnchored`), via the row's sides expressed as
    // `DiffLine`s — the display-safety rule must have exactly one
    // implementation.

    private func splitRowThreads(_ row: SplitDiffRow, in diff: FileDiff, number: Int) -> [ReviewThread] {
        guard !row.isHunkHeader else { return [] }
        let lines = row.anchorableLines
        guard !lines.isEmpty else { return [] }
        return model.prs.threads(for: number).filter { thread in
            lines.contains { thread.isAnchored(to: $0, path: diff.path) }
        }
    }

    private func splitRowComments(_ row: SplitDiffRow, in diff: FileDiff, number: Int) -> [PendingReviewComment] {
        guard !row.isHunkHeader else { return [] }
        let lines = row.anchorableLines
        guard !lines.isEmpty else { return [] }
        return model.prs.pendingComments(for: number).filter { comment in
            lines.contains { comment.isAnchored(to: $0, path: diff.path) }
        }
    }

    @ViewBuilder
    private var itemTitle: some View {
        switch item {
        case .commit(let hash):
            // Identity only — the full message lives in the header card at
            // the top of the diff, where it isn't squeezed to one line.
            Image(systemName: "circle")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text("Commit")
                .font(.system(size: 13, weight: .semibold))
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

    /// The one "Viewed" checkbox spelling — three call sites once repeated
    /// the Toggle + Binding + style chain. (Not `Controls.ViewedToggle`:
    /// that is the icon-only variant used by the sidebar rows.)
    private func viewedCheckbox(
        fontSize: CGFloat, isViewed: @escaping () -> Bool, toggle: @escaping () -> Void
    ) -> some View {
        Toggle("Viewed", isOn: Binding(get: isViewed, set: { _ in toggle() }))
            .toggleStyle(.checkbox)
            .font(.system(size: fontSize))
    }

    /// Per-file "Viewed" checkbox in a diff section header. Inside a commit it
    /// toggles the commit-scoped flag (promoting the commit when its last file
    /// is viewed); on a Files Changed selection it toggles the PR-wide flag.
    @ViewBuilder
    private func fileViewedToggle(for diff: FileDiff) -> some View {
        if let number = model.prs.selectedNumber {
            switch item {
            case .commit(let hash):
                viewedCheckbox(
                    fontSize: 11.5,
                    isViewed: { model.prs.isCommitFileViewed(commit: hash, path: diff.path, in: number) },
                    toggle: {
                        model.prs.toggleCommitFileViewed(
                            commit: hash,
                            path: diff.path,
                            allPaths: model.prs.itemDiffs.map(\.path),
                            in: number
                        )
                    }
                )
            case .file(let path):
                viewedCheckbox(
                    fontSize: 11.5,
                    isViewed: { model.prs.isFileViewed(path, in: number) },
                    toggle: { model.prs.toggleFileViewed(path, in: number) }
                )
            }
        }
    }
}
