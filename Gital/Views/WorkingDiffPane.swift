import SwiftUI

/// The Working Copy diff list: ONE self-sized interactive web page (every
/// file in a single `WKWebView`) inside the native ScrollView, with the
/// native pieces — file headers, binary/image previews, agent composer and
/// thread cards — overlaid at page-reported spacer offsets.
///
/// One page instead of a `LazyVStack` of per-file web chunks because the
/// chunk list scrolled badly: every chunk entering the viewport spawned a
/// web view + full page load mid-scroll (visible hitches), and each chunk's
/// estimated-then-reported height kept re-sizing the scroll content (the
/// scrollbar visibly stretched). Here the web view exists once, loads once
/// per diff refresh, and the content height settles once.
///
/// The overlays stay in perfect sync with the page because BOTH scroll
/// natively: the page never scrolls itself (wheel events go to the outer
/// ScrollView), so a spacer's document offset — reported by the page after
/// layout — is exactly the overlay's offset inside the scroll content.
struct WorkingDiffPane: View {
    @Bindable var model: RepoViewModel

    /// Total page height, reported by the page after layout. Kept across
    /// HTML rebuilds (the fresh page re-reports shortly; the stale value is
    /// far closer than a rows×19 estimate, so the scrollbar barely moves).
    @State private var pageHeight: CGFloat?
    /// Document offset of every spacer, reported alongside the height.
    @State private var anchors: [String: CGFloat] = [:]
    /// Measured native overlay heights, pushed back as spacer heights.
    @State private var overlayHeights: [String: CGFloat] = [:]
    @State private var page = BuiltPage(html: "", estimatedHeight: 0, diffs: [])
    @State private var scroll = ScrollOffsetBox()

