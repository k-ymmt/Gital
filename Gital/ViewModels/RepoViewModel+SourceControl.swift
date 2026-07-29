import Foundation

// MARK: - Sync operations

extension RepoViewModel {
    func fetch() { runSync("Fetching…") { try await self.repository.fetch() } }
    func pull() { runSync("Pulling…") { try await self.repository.pull() } }
    func push() { runSync("Pushing…") { try await self.repository.push() } }

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
