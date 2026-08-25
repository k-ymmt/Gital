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

    private func line(_ id: String, in diff: FileDiff) -> DiffLine? {
        diff.hunks.lazy.flatMap(\.lines).first { $0.id == id }
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

/// Last measured height per native card, keyed by overlay ID. Card heights
/// live in `@State`, which dies when `LazyVStack` recycles a file view —
/// without this, a recycled file would push every card's spacer back at the
/// 150pt estimate, visibly collapsing and re-expanding around tall cards on
/// every scroll-back. The composer IDs (`card:composer` / `card:ask`) are
/// shared across files and PRs, so their cached entry can be stale — it only
/// mis-sizes the spacer until the live card re-measures.
private let cardHeightCache = NSCache<NSString, NSNumber>()

private func cachedCardHeight(_ id: String) -> CGFloat? {
    cardHeightCache.object(forKey: id as NSString).map { CGFloat($0.doubleValue) }
}

private func cacheCardHeight(_ height: CGFloat, id: String) {
    cardHeightCache.setObject(NSNumber(value: height), forKey: id as NSString)
}

/// One PR file's unified diff as a single web page, with the native review
/// pieces — published threads, pending drafts, the review composer, agent
/// threads, and the ask-composer — overlaid at page-reported spacer offsets
/// (the Working Copy scheme, see `WorkingDiffPane`).
///
/// One page per file instead of card-split chunks because the chunk
/// boundaries moved every time a card opened or closed, and every moved
/// boundary changed a chunk's identity — tearing down its `WKWebView` and
/// reloading from scratch, which flashed the whole pane on each composer
/// toggle. Here the page HTML depends only on the diff, so a card opening
/// pushes a spacer via JS and the page just reflows.
private struct PRReviewFileView: View {
    @Bindable var model: RepoViewModel
    let diff: FileDiff
    let number: Int
    let canComment: Bool
    /// `ItemSelection.agentAnchorKey` of the item being shown — the identity
    /// agent cards anchor to alongside line ID and content.
    let itemKey: String
    let onAction: (WebDiffAction) -> Void

    /// Page height, reported after layout; the rows×19 estimate (or a cached
    /// height from a previous life — LazyVStack recycles this view) holds the
    /// scroll extent until the first report.
    @State private var reportedHeight: CGFloat?
    /// Document offset of every spacer, reported alongside the height.
    @State private var anchors: [String: CGFloat] = [:]
    /// Measured native card heights, pushed back as spacer heights.
    @State private var overlayHeights: [String: CGFloat] = [:]
    @State private var page = Page(html: "", estimatedHeight: 0)

    private struct Page {
        let html: String
        let estimatedHeight: CGFloat
        /// Height-cache key, hashed once — heights are reported on every
        /// layout change.
        let heightCacheKey: String

        init(html: String, estimatedHeight: CGFloat) {
            self.html = html
            self.estimatedHeight = estimatedHeight
            self.heightCacheKey = Gital.heightCacheKey(for: html)
        }
    }

    private struct PageInputs: Equatable {
        let diff: FileDiff
        let canComment: Bool
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            InteractiveWebView(
                html: page.html,
                spacers: spacers,
                onAction: onAction,
                onHeight: { height, ready in
                    reportedHeight = height
                    // Loading-phase reports can still describe the outgoing
                    // page; only a post-didFinish report certainly measures
                    // this one.
                    if ready {
                        cacheHeight(height, forKey: page.heightCacheKey)
                    }
                },
                onAnchors: { anchors = $0 }
            )
            .frame(height: reportedHeight ?? page.estimatedHeight)
            ForEach(overlays) { overlay in
                if let top = anchors[overlay.id] {
                    overlayContent(overlay)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) {
                            overlayHeights[overlay.id] = $0
                            cacheCardHeight($0, id: overlay.id)
                        }
                        .frame(maxWidth: .infinity)
                        .offset(y: top)
                }
            }
        }
        .onChange(of: PageInputs(diff: diff, canComment: canComment), initial: true) {
            rebuildPage()
        }
    }

    private func rebuildPage() {
        let html = DiffHTMLBuilder.reviewUnifiedPage(
            items: DiffHTMLBuilder.unifiedItems(for: diff),
            language: DiffSyntaxHighlighting.language(for: diff),
            commentable: canComment
                ? { ReviewCommentAnchor(path: diff.path, diffLine: $0) != nil }
                : nil,
            askable: true
        )
        let rows = diff.hunks.reduce(diff.hunks.count) { $0 + $1.lines.count }
        page = Page(html: html, estimatedHeight: CGFloat(rows) * DiffHTMLBuilder.rowHeight)
        reportedHeight = cachedHeight(forKey: page.heightCacheKey)
    }

    // MARK: - Overlays

    /// One native card positioned over a page spacer. Cards on the same line
    /// keep this order — published conversations first, then local drafts
    /// (history above what is still pending, like GitHub), then the agent's
    /// question threads and composer — because `gitalSetSpacers` inserts
    /// same-line spacers in spec order.
    private struct Overlay: Identifiable {
        enum Kind {
            case thread(ReviewThread)
            case pending(PendingReviewComment)
            case reviewComposer
            case agentThread(AgentThread)
            case agentComposer(RepoViewModel.PRAgentComposer)
        }

        let id: String
        /// Line the card's dynamic spacer inserts after.
        let anchorLineID: String
        let kind: Kind

        /// Space reserved before the native card reports its real height.
        static let cardEstimate: CGFloat = 150
    }

    private var overlays: [Overlay] {
        var out: [Overlay] = []
        for hunk in diff.hunks {
            for line in hunk.lines {
                for thread in model.prs.threads(on: line, path: diff.path, in: number) {
                    out.append(Overlay(id: "thread:\(thread.id)", anchorLineID: line.id, kind: .thread(thread)))
                }
                for comment in model.prs.pendingComments(on: line, path: diff.path, in: number) {
                    out.append(Overlay(id: "draft:\(comment.id)", anchorLineID: line.id, kind: .pending(comment)))
                }
                // The review composer only renders while the PR accepts
                // comments — the "+" affordances are gated the same way.
                if canComment, model.prs.isComposerOpen(at: line, in: diff) {
                    out.append(Overlay(id: "card:composer", anchorLineID: line.id, kind: .reviewComposer))
                }
                for thread in model.prAgentThreads(on: line, in: number, itemKey: itemKey) {
                    out.append(Overlay(id: "agent:\(thread.id)", anchorLineID: line.id, kind: .agentThread(thread)))
                }
                if let composer = model.prAgentComposer,
                   model.isPRAgentComposerOpen(at: line, in: number, itemKey: itemKey) {
                    out.append(Overlay(id: "card:ask", anchorLineID: line.id, kind: .agentComposer(composer)))
                }
            }
        }
        return out
    }

    private var spacers: [WebDiffSpacer] {
        overlays.map { overlay in
            WebDiffSpacer(
                id: overlay.id,
                line: overlay.anchorLineID,
                height: overlayHeights[overlay.id] ?? cachedCardHeight(overlay.id) ?? Overlay.cardEstimate
            )
        }
    }

    @ViewBuilder
    private func overlayContent(_ overlay: Overlay) -> some View {
        switch overlay.kind {
        case .thread(let thread):
            ReviewThreadCard(model: model, thread: thread, number: number)
        case .pending(let comment):
            PendingReviewCommentCard(model: model, comment: comment, diff: diff, number: number)
        case .reviewComposer:
            ReviewCommentComposerView(model: model, number: number)
        case .agentThread(let thread):
            AgentThreadView(model: model, thread: thread)
        case .agentComposer(let composer):
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
    }
}
