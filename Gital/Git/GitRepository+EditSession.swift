import Foundation

// MARK: - Commit Edit Session

extension GitRepository {
    /// Persistent state of a Commit Edit Session (docs/adr/0001): an
    /// app-driven `rebase -i` stopped at the target commit's `edit` line with
    /// the commit's content soft-reset into the index. Written to
    /// `.git/gital-edit-session.json` so a restarted app restores the session;
    /// deleted as stale whenever the `rebase-merge` directory is gone.
    struct CommitEditSession: Codable, Equatable {
        enum Phase: String, Codable {
            /// Stopped at the target's `edit` line, content staged — the
            /// Changes view is editing the commit.
            case editing
            /// The edited commit was saved and `rebase --continue` is
            /// replaying the descendants (possibly stopped on conflicts —
            /// those surface through the ordinary conflict banner).
            case continuing
        }

        /// Original hash of the commit being edited.
        let targetHash: String
        /// Full original message; prefills the composer.
        let originalMessage: String
        let authorName: String
        let authorEmail: String
        /// Raw author date (`%ad` with `--date=raw`, "<epoch> <tz>") — the
        /// one date format that round-trips through `git commit --date`
        /// without timezone loss.
        let authorDate: String
        /// The target's parent — HEAD while the session sits at its edit
        /// stop. HEAD having moved off it means a save already recorded the
        /// replacement commit, so a retried save must amend, not stack a
        /// second commit.
        let baseHash: String
        /// HEAD when the session's rebase started. Once the rebase is gone,
        /// HEAD being back here means it was aborted (abort restores the
        /// pre-rebase head exactly), not completed — the removed-changes
        /// stash must then stay unpopped.
        let headBeforeRebase: String
        var phase: Phase
        /// Stash commit holding the removed changes, created by the save
        /// flow; nil when nothing was removed.
        var stashCommitHash: String?

        var shortTargetHash: String { String(targetHash.prefix(7)) }
        var subject: String { originalMessage.components(separatedBy: "\n").first ?? "" }
    }

    /// Stable, human-inspectable encoding for the state file.
    static func encodeEditSession(_ session: CommitEditSession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(session)
    }

    static func decodeEditSession(_ data: Data) throws -> CommitEditSession {
        try JSONDecoder().decode(CommitEditSession.self, from: data)
    }

    // MARK: - Preparation

    /// The prepared input for a Commit Edit Session: the target commit, its
    /// descendants up to HEAD, and the parent the rebase replays onto.
    struct CommitEditPrep {
        let target: RebaseCommit
        /// Commits between the target and HEAD (newest first, target excluded).
        let descendantsNewestFirst: [RebaseCommit]
        /// The target's first parent — never nil: root targets are rejected,
        /// `reset --soft HEAD^` has no parent to reset onto.
        let baseHash: String
        /// HEAD at prep time; the rebase refuses to start if it moved since.
        var expectedHead: String { descendantsNewestFirst.first?.hash ?? target.hash }
    }

    /// Derives the edit prep from an interactive-rebase span (which already
    /// enforced: clean worktree, linear merge-free reachability from HEAD).
    /// Static so the two extra guards are unit-testable.
    static func editPrep(from prep: InteractiveRebasePrep, targetHash: String) throws -> CommitEditPrep {
        guard let target = prep.commits.last, target.hash == targetHash else {
            throw GitError(
                command: "edit-commit",
                exitCode: 1,
                stderr: "The prepared history span does not end at the selected commit — refusing to edit from it."
            )
        }
        guard let baseHash = prep.baseHash else {
            throw GitError(
                command: "edit-commit",
                exitCode: 1,
                stderr: "The root commit has no parent to reset onto — editing it is not supported."
            )
        }
        return CommitEditPrep(
            target: target,
            descendantsNewestFirst: Array(prep.commits.dropLast()),
            baseHash: baseHash
        )
    }

    /// Same guards as an interactive rebase from the commit, plus the
    /// root-target rejection.
    func prepareCommitEdit(from hash: String) async throws -> CommitEditPrep {
        try Self.editPrep(from: try await prepareInteractiveRebase(from: hash), targetHash: hash)
    }

