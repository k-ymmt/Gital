import SwiftUI

/// Sidebar content for the Branches tab: local branches, remotes, and tags.
struct SidebarBranchesSection: View {
    var model: RepoViewModel
    @Binding var expandedSections: Set<String>
    @Binding var collapsedBranchFolders: Set<String>

    var body: some View {
        SidebarCollapsibleHeader(title: "Branches", key: "branches", expandedSections: $expandedSections)
        if expandedSections.contains("branches") {
            let rows = BranchTree.rows(
                model.branches.map { ($0.name, $0) },
                keyPrefix: "branches",
                collapsed: collapsedBranchFolders
            )
            ForEach(rows) { row in
                switch row {
                case .folder(let path, let name, let depth):
                    SidebarFolderRow(path: path, name: name, depth: depth, collapsed: $collapsedBranchFolders)
                case .leaf(let branch, let name, _, let depth):
                    localBranchRow(branch, displayName: name, depth: depth)
                }
            }
        }

        SidebarCollapsibleHeader(title: "Remotes", key: "remotes", expandedSections: $expandedSections)
        if expandedSections.contains("remotes") {
            ForEach(model.remotes) { remote in
                let remoteKey = "remote:\(remote.name)"
                DisclosureRow(isExpanded: !collapsedBranchFolders.contains(remoteKey)) {
                    collapsedBranchFolders.toggleMembership(remoteKey)
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(remote.name)
                        .font(.system(size: 12.5))
                }

                if !collapsedBranchFolders.contains(remoteKey) {
                    let rows = BranchTree.rows(
                        remote.branches.map { ($0, $0) },
                        keyPrefix: remoteKey,
                        collapsed: collapsedBranchFolders
                    )
                    ForEach(rows) { row in
                        switch row {
                        case .folder(let path, let name, let depth):
                            SidebarFolderRow(path: path, name: name, depth: depth, baseIndent: 37, collapsed: $collapsedBranchFolders)
                        case .leaf(let branch, let name, _, let depth):
                            remoteBranchRow(branch, displayName: name, depth: depth, remote: remote.name)
                        }
                    }
                }
            }
        }

        SidebarCollapsibleHeader(title: "Tags", key: "tags", expandedSections: $expandedSections)
        tagsSection
    }

    private func localBranchRow(_ branch: Branch, displayName: String, depth: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12))
                .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.secondary)
            Text(displayName)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer()
            if branch.isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DesignStyle.addition)
            }
        }
        .padding(.leading, 16 + CGFloat(depth) * 14)
        .padding(.trailing, 16)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(sidebarRowBackground(model.highlightedBranchName == branch.name))
        .onTapGesture(count: 2) {
            model.checkout(branch: branch)
        }
        .onTapGesture {
            model.selectBranch(branch)
        }
        .contextMenu {
            Button("Checkout") { model.checkout(branch: branch) }
                .disabled(branch.isCurrent)
        }
        .help(branch.isCurrent ? "Current branch" : "Click to show latest commit, double-click to checkout")
    }

    private func remoteBranchRow(_ branch: String, displayName: String, depth: Int, remote: String) -> some View {
        Text(displayName)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 37 + CGFloat(depth) * 14)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Checkout Tracking Branch") {
                    model.checkoutRemote(branch: branch, remote: remote)
                }
            }
    }

    @ViewBuilder
    private var tagsSection: some View {
        if expandedSections.contains("tags") {
            ForEach(model.tags) { tag in
                HStack(spacing: 9) {
                    Image(systemName: "tag")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignStyle.tagAmber)
                    Text(tag.name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(sidebarRowBackground(model.selectedTagName == tag.name))
                .onTapGesture {
                    model.selectTag(tag)
                }
                .help("Click to show tagged commit")
            }
        }
    }
}
