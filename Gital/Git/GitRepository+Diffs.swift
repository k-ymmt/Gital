import Foundation

// MARK: - Diffs / file contents

extension GitRepository {
    @concurrent func diffWorking(staged: Bool, path: String? = nil) async throws -> [FileDiff] {
        var args = ["diff"]
        if staged { args.append("--cached") }
        if let path {
            args.append("--")
            args.append(GitPathQuoting.literalPathspec(path))
        }
        let (output, valid) = try await executor.runChecked(args)
        return DiffParser.parse(output, scope: staged ? .staged : .unstaged, strictUTF8: valid)
    }

    /// All-additions diff for an untracked file, synthesized straight from
    /// its bytes. This used to shell out to `git diff --no-index /dev/null`
    /// once per untracked file — a refresh of a repo with hundreds of
    /// untracked files serialized hundreds of subprocess spawns.
    @concurrent func diffUntracked(path: String) async throws -> [FileDiff] {
        let url = root.appendingPathComponent(path)
        // Only regular files (following symlinks) are read: Data(contentsOf:)
        // on a FIFO would block forever, where git just errors.
        let resolved = url.resolvingSymlinksInPath()
        let type = try FileManager.default.attributesOfItem(atPath: resolved.path)[.type] as? FileAttributeType
        guard type == .typeRegular else { return [] }
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        return [DiffParser.untrackedFile(path: path, data: data)]
    }

    @concurrent func diffCommit(_ hash: String, path: String? = nil, renamedFrom: String? = nil) async throws -> [FileDiff] {
        // Merge commits show nothing by default; diff against the first parent.
        var args = ["show", "--patch", "--format=", "--no-color", "--diff-merges=first-parent", hash]
        if let path {
            args.append("--")
            args.append(GitPathQuoting.literalPathspec(path))
            // A rename needs both sides in the pathspec, or the pair breaks
            // and the file shows as a bare addition (or nothing at all).
            if let renamedFrom { args.append(GitPathQuoting.literalPathspec(renamedFrom)) }
        }
        let (output, valid) = try await executor.runChecked(args)
        return DiffParser.parse(output, strictUTF8: valid)
    }

    /// Raw diffstat + patch of what the next commit would contain: index vs
    /// HEAD, or — when amending — index vs HEAD's parent, so the text matches
    /// the content of the commit being rewritten. Used as AI prompt context,
    /// never parsed. The stat rides in front of the patch so a length-capped
    /// prompt still names every file.
    func pendingCommitDiffText(amend: Bool) async throws -> String {
        // --no-ext-diff: a configured external (GUI) diff tool would replace
        // the patch with its own output — or block on a window per file.
        // --stat=400: the default stat width elides deep paths, and the
        // truncation note in the prompt promises the stat names every file.
        var args = ["diff", "--cached", "--no-ext-diff", "--stat=400", "--patch"]
        if amend {
            args.append(await amendDiffBase())
        }
        return try await executor.runChecked(args).output
    }

    /// The base an amended commit is diffed against: HEAD's parent, or the
    /// empty tree when HEAD is a root commit (computed per repo — a SHA-256
    /// repo hashes the empty tree differently than SHA-1's well-known value).
    private func amendDiffBase() async -> String {
        if (try? await executor.run(["rev-parse", "--verify", "--quiet", "HEAD^"])) != nil {
            return "HEAD^"
        }
        let emptyTree = try? await executor.run(["hash-object", "-t", "tree", "/dev/null"])
        guard let emptyTree, !emptyTree.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "HEAD"
        }
        return emptyTree.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - File contents

    /// Raw bytes of one file at one revision, for image previews of binary
    /// diffs. A side that does not exist there (an added file's parent, a
    /// deleted file's commit, an unborn HEAD) throws, and the caller renders
    /// that side as empty. Callers must gate on `fileSize` first — the whole
    /// blob is buffered in memory.
    func fileContents(path: String, at revision: BlobRevision) async throws -> Data {
        guard let spec = Self.blobSpec(path: path, revision: revision) else {
            // Worktree bytes come straight from disk — git has no command
            // that prints the working-tree version of a file. Data(contentsOf:)
            // cannot be interrupted mid-read; the checks around it keep a
            // cancelled preview from at least starting or delivering one, and
            // the caller's size gate bounds how much an orphan can read.
            let url = root.appendingPathComponent(path)
            try Task.checkCancellation()
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            try Task.checkCancellation()
            return data
        }
        // `--filters` (not `show`) so smudge filters run: an LFS-tracked
        // image yields its real bytes when the object is local, instead of
        // the pointer text — matching what the worktree side shows.
        return try await executor.runData(["cat-file", "--filters", spec])
    }

