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
                                // A stash commit's first parent is the commit
                                // the stash was taken on — the same base
                                // `git stash show` diffs against. Untracked
                                // files (`stash -u`) live only in the stash's
                                // third parent, hence the fallback.
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
}
