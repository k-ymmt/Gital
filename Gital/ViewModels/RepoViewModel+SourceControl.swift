import Foundation

// MARK: - Sync operations

extension RepoViewModel {
    func fetch() { runSync("Fetching…") { try await self.repository.fetch() } }
    func pull() { runSync("Pulling…") { try await self.repository.pull() } }

    func push(force: Bool = false) {
        runSync(force ? "Force pushing…" : "Pushing…") {
            try await self.repository.push(force: force)
        }
    }

    func pushBranch(_ branch: Branch) {
        runSync("Pushing…") { try await self.repository.push(branch: branch) }
    }

    // MARK: - Commit operations

    struct PendingReset {
        let commit: Commit
        let mode: GitRepository.ResetMode
    }

    func cherryPick(_ commit: Commit) {
        runConflictAware("Cherry-picking…") { try await self.repository.cherryPick(commit.hash) }
    }

    func revertCommit(_ commit: Commit) {
        runConflictAware("Reverting…") { try await self.repository.revert(commit.hash) }
    }

    func requestReset(to commit: Commit, mode: GitRepository.ResetMode) {
        if mode == .hard {
            pendingReset = PendingReset(commit: commit, mode: mode)
        } else {
            performReset(to: commit, mode: mode)
        }
    }

    func performReset(to commit: Commit, mode: GitRepository.ResetMode) {
        runSync("Resetting…") { try await self.repository.reset(to: commit.hash, mode: mode) }
    }

    func createBranch(name: String, at commit: Commit, checkout: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        perform(refresh: .all) {
            try await self.repository.createBranch(name: trimmed, at: commit.hash, checkout: checkout)
        }
    }

    func createTag(name: String, at commit: Commit) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        perform(refresh: .refs) {
            try await self.repository.createTag(name: trimmed, at: commit.hash)
        }
    }

    // MARK: - Merge / rebase / conflicts

    var conflictedChanges: [FileChange] {
        status.unstaged.filter { $0.status == .conflicted }
    }

    func merge(branch: String) {
        runConflictAware("Merging…") { try await self.repository.merge(branch: branch) }
    }

    func rebaseCurrentBranch(onto target: String) {
        runConflictAware("Rebasing…") { try await self.repository.rebase(onto: target) }
    }

    func continuePendingOperation() {
        guard let operation = pendingOperation else { return }
        runConflictAware("Continuing…") { try await self.repository.continueOperation(operation) }
    }

    /// Skips the stuck commit (cherry-pick/revert/rebase). The escape hatch
    /// when resolving emptied the commit and `--continue` refuses it.
    func skipPendingOperation() {
        guard let operation = pendingOperation, operation != .merge else { return }
        runConflictAware("Skipping…") { try await self.repository.skipOperation(operation) }
    }

    func requestAbort() {
        pendingAbort = pendingOperation
    }

    func abortOperation(_ operation: RepoOperation) {
        runSync("Aborting…") { try await self.repository.abortOperation(operation) }
    }

    func resolveConflicts(_ paths: [String], using side: ConflictSide) {
        perform(refresh: .workingCopy) {
            try await self.repository.resolveConflicts(paths, using: side)
        }
    }

    /// Marks a conflicted file resolved (`git add` as-is), but asks for
    /// confirmation first when the file still contains conflict markers —
    /// a plain stage would let `<<<<<<<` blocks reach the next commit.
    func requestMarkResolved(_ change: FileChange) {
        Task {
            if repository.containsConflictMarkers(path: change.path) {
                pendingMarkResolved = change
            } else {
                stage(change)
            }
        }
    }

    /// Like `runSync`, but when the failure left a stopped operation behind
    /// (merge/rebase/cherry-pick hit conflicts), refreshes the working-copy
    /// state and switches to the Changes tab so the conflicts and the
    /// Continue/Abort banner are in front of the user. The explicit refresh
    /// matters: `runSync`'s failure path doesn't reload anything, and the
    /// FSEvents watcher — the only other trigger — may not be running.
    private func runConflictAware(_ activity: String, _ operation: @escaping @MainActor () async throws -> Void) {
        runSync(activity) {
            do {
                try await operation()
            } catch {
                await self.refreshStatus()
                if self.pendingOperation != nil {
                    await self.loadWorkingDiffs()
                    self.navTab = .changes
                }
                throw error
            }
        }
    }

    // MARK: - Branch / stash operations

    func selectBranch(_ branch: Branch) {
        selectedTagName = nil
        selectedBranchName = branch.name
        selectedCommitHash = branch.tipHash
    }

    func selectTag(_ tag: Tag) {
        selectedBranchName = nil
        selectedTagName = tag.name
        selectedCommitHash = tag.tipHash
    }

    func checkout(branch: Branch) {
        guard !branch.isCurrent else { return }
        perform(refresh: .all) { try await self.repository.checkout(branch: branch.name) }
    }

    func checkoutRemote(branch: String, remote: String) {
        runSync("Checking out…") {
            try await self.repository.checkoutRemote(branch: branch, remote: remote)
        }
    }

    func createBranch(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        perform(refresh: .all) {
            try await self.repository.createBranch(name: trimmed, checkout: true)
        }
    }

    // MARK: - Branch management

    struct PendingBranchDelete {
        let branch: Branch
        /// Commits on the branch not reachable from HEAD — what a delete
        /// would lose. Drives the wording of the confirmation.
        let unmergedCount: Int
    }

    struct RemoteBranchRef {
        let remote: String
        let branch: String
    }

    /// Computes what the delete would lose, then raises the confirmation.
    func requestDeleteBranch(_ branch: Branch) {
        guard !branch.isCurrent else { return }
        Task {
            do {
                let count = try await repository.unmergedCommitCount(branch: branch.name)
                pendingBranchDelete = PendingBranchDelete(branch: branch, unmergedCount: count)
            } catch { report(error) }
        }
    }

    func deleteBranch(_ branch: Branch) {
        perform(refresh: .all) {
            try await self.repository.deleteBranch(name: branch.name)
            if self.selectedBranchName == branch.name {
                self.selectedBranchName = nil
            }
        }
    }

    func renameBranch(_ branch: Branch, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != branch.name else { return }
        perform(refresh: .all) {
            try await self.repository.renameBranch(from: branch.name, to: trimmed)
            if self.selectedBranchName == branch.name {
                self.selectedBranchName = trimmed
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
        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else { return }
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
