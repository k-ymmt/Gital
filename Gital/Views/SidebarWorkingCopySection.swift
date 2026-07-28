import SwiftUI

/// Sidebar content for the Changes tab: unstaged and staged file trees.
struct SidebarWorkingCopySection: View {
    var model: RepoViewModel
    @Binding var collapsedFileFolders: Set<String>

    @State private var fileRowsCache = BranchTreeRowsCache<FileChange>()

    var body: some View {
        SidebarSectionHeader("Unstaged (\(model.status.unstaged.count))") {
            Button("Stage All") { model.stageAll() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.tint)
                .disabled(model.status.unstaged.isEmpty)
        }
        fileTreeRows(model.status.unstaged, keyPrefix: "wc-unstaged", staged: false)

        SidebarSectionHeader("Staged (\(model.status.staged.count))") {
            Button("Unstage All") { model.unstageAll() }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(.tint)
                .disabled(model.status.staged.isEmpty)
        }
        fileTreeRows(model.status.staged, keyPrefix: "wc-staged", staged: true)
    }

    @ViewBuilder
    private func fileTreeRows(_ changes: [FileChange], keyPrefix: String, staged: Bool) -> some View {
        let rows = fileRowsCache.rows(
            changes.map { ($0.path, $0) },
            keyPrefix: keyPrefix,
            collapsed: collapsedFileFolders
        )
        ForEach(rows) { row in
            switch row {
            case .folder(let path, let name, let depth):
                SidebarFolderRow(path: path, name: name, depth: depth, collapsed: $collapsedFileFolders)
            case .leaf(let change, let name, _, let depth):
                fileRow(change, displayName: name, depth: depth, staged: staged)
            }
        }
    }

    private func fileRow(_ change: FileChange, displayName: String, depth: Int, staged: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                staged ? model.unstage(change) : model.stage(change)
            } label: {
                Image(systemName: staged ? "minus.square.fill" : "plus.square")
                    .font(.system(size: 13))
                    .foregroundStyle(staged ? DesignStyle.addition : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(staged ? "Unstage" : "Stage")

            StatusBadge(status: change.status)

            Text(displayName)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 16 + CGFloat(depth) * 14)
        .padding(.trailing, 16)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(sidebarRowBackground(model.selectedChange == RepoViewModel.ChangeSelection(path: change.path, staged: staged)))
        .onTapGesture {
            model.selectedChange = RepoViewModel.ChangeSelection(path: change.path, staged: staged)
            model.navTab = .changes
        }
        .contextMenu {
            if !staged {
                Button(change.status == .untracked ? "Delete File…" : "Discard Changes…", role: .destructive) {
                    model.requestDiscard(.file(change))
                }
            }
        }
    }
}
