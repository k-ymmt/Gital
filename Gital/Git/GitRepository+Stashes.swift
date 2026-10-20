import Foundation

// MARK: - Stashes

extension GitRepository {
    static let stashListFormat = "%gd\u{1f}%H\u{1f}%gs"

    func stashes() async throws -> [Stash] {
        let output = try await executor.run(["stash", "list", "--format=\(Self.stashListFormat)"])
        return Self.parseStashes(output)
    }

    static func parseStashes(_ output: String) -> [Stash] {
        output.split(separator: "\n").enumerated().compactMap { index, line in
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count >= 3 else { return nil }
            // %gs is free text (commit subjects, user stash messages) that
            // can itself contain the separator byte — components() already
            // split there, so stitch the tail back together like parseReflog.
            let message = fields.dropFirst(2).joined(separator: "\u{1f}")
            return Stash(index: index, reference: fields[0], commitHash: fields[1], message: message)
        }
    }

    func stashPush(message: String?) async throws {
        var args = ["stash", "push", "--include-untracked"]
        if let message, !message.isEmpty {
            args.append("-m")
            args.append(message)
        }
        try await executor.run(args)
    }

    /// Finds the stash holding the given commit in a fresh listing, yielding
    /// its current positional `stash@{N}` reference. A stored reference goes
    /// stale the moment the stash list changes (another drop, a `git stash
    /// push` in a terminal), and a positional operation against a stale list
    /// hits the wrong stash — so every use re-resolves by commit hash first.
    /// Nil when the stash is gone; callers decide whether that is an error.
    func findStash(commitHash: String) async throws -> Stash? {
        let output = try await executor.run(["stash", "list", "--format=\(Self.stashListFormat)"])
        return Self.parseStashes(output).first { $0.commitHash == commitHash }
    }

    private func resolveStashRef(_ stash: Stash) async throws -> String {
        guard let match = try await findStash(commitHash: stash.commitHash) else {
            throw GitError(
                command: "stash",
                exitCode: 1,
                stderr: "This stash no longer exists — the stash list changed."
            )
        }
        return match.reference
    }

    func stashApply(_ stash: Stash, pop: Bool) async throws {
        let reference = try await resolveStashRef(stash)
        try await executor.run(["stash", pop ? "pop" : "apply", reference])
    }

    func stashDrop(_ stash: Stash) async throws {
        let reference = try await resolveStashRef(stash)
        try await executor.run(["stash", "drop", reference])
    }

    @concurrent func stashDiff(_ stash: Stash) async throws -> [FileDiff] {
        let reference = try await resolveStashRef(stash)
        // --include-untracked: stashes are pushed with untracked files, so the
        // detail view must show them too.
        let (output, valid) = try await executor.runChecked(
            ["stash", "show", "--patch", "--include-untracked", reference]
        )
        return DiffParser.parse(output, strictUTF8: valid)
    }
}
