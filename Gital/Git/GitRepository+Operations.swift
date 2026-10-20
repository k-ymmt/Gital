import Foundation

// MARK: - Merge / rebase / conflicts / history operations

extension GitRepository {
    /// Marker files (or directories) inside the git dir that identify a
    /// stopped multi-step operation, in classification priority order: the
    /// rebase directories win over the sequencer heads defensively — older
    /// gits left CHERRY_PICK_HEAD behind during a stopped rebase, and
    /// `--rebase-merges` can leave MERGE_HEAD mid-rebase.
    static let operationProbes: [(marker: String, operation: RepoOperation)] = [
        ("rebase-merge", .rebase),
        ("rebase-apply", .rebase),
        ("MERGE_HEAD", .merge),
        ("CHERRY_PICK_HEAD", .cherryPick),
        ("REVERT_HEAD", .revert),
    ]

    static func classifyOperation(existingMarkers: Set<String>) -> RepoOperation? {
        operationProbes.first { existingMarkers.contains($0.marker) }?.operation
    }

    /// Resolves one `rev-parse --git-path` answer to a URL. Relative output
    /// is relative to the repo root (the executor's cwd). Not resolved via
    /// URL(fileURLWithPath:relativeTo:): a base URL without the directory
    /// hint drops its last component.
    static func resolveGitPath(_ path: String, root: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }

    /// URL of an entry inside the git dir, resolved via `--git-path` so
    /// worktrees and submodules land in their real git dir instead of an
    /// assumed `root/.git`.
    func gitPathURL(_ name: String) async throws -> URL {
        let path = try await executor.run(["rev-parse", "--git-path", name])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.resolveGitPath(path, root: root)
    }

