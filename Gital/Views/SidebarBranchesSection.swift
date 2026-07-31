import SwiftUI

/// Sidebar content for the Branches tab: local branches, remotes, and tags.
struct SidebarBranchesSection: View {
    var model: RepoViewModel
    @Binding var expandedSections: Set<String>
    @Binding var collapsedBranchFolders: Set<String>

    @State private var branchRowsCache = BranchTreeRowsCache<Branch>()
    @State private var remoteRowsCache = BranchTreeRowsCache<String>()

    var body: some View {
        SidebarCollapsibleHeader(title: "Branches", key: "branches", expandedSections: $expandedSections)
        if expandedSections.contains("branches") {
            let rows = branchRowsCache.rows(
                model.branches.map { ($0.name, $0) },
                keyPrefix: "branches",
                collapsed: collapsedBranchFolders
            )
            // Visible display order, for ⇧-click ranges — leaves hidden in a
            // collapsed folder are not part of what the user sees selected.
            let visibleNames = rows.compactMap { row -> String? in
                if case .leaf(let branch, _, _, _) = row { return branch.name }
                return nil
            }
            ForEach(rows) { row in
                switch row {
                case .folder(let path, let name, let depth):
                    SidebarFolderRow(path: path, name: name, depth: depth, collapsed: $collapsedBranchFolders)
                case .leaf(let branch, let name, _, let depth):
                    localBranchRow(branch, displayName: name, depth: depth, visibleNames: visibleNames)
                }
            }
        }

        SidebarCollapsibleHeader(title: "Remotes", key: "remotes", expandedSections: $expandedSections)
            .contextMenu {
                Button("Add Remote…") { model.isAddingRemote = true }
            }
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
                .contextMenu {
                    Button("Add Remote…") { model.isAddingRemote = true }
                    Button("Remove Remote…", role: .destructive) {
                        model.requestRemoveRemote(remote)
                    }
                }

                if !collapsedBranchFolders.contains(remoteKey) {
                    let rows = remoteRowsCache.rows(
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

    private func localBranchRow(_ branch: Branch, displayName: String, depth: Int, visibleNames: [String]) -> some View {
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
        .background(sidebarRowBackground(model.isBranchRowHighlighted(branch.name)))
        .onTapGesture(count: 2) {
            model.checkout(branch: branch)
        }
        .onTapGesture {
            let modifiers = NSEvent.modifierFlags
            if modifiers.contains(.command) {
                model.toggleBranchSelection(branch)
            } else if modifiers.contains(.shift) {
                model.extendBranchSelection(to: branch, orderedNames: visibleNames)
            } else {
                model.selectBranch(branch)
            }
        }
        .contextMenu {
            let multiSelection = model.multiSelectedBranches
            if multiSelection.count > 1, model.selectedBranchNames.contains(branch.name) {
                let deletable = multiSelection.filter { !$0.isCurrent }
                Button(
                    deletable.count == 1 ? "Delete 1 Branch…" : "Delete \(deletable.count) Branches…",
                    role: .destructive
                ) {
                    model.requestDeleteBranches(deletable)
                }
                .disabled(deletable.isEmpty)
            } else {
                singleBranchMenuItems(branch)
            }
        }
        .help(branch.isCurrent ? "Current branch" : "Click to show latest commit, double-click to checkout")
    }

    @ViewBuilder
    private func singleBranchMenuItems(_ branch: Branch) -> some View {
        Button("Checkout") { model.checkout(branch: branch) }
            .disabled(branch.isCurrent)
        Divider()
        mergeRebaseMenuItems(target: branch.name, disabled: branch.isCurrent)
        Divider()
        // A branch tracking a local branch has nothing to push; publishing
        // needs a remote actually named "origin" or the push just errors.
        if branch.upstream == nil {
            Button("Publish to Origin") { model.pushBranch(branch) }
                .disabled(!model.remotes.contains { $0.name == "origin" })
        } else {
            Button("Push") { model.pushBranch(branch) }
                .disabled(branch.tracksLocalBranch)
        }
        Divider()
        Button("Rename…") { model.renamingBranch = branch }
        Button("Delete…", role: .destructive) { model.requestDeleteBranch(branch) }
            .disabled(branch.isCurrent)
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
                Divider()
                mergeRebaseMenuItems(target: "\(remote)/\(branch)", disabled: false)
                Divider()
                Button("Delete on Remote…", role: .destructive) {
                    model.requestDeleteRemoteBranch(remote: remote, branch: branch)
                }
            }
    }

    /// Merge/rebase entries shared by local and remote branch rows. Disabled
    /// on a detached HEAD (no current branch to merge into) and while another
    /// multi-step operation is still stopped on conflicts.
    @ViewBuilder
    private func mergeRebaseMenuItems(target: String, disabled: Bool) -> some View {
        let current = model.status.branch
        let blocked = disabled || current == nil || model.pendingOperation != nil
        Button("Merge into “\(current ?? "HEAD")”") {
            model.merge(branch: target)
        }
        .disabled(blocked)
        Button("Rebase “\(current ?? "HEAD")” onto This") {
            model.rebaseCurrentBranch(onto: target)
        }
        .disabled(blocked)
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
