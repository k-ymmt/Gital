import Foundation

// MARK: - Branches / tags / reflog

extension GitRepository {
    func branches() async throws -> [Branch] {
        let output = try await executor.run([
            "branch", "--format=%(refname:short)\u{1f}%(HEAD)\u{1f}%(upstream:short)\u{1f}%(objectname)\u{1f}%(upstream:remotename)",
        ])
        return Self.parseBranches(output)
    }

    static func parseBranches(_ output: String) -> [Branch] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count >= 4, !fields[0].isEmpty else { return nil }
            // On a detached HEAD, `git branch` emits a placeholder entry like
            // "(HEAD detached at abc1234)" — a parenthesized non-ref, never a
            // real branch name (git forbids names starting with "(").
            guard !fields[0].hasPrefix("(") else { return nil }
            // %(upstream:remotename) is "." for a branch tracking a local
            // branch, empty when there is no upstream.
            let remoteName = fields.count >= 5 ? fields[4] : ""
            return Branch(
                name: fields[0],
                isCurrent: fields[1] == "*",
                upstream: fields[2].isEmpty ? nil : fields[2],
                tipHash: fields[3],
                upstreamRemote: remoteName.isEmpty ? nil : remoteName
            )
        }
    }

    /// URL of the default remote — "origin" when present, else the first
    /// listed remote — or nil when the repository has none.
    func defaultRemoteURL() async throws -> String? {
        let names = try await executor.run(["remote"]).split(separator: "\n").map(String.init)
        guard let name = names.first(where: { $0 == "origin" }) ?? names.first else { return nil }
        let url = try await executor.run(["remote", "get-url", name])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? nil : url
    }

    func remotes() async throws -> [RemoteInfo] {
        async let remoteNames = executor.run(["remote"])
        async let remoteBranches = executor.run(["branch", "-r", "--format=%(refname:short)"])

        let names = try await remoteNames.split(separator: "\n").map(String.init)
        let branches = try await remoteBranches.split(separator: "\n").map(String.init)

        return names.map { name in
            let prefix = name + "/"
            let owned = branches
                .filter { $0.hasPrefix(prefix) && !$0.hasSuffix("/HEAD") }
                .map { String($0.dropFirst(prefix.count)) }
            return RemoteInfo(name: name, branches: owned)
        }
    }

    func tags() async throws -> [Tag] {
        let output = try await executor.run([
            "tag", "--sort=-creatordate",
            "--format=%(refname:short)\u{1f}%(objectname)\u{1f}%(*objectname)"
        ])
        return Self.parseTags(output)
    }

    static func parseTags(_ output: String) -> [Tag] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count >= 3 else { return nil }
            // %(*objectname) is the peeled commit of an annotated tag; empty for lightweight tags.
            return Tag(name: fields[0], tipHash: fields[2].isEmpty ? fields[1] : fields[2])
        }
    }

    private static let reflogFormat = "%H\u{1f}%gd\u{1f}%gs"

    /// How many entries the reflog sheet shows. `nonisolated` so the
    /// default-argument position can read it without a main-actor hop
    /// warning.
    nonisolated static let reflogDisplayLimit = 200

    /// The HEAD reflog — every place HEAD has been, newest first. Positions
    /// map 1:1 to git's HEAD@{N} numbering because `git reflog` lists entries
    /// in exactly that order. `--date=relative` makes %gd carry the entry's
    /// own timestamp ("HEAD@{5 minutes ago}") instead of a positional index.
    /// Returns up to `limit + 1` entries: a count above `limit` is the
    /// caller's proof of truncation — a reflog of exactly `limit` entries
    /// must not read as truncated.
    func reflog(limit: Int = GitRepository.reflogDisplayLimit) async throws -> [ReflogEntry] {
        // An unborn branch has no reflog and `git reflog` fatals on it —
        // that's the empty state, not an error to alert about.
        guard await headExists() else { return [] }
        let output = try await executor.run([
            "reflog", "--date=relative", "--format=\(Self.reflogFormat)", "-n", String(limit + 1),
        ])
        return Self.parseReflog(output)
    }

    static func parseReflog(_ output: String) -> [ReflogEntry] {
        output.split(separator: "\n").enumerated().compactMap { index, line in
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count >= 3, !fields[0].isEmpty else { return nil }
            // %gd with --date=relative reads "HEAD@{5 minutes ago}"; the
            // braces hold the timestamp. Fall back to the raw field if git
            // ever changes the shape rather than showing nothing.
            var date = fields[1]
            if let open = date.firstIndex(of: "{"), let close = date.lastIndex(of: "}"), open < close {
                date = String(date[date.index(after: open)..<close])
            }
            // Reflog messages embed free text (commit subjects), which can
            // contain the separator byte — components() already split there,
            // so stitch the tail back together instead of dropping it.
            let subject = fields.dropFirst(2).joined(separator: "\u{1f}")
            return ReflogEntry(index: index, hash: fields[0], recordedDate: date, subject: subject)
        }
    }

    func checkout(branch: String) async throws {
        try await executor.run(["checkout", branch])
    }

    /// Detaches HEAD at `commit`. `--detach` is explicit so a hash that
    /// happens to also name a branch or tag can't silently check that out
    /// instead.
    func checkoutDetached(_ commit: String) async throws {
        try await executor.run(["checkout", "--detach", commit])
    }

    func checkoutRemote(branch: String, remote: String) async throws {
        try await executor.run(["checkout", "-b", branch, "--track", "\(remote)/\(branch)"])
    }

    func createBranch(name: String, at startPoint: String? = nil, checkout: Bool) async throws {
        let start = startPoint.map { [$0] } ?? []
        if checkout {
            // `-b` consumes the next argument as its value, so an
            // option-looking name can't be re-parsed as a flag here.
            try await executor.run(["checkout", "-b", name] + start)
        } else {
            // `--`: `name` is free text from the new-branch prompt — without
            // the separator a value like "--force" is parsed as an option.
            try await executor.run(["branch", "--", name] + start)
        }
    }

    /// Number of commits on `branch` that are not reachable from HEAD —
    /// 0 means deleting the branch loses no work. Computed up front (instead
    /// of relying on `branch -d` refusing) so the delete confirmation can
    /// state exactly what would be lost, without parsing localized stderr.
    /// The `refs/heads/` qualification is load-bearing: a bare name resolves
    /// through gitrevisions precedence, where a same-named TAG outranks the
    /// branch and yields a bogus (reassuring) count, and a same-named file
    /// makes the bare form fatal.
    func unmergedCommitCount(branch: String) async throws -> Int {
        let output = try await executor.run(["rev-list", "--count", "refs/heads/\(branch)", "--not", "HEAD", "--"])
        guard let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            // Never default a parse failure to 0 — that selects the
            // "safe to delete" wording precisely when nothing is known.
            throw BranchOperationError("Unexpected rev-list output for “\(branch)”.")
        }
        return count
    }

    /// Always `-D`: the mergedness check and confirmation happened in the UI,
    /// and `-d`'s own refusal logic (against the upstream, not HEAD) would
    /// second-guess a delete the user already confirmed. One invocation for
    /// the whole batch: git deletes what it can and reports the failures,
    /// so one bad name doesn't strand the rest undeleted.
    func deleteBranches(names: [String]) async throws {
        try await executor.run(["branch", "-D", "--"] + names)
    }

    /// `--` is load-bearing here: `newName` is free text from the rename
    /// prompt, and without the separator a value like "--force" is parsed as
    /// an option — git then force-renames the CURRENT branch over an
    /// existing one instead of erroring.
    func renameBranch(from oldName: String, to newName: String) async throws {
        try await executor.run(["branch", "-m", "--", oldName, newName])
    }

    /// `refs/heads/` qualification: a same-named tag on the remote makes the
    /// short form fail with "matches more than one" — the sidebar's remote
    /// rows only ever list branches, so heads is always the intent.
    func deleteRemoteBranch(remote: String, branch: String) async throws {
        try await executor.run(["push", remote, "--delete", "refs/heads/\(branch)"], lane: .network)
    }

    /// `--` separator: name and URL are free text from the add-remote prompt.
    func addRemote(name: String, url: String) async throws {
        try await executor.run(["remote", "add", "--", name, url])
    }

    func removeRemote(name: String) async throws {
        try await executor.run(["remote", "remove", name])
    }

    /// `--` separator: `name` is free text from the new-tag prompt — without
    /// it a name like "--delete" turns the create into a delete.
    func createTag(name: String, at hash: String) async throws {
        try await executor.run(["tag", "--", name, hash])
    }
}
