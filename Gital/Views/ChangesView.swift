import AppKit
import SwiftUI

struct ChangesView: View {
    @Bindable var model: RepoViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if let operation = model.pendingOperation {
                ConflictBannerView(model: model, operation: operation)
                Divider()
            }

            if model.workingDiffs.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    diffList
                        // Picking a file keeps the pane's scroll offset by
                        // default, so after browsing (or line-selecting) deep
                        // in a long diff the next file opens mid-content —
                        // which reads as "the diff never switched".
                        // Background refreshes must not reset the offset, so
                        // this watches the selection, not the loaded diffs.
                        .onChange(of: model.selectedChange) {
                            proxy.scrollTo(Self.diffTopID, anchor: .top)
                        }
                }
            }

            Divider()
            CommitComposerView(model: model)
        }
        .task {
            await model.loadWorkingDiffsIfNeeded()
        }
    }

    /// Scroll anchor sitting above the first file section — the file-switch
    /// reset can't scrollTo a section id, which may not be materialized in
    /// the lazy stack right after a selection change.
    private static let diffTopID = "diff-top"

    private var diffList: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                Color.clear.frame(height: 0).id(Self.diffTopID)
                ForEach(model.workingDiffs) { diff in
                    Section {
                        diffGroupContent(diff)
                    } header: {
                        FileSectionHeader(diff: diff) {
                            lineSelectionActions(diff)
                        }
                        .contextMenu {
                            // A file not in any commit yet (untracked
                            // or a staged addition) would only open
                            // an empty sheet. A staged rename's
                            // history lives under the old name.
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
                }
                // Threads whose anchor line no longer exists (the
                // agent's own edit re-shaped the diff) must stay
                // reachable — the answer would otherwise vanish.
                ForEach(orphanedThreads) { thread in
                    AgentThreadView(model: model, thread: thread)
                }
                // Same for the composer: don't let a background diff
                // refresh silently swallow the box mid-typing.
                if let range = model.composerRange, let file = model.composerFile,
                   let anchorID = model.composerAnchorID, !model.workingDiffLineIDs.contains(anchorID) {
                    AgentComposerView(model: model, range: range, fileName: (file as NSString).lastPathComponent)
                }
            }
        }
    }

    private var headerBar: some View {
        PaneHeader {
            Text(headerTitle)
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if model.selectedChange != nil {
                Button {
                    model.selectedChange = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show all changes")
            }
            Spacer()
            DiffModePicker(mode: $model.diffMode)
        }
    }

    private var headerTitle: String {
        guard let selection = model.selectedChange else { return "All changes" }
        // A partially staged file exists on both sides; say which one is shown.
        let inBoth = model.status.staged.contains { $0.path == selection.path }
            && model.status.unstaged.contains { $0.path == selection.path }
        guard inBoth else { return selection.path }
        return selection.path + (selection.staged ? " — staged" : " — unstaged")
    }

    /// Agent threads whose anchor line ID is no longer present in the
    /// displayed diffs; rendered at the end of the list so they stay visible.
    private var orphanedThreads: [AgentThread] {
        let visible = model.workingDiffLineIDs
        return model.agentThreads.filter { !visible.contains($0.anchorLineID) }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No changes in the working copy")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    @ViewBuilder
    private func diffGroupContent(_ diff: FileDiff) -> some View {
        if diff.isBinary {
            BinaryFileContentView(diff: diff, imageContext: workingImageContext(diff))
        } else if model.diffMode == .split {
            // Split has no per-line interactions (selection/agent live in
            // unified), so the whole file is one web chunk.
            WebDiffChunkView(
                html: DiffHTMLBuilder.interactiveSplitPage(for: diff, options: splitOptions(for: diff)),
                estimatedHeight: CGFloat(SplitDiffRow.rows(for: diff.hunks).count) * 19,
                onAction: { handle($0, in: diff) }
            )
        } else {
            // Web chunks split where a native view (agent composer, agent
            // thread cards) must interleave with the diff lines.
            ForEach(unifiedSegments(for: diff)) { segment in
                WebDiffChunkView(
                    html: DiffHTMLBuilder.interactiveUnifiedPage(items: segment.items, options: unifiedOptions(for: diff)),
                    selectedLineIDs: model.selectedLineIDs(in: diff),
                    estimatedHeight: CGFloat(segment.items.count) * 19,
                    onAction: { handle($0, in: diff) }
                )
                if let lineID = segment.interleaveAfterLineID {
                    if model.composerAnchorID == lineID, let range = model.composerRange {
                        AgentComposerView(model: model, range: range, fileName: diff.fileName)
                    }
                    ForEach(threadsAnchored(at: lineID)) { thread in
                        AgentThreadView(model: model, thread: thread)
                    }
                }
            }
        }
    }

    private func workingImageContext(_ diff: FileDiff) -> ImageDiffContext? {
        ImageDiffContext.working(repository: model.repository, scope: diff.scope)
    }

    // MARK: - Web diff plumbing

    private struct UnifiedSegment: Identifiable {
        let id: String
        let items: [DiffHTMLBuilder.UnifiedItem]
        /// Line whose composer/thread views render right after this chunk.
        let interleaveAfterLineID: String?
    }

    /// Splits a file's unified rows into web chunks at every line that has an
    /// open composer or anchored agent threads, so those stay native SwiftUI
    /// between the chunks.
    private func unifiedSegments(for diff: FileDiff) -> [UnifiedSegment] {
        var segments: [UnifiedSegment] = []
        var items: [DiffHTMLBuilder.UnifiedItem] = []
        var firstID = ""

        func flush(after lineID: String?) {
            guard !items.isEmpty || lineID != nil else { return }
            segments.append(UnifiedSegment(
                id: "\(firstID)→\(lineID ?? "end")",
                items: items,
                interleaveAfterLineID: lineID
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
                if model.composerAnchorID == line.id || !threadsAnchored(at: line.id).isEmpty {
                    flush(after: line.id)
                }
            }
        }
        flush(after: nil)
        return segments
    }

    private func unifiedOptions(for diff: FileDiff) -> DiffHTMLBuilder.InteractiveOptions {
        var options = DiffHTMLBuilder.InteractiveOptions()
        options.selectableLines = model.canSelectLines(in: diff)
        options.askLines = true
        // The hover-hunk frame's Stage/Unstage/Discard capsules cover hunk
        // actions, so unified headers stay bare — except when lines can't be
        // staged (untracked, renames, invalid UTF-8): no capsules appear
        // there, and the header buttons are the pane's only affordance.
        if !options.selectableLines {
            options.hunkButtons = hunkButtons(for: diff)
        }
        options.language = DiffSyntaxHighlighting.language(for: diff)
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

    private func splitOptions(for diff: FileDiff) -> DiffHTMLBuilder.InteractiveOptions {
        var options = DiffHTMLBuilder.InteractiveOptions()
        options.hunkButtons = hunkButtons(for: diff)
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

    private func handle(_ action: WebDiffAction, in diff: FileDiff) {
        switch action {
        case .toggleLine(let id, let extend):
            if let line = line(withID: id, in: diff) {
                model.toggleLineSelection(line, in: diff, extend: extend)
            }
        case .askRange(let startID, let endID):
            if let start = line(withID: startID, in: diff), let end = line(withID: endID, in: diff) {
                let first = agentLineNumber(start, in: diff)
                let last = agentLineNumber(end, in: diff)
                // Anchoring at the range's last line puts the composer right
                // below the selection.
                model.openComposer(file: diff.path, lines: min(first, last)...max(first, last), anchorID: end.id)
            }
        case .lines(let act, let startID, let endID):
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
            guard let hunk = diff.hunks.first(where: { $0.id == id }) else { return }
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

    private func threadsAnchored(at lineID: String) -> [AgentThread] {
        model.agentThreads.filter { $0.anchorLineID == lineID }
    }
}

// MARK: - Conflict banner

/// Shown while a merge/rebase/cherry-pick/revert is stopped: names the
/// operation, counts the remaining conflicts, and offers Continue/Abort.
/// Continue stays disabled until every conflict is resolved — git would
/// reject it anyway, with a less helpful error.
struct ConflictBannerView: View {
    var model: RepoViewModel
    let operation: RepoOperation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(operation.displayName) in progress")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(statusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Abort…") { model.requestAbort() }
                .disabled(model.isSyncing)
            if operation != .merge {
                // Sequencer/rebase escape hatch: a cherry-pick or revert whose
                // resolution matches HEAD becomes empty, and `--continue`
                // refuses an empty commit forever — skip is the way forward.
                Button("Skip Commit") { model.skipPendingOperation() }
                    .disabled(model.isSyncing)
                    .help("Skip the commit this \(operation.displayName.lowercased()) is stopped on")
            }
            Button("Continue \(operation.displayName)") { model.continuePendingOperation() }
                .buttonStyle(.glassProminent)
                .disabled(!conflictsResolved || model.isSyncing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.orange.opacity(0.09))
    }

    private var conflictsResolved: Bool {
        model.conflictedChanges.isEmpty
    }

    private var statusText: String {
        let count = model.conflictedChanges.count
        if count == 0 {
            return "All conflicts resolved — ready to continue"
        }
        return "\(count) conflicted file\(count == 1 ? "" : "s") — resolve them, then continue"
    }
}

// MARK: - Hunk stage/unstage button

struct HunkActionButton: View {
    let title: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint))
                .padding(.horizontal, 7)
                .padding(.vertical, 1.5)
                .background(.background.opacity(0.7), in: Capsule())
                .overlay(Capsule().strokeBorder((tint ?? .accentColor).opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

// MARK: - Commit composer

struct CommitComposerView: View {
    @Bindable var model: RepoViewModel

    var body: some View {
        VStack(spacing: 10) {
            PlaceholderTextEditor(text: $model.commitMessage, placeholder: "Summary (required)")
                // Every codex delta rewrites the whole field; keystrokes made
                // between deltas would be silently destroyed.
                .disabled(model.isGeneratingCommitMessage)

            HStack(spacing: 12) {
                Toggle("Amend", isOn: $model.amend)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer()
                generateButton
                Button {
                    model.commit()
                } label: {
                    if model.isCommitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(commitLabel)
                    }
                }
                .buttonStyle(.glassProminent)
                // Amend keeps the button usable with an empty message, so an
                // explicit isCommitting check must prevent double-committing.
                .disabled((!model.canCommit && !model.amend) || model.isCommitting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// Sparkles = generate a message from the staged changes via codex;
    /// while a generation runs the same button becomes Cancel.
    private var generateButton: some View {
        Button {
            if model.isGeneratingCommitMessage {
                model.cancelCommitMessageGeneration()
            } else {
                model.generateCommitMessage()
            }
        } label: {
            if model.isGeneratingCommitMessage {
                Label("Cancel", systemImage: "stop.fill")
            } else {
                Label("Generate", systemImage: "sparkles")
            }
        }
        .disabled(!model.isGeneratingCommitMessage && (!model.canGenerateCommitMessage || model.isCommitting))
        .help(model.isGeneratingCommitMessage
            ? "Stop generating the commit message"
            : "Generate a commit message from the staged changes with Codex")
    }

    private var commitLabel: String {
        let count = model.status.staged.count
        if count == 0 { return "Commit" }
        return "Commit \(count) file\(count == 1 ? "" : "s")"
    }
}
