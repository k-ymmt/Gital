import SwiftUI

/// Diff pane for a commit or changed file selected in a PR's sidebar rows.
struct PullRequestItemDiffView: View {
    @Bindable var model: RepoViewModel
    let item: PullRequestsModel.ItemSelection

    /// Collapses the lower commit-details pane down to its header row.
    @State private var commitInfoCollapsed = false
    /// Height of the expanded message area, adjusted by dragging the pane's
    /// top divider. Display and drag both clamp it to the window (see
    /// `commitInfoPane`), so a tall setting can't starve the diff.
    @State private var commitInfoHeight: CGFloat = 150
    /// Height when the current resize drag started; nil outside a drag.
    @State private var commitInfoDragBase: CGFloat?
    /// Whether the resize cursor is currently pushed — onHover alone can't
    /// guarantee the pop when the handle leaves the hierarchy mid-hover.
    @State private var resizeCursorPushed = false

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
                        commitInfoPane(commit, maxBodyHeight: max(60, geo.size.height - Self.commitInfoReservedHeight))
                    }
                }
            } else {
                diffContent
            }
        }
    }

    @ViewBuilder
    private var diffContent: some View {
        if let error = model.prs.itemLoadError {
            EmptyStateView(error, maxTextWidth: 460, systemImage: "exclamationmark.triangle", iconSize: 30)
        } else if model.prs.itemDiffs.isEmpty {
            // Details loaded with no diffs = a genuinely empty commit
            // (--allow-empty, or a merge empty against its first parent) —
            // a plain note, not the error triangle and not a stuck spinner.
            if model.prs.itemCommitDetail != nil {
                Text("No changes in this commit.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                FileDiffContentView(diff: diff, mode: model.diffMode)
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

    /// Agent threads of this PR whose anchor line isn't part of the
    /// displayed diffs (asked while viewing another commit/file of the PR)
    /// must stay reachable — the answer would otherwise vanish. Same for the
    /// open composer. Both render below the diff, like the Working Copy's
    /// orphaned cards.
    @ViewBuilder
    private var trailingAgentCards: some View {
        if let number = model.prs.selectedNumber {
            ForEach(orphanedAgentThreads(in: number)) { thread in
                AgentThreadView(model: model, thread: thread)
            }
            if let composer = model.prAgentComposer, composer.number == number,
               !anchorIsDisplayed(id: composer.anchorLineID, text: composer.anchorLineText) {
                prAgentComposerCard(composer)
            }
        }
    }

    private func orphanedAgentThreads(in number: Int) -> [AgentThread] {
        let threads = model.prAgentThreads.filter { $0.prNumber == number }
        guard !threads.isEmpty else { return [] }
        return threads.filter {
            !anchorIsDisplayed(id: $0.anchorLineID, text: $0.anchorLineText ?? "")
        }
    }

    /// Whether a card's anchor (line ID AND content, like review comments)
    /// is rendered by the inline interleave — which exists in unified mode
    /// only, so in split mode every agent card falls through to the trailing
    /// section instead of vanishing.
    private func anchorIsDisplayed(id: String, text: String) -> Bool {
        guard model.diffMode == .unified else { return false }
        return model.prs.itemDiffs.contains { diff in
            diff.hunks.contains { hunk in
                hunk.lines.contains { $0.id == id && $0.text == text }
            }
        }
    }

    private func prAgentComposerCard(_ composer: RepoViewModel.PRAgentComposer) -> some View {
        AgentComposerView(
            text: $model.prAgentDraft,
            range: composer.range,
            fileName: (composer.filePath as NSString).lastPathComponent,
            hint: "Select lines to ask about a range",
            placeholder: "Ask a question about these lines…",
            onCancel: { model.cancelPRAgentComposer() },
            onSend: { model.sendPRAgentQuestion() }
        )
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
            ForEach(unifiedSegments(for: diff, number: number, canComment: canComment)) { segment in
                WebDiffChunkView(
                    html: DiffHTMLBuilder.reviewUnifiedPage(
                        items: segment.items,
                        language: DiffSyntaxHighlighting.language(for: diff),
                        commentable: canComment
                            ? { ReviewCommentAnchor(path: diff.path, diffLine: $0) != nil }
                            : nil,
                        askable: true
                    ),
                    estimatedHeight: CGFloat(segment.items.count) * DiffHTMLBuilder.rowHeight,
                    onAction: { handleReview($0, in: diff) }
                )
                if let line = segment.interleaveAfterLine {
                    // Published conversations first, then local drafts —
                    // history above what is still pending, like GitHub —
                    // then the agent's question threads and composer.
                    ForEach(model.prs.threads(on: line, path: diff.path, in: number)) { thread in
                        ReviewThreadCard(model: model, thread: thread, number: number)
                    }
                    ForEach(model.prs.pendingComments(on: line, path: diff.path, in: number)) { comment in
                        PendingReviewCommentCard(model: model, comment: comment, diff: diff, number: number)
                    }
                    if canComment, composerIsOpen(at: line, in: diff) {
                        ReviewCommentComposerView(model: model, number: number)
                    }
                    ForEach(model.prAgentThreads(on: line, in: number)) { thread in
                        AgentThreadView(model: model, thread: thread)
                    }
                    if let composer = model.prAgentComposer,
                       model.isPRAgentComposerOpen(at: line, in: number) {
                        prAgentComposerCard(composer)
                    }
                }
            }
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

    private func composerIsOpen(at line: DiffLine, in diff: FileDiff) -> Bool {
        model.prs.isComposerOpen(at: line, in: diff)
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
            guard let line = line(id, in: diff),
                  let anchor = ReviewCommentAnchor(path: diff.path, diffLine: line) else { return }
            model.prs.openReviewComposer(at: anchor, lineText: line.text)
        case .lines(let act, let startID, let endID) where act == "commentRange":
            guard let end = line(endID, in: diff),
                  let endAnchor = ReviewCommentAnchor(path: diff.path, diffLine: end) else { return }
            guard startID != endID else {
                model.prs.openReviewComposer(at: endAnchor, lineText: end.text)
                return
            }
            guard let start = line(startID, in: diff),
                  let startAnchor = ReviewCommentAnchor(path: diff.path, diffLine: start) else { return }
            model.prs.openReviewComposer(
                at: endAnchor,
                lineText: end.text,
                startAnchor: startAnchor,
                startLineText: start.text
            )
        case .hunk(let act, let id) where act == "askLine":
            guard let line = line(id, in: diff) else { return }
            openAskComposer(start: line, end: line, in: diff)
        case .askRange(let startID, let endID):
            guard let start = line(startID, in: diff), let end = line(endID, in: diff) else { return }
            openAskComposer(start: start, end: end, in: diff)
        default:
            break
        }
    }

    /// Opens the agent composer for a line span, anchored at the range's
    /// LAST line so it sits right below the selection — the same anchoring
    /// as review comments and the Working Copy ask.
    private func openAskComposer(start: DiffLine, end: DiffLine, in diff: FileDiff) {
        guard let number = model.prs.selectedNumber else { return }
        let first = diff.newFileLineNumber(of: start)
        let last = diff.newFileLineNumber(of: end)
        model.openPRAgentComposer(
            number: number,
            file: diff.path,
            range: min(first, last)...max(first, last),
            anchorID: end.id,
            anchorText: end.text
        )
    }

    private func line(_ id: String, in diff: FileDiff) -> DiffLine? {
        diff.hunks.lazy.flatMap(\.lines).first { $0.id == id }
    }

    // MARK: - Web chunk segmentation

    private struct ReviewSegment: Identifiable {
        let id: String
        let items: [DiffHTMLBuilder.UnifiedItem]
        /// Line whose review cards (threads, drafts, composer) render right
        /// after this chunk.
        let interleaveAfterLine: DiffLine?
    }

    /// Splits a file's unified rows into web chunks at every line carrying a
    /// published thread, a pending draft, an agent thread, or an open
    /// composer, so those stay native SwiftUI between the chunks (same
    /// scheme as the Working Copy). The review composer only counts while
    /// the PR accepts comments — the render side gates it the same way, and
    /// a boundary with nothing rendered at it would still split the chunk
    /// and break text selection across it.
    private func unifiedSegments(for diff: FileDiff, number: Int, canComment: Bool) -> [ReviewSegment] {
        var segments: [ReviewSegment] = []
        var items: [DiffHTMLBuilder.UnifiedItem] = []
        var firstID = ""

        func flush(after line: DiffLine?) {
            guard !items.isEmpty || line != nil else { return }
            segments.append(ReviewSegment(
                id: "\(firstID)→\(line?.id ?? "end")",
                items: items,
                interleaveAfterLine: line
            ))
            items = []
            firstID = ""
        }

        for hunk in diff.hunks {
            if items.isEmpty { firstID = hunk.id }
            items.append(.header(hunk))
            for line in hunk.lines {
                if items.isEmpty { firstID = line.id }
                items.append(.line(line))
                let hasCards = !model.prs.threads(on: line, path: diff.path, in: number).isEmpty
                    || !model.prs.pendingComments(on: line, path: diff.path, in: number).isEmpty
                    || (canComment && composerIsOpen(at: line, in: diff))
                    || !model.prAgentThreads(on: line, in: number).isEmpty
                    || model.isPRAgentComposerOpen(at: line, in: number)
                if hasCards {
                    flush(after: line)
                }
            }
        }
        flush(after: nil)
        return segments
    }

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

    private func splitRowThreads(_ row: SplitDiffRow, in diff: FileDiff, number: Int) -> [ReviewThread] {
        guard !row.isHunkHeader else { return [] }
        return model.prs.threads(for: number).filter { thread in
            guard thread.path == diff.path, let line = thread.line else { return false }
            switch thread.side {
            case .left:
                return row.left.kind == .deletion && row.left.number == line
                    && (thread.lineText.map { row.left.text == $0 } ?? true)
            case .right:
                return row.right.kind != nil && row.right.number == line
                    && (thread.lineText.map { row.right.text == $0 } ?? true)
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

    /// Lower pane with just the commit's details, History-style: avatar,
    /// author line, hash, and the FULL commit message (subject and body) —
    /// the one-line toolbar title can't show either. Sourced from local git,
    /// since gh's PR detail only carries each commit's headline.
    private func commitInfoPane(_ commit: CommitDetail, maxBodyHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            resizeHandle(cap: maxBodyHeight)
            commitInfoHeader(commit)
            // Collapsing squeezes the message area to zero height instead of
            // removing it, which is what makes the toggle animatable. The
            // divider lives inside so it disappears along with the area.
            VStack(spacing: 0) {
                Divider()
                ScrollView {
                    Text(commit.message)
                        .font(.system(size: 12.5))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .frame(height: commitInfoCollapsed ? 0 : min(commitInfoHeight, maxBodyHeight))
            .clipped()
        }
    }

    /// The pane's top divider, doubling as its resize handle — a slim drag
    /// band replacing the VSplitView divider. Inert while collapsed, so the
    /// hidden message area can't be dragged open.
    private func resizeHandle(cap: CGFloat) -> some View {
        ZStack {
            Divider()
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    // Global space: the handle itself moves with every height
                    // change, so a local-space translation would be measured
                    // against a moving origin and lag the cursor.
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let base = commitInfoDragBase ?? min(commitInfoHeight, cap)
                            commitInfoDragBase = base
                            commitInfoHeight = min(max(base - value.translation.height, 60), cap)
                        }
                        .onEnded { _ in commitInfoDragBase = nil }
                )
                .onHover { setResizeCursor($0) }
        }
        .frame(height: 7)
        .allowsHitTesting(!commitInfoCollapsed)
        // onHover's exit callback isn't delivered when the handle leaves the
        // hierarchy (or stops hit-testing) mid-hover, which would leave the
        // resize cursor pushed over the whole app.
        .onDisappear {
            setResizeCursor(false)
            commitInfoDragBase = nil
        }
        .onChange(of: commitInfoCollapsed) { _, collapsed in
            if collapsed { setResizeCursor(false) }
        }
    }

    /// Push/pop tracked through one flag so the two can never run unpaired.
    private func setResizeCursor(_ pushed: Bool) {
        guard pushed != resizeCursorPushed else { return }
        resizeCursorPushed = pushed
        if pushed {
            NSCursor.resizeUpDown.push()
        } else {
            NSCursor.pop()
        }
    }

    /// The pane's header row — avatar, author line, hash, and the collapse
    /// toggle. This is what remains on screen while the pane is collapsed.
    private func commitInfoHeader(_ commit: CommitDetail) -> some View {
        HStack(spacing: 11) {
            AvatarView(name: commit.author, url: model.avatarURL(email: commit.authorEmail, size: 30))
            VStack(alignment: .leading, spacing: 3) {
                Text("\(commit.author) <\(commit.authorEmail)>")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(commit.authorDate)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(commit.hash)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    commitInfoCollapsed.toggle()
                }
            } label: {
                // The Xcode/Fork bottom-panel toggle: one fixed glyph whose
                // tint carries the state, not a direction-flipping chevron.
                Image(systemName: "inset.filled.bottomthird.square")
                    .font(.system(size: 13))
                    .foregroundStyle(commitInfoCollapsed ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(commitInfoCollapsed ? "Expand commit details" : "Collapse commit details")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.25))
    }
}
