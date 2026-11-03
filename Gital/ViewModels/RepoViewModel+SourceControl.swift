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
        guard !isSyncing, !isAutoFetching else { return }
        let now = ContinuousClock.now
        guard AutoFetchPreference.shouldFetch(lastFetch: lastAutoFetch, now: now, interval: interval) else { return }
        lastAutoFetch = now
        isAutoFetching = true
        defer { isAutoFetching = false }
        // Timeout because the executor serializes network commands behind
        // this fetch: a wedged remote would otherwise stall every push/pull
        // (and the following ticks) with no busy indicator anywhere. `try?`
        // also swallows the tick's own cancellation (window closed, interval
        // changed).
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

        var shortHash: String { hash.gitShortHash }
    }

    /// Refuses actions that move HEAD while a stopped operation or a Commit
    /// Edit Session is in progress. `git checkout`/`git reset` succeed even
    /// at a stopped rebase's edit stop — HEAD moving out from under a
    /// session would leave its save amending whatever commit HEAD landed on,
    /// and a reset destroys the staged edit content outright.
    func ensureHeadCanMove() -> Bool {
        guard pendingOperation != nil || editSession != nil else { return true }
        let name = editSession != nil
            ? "commit edit"
            : (pendingOperation?.displayName.lowercased() ?? "operation")
        errorMessage = "A \(name) is in progress — finish or abort it before moving HEAD."
        return false
    }

    func cherryPick(_ commit: Commit) {
        runConflictAware("Cherry-picking…") { try await self.repository.cherryPick(commit.hash) }
    }

    func revertCommit(_ commit: Commit) {
        runConflictAware("Reverting…") { try await self.repository.revert(commit.hash) }
    }

    func requestReset(toHash hash: String, mode: GitRepository.ResetMode) {
        guard ensureHeadCanMove() else { return }
        if mode == .hard {
            pendingReset = PendingReset(hash: hash, mode: mode)
        } else {
            performReset(toHash: hash, mode: mode)
        }
    }

    func performReset(toHash hash: String, mode: GitRepository.ResetMode) {
        // Re-checked here (not only in the request): a session can start
        // while the hard-reset confirmation sits open.
        guard ensureHeadCanMove() else { return }
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

        var shortHash: String { hash.gitShortHash }
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
        guard ensureHeadCanMove() else { return }
        pendingDetachedCheckout = DetachedCheckoutRequest(hash: hash, subject: subject)
    }

    func checkoutDetached(_ request: DetachedCheckoutRequest) {
        guard ensureHeadCanMove() else { return }
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
        guard !checkout || ensureHeadCanMove() else { return }
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
        guard !hasRewriteBlockingChanges else {
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
            if await repository.containsConflictMarkers(path: change.path) {
                pendingMarkResolved = change
            } else {
                stage(change)
            }
        }
    }

    /// Changes that block a history rewrite (interactive rebase, commit
    /// edit): anything staged or modified — untracked files don't block a
    /// rebase. Computed on the cached status, so callers use it as a fast
    /// path; the prepare re-checks with fresh `status` output because the
    /// cache is stale whenever the file watcher is down.
    var hasRewriteBlockingChanges: Bool {
        !status.staged.isEmpty || status.unstaged.contains { $0.status != .untracked }
    }

    /// After a failed operation: refreshes the status and, when the failure
    /// left a stopped operation behind (merge/rebase/cherry-pick hit
    /// conflicts), switches to the Changes tab so the conflicts and the
    /// Continue/Abort banner are in front of the user. The explicit refresh
    /// matters: `runSync`'s failure path doesn't reload anything, and the
    /// FSEvents watcher — the only other trigger — may not be running.
    func surfaceStoppedOperation() async {
        await refreshStatus()
        if pendingOperation != nil {
            await loadWorkingDiffs()
            navTab = .changes
        }
    }

    /// Like `runSync`, but routes a failure through
    /// `surfaceStoppedOperation()` so a conflict stop lands in front of the
    /// user instead of only raising the error alert.
    private func runConflictAware(_ activity: String, _ operation: @escaping @MainActor () async throws -> Void) {
        runSync(activity) {
            do {
                try await operation()
            } catch {
                await self.surfaceStoppedOperation()
                throw error
            }
        }
    }
}
