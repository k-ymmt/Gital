import Foundation

// MARK: - Commit Edit Session

extension RepoViewModel {
    /// True while the Changes view is editing a commit: the session banner
    /// replaces the conflict banner and the composer saves instead of
    /// committing.
    var isEditingCommit: Bool { editSession?.phase == .editing }

    /// Entry point from the history context menu. Guards mirror
    /// `requestInteractiveRebase` (the prepare re-checks with fresh status);
    /// a pushed target raises a force-push warning before anything starts.
    func requestEditCommit(from commit: Commit) {
        guard pendingOperation == nil, editSession == nil else { return }
        guard !hasRewriteBlockingChanges else {
            errorMessage = "Editing a commit needs a clean working copy — commit or stash your changes first."
            return
        }
        runSync("Preparing commit edit…") {
            let prep = try await self.repository.prepareCommitEdit(from: commit.hash)
            if try await self.repository.isPushedToUpstream(commit.hash) {
                self.pendingPushedCommitEdit = prep
            } else {
                self.startCommitEdit(prep)
            }
        }
    }

    /// Starts the session (rebase to the edit stop, soft reset, state file)
    /// and lands the user in the Changes view with the message prefilled.
    func startCommitEdit(_ prep: GitRepository.CommitEditPrep) {
        runSync("Starting commit edit…") {
            let session = try await self.repository.startCommitEditSession(prep)
            self.editSession = session
            self.commitMessage = session.originalMessage
            self.amend = false
            // Every hash in the span is being rewritten; a pinned selection
            // would point at a vanished commit once the session completes.
            self.selectedCommitHash = nil
            self.navTab = .changes
        }
    }

    /// The composer's action during a session: recommit the staged content
    /// under the original author/date, stash the removed changes, continue
    /// the rebase, and — when it runs through without conflicts — finish by
    /// popping the stash back into the working copy.
    func saveCommitEdit() {
        guard var session = editSession, session.phase == .editing, !isCommitting else { return }
        let message = takeComposerMessage()
        guard !message.isEmpty else { return }
        isCommitting = true
        Task {
            defer { isCommitting = false }
            do {
                // Where is HEAD relative to the session? At the edit stop's
                // base: nothing recorded yet, commit fresh. At the replacement
                // commit a previous save recorded before failing on a later
                // step (stash, state write): amend it instead of stacking a
                // second one. Anywhere else, something outside the session
                // moved HEAD (a checkout, a reset, a terminal commit) — an
                // amend would rewrite a commit the session doesn't own.
                let head = try await repository.headHash()
                let amend: Bool
                if head == session.baseHash {
                    amend = false
                } else if head == session.replacementCommitHash {
                    amend = true
                } else if session.replacementCommitHash == nil,
                          try await repository.headMatchesEditReplacement(session) {
                    // Crash window: a previous save recorded the replacement
                    // but died before persisting its hash. HEAD carrying the
                    // base as parent plus the session's exact author/date is
                    // that commit.
                    amend = true
                } else {
                    throw GitError(
                        command: "edit-commit",
                        exitCode: 1,
                        stderr: "HEAD is no longer at the edit stop — it moved outside the session (a checkout, reset, or commit in a terminal). Abort the edit from the banner, or conclude the rebase in a terminal."
                    )
                }
                try await repository.commitEditedContent(message: message, session: session, amend: amend)
                // Each step below publishes what it learned (the recorded
                // commit's hash, the stash hash) to the in-memory session and
                // the state file before the next step runs: a later failure —
                // or the app dying — must not lose it, or the retry would
                // stack a second commit or strand the stash silently.
                session.replacementCommitHash = try await repository.headHash()
                editSession = session
                try await repository.writeEditSessionFile(session)
                // Keep a hash from a previous failed save when the retry's
                // worktree is already clean — overwriting it with nil would
                // orphan that stash.
                if let stashed = try await repository.stashRemovedChanges(for: session) {
                    session.stashCommitHash = stashed
                    editSession = session
                    try await repository.writeEditSessionFile(session)
                }
                // The phase must flip (and persist) before --continue: a
                // conflict stop refreshes the UI, which must show the normal
                // rebase banner, not the session banner.
                session.phase = .continuing
                try await repository.writeEditSessionFile(session)
                editSession = session
                commitMessage = ""
                do {
                    try await repository.continueOperation(.rebase)
                } catch {
                    // A descendant conflicted: join the ordinary stopped-
                    // operation flow.
                    await surfaceStoppedOperation()
                    throw error
                }
                await finishEditSession(refreshAfterPop: false)
                await refreshAll()
            } catch { report(error) }
        }
    }

