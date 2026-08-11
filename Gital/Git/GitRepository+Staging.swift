import Foundation

// MARK: - Staging / committing

extension GitRepository {
    func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await executor.run(["add", "--"] + paths.map(GitPathQuoting.literalPathspec))
    }

    func stageAll() async throws {
        try await executor.run(["add", "-A"])
    }

    func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        // `reset -- <paths>` instead of `restore --staged`: identical for a
        // normal HEAD, but also works on an unborn branch (fresh repo), where
        // restore fails with "could not resolve 'HEAD'".
        try await executor.run(["reset", "-q", "--"] + paths.map(GitPathQuoting.literalPathspec))
    }

    func unstageAll() async throws {
        try await executor.run(["reset", "HEAD", "--", "."])
    }

    /// Applies a patch to the index only — hunk-level stage (or unstage with
    /// `reverse`) without touching the worktree.
    func applyToIndex(patch: String, reverse: Bool) async throws {
        var args = ["apply", "--cached", "--whitespace=nowarn"]
        if reverse { args.append("--reverse") }
        try await executor.run(args, stdin: Data(patch.utf8))
    }

    func discardChanges(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await executor.run(["checkout", "--"] + paths.map(GitPathQuoting.literalPathspec))
    }

    func removeUntracked(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        // :(literal) matters most here — a globbing pathspec could make
        // `clean` delete a sibling file the user never confirmed.
        try await executor.run(["clean", "-f", "-d", "--"] + paths.map(GitPathQuoting.literalPathspec))
    }

    /// Applies a patch to the worktree only — hunk/line-level discard uses
    /// `reverse: true` with a worktree-vs-index patch, leaving the index as is.
    func applyToWorktree(patch: String, reverse: Bool) async throws {
        var args = ["apply", "--whitespace=nowarn"]
        if reverse { args.append("--reverse") }
        try await executor.run(args, stdin: Data(patch.utf8))
    }

    func commit(message: String, amend: Bool) async throws {
        var args = ["commit"]
        if amend, message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Empty message + amend means "keep the existing message";
            // passing -m "" would abort the commit.
            args += ["--amend", "--no-edit"]
        } else {
            args += ["-m", message]
            if amend { args.append("--amend") }
        }
        try await executor.run(args)
    }

    /// Full message of the HEAD commit, shown to the AI as context when
    /// generating a message for an amend.
    func headCommitMessage() async throws -> String {
        // --no-show-signature: log.showSignature=true would prepend the
        // verification block to stdout ahead of %B.
        try await executor.run(["log", "-1", "--no-show-signature", "--format=%B"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