    /// Scroll anchor above the page — the file-switch reset scrolls here.
    private static let diffTopID = "diff-top"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.diffTopID)
                    ZStack(alignment: .topLeading) {
                        InteractiveWebView(
                            html: page.html,
                            selectedLineIDs: model.selectedDiffLineIDs,
                            spacers: spacers,
                            onAction: { handle($0) },
                            onHeight: { height, ready in
                                pageHeight = height
                                // Loading-phase reports can still describe
                                // the outgoing page; only a post-didFinish
                                // report certainly measures this one. The
                                // spacer push after didFinish guarantees at
                                // least one ready report per load.
                                if ready {
                                    cacheHeight(height, forKey: page.heightCacheKey)
                                }
                            },
                            onAnchors: { anchors = $0 }
                        )
                        .frame(height: pageHeight ?? page.estimatedHeight)
                        ForEach(overlays) { overlay in
                            if let top = anchors[overlay.id] {
                                overlayContent(overlay)
                                    .onGeometryChange(for: CGFloat.self, of: \.size.height) {
                                        overlayHeights[overlay.id] = $0
                                    }
                                    .frame(maxWidth: .infinity)
                                    .offset(y: top)
                            }
                        }
                    }
                    trailingCards
                }
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, offset in
                scroll.y = offset
            }
            // Picking a file keeps the pane's scroll offset by default, so
            // after browsing deep in a long diff the next file would open
            // mid-content. Background refreshes must not reset the offset,
            // so this watches the selection, not the loaded diffs.
            .onChange(of: model.selectedChange) {
                proxy.scrollTo(Self.diffTopID, anchor: .top)
            }
        }
        .overlay(alignment: .top) {
            PinnedFileHeader(
                files: model.workingDiffs,
                anchors: anchors,
                headerHeights: overlayHeights,
                scroll: scroll
            ) { diff in
                fileHeader(for: diff)
            }
        }
        .onChange(of: PageInputs(diffs: model.workingDiffs, mode: model.diffMode), initial: true) {
            rebuildPage()
        }
    }

    // MARK: - Page building

    private struct PageInputs: Equatable {
        let diffs: [FileDiff]
        let mode: DiffMode
    }

    private struct BuiltPage {
        let html: String
        let estimatedHeight: CGFloat
        /// The diffs this page was rendered from. Bridge actions resolve
        /// their positional IDs against THIS snapshot, not the live model:
        /// between a diff refresh landing in the model and the fresh page
        /// replacing the old one, a click on the still-visible old page
        /// would otherwise resolve `path@N` against the NEW diff — and stage
        /// or discard a physical line the user never saw. Against the
        /// snapshot, a stale action degrades to a patch that fails to apply.
        let diffs: [FileDiff]
        /// Height-cache key, hashed once — heights are reported on every
        /// layout change and this page can be megabytes.
        let heightCacheKey: String

        init(html: String, estimatedHeight: CGFloat, diffs: [FileDiff]) {
            self.html = html
            self.estimatedHeight = estimatedHeight
            self.diffs = diffs
            self.heightCacheKey = Gital.heightCacheKey(for: html)
        }
    }

    private func rebuildPage() {
        let mode = model.diffMode
        let diffs = model.workingDiffs
        let files = diffs.map { diff in
            DiffHTMLBuilder.WorkingFile(diff: diff, options: options(for: diff, mode: mode))
        }
        let html = DiffHTMLBuilder.workingCopyPage(files: files, mode: mode)
        page = BuiltPage(html: html, estimatedHeight: Self.estimatedHeight(for: diffs, mode: mode), diffs: diffs)
        if let cached = cachedHeight(forKey: page.heightCacheKey) {
            pageHeight = cached
        }
    }

    /// rows × 19 plus the header spacers — only holds the scroll extent until
    /// the first real height report (wrong whenever lines wrap).
    private static func estimatedHeight(for diffs: [FileDiff], mode: DiffMode) -> CGFloat {
        diffs.reduce(0) { total, diff in
            let rows: CGFloat
            if diff.isBinary {
                rows = Overlay.binaryEstimate / 19
            } else if mode == .split {
                rows = CGFloat(SplitDiffRow.rows(for: diff.hunks).count)
            } else {
                rows = CGFloat(diff.hunks.reduce(diff.hunks.count) { $0 + $1.lines.count })
            }
            return total + CGFloat(DiffHTMLBuilder.headerSpacerEstimate) + rows * 19
        }
    }

    private func options(for diff: FileDiff, mode: DiffMode) -> DiffHTMLBuilder.InteractiveOptions {
        var options = DiffHTMLBuilder.InteractiveOptions()
        options.language = DiffSyntaxHighlighting.language(for: diff)
        if mode == .split {
            // Split has no per-line interactions (selection/agent live in
            // unified), so hunk actions always sit on the headers.
            options.hunkButtons = hunkButtons(for: diff)
            return options
        }
        options.selectableLines = model.canSelectLines(in: diff)
        options.askLines = true
        // The hover-hunk frame's Stage/Unstage/Discard capsules cover hunk
        // actions, so unified headers stay bare — except when lines can't be
        // staged (untracked, renames, invalid UTF-8): no capsules appear
        // there, and the header buttons are the pane's only affordance.
        if !options.selectableLines {
            options.hunkButtons = hunkButtons(for: diff)
        }
        if options.selectableLines {
            switch diff.scope {
            case .unstaged:
                options.selectionButtons = [
                    DiffHTMLBuilder.HunkButton(action: "stageLines", title: "Stage"),
                    DiffHTMLBuilder.HunkButton(action: "discardLines", title: "Discard", destructive: true),
                ]
            case .staged:
                options.selectionButtons = [DiffHTMLBuilder.HunkButton(action: "unstageLines", title: "Unstage")]
            default:
                break
            }
        }
        return options
    }

    /// Hunk-header buttons for the pages the hover-hunk frame can't serve:
    /// all of split mode (no frame there), and unified files whose lines
    /// can't be staged (no capsules on their frame).
    /// Combined (conflict) hunks: no patch can be built from them, and the
    /// whole-file fallback behind "Stage" would mark the conflict resolved
    /// with the markers still in the file. Resolution happens through the
    /// sidebar's resolve menu, never through hunk buttons.
    private func hunkButtons(for diff: FileDiff) -> [DiffHTMLBuilder.HunkButton] {
        guard !diff.isCombined else { return [] }
        switch diff.scope {
        case .unstaged:
            return [
                DiffHTMLBuilder.HunkButton(action: "discardHunk", title: "Discard", destructive: true),
                DiffHTMLBuilder.HunkButton(action: "stageHunk", title: "Stage"),
            ]
        case .untracked:
            return [DiffHTMLBuilder.HunkButton(action: "stageHunk", title: "Stage")]
        case .staged:
            return [DiffHTMLBuilder.HunkButton(action: "unstageHunk", title: "Unstage")]
        case .snapshot:
            return []
        }
    }

    // MARK: - Overlays

    /// One native view positioned over a page spacer.
    private struct Overlay: Identifiable {
        enum Kind {
            case header(FileDiff)
            case binary(FileDiff)
            case composer(range: ClosedRange<Int>, fileName: String, anchorLineID: String)
            case thread(AgentThread)
        }

        let id: String
        let kind: Kind

        /// Space reserved before the native view reports its real height.
        static let binaryEstimate: CGFloat = 120
        static let cardEstimate: CGFloat = 150

        var defaultHeight: CGFloat {
            switch kind {
            case .header: CGFloat(DiffHTMLBuilder.headerSpacerEstimate)
            case .binary: Self.binaryEstimate
            case .composer, .thread: Self.cardEstimate
            }
        }

        /// Line a dynamic spacer inserts after; nil for spacers baked into
        /// the page HTML.
        var anchorLine: String? {
            switch kind {
            case .header, .binary: nil
            case .composer(_, _, let anchorLineID): anchorLineID
            case .thread(let thread): thread.anchorLineID
            }
        }
    }

    private var overlays: [Overlay] {
        var out: [Overlay] = []
        for diff in model.workingDiffs {
            out.append(Overlay(id: DiffHTMLBuilder.headerSpacerID(for: diff), kind: .header(diff)))
            if diff.isBinary {
                out.append(Overlay(id: DiffHTMLBuilder.binarySpacerID(for: diff), kind: .binary(diff)))
            }
        }
        // Agent cards interleave in unified mode only (split rows carry no
        // line IDs to insert after) — matching the chunked pane before it.
        guard model.diffMode == .unified else { return out }
        if let anchorID = model.composerAnchorID, let range = model.composerRange, let file = model.composerFile,
           model.workingDiffLineIDs.contains(anchorID) {
            out.append(Overlay(
                id: "card:composer",
                kind: .composer(range: range, fileName: (file as NSString).lastPathComponent, anchorLineID: anchorID)
            ))
        }
        for thread in model.agentThreads where model.workingDiffLineIDs.contains(thread.anchorLineID) {
            out.append(Overlay(id: "card:thread:\(thread.id)", kind: .thread(thread)))
        }
        return out
    }

    private var spacers: [WebDiffSpacer] {
        overlays.map { overlay in
            WebDiffSpacer(
                id: overlay.id,
                line: overlay.anchorLine,
                height: overlayHeights[overlay.id] ?? overlay.defaultHeight
            )
        }
    }

    @ViewBuilder
    private func overlayContent(_ overlay: Overlay) -> some View {
        switch overlay.kind {
        case .header(let diff):
            fileHeader(for: diff)
        case .binary(let diff):
            BinaryFileContentView(
                diff: diff,
                imageContext: ImageDiffContext.working(repository: model.repository, scope: diff.scope)
            )
        case .composer(let range, let fileName, _):
            AgentComposerView(model: model, range: range, fileName: fileName)
        case .thread(let thread):
            AgentThreadView(model: model, thread: thread)
        }
    }

    /// Threads whose anchor line no longer exists (the agent's own edit
    /// re-shaped the diff) must stay reachable — the answer would otherwise
    /// vanish. Same for the composer: a background diff refresh must not
    /// silently swallow the box mid-typing. Both render below the page.
    private var trailingCards: some View {
        VStack(spacing: 0) {
            ForEach(orphanedThreads) { thread in
                AgentThreadView(model: model, thread: thread)
            }
            if let range = model.composerRange, let file = model.composerFile,
               let anchorID = model.composerAnchorID, !model.workingDiffLineIDs.contains(anchorID) {
                AgentComposerView(model: model, range: range, fileName: (file as NSString).lastPathComponent)
            }
        }
    }

    private var orphanedThreads: [AgentThread] {
        let visible = model.workingDiffLineIDs
        return model.agentThreads.filter { !visible.contains($0.anchorLineID) }
    }

    // MARK: - File header

    private func fileHeader(for diff: FileDiff) -> some View {
        FileSectionHeader(diff: diff) {
            lineSelectionActions(diff)
        }
        .contextMenu {
            // A file not in any commit yet (untracked or a staged addition)
            // would only open an empty sheet. A staged rename's history
            // lives under the old name.
            let isNewFile = diff.scope == .untracked
                || (model.status.staged + model.status.unstaged).contains {
                    $0.path == diff.path && ($0.status == .added || $0.status == .untracked)
                }
            if !isNewFile {
                Button("File History") {
                    model.showFileHistory(path: diff.oldPath ?? diff.path)
                }
                Button("Blame") {
                    model.showFileHistory(path: diff.oldPath ?? diff.path, tab: .blame)
                }
            }
        }
    }

    @ViewBuilder
    private func lineSelectionActions(_ diff: FileDiff) -> some View {
        let selected = model.selectedLineIDs(in: diff)
        let selectedCount = selected.count
        if selectedCount > 0 {
            if diff.scope == .unstaged {
                HunkActionButton(title: "Discard \(selectedCount) Line\(selectedCount == 1 ? "" : "s")", tint: DesignStyle.deletion) {
                    model.requestDiscard(.lines(diff, ids: selected))
                }
            }
            HunkActionButton(title: lineActionTitle(diff, count: selectedCount)) {
                model.applySelectedLines(in: diff)
            }
            Button {
                model.clearLineSelection(in: diff)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear line selection")
        }
    }

    private func lineActionTitle(_ diff: FileDiff, count: Int) -> String {
        let verb = diff.scope == .staged ? "Unstage" : "Stage"
        return "\(verb) \(count) Line\(count == 1 ? "" : "s")"
    }

    // MARK: - Bridge actions

    /// The page's line/hunk IDs embed the file path and are unique across
    /// the whole multi-file page, so the owning diff is recovered by lookup.
    /// Resolves against the snapshot the page was BUILT from (see
    /// `BuiltPage.diffs`) — clicks always mean what the user saw.
    private func diff(containing id: String) -> FileDiff? {
        page.diffs.first { diff in
            diff.hunks.contains { $0.id == id || $0.lines.contains { $0.id == id } }
        }
    }

    private func handle(_ action: WebDiffAction) {
        switch action {
        case .toggleLine(let id, let extend):
            if let diff = diff(containing: id), let line = line(withID: id, in: diff) {
                model.toggleLineSelection(line, in: diff, extend: extend)
            }
        case .askRange(let startID, let endID):
            guard let diff = diff(containing: startID) else { return }
            if let start = line(withID: startID, in: diff), let end = line(withID: endID, in: diff) {
                let first = agentLineNumber(start, in: diff)
                let last = agentLineNumber(end, in: diff)
                // Anchoring at the range's last line puts the composer right
                // below the selection.
                model.openComposer(file: diff.path, lines: min(first, last)...max(first, last), anchorID: end.id)
            }
        case .lines(let act, let startID, let endID):
            guard let diff = diff(containing: startID) else { return }
            // The framed range goes to the model as explicit IDs — never
            // through the click-based line selection, which the user may be
            // curating separately.
            let ids = changedLineIDs(from: startID, to: endID, in: diff)
            guard !ids.isEmpty else { return }
            switch act {
            case "stageLines", "unstageLines":
                // Direction comes from the diff's scope inside the model —
                // both actions are the same apply.
                model.applyLines(ids, in: diff)
            case "discardLines":
                model.requestDiscard(.lines(diff, ids: ids))
            default:
                break
            }
        case .hunk(let act, let id):
            guard let diff = diff(containing: id),
                  let hunk = diff.hunks.first(where: { $0.id == id }) else { return }
            switch act {
            case "stageHunk": model.stageHunk(hunk, in: diff)
            case "unstageHunk": model.unstageHunk(hunk, in: diff)
            case "discardHunk": model.requestDiscard(.hunk(hunk, diff))
            default: break
            }
        }
    }

    /// The changed (stageable) lines between two line IDs in document order,
    /// bounds included — context lines in the span don't stage.
    private func changedLineIDs(from startID: String, to endID: String, in diff: FileDiff) -> Set<String> {
        let all = diff.hunks.flatMap(\.lines)
        guard let from = all.firstIndex(where: { $0.id == startID }),
              let to = all.firstIndex(where: { $0.id == endID }) else { return [] }
        return Set(all[min(from, to)...max(from, to)].filter { $0.kind != .context }.map(\.id))
    }

    private func line(withID id: String, in diff: FileDiff) -> DiffLine? {
        for hunk in diff.hunks {
            if let line = hunk.lines.first(where: { $0.id == id }) {
                return line
            }
        }
        return nil
    }

    /// New-file coordinate for a diff line. Deletions have no new number, so
    /// they anchor to the new-file position they were removed at — mixing old
    /// and new coordinates in one range produced prompts pointing at regions
    /// the user never selected.
    private func agentLineNumber(_ line: DiffLine, in diff: FileDiff) -> Int {
        if let number = line.newNumber { return number }
        for hunk in diff.hunks {
            guard let index = hunk.lines.firstIndex(where: { $0.id == line.id }) else { continue }
            for prior in hunk.lines[..<index].reversed() {
                if let number = prior.newNumber { return number }
            }
            return hunk.newStart
        }
        return line.oldNumber ?? 0
    }
}