    func headHash() async throws -> String {
        try await executor.run(["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The stopped operation in progress, if any — detected by probing marker
    /// files in the git dir. `rev-parse --git-path` resolves the real git dir
    /// (worktrees, submodules) instead of assuming `root/.git`, and file
    /// existence probes don't depend on localized `git status` wording.
    func pendingOperation() async throws -> RepoOperation? {
        var args = ["rev-parse"]
        for probe in Self.operationProbes {
            args += ["--git-path", probe.marker]
        }
        let output = try await executor.run(args)
        let paths = output.split(separator: "\n").map(String.init)
        guard paths.count == Self.operationProbes.count else { return nil }
        var existing: Set<String> = []
        for (probe, path) in zip(Self.operationProbes, paths) {
            if FileManager.default.fileExists(atPath: Self.resolveGitPath(path, root: root).path) {
                existing.insert(probe.marker)
            }
        }
        return Self.classifyOperation(existingMarkers: existing)
    }

    func merge(branch: String) async throws {
        try await executor.run(["merge", "--no-edit", branch])
    }

    func rebase(onto target: String) async throws {
        try await executor.run(["rebase", target])
    }

    /// `--continue` finalizes with a commit whose message git already
    /// prepared; `core.editor=true` (the `true` binary) accepts it without
    /// opening an editor the app has no terminal for.
    ///
    /// A continued/skipped rebase re-reads the remaining todo, so the pins
    /// an app-started interactive rebase relies on must hold here too:
    /// `core.commentChar=#` keeps `pick`/`drop`/`exec` lines from being
    /// parsed as comments under an exotic user commentChar, and
    /// `rescheduleFailedExec` keeps a failed message-rewrite exec retried
    /// instead of silently dropped.
    static func operationArguments(_ operation: RepoOperation) -> [String] {
        var args = ["-c", "core.editor=true"]
        if operation == .rebase {
            args += ["-c", "core.commentChar=#", "-c", "rebase.rescheduleFailedExec=true"]
        }
        return args
    }

    func continueOperation(_ operation: RepoOperation) async throws {
        try await executor.run(Self.operationArguments(operation) + [operation.rawValue, "--continue"])
    }

    func abortOperation(_ operation: RepoOperation) async throws {
        try await executor.run([operation.rawValue, "--abort"])
    }

    /// Skips the commit a stopped sequencer/rebase operation is stuck on.
    /// This is the only way forward when resolving made a cherry-pick or
    /// revert empty — their `--continue` refuses an empty commit forever.
    /// Merge has no skip; callers must not offer it there.
    func skipOperation(_ operation: RepoOperation) async throws {
        guard operation != .merge else {
            throw GitError(command: "merge --skip", exitCode: 1, stderr: "A merge cannot be skipped — continue or abort it.")
        }
        try await executor.run(Self.operationArguments(operation) + [operation.rawValue, "--skip"])
    }

    /// One side of an unmerged index entry, from `ls-files -u`.
    struct UnmergedEntry: Hashable {
        let path: String
        let stage: Int  // 1 = base, 2 = ours, 3 = theirs
    }

    static func parseUnmergedEntries(_ output: String) -> [UnmergedEntry] {
        // "<mode> <object> <stage>\t<path>" per line (NUL-terminated with -z).
        output.split(separator: "\u{0}", omittingEmptySubsequences: true).compactMap { record in
            guard let tab = record.firstIndex(of: "\t") else { return nil }
            let meta = record[..<tab].split(separator: " ")
            guard meta.count >= 3, let stage = Int(meta[2]) else { return nil }
            return UnmergedEntry(path: String(record[record.index(after: tab)...]), stage: stage)
        }
    }

    /// Resolves conflicted paths by taking one side wholesale, then stages
    /// them — `checkout --ours/--theirs` alone leaves the index conflicted.
    /// Paths whose chosen side has no index entry (delete/modify conflicts)
    /// are resolved by accepting the deletion via `git rm` instead:
    /// `checkout` would fail with "does not have our/their version" and no
    /// other in-app affordance can take the deleting side.
    func resolveConflicts(_ paths: [String], using side: ConflictSide) async throws {
        guard !paths.isEmpty else { return }
        let stage = side == .ours ? 2 : 3
        let unmerged = Self.parseUnmergedEntries(
            try await executor.run(["ls-files", "-u", "-z", "--"] + paths.map(GitPathQuoting.literalPathspec))
        )
        let sideExists = Set(unmerged.filter { $0.stage == stage }.map(\.path))
        let checkoutPaths = paths.filter { sideExists.contains($0) }
        let deletePaths = paths.filter { !sideExists.contains($0) }
        if !checkoutPaths.isEmpty {
            try await executor.run(["checkout", "--\(side.rawValue)", "--"] + checkoutPaths.map(GitPathQuoting.literalPathspec))
            try await executor.run(["add", "--"] + checkoutPaths.map(GitPathQuoting.literalPathspec))
        }
        if !deletePaths.isEmpty {
            // -f: the worktree copy holds the other side's content, which git
            // otherwise refuses to remove as "local modifications".
            try await executor.run(["rm", "-f", "--"] + deletePaths.map(GitPathQuoting.literalPathspec))
        }
    }

    /// Whether the working-tree file still contains unresolved conflict
    /// markers. Used to warn before "Mark as Resolved" stages the file as is.
    /// Reads and scans the whole file off the main actor — a large conflicted
    /// file must not stall the UI for the duration.
    func containsConflictMarkers(path: String) async -> Bool {
        let url = root.appendingPathComponent(path)
        return await Task.detached {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return false
            }
            return Self.hasConflictMarkers(in: data)
        }.value
    }

    nonisolated static func hasConflictMarkers(in data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        var foundStart = false
        var foundEnd = false
        // components, not split: in a CRLF file the "\r\n" ending of the line
        // before a marker is one grapheme that never matches "\n", so the
        // marker would hide mid-"line" and the warning would never fire.
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("<<<<<<<") { foundStart = true }
            if line.hasPrefix(">>>>>>>") { foundEnd = true }
            if foundStart && foundEnd { return true }
        }
        return false
    }

    // MARK: - History operations

    func cherryPick(_ hash: String) async throws {
        try await executor.run(["cherry-pick", hash])
    }

    func revert(_ hash: String) async throws {
        try await executor.run(["revert", "--no-edit", hash])
    }

    enum ResetMode: String, CaseIterable {
        case soft, mixed, hard
    }

    func reset(to hash: String, mode: ResetMode) async throws {
        try await executor.run(["reset", "--\(mode.rawValue)", hash])
    }
}
