import Foundation

// MARK: - Staging / committing

extension RepoViewModel {
    func stage(_ change: FileChange) {
        perform(refresh: .workingCopy) { try await self.repository.stage([change.path]) }
    }

    func unstage(_ change: FileChange) {
        perform(refresh: .workingCopy) { try await self.repository.unstage([change.path]) }
    }

    func stageAll() {
        perform(refresh: .workingCopy) { try await self.repository.stageAll() }
    }

    func unstageAll() {
        perform(refresh: .workingCopy) { try await self.repository.unstageAll() }
    }

    func stageHunk(_ hunk: DiffHunk, in diff: FileDiff) {
        applyHunk(hunk, in: diff, reverse: false)
    }

    func unstageHunk(_ hunk: DiffHunk, in diff: FileDiff) {
        applyHunk(hunk, in: diff, reverse: true)
    }

    private func applyHunk(_ hunk: DiffHunk, in diff: FileDiff, reverse: Bool) {
        let changes = reverse ? status.staged : status.unstaged
        let fileStatus = changes.first { $0.path == diff.path }?.status
        // Untracked/added/deleted files are one hunk anyway and renames can't
        // round-trip through a plain patch header — stage those whole so git
        // records the right index entry (deletion, intent-to-add, rename).
        let canPatch = fileStatus == .modified || fileStatus == nil
        perform(refresh: .workingCopy) {
            if canPatch, let patch = PatchBuilder.hunkPatch(for: hunk, in: diff) {
                try await self.repository.applyToIndex(patch: patch, reverse: reverse)
            } else if reverse {
                try await self.repository.unstage([diff.path])
            } else {
                try await self.repository.stage([diff.path])
            }
        }
    }

    // MARK: - Line-level staging

    /// Line selection only makes sense where a partial patch can be applied:
    /// untracked files have no index entry yet and renames/binaries fall back
    /// to whole-file staging.
    func canSelectLines(in diff: FileDiff) -> Bool {
        (diff.scope == .unstaged || diff.scope == .staged) && !diff.isBinary
            && !diff.containsInvalidUTF8 && diff.oldPath == nil
    }

    func toggleLineSelection(_ line: DiffLine, in diff: FileDiff, extend: Bool) {
        guard canSelectLines(in: diff), line.kind != .context else { return }
        let selectable = diff.hunks.flatMap(\.lines).filter { $0.kind != .context }
        if extend, let anchor = lineSelectionAnchor, anchor.path == diff.path,
           let from = selectable.firstIndex(where: { $0.id == anchor.id }),
           let to = selectable.firstIndex(where: { $0.id == line.id }) {
            for picked in selectable[min(from, to)...max(from, to)] {
                selectedDiffLineIDs.insert(picked.id)
            }
        } else if selectedDiffLineIDs.contains(line.id) {
            selectedDiffLineIDs.remove(line.id)
        } else {
            selectedDiffLineIDs.insert(line.id)
        }
        lineSelectionAnchor = (diff.path, line.id)
    }

    func selectedLineIDs(in diff: FileDiff) -> Set<String> {
        let changed = Set(diff.hunks.flatMap(\.lines).filter { $0.kind != .context }.map(\.id))
        return selectedDiffLineIDs.intersection(changed)
    }

    func clearLineSelection(in diff: FileDiff) {
        selectedDiffLineIDs.subtract(selectedLineIDs(in: diff))
    }

    func applySelectedLines(in diff: FileDiff) {
        let ids = selectedLineIDs(in: diff)
        let direction: PatchBuilder.Direction? = switch diff.scope {
        case .unstaged: .stage
        case .staged: .unstage
        default: nil
        }
        guard let direction,
              let patch = PatchBuilder.linesPatch(for: diff, selecting: ids, direction: direction) else { return }
        perform(refresh: .workingCopy) {
            try await self.repository.applyToIndex(patch: patch, reverse: direction == .unstage)
            self.selectedDiffLineIDs.subtract(ids)
        }
    }

    // MARK: - Discarding

    enum DiscardTarget {
        case file(FileChange)
        case hunk(DiffHunk, FileDiff)
        case lines(FileDiff, count: Int)

        var confirmationTitle: String {
            switch self {
            case .file(let change) where change.status == .untracked: "Delete Untracked File?"
            case .file: "Discard Changes?"
            case .hunk: "Discard Hunk?"
            case .lines: "Discard Lines?"
            }
        }

        var confirmationMessage: String {
            switch self {
            case .file(let change) where change.status == .untracked:
                "“\(change.path)” will be permanently deleted. This cannot be undone."
            case .file(let change):
                "All unstaged changes in “\(change.path)” will be lost. This cannot be undone."
            case .hunk(_, let diff):
                "This hunk in “\(diff.fileName)” will be reverted. This cannot be undone."
            case .lines(let diff, let count):
                "\(count) selected line\(count == 1 ? "" : "s") in “\(diff.fileName)” will be reverted. This cannot be undone."
            }
        }
    }

    func requestDiscard(_ target: DiscardTarget) {
        pendingDiscard = target
        pendingDiscardSnapshot = nil
        if case .file(let change) = target, change.status != .untracked {
            // Snapshot what the confirmation dialog is about. A whole-file
            // discard wipes whatever the worktree holds at execution time —
            // if the file gains changes while the alert sits open (an agent
            // writing, an editor autosave), those must not be swept away.
            Task {
                pendingDiscardSnapshot = try? await repository.diffWorking(staged: false, path: change.path)
            }
        }
    }

    func performDiscard(_ target: DiscardTarget) {
        let snapshot = pendingDiscardSnapshot
        pendingDiscardSnapshot = nil
        perform(refresh: .workingCopy) {
            switch target {
            case .file(let change) where change.status == .untracked:
                try await self.repository.removeUntracked([change.path])
            case .file(let change):
                let current = try await self.repository.diffWorking(staged: false, path: change.path)
                if let snapshot, current != snapshot {
                    throw GitError(
                        command: "discard",
                        exitCode: 1,
                        stderr: "“\(change.path)” changed while the confirmation was open. Review the new changes and try again."
                    )
                }
                try await self.repository.discardChanges([change.path])
            case .hunk(let hunk, let diff):
                // No whole-file fallback here: the user confirmed one hunk,
                // and discarding the entire file instead would destroy more
                // than they agreed to.
                guard let patch = PatchBuilder.hunkPatch(for: hunk, in: diff) else {
                    throw GitError(
                        command: "discard",
                        exitCode: 1,
                        stderr: "This hunk cannot be discarded on its own. Discard the whole file instead if that is what you want."
                    )
                }
                try await self.repository.applyToWorktree(patch: patch, reverse: true)
            case .lines(let diff, _):
                // The worktree holds unselected additions and lacks unselected
                // deletions — the same shape as the index in the unstage case,
                // so `.unstage` builds the right reverse-apply patch here too.
                let ids = self.selectedLineIDs(in: diff)
                guard let patch = PatchBuilder.linesPatch(for: diff, selecting: ids, direction: .unstage) else { return }
                try await self.repository.applyToWorktree(patch: patch, reverse: true)
                self.selectedDiffLineIDs.subtract(ids)
            }
        }
    }

    // MARK: - Committing

    func commit() {
        guard !isCommitting else { return }  // the button stays enabled for amend; don't double-commit
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || amend else { return }
        isCommitting = true
        Task {
            defer { isCommitting = false }
            do {
                try await repository.commit(message: message, amend: amend)
                commitMessage = ""
                amend = false
                await refreshAll()
            } catch { report(error) }
        }
    }

    var canCommit: Bool {
        !status.staged.isEmpty && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCommitting
    }
}
