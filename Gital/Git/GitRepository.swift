import Foundation

/// High-level git operations backed by the git CLI.
final class GitRepository: @unchecked Sendable {
    let root: URL
    private let executor: GitExecutor

    var name: String { root.lastPathComponent }
    var displayPath: String {
        root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    init(root: URL) {
        self.root = root
        self.executor = GitExecutor(workingDirectory: root)
    }

    static func discover(at url: URL) async -> GitRepository? {
        let executor = GitExecutor(workingDirectory: url)
        guard let output = try? await executor.run(["rev-parse", "--show-toplevel"]) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return GitRepository(root: URL(fileURLWithPath: path))
    }

    // MARK: - Status

    func status() async throws -> WorkingStatus {
        let data = try await executor.runData(["status", "--porcelain=v2", "--branch", "-z"])
        return Self.parseStatus(data)
    }

    static func parseStatus(_ data: Data) -> WorkingStatus {
        var status = WorkingStatus()
        let tokens = data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1

            if token.hasPrefix("# branch.head ") {
                let value = String(token.dropFirst("# branch.head ".count))
                status.branch = value == "(detached)" ? nil : value
            } else if token.hasPrefix("# branch.upstream ") {
                status.upstream = String(token.dropFirst("# branch.upstream ".count))
            } else if token.hasPrefix("# branch.ab ") {
                let parts = token.dropFirst("# branch.ab ".count).split(separator: " ")
                for part in parts {
                    if part.hasPrefix("+"), let n = Int(part.dropFirst()) { status.ahead = n }
                    if part.hasPrefix("-"), let n = Int(part.dropFirst()) { status.behind = n }
                }
            } else if token.hasPrefix("1 ") || token.hasPrefix("2 ") {
                let isRename = token.hasPrefix("2 ")
                // 1 XY sub mH mI mW hH hI path
                // 2 XY sub mH mI mW hH hI Xscore path (+ NUL origPath)
                let fieldCount = isRename ? 9 : 8
                let parts = token.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
                guard parts.count > fieldCount else { continue }
                let xy = parts[1]
                let path = String(parts[fieldCount])
                var originalPath: String?
                if isRename, index < tokens.count {
                    originalPath = tokens[index]
                    index += 1
                }

                let x = xy.first ?? "."
                let y = xy.count > 1 ? Array(xy)[1] : "."
                if x != "." {
                    status.staged.append(FileChange(path: path, originalPath: originalPath, status: Self.changeStatus(x)))
                }
                if y != "." {
                    status.unstaged.append(FileChange(path: path, originalPath: originalPath, status: Self.changeStatus(y)))
                }
            } else if token.hasPrefix("u ") {
                let parts = token.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard parts.count > 10 else { continue }
                status.unstaged.append(FileChange(path: String(parts[10]), originalPath: nil, status: .conflicted))
            } else if token.hasPrefix("? ") {
                status.unstaged.append(FileChange(path: String(token.dropFirst(2)), originalPath: nil, status: .untracked))
            }
        }

        status.staged.sort { $0.path < $1.path }
        status.unstaged.sort { $0.path < $1.path }
        return status
    }

    private static func changeStatus(_ char: Character) -> FileChange.Status {
        switch char {
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "U": .conflicted
        default: .modified
        }
    }

    // MARK: - Log

    func log(limit: Int = 400, skip: Int = 0) async throws -> [Commit] {
        let format = "%H%x1f%P%x1f%an%x1f%ae%x1f%ad%x1f%s%x1f%D%x1e"
        var args = [
            "log", "--branches", "--remotes", "--tags", "HEAD",
            "--topo-order", "--date=relative",
            "-n", String(limit),
        ]
        if skip > 0 {
            args.append("--skip=\(skip)")
        }
        args.append("--pretty=format:\(format)")
        let output = try await executor.run(args)
        return Self.parseLog(output)
    }

    static func parseLog(_ output: String) -> [Commit] {
        output.split(separator: "\u{1e}", omittingEmptySubsequences: true).compactMap { record in
            let fields = record
                .trimmingCharacters(in: .newlines)
                .components(separatedBy: "\u{1f}")
            guard fields.count >= 7, !fields[0].isEmpty else { return nil }
            return Commit(
                hash: fields[0],
                parents: fields[1].split(separator: " ").map(String.init),
                author: fields[2],
                authorEmail: fields[3],
                relativeDate: fields[4],
                subject: fields[5],
                body: "",
                refs: parseRefs(fields[6])
            )
        }
    }

