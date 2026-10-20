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
        let blockingChanges = status.staged.count
            + status.unstaged.filter { $0.status != .untracked }.count
        guard blockingChanges == 0 else {
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
        // Same composer hygiene as commit(): a codex reply landing after the
        // save would refill the cleared composer, and mid-stream text never
        // went through the completion-time cleanup.
        let wasGenerating = isGeneratingCommitMessage
        cancelCommitMessageGeneration()
        let message = wasGenerating
            ? CommitMessageGenerator.extractMessage(commitMessage)
            : commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        isCommitting = true
        Task {
            defer { isCommitting = false }
            do {
                // A previous save may have recorded the commit and then
                // failed on a later step (stash, state write), leaving the
                // phase at .editing — HEAD off the edit stop's base is that
                // exact situation, and the retry must amend the recorded
                // commit instead of stacking a second one.
                let alreadyCommitted = try await repository.headHash() != session.baseHash
                try await repository.commitEditedContent(
                    message: message,
                    session: session,
                    amend: alreadyCommitted
                )
                session.stashCommitHash = try await repository.stashRemovedChanges(for: session)
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
                    // operation flow (same shape as runConflictAware).
                    await refreshStatus()
                    if pendingOperation != nil {
                        await loadWorkingDiffs()
                        navTab = .changes
                    }
                    throw error
                }
                await finishEditSession()
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
    func finishEditSession() async {
        guard let session = editSession else { return }
        editSession = nil
        if let stashHash = session.stashCommitHash {
            do {
                try await repository.popRemovedChanges(stashCommitHash: stashHash)
            } catch {
                // A conflicted pop keeps the stash — nothing is lost, but the
                // user must hear where the removed changes went.
                errorMessage = "The edited commit was saved, but the removed changes could not be restored cleanly — they are kept in the stash list. (\(error.localizedDescription))"
            }
        }
        await repository.deleteEditSessionFile()
        guard session.stashCommitHash != nil else { return }
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
        guard let rebaseExists = try? await repository.editSessionRebaseExists(), !rebaseExists else {
            return
        }
        switch session.phase {
        case .editing:
            // The rebase was concluded outside the app (abort or continue in
            // a terminal) — there is no stop left to save into.
            editSession = nil
            await repository.deleteEditSessionFile()
            if commitMessage == session.originalMessage {
                commitMessage = ""
            }
        case .continuing:
            guard let head = try? await repository.headHash() else { return }
            if head == session.headBeforeRebase {
                // An abort restores the pre-rebase head exactly: the edit was
                // rolled back, so the stash must not be popped onto history
                // that still contains the removed changes.
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
}
