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
                                    WebDiffChunkView(
                                        html: DiffHTMLBuilder.chunkPage(for: diff, mode: model.diffMode),
                                        estimatedHeight: estimatedHeight(for: diff),
                                        onAction: { _ in }
                                    )
                                }
                            } header: {
                                FileSectionHeader(diff: diff)
                            }
                        }
                    }
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "archivebox")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text("Select a stash to see its contents")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Rows × line height, exact unless lines wrap; holds the chunk's frame
    /// only until the page reports its real height.
    private func estimatedHeight(for diff: FileDiff) -> CGFloat {
        switch model.diffMode {
        case .unified:
            CGFloat(DiffHTMLBuilder.unifiedItems(for: diff).count) * 19
        case .split:
            CGFloat(SplitDiffRow.rows(for: diff.hunks).count) * 19
        }
    }
}
