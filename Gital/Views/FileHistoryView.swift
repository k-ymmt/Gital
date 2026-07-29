import SwiftUI

/// Modal browser for one file's past: a History tab (commits touching the
/// file + the file's diff at the selected commit) and a Blame tab (line
/// annotations at the selected commit, or the working tree).
struct FileHistorySheet: View {
    @Bindable var model: FileHistoryModel
    @Environment(\.dismiss) private var dismiss

    @State private var diffMode: DiffMode = .unified

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 900, idealWidth: 1080, minHeight: 540, idealHeight: 680)
        .task { await model.load() }
        .alert("Git Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.path)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(scopeDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Tab", selection: $model.tab) {
                ForEach(FileHistoryModel.Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 150)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.quaternary.opacity(0.25))
    }

    private var scopeDescription: String {
        let commits = "\(model.entries.count)\(model.hasMore ? "+" : "") commit\(model.entries.count == 1 ? "" : "s")"
        if let start = model.startHash {
            return "\(commits) · from \(start.prefix(7))"
        }
        return commits
    }

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty {
            if model.isLoadingEntries {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.entriesLoadFailed {
                // Distinct from the no-commits case: claiming "no commits"
                // after a failed load would be a statement the model can't
                // back.
                VStack(spacing: 10) {
                    Text("The file's history could not be loaded")
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        Task { await model.load() }
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No commits touch this file")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            switch model.tab {
            case .history:
                HSplitView {
                    entryList
                        .frame(minWidth: 320, idealWidth: 400, maxWidth: 560)
                    diffPane
                        .frame(minWidth: 400, maxWidth: .infinity)
                }
            case .blame:
                FileBlameView(model: model)
            }
        }
    }

    // MARK: History tab

    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.entries) { entry in
                    FileHistoryEntryRow(entry: entry, isSelected: entry.hash == model.selectedHash)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedHash = entry.hash }
                }
                if model.hasMore {
                    Button("Load More") {
                        Task { await model.loadMore() }
                    }
                    .controlSize(.small)
                    .padding(.vertical, 10)
                    .disabled(model.isLoadingEntries)
                }
            }
        }
    }

    private var diffPane: some View {
        VStack(spacing: 0) {
            PaneHeader {
                if let entry = model.selectedEntry {
                    Text(entry.path)
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let previous = entry.previousPath {
                        Text("from \(previous)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let diff = model.diffs.first {
                        DiffStatsLabel(additions: diff.additions, deletions: diff.deletions)
                    }
                }
                Spacer()
                DiffModePicker(mode: $diffMode)
            }
            ScrollView([.vertical, .horizontal]) {
                if let diff = model.diffs.first {
                    FileDiffContentView(diff: diff, mode: diffMode, imageContext: entryImageContext)
                        .frame(minWidth: 600, alignment: .leading)
                } else {
                    // `git show` legitimately returns nothing here for a
                    // merge commit that kept the first parent's version.
                    Text("No changes to this file in this commit")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .padding(40)
                }
            }
        }
    }

    /// Entry diffs are taken against the commit's first parent (`^`); a root
    /// commit's old side fails to resolve and renders as empty. Keyed off
    /// the hash the diff was loaded for, not the selection — they diverge
    /// while a new selection's diff load is in flight.
    private var entryImageContext: ImageDiffContext? {
        model.diffsHash.map { hash in
            ImageDiffContext(
                repository: model.repository,
                oldRevision: .commit("\(hash)^"),
                newRevision: .commit(hash)
            )
        }
    }
}

// MARK: - History entry row

private struct FileHistoryEntryRow: View {
    let entry: FileHistoryEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            // No badge for entries without a name-status record (merges) —
            // showing the parser's default would fabricate an "M".
            if let status = entry.status {
                StatusBadge(status: status)
            } else {
                Color.clear.frame(width: 17, height: 17)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.subject)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(entry.author)
                        .lineLimit(1)
                    Text(entry.relativeDate)
                        .lineLimit(1)
                    if entry.previousPath != nil {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.system(size: 9))
                            .help("Renamed from \(entry.previousPath ?? "")")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(entry.shortHash)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear)
    }
}

// MARK: - Blame tab

private struct FileBlameView: View {
    @Bindable var model: FileHistoryModel

    private static let annotationWidth: CGFloat = 250

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader {
                Text(blameTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.isLoadingBlame {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let blame = model.blame {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(spacing: 0) {
                        ForEach(blame.lines) { line in
                            BlameLineRow(
                                line: line,
                                annotation: blame.annotations[line.hash],
                                annotationWidth: Self.annotationWidth
                            ) {
                                model.revealCommit(line.hash)
                            }
                        }
                    }
                    .frame(minWidth: 700, alignment: .leading)
                }
            } else if !model.isLoadingBlame {
                // Failed load. The `.task(id:)` below won't re-fire on its
                // own (the target didn't change), so offer the retry here.
                VStack(spacing: 10) {
                    Text("Blame could not be loaded")
                        .foregroundStyle(.secondary)
                    Button("Retry") { model.reloadBlame() }
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        // Reload whenever the target drifts (selection changed in the
        // History tab, or the sheet just opened on the Blame tab).
        .task(id: model.blameTargetKey) {
            await model.loadBlameIfNeeded()
        }
    }

    private var blameTitle: String {
        guard let key = model.blameTargetKey else { return "Blame" }
        if key.isEmpty { return "Blame — working tree" }
        // A deleting commit has no content of its own; what's shown is the
        // last version, blamed at the parent.
        if model.selectedEntry?.status == .deleted {
            return "Blame before \(key.prefix(7)) (file deleted)"
        }
        return "Blame at \(key.prefix(7))"
    }
}

private struct BlameLineRow: View {
    let line: BlameLine
    let annotation: BlameAnnotation?
    let annotationWidth: CGFloat
    let onSelectCommit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            annotationColumn
                .frame(width: annotationWidth, alignment: .leading)
            Text(String(line.number))
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 10)
                .foregroundStyle(Color.secondary.opacity(0.55))
            Text(line.text.isEmpty ? " " : line.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 16)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(minHeight: 19, alignment: .top)
        .overlay(alignment: .top) {
            if line.isGroupStart, line.number > 1 {
                Divider()
            }
        }
    }

    @ViewBuilder
    private var annotationColumn: some View {
        if line.isGroupStart {
            if line.isUncommitted {
                Text("Uncommitted")
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .padding(.top, 2)
            } else {
                Button(action: onSelectCommit) {
                    HStack(spacing: 7) {
                        Text(String(line.hash.prefix(7)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DesignStyle.linkBlue)
                        Text(annotation?.author ?? "")
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(annotation?.date ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 10)
                    .padding(.top, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(annotation.map { "\($0.summary) — \($0.author), \($0.date)" } ?? "")
            }
        }
    }
}
