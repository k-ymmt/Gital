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
        runSync("Cherry-picking…") { try await self.repository.cherryPick(commit.hash) }
    }

    func revertCommit(_ commit: Commit) {
        runSync("Reverting…") { try await self.repository.revert(commit.hash) }
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
