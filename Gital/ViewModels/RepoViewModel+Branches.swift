import Foundation

// MARK: - Branches, remotes, and stashes

extension RepoViewModel {
    // MARK: - Branch / tag selection and checkout

    func selectBranch(_ branch: Branch) {
        selectedTagName = nil
        selectedRemoteBranch = nil
        selectedBranchName = branch.name
        selectedBranchNames = [branch.name]
        branchSelectionAnchor = branch.name
        revealCommit(branch.tipHash)
    }

    /// ⌘-click: toggle the row in the multi-selection. Toggling a row on also
    /// makes it the primary selection (detail pane follows the last click);
    /// toggling the primary off promotes another selected row so the set never
    /// outlives the primary selection that anchors it.
    func toggleBranchSelection(_ branch: Branch) {
        branchSelectionAnchor = branch.name
        if selectedBranchNames.contains(branch.name) {
            selectedBranchNames.remove(branch.name)
            if selectedBranchName == branch.name {
                if let next = branches.first(where: { selectedBranchNames.contains($0.name) }) {
                    selectedTagName = nil
                    selectedRemoteBranch = nil
                    selectedBranchName = next.name
                    revealCommit(next.tipHash)
                } else {
                    selectedBranchName = nil
                }
            }
        } else {
            selectedTagName = nil
            selectedRemoteBranch = nil
            selectedBranchNames.insert(branch.name)
            selectedBranchName = branch.name
            revealCommit(branch.tipHash)
        }
    }

