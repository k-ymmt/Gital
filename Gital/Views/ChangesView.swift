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
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
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

            Divider()
            CommitComposerView(model: model)
        }
        .task {
            await model.loadWorkingDiffsIfNeeded()
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
        let selectedCount = model.selectedLineIDs(in: diff).count
        if selectedCount > 0 {
            if diff.scope == .unstaged {
                HunkActionButton(title: "Discard \(selectedCount) Line\(selectedCount == 1 ? "" : "s")", tint: DesignStyle.deletion) {
                    model.requestDiscard(.lines(diff, count: selectedCount))
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
            ForEach(SplitDiffRow.rows(for: diff.hunks)) { row in
                if row.isHunkHeader,
                   let hunk = diff.hunks.first(where: { row.id.hasPrefix("\($0.id)#") }) {
                    SplitDiffRowView(row: row)
                        .overlay(alignment: .trailing) { hunkStageButton(hunk, in: diff) }
                } else {
                    SplitDiffRowView(row: row)
                }
            }
        } else {
            ForEach(diff.hunks) { hunk in
                HunkHeaderView(text: hunk.header)
                    .overlay(alignment: .trailing) { hunkStageButton(hunk, in: diff) }
                ForEach(hunk.lines) { line in
                    interactiveLine(line, in: diff)
                }
            }
        }
    }

    private func workingImageContext(_ diff: FileDiff) -> ImageDiffContext? {
        ImageDiffContext.working(repository: model.repository, scope: diff.scope)
    }

    @ViewBuilder
    private func hunkStageButton(_ hunk: DiffHunk, in diff: FileDiff) -> some View {
        // Combined (conflict) hunks: no patch can be built from them, and the
        // whole-file fallback behind "Stage" would mark the conflict resolved
        // with the markers still in the file. Resolution happens through the
        // sidebar's resolve menu, never through hunk buttons.
        if diff.isCombined {
            EmptyView()
        } else {
            plainHunkStageButton(hunk, in: diff)
        }
    }

    @ViewBuilder
    private func plainHunkStageButton(_ hunk: DiffHunk, in diff: FileDiff) -> some View {
        switch diff.scope {
        case .unstaged:
            HStack(spacing: 6) {
                HunkActionButton(title: "Discard", tint: DesignStyle.deletion) {
                    model.requestDiscard(.hunk(hunk, diff))
                }
                HunkActionButton(title: "Stage") { model.stageHunk(hunk, in: diff) }
            }
            .padding(.trailing, 8)
        case .untracked:
            HunkActionButton(title: "Stage") { model.stageHunk(hunk, in: diff) }
                .padding(.trailing, 8)
        case .staged:
            HunkActionButton(title: "Unstage") { model.unstageHunk(hunk, in: diff) }
                .padding(.trailing, 8)
        case .snapshot:
            EmptyView()
        }
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

    @ViewBuilder
    private func interactiveLine(_ line: DiffLine, in diff: FileDiff) -> some View {
        let lineNumber = agentLineNumber(line, in: diff)
        let selectable = model.canSelectLines(in: diff) && line.kind != .context

        InteractiveDiffLineView(
            line: line,
            isSelected: model.selectedDiffLineIDs.contains(line.id),
            onSelect: selectable ? { extend in
                model.toggleLineSelection(line, in: diff, extend: extend)
            } : nil
        ) {
            if NSEvent.modifierFlags.contains(.shift) {
                model.extendComposer(file: diff.path, line: lineNumber, anchorID: line.id)
            } else {
                model.openComposer(file: diff.path, line: lineNumber, anchorID: line.id)
            }
        }

        if model.composerAnchorID == line.id, let range = model.composerRange {
            AgentComposerView(model: model, range: range, fileName: diff.fileName)
        }

        ForEach(threadsAnchored(at: line.id)) { thread in
            AgentThreadView(model: model, thread: thread)
        }
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

// MARK: - Interactive diff line (hover + button)

struct InteractiveDiffLineView: View {
    let line: DiffLine
    var isSelected = false
    var onSelect: ((_ extend: Bool) -> Void)?
    let onAsk: () -> Void

    @State private var isHovering = false

    var body: some View {
        UnifiedDiffLineView(line: line)
            .background(isHovering ? Color.primary.opacity(0.04) : .clear)
            .overlay {
                if isSelected {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.14))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2.5)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect?(NSEvent.modifierFlags.contains(.shift))
            }
            .overlay(alignment: .leading) {
                if isHovering {
                    Button(action: onAsk) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 17, height: 17)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 3)
                    .help("Ask AI Agent about this line (⇧-click to extend range)")
                }
            }
            .onHover { isHovering = $0 }
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