    /// Concludes a session whose rebase completed: pop the removed-changes
    /// stash back into the working copy and drop the state file. Clears
    /// `editSession` before the first await so the save flow and a concurrent
    /// reconcile can never pop the stash twice. The state file goes away only
    /// after the pop: dying between the two resumes the restoration on the
    /// next launch (a pop whose stash is already gone is a no-op), while the
    /// reverse order would strand the stash silently.
    ///
    /// `refreshAfterPop: false` is for a caller that refreshes everything
    /// right after anyway (the save flow's `refreshAll`) — the pop would
    /// otherwise trigger a redundant status+diff pass of its own.
    func finishEditSession(refreshAfterPop: Bool = true) async {
        guard let session = editSession else { return }
        editSession = nil
        if let stashHash = session.stashCommitHash {
            do {
                try await repository.popRemovedChanges(stashCommitHash: stashHash)
            } catch {
                // A cancelled pop (the window closing mid-refresh, an
                // auto-fetch interval change) is not a conflicted pop:
                // restore the session so the next reconcile retries the
                // finish, instead of deleting the state file below and
                // stranding the stash.
                if Task.isCancelled {
                    editSession = session
                    return
                }
                // A conflicted pop keeps the stash — nothing is lost, but the
                // user must hear where the removed changes went.
                errorMessage = "The edited commit was saved, but the removed changes could not be restored cleanly — they are kept in the stash list. (\(error.localizedDescription))"
            }
        }
        await repository.deleteEditSessionFile()
        guard session.stashCommitHash != nil, refreshAfterPop else { return }
        // The pop changed the working copy after the caller's status snapshot
        // was taken (reconcile runs at the end of refreshStatus); without the
        // file watcher the restored files would stay invisible until the next
        // manual refresh. Re-entrancy is safe: editSession is already nil, so
        // the nested reconcile returns immediately.
        await refreshStatus()
        await loadWorkingDiffs()
    }

    func requestAbortEdit() {
        pendingEditAbort = true
    }

    /// Aborts the session from its banner: the rebase rolls back to the
    /// pre-edit history, so no stash exists yet and nothing is lost.
    func abortEditSession() {
        guard editSession?.phase == .editing else { return }
        runSync("Aborting commit edit…") {
            try await self.repository.abortOperation(.rebase)
            await self.repository.deleteEditSessionFile()
            self.editSession = nil
            // The composer belonged to the session; the prefill (or a draft
            // of it) is moot once the commit is back as it was.
            self.commitMessage = ""
        }
    }

    /// Keeps the in-memory session consistent with the repository. Called
    /// from every status refresh: restores a persisted session on open,
    /// finishes a session whose rebase completed outside the save flow (a
    /// conflict stop continued from the banner, or a relaunch), and deletes
    /// stale state whenever the rebase is gone without completing.
    func reconcileEditSession() async {
        if !hasLoadedEditSession {
            hasLoadedEditSession = true
            if let restored = await repository.loadEditSessionFile() {
                editSession = restored
                if restored.phase == .editing, commitMessage.isEmpty {
                    commitMessage = restored.originalMessage
                }
            }
        }
        guard let session = editSession else { return }
        // A failed probe (cancellation mid-refresh) must not read as "rebase
        // gone" — that would tear down a live session.
        guard let rebaseExists = try? await repository.editSessionRebaseExists() else { return }
        if rebaseExists {
            guard let ownsRebase = try? await repository.editSessionOwnsRebase(session) else { return }
            if ownsRebase { return }
            // A stopped rebase that is not the session's own: the session's
            // rebase was concluded in a terminal and a new one started. An
            // .editing session has no stop left to save into — tear it down
            // now, before a save could amend the foreign rebase's HEAD. A
            // .continuing session's outcome (aborted vs completed) can't be
            // judged mid-foreign-rebase, and a stash must never pop into
            // someone else's stopped rebase: decide on a later reconcile,
            // once that rebase is gone.
            if session.phase == .editing {
                await clearConcludedEditingSession(session)
            }
            return
        }
        switch session.phase {
        case .editing:
            // The rebase was concluded outside the app (abort or continue in
            // a terminal) — there is no stop left to save into.
            await clearConcludedEditingSession(session)
        case .continuing:
            // An external abort can be followed by commits or checkouts
            // before the app looks again, so HEAD alone can't tell abort
            // from completion. Reachability can: an abort restores the
            // original history, putting the target commit back on the
            // branch; a completed rebase rewrote it away.
            guard let aborted = try? await repository.isReachableFromHead(session.targetHash) else { return }
            if aborted {
                // The removed changes must not be popped onto history that
                // still contains them.
                editSession = nil
                await repository.deleteEditSessionFile()
                if session.stashCommitHash != nil {
                    errorMessage = "The commit edit was aborted. The changes removed during the edit are kept in the stash list."
                }
            } else {
                await finishEditSession()
            }
        }
    }

    /// Tears down an `.editing` session whose edit stop no longer exists
    /// (the rebase was aborted, continued, or replaced in a terminal).
    private func clearConcludedEditingSession(_ session: GitRepository.CommitEditSession) async {
        editSession = nil
        await repository.deleteEditSessionFile()
        // A failed save can have stashed the removed changes while the phase
        // was still .editing — with the rebase gone, the stash is all that
        // remains of them.
        if session.stashCommitHash != nil {
            errorMessage = "The commit edit was concluded outside the app. The changes removed during the edit are kept in the stash list."
        }
        if commitMessage == session.originalMessage {
            commitMessage = ""
        }
    }
}