    /// Todo for the session's rebase: stop at the target with `edit`, then
    /// replay every descendant with a plain `pick`. A HEAD target gets a
    /// one-line todo through the same path. The `edit` stop itself can never
    /// conflict — the target replays onto its own parent — so the session
    /// reliably reaches its editing state.
    static func editSessionTodoScript(target: RebaseCommit, descendantsNewestFirst: [RebaseCommit]) -> String {
        let lines = ["edit \(target.hash) \(target.subject)"]
            + descendantsNewestFirst.reversed().map { "pick \($0.hash) \($0.subject)" }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Pushed probe

    /// Argv probing whether a commit is already on the upstream branch —
    /// exit 0 means pushed, so editing it will require a force push.
    static func pushedProbeArguments(_ hash: String) -> [String] {
        ["merge-base", "--is-ancestor", hash, "@{u}"]
    }

    /// Whether the commit is reachable from the upstream branch. False when
    /// there is no upstream — then there is nothing a rewrite could diverge
    /// from.
    func isPushedToUpstream(_ hash: String) async throws -> Bool {
        do {
            try await executor.run(Self.pushedProbeArguments(hash))
            return true
        } catch {
            // A cancelled probe must not read as "not pushed" — the warning
            // would silently be skipped.
            try Task.checkCancellation()
            return false
        }
    }

    // MARK: - Session lifecycle

    /// Starts the session: runs the edit-stop rebase, soft-resets the target
    /// into the index, and persists the state file.
    func startCommitEditSession(_ prep: CommitEditPrep) async throws -> CommitEditSession {
        // Author fields are captured before the rebase moves anything. NUL
        // separators: git forbids NUL in all of these fields, so hostile
        // content can never shift a field boundary.
        let line = try await executor.run([
            "log", "-1", "--no-show-signature", "--date=raw",
            "--format=%an%x00%ae%x00%ad%x00%B", prep.target.hash,
        ])
        let fields = line.components(separatedBy: "\u{0}")
        guard fields.count == 4 else {
            throw GitError(
                command: "edit-commit",
                exitCode: 1,
                stderr: "Unexpected git log output while reading the commit's author — refusing to start the edit."
            )
        }
        try await interactiveRebase(
            baseHash: prep.baseHash,
            expectedHead: prep.expectedHead,
            todo: Self.editSessionTodoScript(
                target: prep.target,
                descendantsNewestFirst: prep.descendantsNewestFirst
            )
        )
        try await executor.run(["reset", "--soft", "HEAD^"])
        let session = CommitEditSession(
            targetHash: prep.target.hash,
            originalMessage: fields[3].trimmingCharacters(in: .whitespacesAndNewlines),
            authorName: fields[0],
            authorEmail: fields[1],
            authorDate: fields[2].trimmingCharacters(in: .whitespacesAndNewlines),
            baseHash: prep.baseHash,
            // interactiveRebase verified HEAD == expectedHead before starting.
            headBeforeRebase: prep.expectedHead,
            phase: .editing,
            stashCommitHash: nil
        )
        try await writeEditSessionFile(session)
        return session
    }

    /// Argv for the save recommit: original author and author date, current
    /// committer. `--allow-empty` keeps a save legal when the user removed
    /// every change from the commit. `amend` is the retry path — a previous
    /// save already recorded the replacement commit before a later step
    /// failed, and committing again on top of it would stack two replacement
    /// commits into the rewritten history.
    static func editSaveCommitArguments(message: String, session: CommitEditSession, amend: Bool) -> [String] {
        var args = ["commit", "--allow-empty"]
        if amend { args.append("--amend") }
        return args + [
            "--author=\(session.authorName) <\(session.authorEmail)>",
            "--date=\(session.authorDate)",
            "-m", message,
        ]
    }

    func commitEditedContent(message: String, session: CommitEditSession, amend: Bool) async throws {
        try await executor.run(Self.editSaveCommitArguments(message: message, session: session, amend: amend))
    }

    /// Stashes whatever the save left in the worktree — the removed changes,
    /// plus any untracked files a session is allowed to start with (they come
    /// back with the pop). Returns the stash's commit hash, or nil when
    /// nothing was stashed.
    func stashRemovedChanges(for session: CommitEditSession) async throws -> String? {
        let porcelain = try await executor.run(["status", "--porcelain"])
        guard !porcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // `stash push` can be a no-op that still exits 0 (a dirty submodule
        // shows in status but stashes nothing). Detect "created" by comparing
        // refs/stash around the push — returning a pre-existing hash would
        // make the session pop (and drop) an unrelated stash at the end.
        let before = try? await executor.run(["rev-parse", "refs/stash"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await stashPush(message: "gital: changes removed while editing \(session.shortTargetHash)")
        let after = try? await executor.run(["rev-parse", "refs/stash"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let after, after != before else { return nil }
        return after
    }

    /// Pops the removed-changes stash, resolved by commit hash — the stored
    /// positional reference goes stale the moment the stash list changes. A
    /// stash already gone (dropped in a terminal) is success: nothing left to
    /// restore.
    func popRemovedChanges(stashCommitHash: String) async throws {
        let output = try await executor.run(["stash", "list", "--format=\(Self.stashListFormat)"])
        guard let match = Self.parseStashes(output).first(where: { $0.commitHash == stashCommitHash }) else {
            return
        }
        try await executor.run(["stash", "pop", match.reference])
    }

    // MARK: - State file

    static let editSessionFileName = "gital-edit-session.json"

    /// The state file lives inside the git dir, resolved via `--git-path`
    /// (worktrees, submodules) like the operation probes.
    private func editSessionFileURL() async throws -> URL {
        let path = try await executor.run(["rev-parse", "--git-path", Self.editSessionFileName])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    func loadEditSessionFile() async -> CommitEditSession? {
        guard let url = try? await editSessionFileURL(),
              let data = try? Data(contentsOf: url) else { return nil }
        // Unreadable content (a future format, manual edits) reads as "no
        // session" — reconcile then cleans the file up as stale.
        return try? Self.decodeEditSession(data)
    }

    func writeEditSessionFile(_ session: CommitEditSession) async throws {
        try Self.encodeEditSession(session).write(to: await editSessionFileURL(), options: .atomic)
    }

    func deleteEditSessionFile() async {
        guard let url = try? await editSessionFileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Whether the session's stopped rebase still exists. `rebase-merge` is
    /// the interactive rebase's state directory; gone means the session's
    /// rebase is over — completed, aborted, or concluded in a terminal.
    /// Throwing (not degrading to false): a cancelled probe must not read as
    /// "rebase gone", which would stale-delete a live session.
    func editSessionRebaseExists() async throws -> Bool {
        let path = try await executor.run(["rev-parse", "--git-path", "rebase-merge"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path)
    }

    func headHash() async throws -> String {
        try await executor.run(["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
