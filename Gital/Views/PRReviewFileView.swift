import SwiftUI

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

/// The PR ask-composer card — one spelling for the inline overlay and the
/// trailing section, so the two can't drift.
struct PRAgentComposerCard: View {
    @Bindable var model: RepoViewModel
    let composer: RepoViewModel.PRAgentComposer

    var body: some View {
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
struct PRReviewFileView: View {
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

    private nonisolated struct Page {
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
        // Computed once and shared between the spacer specs and the card
        // views — each body evaluation used to run the full overlay scan
        // twice (spacers + ForEach).
        let overlays = computeOverlays()
        ZStack(alignment: .topLeading) {
            InteractiveWebView(
                html: page.html,
                spacers: spacers(for: overlays),
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

    /// Builds the page HTML off the main thread — a big PR file's string
    /// assembly is O(file size), and LazyVStack materializes several of
    /// these views in one frame while scrolling.
    private func rebuildPage() {
        let diff = diff
        let canComment = canComment
        Task {
            let built = await Task.detached { () -> Page in
                let html = DiffHTMLBuilder.reviewUnifiedPage(
                    items: DiffHTMLBuilder.unifiedItems(for: diff),
                    language: DiffSyntaxHighlighting.language(for: diff),
                    commentable: canComment
                        ? { ReviewCommentAnchor(path: diff.path, diffLine: $0) != nil }
                        : nil,
                    askable: true
                )
                let rows = diff.hunks.reduce(diff.hunks.count) { $0 + $1.lines.count }
                return Page(html: html, estimatedHeight: CGFloat(rows) * DiffHTMLBuilder.rowHeight)
            }.value
            // Inputs superseded mid-build (file switch, permissions change).
            guard PageInputs(diff: self.diff, canComment: self.canComment) == PageInputs(diff: diff, canComment: canComment) else { return }
            page = built
            reportedHeight = cachedHeight(forKey: built.heightCacheKey)
        }
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

    /// The card anchors, pre-bucketed so the exact (and unchanged) per-line
    /// matching predicates only run on lines that can possibly hold a card.
    /// Without the gate, every body evaluation ran every predicate on every
    /// line — O(rows × cards) twice over on a big file.
    private func computeOverlays() -> [Overlay] {
        let threads = model.prs.threads(for: number)
        let drafts = model.prs.pendingComments(for: number)
        let reviewComposer = canComment ? model.prs.composer : nil
        let askComposer = model.prAgentComposer

        // Old/new line numbers that may anchor a thread, draft, or the
        // review composer on this file, and the line IDs agent cards hang
        // on. Supersets are fine — matched lines still run the predicates.
        var leftNumbers = Set<Int>()
        var rightNumbers = Set<Int>()
        func note(side: ReviewCommentAnchor.Side, line: Int) {
            if side == .left { leftNumbers.insert(line) } else { rightNumbers.insert(line) }
        }
        for thread in threads where thread.path == diff.path {
            if let line = thread.line { note(side: thread.side, line: line) }
        }
        for draft in drafts where draft.anchor.path == diff.path {
            note(side: draft.anchor.side, line: draft.anchor.line)
        }
        if let anchor = reviewComposer?.anchor, anchor.path == diff.path {
            note(side: anchor.side, line: anchor.line)
        }
        var agentLineIDs = Set<String>()
        for thread in model.agentThreads where thread.prNumber == number {
            agentLineIDs.insert(thread.anchorLineID)
        }
        if let askComposer, askComposer.number == number {
            agentLineIDs.insert(askComposer.anchorLineID)
        }
        guard !leftNumbers.isEmpty || !rightNumbers.isEmpty || !agentLineIDs.isEmpty else { return [] }

        var out: [Overlay] = []
        for hunk in diff.hunks {
            for line in hunk.lines {
                let mayAnchor = line.oldNumber.map(leftNumbers.contains) == true
                    || line.newNumber.map(rightNumbers.contains) == true
                    || agentLineIDs.contains(line.id)
                guard mayAnchor else { continue }
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
                if let askComposer, model.isPRAgentComposerOpen(at: line, in: number, itemKey: itemKey) {
                    out.append(Overlay(id: "card:ask", anchorLineID: line.id, kind: .agentComposer(askComposer)))
                }
            }
        }
        return out
    }

    private func spacers(for overlays: [Overlay]) -> [WebDiffSpacer] {
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
            PRAgentComposerCard(model: model, composer: composer)
        }
    }
}
