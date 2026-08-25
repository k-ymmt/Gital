import SwiftUI

struct StashDetailView: View {
    @Bindable var model: RepoViewModel

    var body: some View {
        if let ref = model.selectedStashRef,
           let stash = model.stashes.first(where: { $0.id == ref }) {
            VStack(spacing: 0) {
                PaneHeader(horizontalPadding: 14, verticalPadding: 10) {
                    Image(systemName: "archivebox")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stash.message)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(stash.reference)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Apply") { model.stashApply(stash, pop: false) }
                    Button("Pop") { model.stashApply(stash, pop: true) }
                    Button("Drop…", role: .destructive) { model.pendingStashDrop = stash }
                    DiffModePicker(mode: $model.diffMode)
                }

                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(model.stashDiffs) { diff in
                            Section {
                                if diff.isBinary || diff.hunks.isEmpty {
                                    // A stash commit's first parent is the
                                    // commit the stash was taken on — the same
                                    // base `git stash show` diffs against.
                                    // Untracked files (`stash -u`) live only in
                                    // the stash's third parent, hence the
                                    // fallback.
                                    FileDiffContentView(
                                        diff: diff,
                                        mode: model.diffMode,
                                        imageContext: ImageDiffContext(
                                            repository: model.repository,
                                            oldRevision: .commit("\(stash.commitHash)^"),
                                            newRevision: .commit(stash.commitHash),
                                            newFallbackRevision: .commit("\(stash.commitHash)^3")
                                        )
                                    )
                                } else {
                                    StashChunkView(diff: diff, mode: model.diffMode)
                                }
                            } header: {
                                FileSectionHeader(diff: diff)
                            }
                        }
                    }
                }
            }
        } else {
            EmptyStateView("Select a stash to see its contents", systemImage: "archivebox")
        }
    }

}

/// One stash file's chunk page, built off the main thread and memoized on
/// (diff, mode) — the HTML used to be rebuilt inside `body` on every
/// evaluation, costing O(file size) per visible file on any state change.
private struct StashChunkView: View {
    let diff: FileDiff
    let mode: DiffMode

    @State private var html = ""
    @State private var estimatedHeight: CGFloat = 0

    private struct Inputs: Equatable {
        let diff: FileDiff
        let mode: DiffMode
    }

    var body: some View {
        WebDiffChunkView(html: html, estimatedHeight: estimatedHeight, onAction: { _ in })
            .onChange(of: Inputs(diff: diff, mode: mode), initial: true) {
                // Cheap row-count estimate holds the frame until the build
                // (and later the page's own height report) replaces it.
                if html.isEmpty {
                    let rows = diff.hunks.reduce(diff.hunks.count) { $0 + $1.lines.count }
                    estimatedHeight = CGFloat(rows) * DiffHTMLBuilder.rowHeight
                }
                let diff = diff
                let mode = mode
                Task {
                    let built = await Task.detached { () -> (html: String, height: CGFloat) in
                        let html = DiffHTMLBuilder.chunkPage(for: diff, mode: mode)
                        let rows = mode == .split
                            ? SplitDiffRow.rows(for: diff.hunks).count
                            : DiffHTMLBuilder.unifiedItems(for: diff).count
                        return (html, CGFloat(rows) * DiffHTMLBuilder.rowHeight)
                    }.value
                    guard Inputs(diff: self.diff, mode: self.mode) == Inputs(diff: diff, mode: mode) else { return }
                    html = built.html
                    estimatedHeight = built.height
                }
            }
    }
}