    static func parseRefs(_ decoration: String) -> [GitRef] {
        guard !decoration.isEmpty else { return [] }
        var refs: [GitRef] = []
        for part in decoration.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.hasPrefix("HEAD -> ") {
                refs.append(GitRef(kind: .head, name: String(part.dropFirst("HEAD -> ".count))))
            } else if part == "HEAD" {
                continue
            } else if part.hasPrefix("tag: ") {
                refs.append(GitRef(kind: .tag, name: String(part.dropFirst("tag: ".count))))
            } else if part.contains("/") {
                refs.append(GitRef(kind: .remoteBranch, name: part))
            } else {
                refs.append(GitRef(kind: .branch, name: part))
            }
        }
        return refs
    }

    // MARK: - Diffs

    func diffWorking(staged: Bool, path: String? = nil) async throws -> [FileDiff] {
        var args = ["diff"]
        if staged { args.append("--cached") }
        if let path {
            args.append("--")
            args.append(path)
        }
        let output = try await executor.run(args)
        return DiffParser.parse(output, scope: staged ? .staged : .unstaged)
    }

    func diffUntracked(path: String) async throws -> [FileDiff] {
        // Show new-file contents for untracked files. `--no-index` exits 1
        // when the files differ (which is the expected case here).
        let output = try await executor.run(
            ["diff", "--no-index", "--", "/dev/null", path],
            successCodes: [0, 1]
        )
        return DiffParser.parse(output, scope: .untracked)
    }

    func diffCommit(_ hash: String, path: String? = nil) async throws -> [FileDiff] {
        // Merge commits show nothing by default; diff against the first parent.
        var args = ["show", "--patch", "--format=", "--no-color", "--diff-merges=first-parent", hash]
        if let path {
            args.append("--")
            args.append(path)
        }
        let output = try await executor.run(args)
        return DiffParser.parse(output)
    }

    func commitFileStats(_ hash: String) async throws -> [CommitFileStat] {
        async let numstatOutput = executor.run(["show", "--numstat", "--format=", "--diff-merges=first-parent", hash])
        async let nameStatusOutput = executor.run(["show", "--name-status", "--format=", "--diff-merges=first-parent", hash])

        var statuses: [String: FileChange.Status] = [:]
        for line in try await nameStatusOutput.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 2, let statusChar = parts[0].first else { continue }
            let path = String(parts.last ?? "")
            statuses[path] = Self.changeStatus(statusChar)
        }

        var stats: [CommitFileStat] = []
        for line in try await numstatOutput.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 3 else { continue }
            let path = String(parts[2])
            stats.append(CommitFileStat(
                path: path,
                status: statuses[path] ?? .modified,
                additions: Int(parts[0]) ?? 0,
                deletions: Int(parts[1]) ?? 0
            ))
        }
        return stats
    }

    // MARK: - Staging / committing

    func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await executor.run(["add", "--"] + paths)
    }

    func stageAll() async throws {
        try await executor.run(["add", "-A"])
    }

    func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await executor.run(["restore", "--staged", "--"] + paths)
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
        try await executor.run(["checkout", "--"] + paths)
    }

    func removeUntracked(_ paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        try await executor.run(["clean", "-f", "-d", "--"] + paths)
    }

    /// Applies a patch to the worktree only — hunk/line-level discard uses
    /// `reverse: true` with a worktree-vs-index patch, leaving the index as is.
    func applyToWorktree(patch: String, reverse: Bool) async throws {
        var args = ["apply", "--whitespace=nowarn"]
        if reverse { args.append("--reverse") }
        try await executor.run(args, stdin: Data(patch.utf8))
    }

    func commit(message: String, amend: Bool) async throws {
        var args = ["commit", "-m", message]
        if amend { args.append("--amend") }
        try await executor.run(args)
    }

    // MARK: - Remote operations

    func fetch() async throws {
        try await executor.run(["fetch", "--all", "--prune", "--tags"])
    }

    func pull() async throws {
        try await executor.run(["pull", "--ff-only"])
    }

    func push() async throws {
        do {
            try await executor.run(["push"])
        } catch let error as GitError where error.stderr.contains("--set-upstream") {
            let branch = try await currentBranch()
            try await executor.run(["push", "--set-upstream", "origin", branch])
        }
    }

    func currentBranch() async throws -> String {
        try await executor.run(["rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Branches / tags / remotes / stashes

    func branches() async throws -> [Branch] {
        let output = try await executor.run([
            "branch", "--format=%(refname:short)\u{1f}%(HEAD)\u{1f}%(upstream:short)\u{1f}%(objectname)",
        ])
        return output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count >= 4, !fields[0].isEmpty else { return nil }
            return Branch(
                name: fields[0],
                isCurrent: fields[1] == "*",
                upstream: fields[2].isEmpty ? nil : fields[2],
                tipHash: fields[3]
            )
        }
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
        return output.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count >= 3 else { return nil }
            // %(*objectname) is the peeled commit of an annotated tag; empty for lightweight tags.
            return Tag(name: fields[0], tipHash: fields[2].isEmpty ? fields[1] : fields[2])
        }
    }

    func stashes() async throws -> [Stash] {
        let output = try await executor.run(["stash", "list", "--format=%gd\u{1f}%gs"])
        return output.split(separator: "\n").enumerated().compactMap { index, line in
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count >= 2 else { return nil }
            return Stash(index: index, reference: fields[0], message: fields[1])
        }
    }

    func checkout(branch: String) async throws {
        try await executor.run(["checkout", branch])
    }

    func checkoutRemote(branch: String, remote: String) async throws {
        try await executor.run(["checkout", "-b", branch, "--track", "\(remote)/\(branch)"])
    }

    func createBranch(name: String, at startPoint: String? = nil, checkout: Bool) async throws {
        let start = startPoint.map { [$0] } ?? []
        if checkout {
            try await executor.run(["checkout", "-b", name] + start)
        } else {
            try await executor.run(["branch", name] + start)
        }
    }

    func createTag(name: String, at hash: String) async throws {
        try await executor.run(["tag", name, hash])
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

    func stashPush(message: String?) async throws {
        var args = ["stash", "push", "--include-untracked"]
        if let message, !message.isEmpty {
            args.append("-m")
            args.append(message)
        }
        try await executor.run(args)
    }

    func stashApply(_ stash: Stash, pop: Bool) async throws {
        try await executor.run(["stash", pop ? "pop" : "apply", stash.reference])
    }

    func stashDrop(_ stash: Stash) async throws {
        try await executor.run(["stash", "drop", stash.reference])
    }

    func stashDiff(_ stash: Stash) async throws -> [FileDiff] {
        let output = try await executor.run(["stash", "show", "--patch", stash.reference])
        return DiffParser.parse(output)
    }
}
