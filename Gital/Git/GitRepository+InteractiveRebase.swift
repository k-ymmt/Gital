import Foundation

// MARK: - Interactive rebase

extension GitRepository {
    /// The prepared span for an interactive rebase: the commits it would
    /// rewrite (newest first) and the base to replay them onto.
    struct InteractiveRebasePrep: Identifiable {
        let commits: [RebaseCommit]
        /// First parent of the oldest commit in the span; nil means the span
        /// reaches the root commit and the rebase must use `--root`.
        let baseHash: String?

        var id: String { "\(commits.first?.hash ?? "")→\(baseHash ?? "root")" }
    }

    /// Loads the commits `<from>..HEAD` (inclusive of `from`) that an
    /// interactive rebase started at `from` would rewrite. Throws when the
    /// worktree is dirty, the commit is not an ancestor of HEAD, the span
    /// contains merge commits (a flattening rebase would silently discard
    /// one side of each merge), or the span's start looks like a root commit
    /// only because the clone is shallow — treating a graft boundary as the
    /// root would rewrite the branch as a parentless history.
    func prepareInteractiveRebase(from hash: String) async throws -> InteractiveRebasePrep {
        try await ensureCleanWorktree()
        do {
            try await executor.run(["merge-base", "--is-ancestor", hash, "HEAD"])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GitError(
                command: "rebase",
                exitCode: 1,
                stderr: "This commit is not an ancestor of HEAD — interactive rebase can only rewrite the current branch's own history."
            )
        }
        let parentsLine = try await executor.run(["rev-list", "--max-count=1", "--parents", hash])
        let baseHash = Self.parseFirstParent(parentsLine)
        if baseHash == nil {
            let shallow = try await executor.run(["rev-parse", "--is-shallow-repository"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard shallow != "true" else {
                throw GitError(
                    command: "rebase",
                    exitCode: 1,
                    stderr: "This is a shallow clone — the commit's real parents are unavailable, so rebasing from here would detach the branch from its true history. Fetch the full history first (git fetch --unshallow)."
                )
            }
        }
        let range = baseHash.map { "\($0)..HEAD" } ?? "HEAD"
        let expectedCount = Int(
            try await executor.run(["rev-list", "--count", range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let output = try await executor.run(["log", "-z", "--format=\(Self.rebaseLogFormat)", range])
        let commits = try Self.parseRebaseCommits(output)
        // Belt and braces: a parser that dropped a commit here means the
        // rebase deletes it. Cross-check against an independent count.
        guard commits.count == expectedCount else {
            throw GitError(
                command: "rebase",
                exitCode: 1,
                stderr: "Commit parsing did not match the range (\(commits.count) of \(expectedCount ?? -1)) — refusing to build a rebase plan from it."
            )
        }
        guard !commits.isEmpty else {
            throw GitError(command: "rebase", exitCode: 1, stderr: "No commits to rebase.")
        }
        guard !commits.contains(where: \.isMerge) else {
            throw GitError(
                command: "rebase",
                exitCode: 1,
                stderr: "The selected range contains merge commits. Interactive rebase would flatten them, so it is not offered here."
            )
        }
        return InteractiveRebasePrep(commits: commits, baseHash: baseHash)
    }

    /// `git rebase` refuses on a dirty worktree; check up front with fresh
    /// `status` output — the UI's cached status can be stale whenever the
    /// file watcher is not running.
    func ensureCleanWorktree() async throws {
        let porcelain = try await executor.run(["status", "--porcelain"])
        guard Self.isCleanForRebase(porcelain) else {
            throw GitError(
                command: "rebase",
                exitCode: 1,
                stderr: "Interactive rebase needs a clean working copy — commit or stash your changes first."
            )
        }
    }

    /// Untracked (and ignored) files don't block a rebase; anything else does.
    static func isCleanForRebase(_ porcelain: String) -> Bool {
        porcelain.split(separator: "\n").allSatisfy {
            $0.hasPrefix("??") || $0.hasPrefix("!!")
        }
    }

    /// First parent hash from one `rev-list --parents` line
    /// (`<hash> <parent>…`); nil for a root commit.
    static func parseFirstParent(_ output: String) -> String? {
        let tokens = output.split(separator: "\n").first?
            .split(separator: " ", omittingEmptySubsequences: true) ?? []
        return tokens.count >= 2 ? String(tokens[1]) : nil
    }

    /// Six NUL-separated fields per commit; with `log -z` each record is
    /// NUL-terminated too. NUL is the only byte git forbids in all of these
    /// fields, so hostile content (record separators, CRs) can never shift a
    /// record boundary — which is why this must not use any printable
    /// separator byte.
    static let rebaseLogFormat = "%H%x00%P%x00%an%x00%at,%ae,%s%x00%s%x00%B"

    /// Parses `log -z --format=rebaseLogFormat` output. Throws instead of
    /// skipping on any structural violation: a commit silently dropped here
    /// is a commit the rebase would delete.
    static func parseRebaseCommits(_ output: String) throws -> [RebaseCommit] {
        func malformed() -> GitError {
            GitError(
                command: "rebase",
                exitCode: 1,
                stderr: "Unexpected git log output while preparing the rebase — refusing to build a plan from it."
            )
        }
        guard !output.isEmpty else { return [] }
        var chunks = output.split(separator: "\u{0}", omittingEmptySubsequences: false)
        // `-z` terminates the final record, so the split ends with one empty
        // piece; anything else means the stream is not what we asked for.
        guard chunks.last == "", chunks.count % 6 == 1 else { throw malformed() }
        chunks.removeLast()
        var commits: [RebaseCommit] = []
        for start in stride(from: 0, to: chunks.count, by: 6) {
            let hash = String(chunks[start])
            guard (hash.count == 40 || hash.count == 64), hash.allSatisfy(\.isHexDigit) else {
                throw malformed()
            }
            let parents = chunks[start + 1].split(separator: " ", omittingEmptySubsequences: true)
            commits.append(RebaseCommit(
                hash: hash,
                subject: String(chunks[start + 4]),
                message: chunks[start + 5].trimmingCharacters(in: .whitespacesAndNewlines),
                author: String(chunks[start + 2]),
                identity: String(chunks[start + 3]),
                isMerge: parents.count > 1
            ))
        }
        return commits
    }

    /// Ceiling for one amended message (raw bytes). The message travels
    /// base64-encoded inside a single `exec` argv word, and `sh` rejects the
    /// whole line past ARG_MAX; 64 KiB is far below that and far above any
    /// sane commit message.
    static let maxAmendMessageBytes = 65_536

    /// Builds the todo file an interactive rebase should run, oldest step
    /// first (git applies the todo top to bottom, oldest commit first).
    ///
    /// No native `reword`/`squash`/`fixup` verbs and no editors: every step
    /// is a `pick`, and rewrites happen in `exec` lines that verify — via
    /// the commit-identity fingerprint — that the commit they are about to
    /// amend is the one the plan targeted. Positional todo verbs lose that
    /// link the moment a conflicted pick is skipped, and then fold content
    /// or messages into whatever HEAD happens to be, including commits
    /// outside the rebase span; the guards make such a step degrade into a
    /// loud no-op instead. `drop` lines are explicit — silently omitting a
    /// commit trips `rebase.missingCommitsCheck` for users who enable it.
    ///
    /// `requireSurvivor` must be true when the span reaches the root commit:
    /// with `--root` and every commit dropped there is no base to fall back
    /// to, and git leaves the branch on an empty sentinel commit.
    static func rebaseTodoScript(stepsOldestFirst: [RebaseStep], requireSurvivor: Bool) throws -> String {
        var lines: [String] = []
        // The open group: the base commit its followers fold into, the
        // message the group must end with, and whether that message differs
        // from what the base already carries (only then is an amend needed).
        var group: (base: RebaseCommit, message: String, needsAmend: Bool)?

        func flushGroup() throws {
            defer { group = nil }
            guard let group, group.needsAmend else { return }
            guard group.message.utf8.count <= maxAmendMessageBytes else {
                throw GitError(
                    command: "rebase",
                    exitCode: 1,
                    stderr: "The combined message for \(group.base.shortHash) exceeds \(maxAmendMessageBytes / 1024) KB — shorten it."
                )
            }
            lines.append(amendExecLine(base: group.base, message: group.message))
        }
        func requireMessage(_ step: RebaseStep) throws -> String {
            let message = step.message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                throw GitError(
                    command: "rebase",
                    exitCode: 1,
                    stderr: "The message for \(step.commit.shortHash) is empty — a rewritten commit needs a message."
                )
            }
            return message
        }

        for step in stepsOldestFirst {
            switch step.action {
            case .drop:
                lines.append("drop \(step.commit.hash)")
            case .pick, .reword:
                try flushGroup()
                lines.append("pick \(step.commit.hash) \(step.commit.subject)")
                if step.action == .reword {
                    group = (step.commit, try requireMessage(step), true)
                } else {
                    group = (step.commit, step.commit.message, false)
                }
            case .squash, .fixup:
                guard let openGroup = group else {
                    throw GitError(
                        command: "rebase",
                        exitCode: 1,
                        stderr: "\(step.action.label) on \(step.commit.shortHash) has no commit to combine into — it must come after a picked commit."
                    )
                }
                lines.append("pick \(step.commit.hash) \(step.commit.subject)")
                lines.append(foldExecLine(follower: step.commit, base: openGroup.base))
                if step.action == .squash {
                    group = (openGroup.base, openGroup.message + "\n\n" + (try requireMessage(step)), true)
                }
            }
        }
        try flushGroup()

        if requireSurvivor {
            let survivors = stepsOldestFirst.contains { $0.action == .pick || $0.action == .reword }
            guard survivors else {
                throw GitError(
                    command: "rebase",
                    exitCode: 1,
                    stderr: "This plan drops every commit — with the root commit in the span there is nothing left for the branch to point at."
                )
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Shell test verifying that the commit `skip` entries below HEAD is the
    /// given one, by identity fingerprint (see `RebaseCommit.identity`) —
    /// hashes are useless here because picking rewrites them.
    private static func identityGuard(_ commit: RebaseCommit, skip: Int = 0) -> String {
        let skipArg = skip > 0 ? " --skip=\(skip)" : ""
        // --no-show-signature: with log.showSignature=true the signature block
        // would join the format line on stdout and the comparison could never
        // match — every rewrite would silently degrade into its warning branch.
        return "test \"$(git log -1\(skipArg) --no-show-signature --format=%at,%ae,%s 2>/dev/null)\" = \(shellQuote(commit.identity))"
    }

    /// A todo `exec` line that rewrites HEAD's message — guarded so that if
    /// the target commit is not at HEAD (its pick was skipped), the rewrite
    /// degrades into a warning instead of amending an unrelated commit. The
    /// message travels base64-encoded: todo lines cannot contain newlines,
    /// and base64 needs no shell quoting at all. `--no-verify` keeps content
    /// hooks out of a message-only amend; `--allow-empty` keeps it working
    /// on a commit that was empty to begin with.
    static func amendExecLine(base: RebaseCommit, message: String) -> String {
        let encoded = Data(message.utf8).base64EncodedString()
        return "exec if \(identityGuard(base)); then printf %s \(encoded) | base64 -d"
            + " | git commit --amend --no-verify --allow-empty -F -;"
            + " else echo 'gital: message rewrite for \(base.shortHash) skipped - the commit is not at HEAD' >&2; fi"
    }

    /// A todo `exec` line that folds the just-picked follower into the group
    /// base directly beneath it (squash/fixup). Guarded on both positions:
    /// if the follower's pick was skipped, or the base is not directly below
    /// (its own pick was skipped), the follower survives as a standalone
    /// commit with a warning — never folded into the wrong commit.
    static func foldExecLine(follower: RebaseCommit, base: RebaseCommit) -> String {
        "exec if \(identityGuard(follower)) && \(identityGuard(base, skip: 1));"
            + " then git reset --soft HEAD^ && git commit --amend --no-edit --no-verify --allow-empty;"
            + " else echo 'gital: fold of \(follower.shortHash) skipped - commits are not in the expected positions' >&2; fi"
    }

    /// Single-quotes a string for POSIX `sh` (sequence.editor runs through
    /// the shell).
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Starts an interactive rebase driven by a pre-built todo. The todo is
    /// injected by pointing `sequence.editor` at a `cp` that overwrites
    /// git's generated file — the app has no terminal to host an editor.
    /// `core.editor=true` is pinned defensively; the todo itself carries any
    /// message rewrites, so no step should open an editor. A conflict stop
    /// surfaces through the ordinary pending-rebase detection.
    ///
    /// `expectedHead` is the hash HEAD had when the plan was prepared. The
    /// todo addresses commits positionally, so if the branch moved while the
    /// plan sat in the sheet (a terminal commit, a pull), running it would
    /// silently drop the newcomers — refuse instead.
    func interactiveRebase(baseHash: String?, expectedHead: String, todo: String) async throws {
        let head = try await executor.run(["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard head == expectedHead else {
            throw GitError(
                command: "rebase",
                exitCode: 1,
                stderr: "The branch has changed since this rebase was planned — plan it again from the current history."
            )
        }
        try await ensureCleanWorktree()
        let todoFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-rebase-todo-\(UUID().uuidString).txt")
        try todo.write(to: todoFile, atomically: true, encoding: .utf8)
        // The sequence editor consumes the file while `rebase -i` starts up,
        // so it is safe to delete as soon as the command returns — even on a
        // conflict stop.
        defer { try? FileManager.default.removeItem(at: todoFile) }
        try await executor.run(Self.interactiveRebaseArguments(todoPath: todoFile.path, baseHash: baseHash))
    }

    /// The full argv that starts an app-driven interactive rebase. The config
    /// pins come from `operationArguments(.rebase)` — the same ones
    /// `--continue` re-applies, which must match because a continued rebase
    /// re-reads the remaining todo. Static so tests can pin the whole argv.
    static func interactiveRebaseArguments(todoPath: String, baseHash: String?) -> [String] {
        ["-c", "sequence.editor=/bin/cp -f \(shellQuote(todoPath))"]
            + operationArguments(.rebase)
            + [
                "rebase", "--interactive",
                // A pick that reorder/drop made empty is kept instead of
                // stopping: the stop's obvious "Continue" drops the commit and
                // desynchronizes the todo from its pending exec rewrites. The
                // amend execs pass --allow-empty and tolerate kept-empty picks.
                "--empty=keep",
                // rebase.updateRefs would put update-ref lines into the todo the
                // cp injection then discards; disable it explicitly so the
                // behavior is deliberate rather than silently config-dependent.
                "--no-update-refs",
                baseHash ?? "--root",
            ]
    }
}
