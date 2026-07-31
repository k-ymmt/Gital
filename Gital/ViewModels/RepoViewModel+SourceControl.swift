import Foundation

// MARK: - Sync operations

extension RepoViewModel {
    func fetch() { runSync("Fetching…") { try await self.repository.fetch() } }

    /// Timer-driven background fetch. Deliberately silent: no `runSync` (the
    /// busy state would disable the toolbar sync buttons on every tick) and
    /// no error alert (offline is a normal state here — the next tick simply
    /// retries). Refreshes only what a fetch can change; the working diff and
    /// the PR list (a gh network call of its own) are untouched.
    func autoFetchTick(interval: TimeInterval) async {
        guard !isSyncing else { return }
        let now = ContinuousClock.now
        guard AutoFetchPreference.shouldFetch(lastFetch: lastAutoFetch, now: now, interval: interval) else { return }
        lastAutoFetch = now
        // Timeout because the executor serializes every git command behind
        // this fetch: a wedged remote would otherwise stall all user
        // operations with no busy indicator anywhere. `try?` also swallows
        // the tick's own cancellation (window closed, interval changed).
        // A fetch that changed nothing skips the refreshes outright — and
        // with --no-write-fetch-head it leaves no file change behind either,
        // so the FSEvents watcher stays quiet too.
        guard let changed = try? await Timeout.run(seconds: AutoFetchPreference.fetchTimeout) { [repository] in
            try await repository.autoFetch()
        }, changed else { return }
        await refreshStatus()
        await refreshLog()
        await refreshRefs()
    }
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

    /// Reset target by bare hash, not `Commit` — reflog entries point at
    /// commits the loaded log may not contain.
    struct PendingReset {
        let hash: String
        let mode: GitRepository.ResetMode

        var shortHash: String { String(hash.prefix(7)) }
    }

    func cherryPick(_ commit: Commit) {
        runConflictAware("Cherry-picking…") { try await self.repository.cherryPick(commit.hash) }
    }

    func revertCommit(_ commit: Commit) {
        runConflictAware("Reverting…") { try await self.repository.revert(commit.hash) }
    }

    func requestReset(toHash hash: String, mode: GitRepository.ResetMode) {
        if mode == .hard {
            pendingReset = PendingReset(hash: hash, mode: mode)
        } else {
            performReset(toHash: hash, mode: mode)
        }
    }

    func performReset(toHash hash: String, mode: GitRepository.ResetMode) {
        runSync("Resetting…") { try await self.repository.reset(to: hash, mode: mode) }
    }

    // MARK: - Detached checkout / reflog

    /// A detached-HEAD checkout awaiting confirmation, carrying its own
    /// display fields because the target may come from the reflog, where no
    /// loaded `Commit` exists.
    struct DetachedCheckoutRequest {
        let hash: String
        /// What the user clicked, for the alert ("Checkout abc1234?" needs
        /// to say which commit that was).
        let subject: String

        var shortHash: String { String(hash.prefix(7)) }
    }

    /// The reflog list backing the sheet; `Identifiable` for `.sheet(item:)`.
    struct ReflogSnapshot: Identifiable {
        let entries: [ReflogEntry]
        /// True when the list hit the load limit — the sheet must say so, or
        /// a commit sitting just past the cutoff reads as unrecoverable.
        let isTruncated: Bool
        let id = UUID()
    }

    func requestCheckoutDetached(hash: String, subject: String) {
        pendingDetachedCheckout = DetachedCheckoutRequest(hash: hash, subject: subject)
    }

    func checkoutDetached(_ request: DetachedCheckoutRequest) {
        runSync("Checking out…") {
            try await self.repository.checkoutDetached(request.hash)
            // Follow HEAD in the detail pane. Works even when the hash is
            // absent from the loaded log (reflog entries often are) — the
            // detail load fetches by hash, not from the list.
            self.selectedCommitHash = request.hash
        }
    }

