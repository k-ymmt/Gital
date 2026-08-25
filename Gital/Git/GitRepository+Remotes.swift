import Foundation

// MARK: - Remote operations

extension GitRepository {
    func fetch() async throws {
        // --no-write-fetch-head (git 2.29+): nothing in the app reads
        // FETCH_HEAD, and writing it turns even a no-change fetch into an
        // FSEvents event that sends the watcher into a full refresh.
        try await executor.run(["fetch", "--all", "--prune", "--tags", "--no-write-fetch-head"], lane: .network)
    }

    /// Fetch for the auto-fetch timer: reports whether anything changed, so
    /// a no-change tick can skip its refreshes entirely. Change is detected
    /// by snapshotting remote-tracking refs and tags around the fetch — the
    /// only refs `fetch --all --prune --tags` can create, move, or prune.
    func autoFetch() async throws -> Bool {
        let before = try await refsSnapshot()
        try await fetch()
        return try await refsSnapshot() != before
    }

    private func refsSnapshot() async throws -> String {
        try await executor.run(["for-each-ref", "refs/remotes", "refs/tags", "--format=%(objectname) %(refname)"])
    }

    /// Fetches a GitHub pull request's commits into the object store via the
    /// `refs/pull/<n>/head` ref, without creating a local branch. This is the
    /// only way to reach commits of PRs from forks (their remote is never
    /// configured locally); the ref namespace is GitHub-specific.
    func fetchPullRequestHead(number: Int) async throws {
        // --no-write-fetch-head for the same reason as fetch(): a FETCH_HEAD
        // write turns opening a PR into a spurious full watcher refresh.
        try await executor.run(["fetch", "origin", "refs/pull/\(number)/head", "--no-write-fetch-head"], lane: .network)
    }

    func pull() async throws {
        // Exclusive: pull rewrites the worktree and index, so it must not
        // overlap local commands — but it also talks to the network, so it
        // must not overlap an in-flight fetch either.
        try await executor.run(["pull", "--ff-only"], lane: .exclusive)
    }

    func push(force: Bool = false) async throws {
        let branch = try await currentBranch()
        var pushRemote: String?
        var remote: String?
        var merge: String?
        if branch != "HEAD" {
            pushRemote = try await configValue("branch.\(branch).pushRemote")
            if pushRemote == nil { pushRemote = try await configValue("remote.pushDefault") }
            remote = try await configValue("branch.\(branch).remote")
            merge = try await configValue("branch.\(branch).merge")
        }
        try await executor.run(Self.pushArguments(
            currentBranch: branch, pushRemote: pushRemote,
            upstreamRemote: remote, upstreamMerge: merge, force: force
        ), lane: .network)
    }

    /// Builds the `git push` invocation for the current branch. `force` uses
    /// `--force-with-lease`, never bare `--force`: it refuses to overwrite
    /// remote commits that were never fetched locally. A forced push always
    /// carries an explicit refspec — a bare `push --force-with-lease` obeys
    /// `push.default`, and under "matching" that force-pushes every matching
    /// branch, not just the one the user confirmed. A triangular push
    /// destination (`branch.<name>.pushRemote` / `remote.pushDefault`) wins
    /// over the fetch remote, mirroring where a plain `git push` would go.
    static func pushArguments(currentBranch: String?, pushRemote: String?, upstreamRemote: String?, upstreamMerge: String?, force: Bool) -> [String] {
        var args = ["push"]
        if force { args.append("--force-with-lease") }
        // Detached HEAD ("HEAD" pseudo-branch): plain push lets git report
        // the real problem instead of creating a branch literally named "HEAD".
        guard let branch = currentBranch, branch != "HEAD" else { return args }
        if let pushRemote, pushRemote != "." {
            // Triangular workflow: the branch lands under its own name on the
            // push remote (push.default "simple"/"current" semantics). A
            // plain push already routes there via the config, so only the
            // forced form needs the explicit refspec.
            if force { args += [pushRemote, "\(branch):refs/heads/\(branch)"] }
            return args
        }
        guard let remote = upstreamRemote, let merge = upstreamMerge else {
            args += ["--set-upstream", "origin", branch]
            return args
        }
        if force { args += [remote, "\(branch):\(merge)"] }
        return args
    }

    /// Pushes a specific local branch without checking it out. A triangular
    /// push destination (`branch.<name>.pushRemote` / `remote.pushDefault`)
    /// wins; otherwise the branch goes to its configured upstream, and a
    /// branch with no upstream at all is published to "origin". Ambiguous
    /// upstream configuration throws instead of guessing — a wrong guess
    /// would silently rewrite the branch's tracking setup.
    func push(branch: Branch) async throws {
        let name = branch.name
        var pushRemote = try await configValue("branch.\(name).pushRemote")
        if pushRemote == nil { pushRemote = try await configValue("remote.pushDefault") }
        let fetchRemote = try await configValue("branch.\(name).remote")
        let merge = try await configValue("branch.\(name).merge")
        try await executor.run(Self.pushBranchArguments(
            branch: name, pushRemote: pushRemote, fetchRemote: fetchRemote, upstreamMerge: merge
        ), lane: .network)
    }

    /// Builds the `git push` invocation for a non-checked-out branch.
    /// `upstreamMerge` is the full ref (`refs/heads/x`), so the refspec is
    /// immune to short-name ambiguity. Only a branch with no upstream at all
    /// may be published to "origin"; every partial configuration throws.
    static func pushBranchArguments(branch: String, pushRemote: String?, fetchRemote: String?, upstreamMerge: String?) throws -> [String] {
        if let pushRemote {
            guard pushRemote != "." else {
                throw BranchOperationError("“\(branch)” is configured to push to “.” (this repository) — there is no remote to push to.")
            }
            // Triangular workflow: the push destination gets the branch under
            // its own name (push.default "simple"/"current" semantics).
            return ["push", pushRemote, "\(branch):refs/heads/\(branch)"]
        }
        guard fetchRemote != nil || upstreamMerge != nil else {
            return ["push", "--set-upstream", "origin", branch]
        }
        guard let remote = fetchRemote, let merge = upstreamMerge else {
            throw BranchOperationError("“\(branch)” has an incomplete upstream configuration (branch.\(branch).remote / .merge) — push it from a terminal.")
        }
        guard remote != "." else {
            throw BranchOperationError("“\(branch)” tracks the local branch “\(merge)” — there is no remote to push to.")
        }
        return ["push", remote, "\(branch):\(merge)"]
    }

    /// Reads one config value. Unset (exit 1) and set-but-empty both map to
    /// nil; any other failure is rethrown — collapsing a transient error into
    /// "unset" would silently reroute pushes to the wrong remote.
    private func configValue(_ key: String) async throws -> String? {
        do {
            let value = try await executor.run(["config", "--get", key])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } catch let error as GitError where error.exitCode == 1 {
            return nil
        }
    }

    func currentBranch() async throws -> String {
        try await executor.run(["rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