    /// Byte size at a revision without reading the content, so previews can
    /// refuse unbounded loads. For LFS-tracked paths this is the pointer
    /// size, not the smudged size — `fileContents` callers re-check the
    /// bytes they actually got.
    func fileSize(path: String, at revision: BlobRevision) async throws -> Int {
        guard let spec = Self.blobSpec(path: path, revision: revision) else {
            // Resolve symlinks first: attributesOfItem reports the link's own
            // few-byte length while fileContents follows it, so a symlink to
            // a huge file would sail through the size gate.
            let attributes = try FileManager.default.attributesOfItem(
                atPath: root.appendingPathComponent(path).resolvingSymlinksInPath().path
            )
            return (attributes[.size] as? Int) ?? 0
        }
        let output = try await executor.run(["cat-file", "-s", spec])
        guard let size = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw GitError(command: "cat-file -s", exitCode: 0, stderr: "unexpected size output: \(output)")
        }
        return size
    }

    /// `git show` object spec for a revision, or nil when the bytes live on
    /// disk instead. The index spec pins stage 0 explicitly (`:0:path`), so
    /// a conflicted path — which has only stages 1–3 — fails instead of
    /// resolving to an arbitrary side.
    static func blobSpec(path: String, revision: BlobRevision) -> String? {
        switch revision {
        case .worktree: nil
        case .index: ":0:\(path)"
        case .commit(let rev): "\(rev):\(path)"
        }
    }

    @concurrent func commitFileStats(_ hash: String) async throws -> [CommitFileStat] {
        // -z output: rename entries carry two NUL-separated paths, which the
        // line-based form mangles into "old => new" pseudo-paths.
        async let numstatOutput = executor.runData(["show", "--numstat", "-z", "--format=", "--diff-merges=first-parent", hash])
        async let nameStatusOutput = executor.runData(["show", "--name-status", "-z", "--format=", "--diff-merges=first-parent", hash])
        return try await Self.parseCommitStats(numstat: numstatOutput, nameStatus: nameStatusOutput)
    }

    static func parseCommitStats(numstat: Data, nameStatus: Data) -> [CommitFileStat] {
        let statusTokens = nameStatus.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        // name-status -z: STATUS NUL path NUL — renames/copies: R<score> NUL old NUL new NUL
        var statuses: [String: (status: FileChange.Status, oldPath: String?)] = [:]
        var index = 0
        while index < statusTokens.count {
            let token = statusTokens[index]
            index += 1
            guard let statusChar = token.first, !token.isEmpty else { continue }
            let status = changeStatus(statusChar)
            if statusChar == "R" || statusChar == "C" {
                guard index + 1 < statusTokens.count else { break }
                let oldPath = statusTokens[index]
                let newPath = statusTokens[index + 1]
                index += 2
                statuses[newPath] = (status, oldPath)
            } else {
                guard index < statusTokens.count else { break }
                statuses[statusTokens[index]] = (status, nil)
                index += 1
            }
        }

        // numstat -z: "add\tdel\tpath" NUL — renames: "add\tdel\t" NUL old NUL new NUL
        let numTokens = numstat.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var stats: [CommitFileStat] = []
        index = 0
        while index < numTokens.count {
            let token = numTokens[index]
            index += 1
            let parts = token.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            var path = String(parts[2])
            if path.isEmpty {
                // Rename: the two real paths follow as separate tokens.
                guard index + 1 < numTokens.count else { break }
                path = numTokens[index + 1]
                index += 2
            }
            let entry = statuses[path]
            stats.append(CommitFileStat(
                path: path,
                oldPath: entry?.oldPath,
                status: entry?.status ?? .modified,
                additions: Int(parts[0]) ?? 0,
                deletions: Int(parts[1]) ?? 0
            ))
        }
        return stats
    }
}