    /// Loads the HEAD reflog and raises the sheet. `runSync` for the same
    /// reason as `requestInteractiveRebase`: the load queues behind the
    /// serialized executor, and an invisible pending load would pop the
    /// sheet "out of nowhere" much later. Checked against other sheets both
    /// here (the menu item disables, but the shortcut can race it) and after
    /// the load — a file-history sheet can open while the load is queued.
    func requestReflog() {
        guard isWindowHosted, !isPresentingSheet else { return }
        runSync("Loading reflog…") {
            // The load fetches one entry past the display limit so a reflog
            // of exactly `limit` entries doesn't read as truncated.
            let entries = try await self.repository.reflog()
            guard !self.isPresentingSheet else { return }
            let limit = GitRepository.reflogDisplayLimit
            self.reflogSnapshot = ReflogSnapshot(
                entries: Array(entries.prefix(limit)),
                isTruncated: entries.count > limit
            )
        }
    }

    /// Entry actions close the sheet first: the confirmation alerts attach
    /// beneath it in `ContentView`, and an alert raised under a presented
    /// sheet stays invisible until the sheet happens to close.
    func reflogCheckout(_ entry: ReflogEntry) {
        reflogSnapshot = nil
        requestCheckoutDetached(hash: entry.hash, subject: entry.subject)
    }

    func reflogReset(_ entry: ReflogEntry, mode: GitRepository.ResetMode) {
        reflogSnapshot = nil
        requestReset(toHash: entry.hash, mode: mode)
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

    // MARK: - Interactive rebase

    /// Loads the span `commit..HEAD` and raises the interactive-rebase
    /// sheet. A dirty working copy is rejected before anything else — git
    /// would refuse after the user already arranged the whole plan, which is
    /// the worst moment to find out. The cached-status check here is only a
    /// fast path; `prepareInteractiveRebase` re-checks with fresh `status`
    /// output because the cache is stale whenever the file watcher is down.
    /// `runSync` drives the busy indicator: prep queues behind whatever the
    /// serialized executor is doing, and an invisible pending prep would pop
    /// the sheet "out of nowhere" much later. Checked against other sheets
    /// both up front and after the load, same as `requestReflog` — another
    /// sheet can open while the prep is queued.
    func requestInteractiveRebase(from commit: Commit) {
        guard !isPresentingSheet else { return }
        let blockingChanges = status.staged.count
            + status.unstaged.filter { $0.status != .untracked }.count
        guard blockingChanges == 0 else {
            errorMessage = "Interactive rebase needs a clean working copy — commit or stash your changes first."
            return
        }
        runSync("Preparing rebase…") {
            let prep = try await self.repository.prepareInteractiveRebase(from: commit.hash)
            guard !self.isPresentingSheet else { return }
            self.interactiveRebasePrep = prep
        }
    }

    /// Runs the plan the sheet produced. Steps arrive newest first (display
    /// order); the todo wants oldest first. Todo generation happens before
    /// the git command so a plan error surfaces immediately, without a sync
    /// spinner flash. The prep's newest commit is HEAD as of planning time;
    /// `interactiveRebase` refuses to run if HEAD has moved since.
    func startInteractiveRebase(prep: GitRepository.InteractiveRebasePrep, stepsNewestFirst: [RebaseStep]) {
        guard let expectedHead = prep.commits.first?.hash else { return }
        do {
            let todo = try GitRepository.rebaseTodoScript(
                stepsOldestFirst: stepsNewestFirst.reversed(),
                requireSurvivor: prep.baseHash == nil
            )
            runConflictAware("Rebasing…") {
                try await self.repository.interactiveRebase(
                    baseHash: prep.baseHash,
                    expectedHead: expectedHead,
                    todo: todo
                )
                // Every hash in the span was rewritten (HEAD included, which
                // is also the default selection). Clearing the selection lets
                // the follow-up refresh re-seed it at the new HEAD instead of
                // leaving the detail pane pinned to a vanished commit.
                self.selectedCommitHash = nil
            }
        } catch { report(error) }
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
        selectedBranchNames = [branch.name]
        branchSelectionAnchor = branch.name
        selectedCommitHash = branch.tipHash
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
                    selectedBranchName = next.name
                    selectedCommitHash = next.tipHash
                } else {
                    selectedBranchName = nil
                }
            }
        } else {
            selectedTagName = nil
            selectedBranchNames.insert(branch.name)
            selectedBranchName = branch.name
            selectedCommitHash = branch.tipHash
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
        selectedBranchNames = Set(orderedNames[min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)])
        selectedBranchName = branch.name
        selectedCommitHash = branch.tipHash
    }

    func selectTag(_ tag: Tag) {
        selectedBranchName = nil
        selectedBranchNames = []
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

    struct RemoteBranchRef {
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