    /// ⇧-click: select the contiguous run of rows between the anchor and the
    /// clicked row. `orderedNames` is the sidebar's *visible* leaf order
    /// (collapsed folders excluded), so the range matches what the user sees.
    func extendBranchSelection(to branch: Branch, orderedNames: [String]) {
        let anchor = branchSelectionAnchor ?? selectedBranchName
        guard let anchorIndex = anchor.flatMap({ orderedNames.firstIndex(of: $0) }),
              let clickedIndex = orderedNames.firstIndex(of: branch.name) else {
            selectBranch(branch)
            return
        }
        selectedTagName = nil
        selectedRemoteBranch = nil
        selectedBranchNames = Set(orderedNames[min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)])
        selectedBranchName = branch.name
        revealCommit(branch.tipHash)
    }

    func selectTag(_ tag: Tag) {
        selectedBranchName = nil
        selectedBranchNames = []
        selectedRemoteBranch = nil
        selectedTagName = tag.name
        revealCommit(tag.tipHash)
    }

    func selectRemoteBranch(_ branch: RemoteBranch, remote: String) {
        selectedBranchName = nil
        selectedBranchNames = []
        selectedTagName = nil
        selectedRemoteBranch = RemoteBranchRef(remote: remote, branch: branch.name)
        revealCommit(branch.tipHash)
    }

    /// Selects `hash` in the History pane and, when it lies beyond the
    /// commits paged in so far, loads history up to it so the list can
    /// actually scroll there. Every sidebar ref click routes through here.
    func revealCommit(_ hash: String) {
        selectedCommitHash = hash
        Task { await ensureCommitLoaded(hash) }
    }

    func checkout(branch: Branch) {
        guard !branch.isCurrent else { return }
        guard ensureHeadCanMove() else { return }
        perform(refresh: .all) { try await self.repository.checkout(branch: branch.name) }
    }

    func checkoutRemote(branch: String, remote: String) {
        guard ensureHeadCanMove() else { return }
        runSync("Checking out…") {
            try await self.repository.checkoutRemote(branch: branch, remote: remote)
        }
    }

    func createBranch(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, ensureHeadCanMove() else { return }
        perform(refresh: .all) {
            try await self.repository.createBranch(name: trimmed, checkout: true)
        }
    }

    // MARK: - Branch management

    struct PendingBranchDelete {
        struct Entry {
            let branch: Branch
            /// Commits on the branch not reachable from HEAD; nil when it
            /// could not be determined (unborn HEAD, odd repo state) — the
            /// alert then warns conservatively instead of blocking the
            /// delete. Never defaulted to 0: that would select the reassuring
            /// wording exactly when nothing is known.
            let unmergedCount: Int?
        }

        /// One entry per branch — a single right-click delete and a
        /// multi-selection delete share this confirmation.
        let entries: [Entry]
        /// Current branch when the confirmation was raised. The alert
        /// auto-dismisses if HEAD moves elsewhere — the counts are relative
        /// to HEAD and would silently describe a different comparison.
        let head: String?

        var branches: [Branch] { entries.map(\.branch) }

        var title: String {
            entries.count == 1 ? "Delete Branch?" : "Delete \(entries.count) Branches?"
        }

        var confirmButtonLabel: String {
            entries.count == 1 ? "Delete" : "Delete \(entries.count) Branches"
        }

        var message: String {
            let headName = head ?? "HEAD"
            if let entry = entries.first, entries.count == 1 {
                switch entry.unmergedCount {
                case nil:
                    return "“\(entry.branch.name)” will be deleted. Whether its commits are reachable elsewhere could not be determined — they may be lost. This cannot be undone."
                case 0:
                    return "“\(entry.branch.name)” will be deleted. Its commits are all reachable from “\(headName)”."
                case let count?:
                    return "“\(entry.branch.name)” has \(count) commit(s) not on “\(headName)”. Unless another branch or tag points at them, deleting the branch loses them. This cannot be undone."
                }
            }
            let names = entries.map { "“\($0.branch.name)”" }.joined(separator: ", ")
            if entries.contains(where: { $0.unmergedCount == nil }) {
                return "\(names) will be deleted. Whether all their commits are reachable elsewhere could not be determined — some may be lost. This cannot be undone."
            }
            let total = entries.reduce(0) { $0 + ($1.unmergedCount ?? 0) }
            if total == 0 {
                return "\(names) will be deleted. Their commits are all reachable from “\(headName)”."
            }
            return "\(names) will be deleted. They have \(total) commit(s) not on “\(headName)”. Unless another branch or tag points at them, deleting the branches loses them. This cannot be undone."
        }
    }

    struct RemoteBranchRef: Hashable {
        let remote: String
        let branch: String
    }

    /// Computes what the delete would lose, then raises the confirmation.
    /// A failed count (unborn HEAD, exotic repo state) raises the alert with
    /// an "unknown" warning rather than blocking the delete entirely.
    func requestDeleteBranches(_ branchesToDelete: [Branch]) {
        let targets = branchesToDelete.filter { !$0.isCurrent }
        guard !targets.isEmpty else { return }
        Task {
            var entries: [PendingBranchDelete.Entry] = []
            for branch in targets {
                let count = try? await repository.unmergedCommitCount(branch: branch.name)
                entries.append(PendingBranchDelete.Entry(branch: branch, unmergedCount: count))
            }
            // The counts may have queued behind a long fetch/pull on the
            // serialized executor. Only raise the confirmation if every
            // branch still is what the user clicked on.
            guard targets.allSatisfy({ target in
                self.branches.first(where: { $0.name == target.name })?.tipHash == target.tipHash
            }) else { return }
            pendingBranchDelete = PendingBranchDelete(
                entries: entries,
                head: self.branches.first(where: \.isCurrent)?.name
            )
        }
    }

    func requestDeleteBranch(_ branch: Branch) {
        requestDeleteBranches([branch])
    }

    func deleteBranches(_ branchesToDelete: [Branch]) {
        perform(refresh: .all) {
            try await self.repository.deleteBranches(names: branchesToDelete.map(\.name))
            let names = Set(branchesToDelete.map(\.name))
            self.selectedBranchNames.subtract(names)
            if let selected = self.selectedBranchName, names.contains(selected) {
                self.selectedBranchName = nil
            }
            // A deleted tip may exist nowhere else; keeping it selected
            // would pin the detail pane to a commit absent from the graph.
            if let hash = self.selectedCommitHash,
               branchesToDelete.contains(where: { $0.tipHash == hash }) {
                self.selectedCommitHash = nil
            }
        }
    }

    func renameBranch(_ branch: Branch, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        // Alert buttons always dismiss; a silent no-op here would look like
        // a successful rename.
        guard !trimmed.isEmpty else {
            errorMessage = "Branch name cannot be empty."
            return
        }
        guard trimmed != branch.name else { return }
        perform(refresh: .all) {
            try await self.repository.renameBranch(from: branch.name, to: trimmed)
            if self.selectedBranchName == branch.name {
                self.selectedBranchName = trimmed
            }
            // The multi-selection and the ⇧-click anchor resolve by name —
            // left stale, the renamed branch silently drops out of "Delete N
            // Branches…" and shift-extension falls back to single-select.
            if self.selectedBranchNames.remove(branch.name) != nil {
                self.selectedBranchNames.insert(trimmed)
            }
            if self.branchSelectionAnchor == branch.name {
                self.branchSelectionAnchor = trimmed
            }
        }
    }

    func requestDeleteRemoteBranch(remote: String, branch: String) {
        pendingRemoteBranchDelete = RemoteBranchRef(remote: remote, branch: branch)
    }

    func deleteRemoteBranch(_ ref: RemoteBranchRef) {
        runSync("Deleting remote branch…") {
            try await self.repository.deleteRemoteBranch(remote: ref.remote, branch: ref.branch)
        }
    }

    // MARK: - Remote management

    func addRemote(name: String, url: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        // Alert buttons always dismiss; a silent no-op would discard the
        // typed input without a trace.
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else {
            errorMessage = "Remote name and URL are both required."
            return
        }
        perform(refresh: .refs) {
            try await self.repository.addRemote(name: trimmedName, url: trimmedURL)
        }
    }

    func requestRemoveRemote(_ remote: RemoteInfo) {
        pendingRemoteRemoval = remote
    }

    /// Refreshes everything, not just refs: removing a remote drops its
    /// remote-tracking refs, which decorate the history graph.
    func removeRemote(_ remote: RemoteInfo) {
        perform(refresh: .all) {
            try await self.repository.removeRemote(name: remote.name)
        }
    }

    // MARK: - Stashes

    func stashPush(message: String) {
        perform(refresh: .all) { try await self.repository.stashPush(message: message) }
    }

    func stashApply(_ stash: Stash, pop: Bool) {
        perform(refresh: .all) {
            try await self.repository.stashApply(stash, pop: pop)
            if pop, self.selectedStashRef == stash.id {
                self.selectedStashRef = nil
            }
        }
    }

    func stashDrop(_ stash: Stash) {
        perform(refresh: .all) {
            try await self.repository.stashDrop(stash)
            if self.selectedStashRef == stash.id {
                self.selectedStashRef = nil
            }
        }
    }
}
