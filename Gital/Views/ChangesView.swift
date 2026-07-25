import AppKit
import SwiftUI

struct ChangesView: View {
    @Bindable var model: RepoViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

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
                            }
                        }
                    }
                }
            }

            Divider()
            CommitComposerView(model: model)
        }
        .task(id: model.navTab) {
            if model.navTab == .changes {
                await model.loadWorkingDiffs()
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Text(model.selectedChangePath ?? "All changes")
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if model.selectedChangePath != nil {
                Button {
                    model.selectedChangePath = nil
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.25))
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
            Text("Binary file not shown")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(30)
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

    @ViewBuilder
    private func hunkStageButton(_ hunk: DiffHunk, in diff: FileDiff) -> some View {
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

    @ViewBuilder
    private func interactiveLine(_ line: DiffLine, in diff: FileDiff) -> some View {
        let lineNumber = line.newNumber ?? line.oldNumber ?? 0
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

            HStack(spacing: 12) {
                Toggle("Amend", isOn: $model.amend)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer()
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
                .disabled(!model.canCommit && !model.amend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var commitLabel: String {
        let count = model.status.staged.count
        if count == 0 { return "Commit" }
        return "Commit \(count) file\(count == 1 ? "" : "s")"
    }
}