/// Scroll offset in a plain observable box: the pane's body must not read it
/// (a per-frame @State write would re-evaluate — and re-hash — the whole
/// pane during every scroll), so only `PinnedFileHeader` observes it.
@Observable
final class ScrollOffsetBox {
    var y: CGFloat = 0
}

/// The floating copy of the current file's header, pinned to the pane's top
/// edge while its file is scrolled under it — the native replacement for the
/// old `LazyVStack` pinned section headers. The next file's header pushes it
/// out through the clamped offset.
private struct PinnedFileHeader<Content: View>: View {
    let files: [FileDiff]
    let anchors: [String: CGFloat]
    let headerHeights: [String: CGFloat]
    let scroll: ScrollOffsetBox
    @ViewBuilder let header: (FileDiff) -> Content

    var body: some View {
        let y = scroll.y
        if y > 0, let index = currentIndex(at: y) {
            let diff = files[index]
            let height = headerHeights[DiffHTMLBuilder.headerSpacerID(for: diff)]
                ?? CGFloat(DiffHTMLBuilder.headerSpacerEstimate)
            let pushOut = nextHeaderTop(after: index).map { min(0, $0 - y - height) } ?? 0
            header(diff)
                .offset(y: pushOut)
        }
    }

    /// The file whose content is under the pane's top edge: the last file
    /// whose header offset is at or above the scroll position.
    private func currentIndex(at y: CGFloat) -> Int? {
        var current: Int?
        for (index, diff) in files.enumerated() {
            guard let top = anchors[DiffHTMLBuilder.headerSpacerID(for: diff)] else { continue }
            if top <= y { current = index } else { break }
        }
        return current
    }

    private func nextHeaderTop(after index: Int) -> CGFloat? {
        for diff in files[(index + 1)...] {
            if let top = anchors[DiffHTMLBuilder.headerSpacerID(for: diff)] { return top }
        }
        return nil
    }
}
