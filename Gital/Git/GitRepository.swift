import Foundation

/// Branch/remote operation refused before reaching git — the configuration
/// is ambiguous and guessing would do the wrong thing silently.
struct BranchOperationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) { self.message = message }
}

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
        async let remotes = remoteNames()
        // NUL field separators: none of these fields can ever contain a NUL,
        // unlike 0x1E/0x1F which a hostile subject could carry.
        let format = "%H%x00%P%x00%an%x00%ae%x00%ad%x00%s%x00%D"
        var args = [
            "log", "--branches", "--remotes", "--tags", "HEAD",
            "--topo-order", "--date=relative",
            "-n", String(limit),
        ]
        if skip > 0 {
            args.append("--skip=\(skip)")
        }
        args.append("--pretty=format:\(format)")
        var output: String
        do {
            output = try await executor.run(args)
        } catch let error as GitError {
            // Unborn HEAD (fresh repo / orphan branch): the positional HEAD
            // doesn't resolve; list reachable refs only, which may be empty.
            // Probed with rev-parse instead of matching stderr wording, which
            // varies across git versions and locales.
            guard await !headExists() else { throw error }
            var retryArgs = args
            retryArgs.removeAll { $0 == "HEAD" }
            output = try await executor.run(retryArgs)
        }
        return Self.parseLog(output, remotes: await remotes)
    }

    /// Whether HEAD resolves to a commit — false on an unborn branch.
    private func headExists() async -> Bool {
        (try? await executor.run(["rev-parse", "--verify", "--quiet", "HEAD"])) != nil
    }

    /// Names of configured remotes. Failure degrades to an empty set — refs
    /// then classify as local branches — because log/detail loading must not
    /// fail outright over a broken `git remote`.
    private func remoteNames() async -> Set<String> {
        Set(((try? await executor.run(["remote"])) ?? "").split(separator: "\n").map(String.init))
    }

    static func parseLog(_ output: String, remotes: Set<String> = []) -> [Commit] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { record in
            let fields = record.components(separatedBy: "\u{0}")
            guard fields.count >= 7, !fields[0].isEmpty else { return nil }
            return Commit(
                hash: fields[0],
                parents: fields[1].split(separator: " ").map(String.init),
                author: fields[2],
                authorEmail: fields[3],
                relativeDate: fields[4],
                subject: fields[5],
                body: "",
                refs: parseRefs(fields[6], remotes: remotes)
            )
        }
    }

    static func parseRefs(_ decoration: String, remotes: Set<String> = []) -> [GitRef] {
        guard !decoration.isEmpty else { return [] }
        var refs: [GitRef] = []
        for part in decoration.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if part.hasPrefix("HEAD -> ") {
                refs.append(GitRef(kind: .head, name: String(part.dropFirst("HEAD -> ".count))))
            } else if part == "HEAD" {
                continue
            } else if part.hasPrefix("tag: ") {
                refs.append(GitRef(kind: .tag, name: String(part.dropFirst("tag: ".count))))
            } else if let slash = part.firstIndex(of: "/"), remotes.contains(String(part[..<slash])) {
                // Only a known remote name before the slash makes it a remote
                // branch — local branches like "feature/login" also contain "/".
                refs.append(GitRef(kind: .remoteBranch, name: part))
            } else {
                refs.append(GitRef(kind: .branch, name: part))
            }
        }
        return refs
    }

    func commitDetail(_ hash: String) async throws -> CommitDetail? {
        async let remotes = remoteNames()
        // NUL separators as in `log`; %B goes last so the multi-line message
        // can't split the record even though it contains newlines.
        let format = "%H%x00%P%x00%an%x00%ae%x00%ad%x00%cn%x00%ce%x00%cd%x00%D%x00%B"
        let output = try await executor.run([
            "show", "-s", "--no-color",
            "--date=format-local:%Y-%m-%d %H:%M:%S",
            "--pretty=format:\(format)", hash,
        ])
        return Self.parseCommitDetail(output, remotes: await remotes)
    }

    static func parseCommitDetail(_ output: String, remotes: Set<String> = []) -> CommitDetail? {
        let fields = output.components(separatedBy: "\u{0}")
        guard fields.count >= 10, !fields[0].isEmpty else { return nil }
        return CommitDetail(
            hash: fields[0],
            parents: fields[1].split(separator: " ").map(String.init),
            author: fields[2],
            authorEmail: fields[3],
            authorDate: fields[4],
            committer: fields[5],
            committerEmail: fields[6],
            committerDate: fields[7],
            refs: parseRefs(fields[8], remotes: remotes),
            message: fields[9].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Diffs

    func diffWorking(staged: Bool, path: String? = nil) async throws -> [FileDiff] {
        var args = ["diff"]
        if staged { args.append("--cached") }
        if let path {
            args.append("--")
            args.append(path)
        }
        let (output, valid) = try await executor.runChecked(args)
        return DiffParser.parse(output, scope: staged ? .staged : .unstaged, strictUTF8: valid)
    }

    func diffUntracked(path: String) async throws -> [FileDiff] {
        // Show new-file contents for untracked files. `--no-index` exits 1
        // when the files differ (which is the expected case here).
        let (output, valid) = try await executor.runChecked(
            ["diff", "--no-index", "--", "/dev/null", path],
            successCodes: [0, 1]
        )
        return DiffParser.parse(output, scope: .untracked, strictUTF8: valid)
    }

    func diffCommit(_ hash: String, path: String? = nil, renamedFrom: String? = nil) async throws -> [FileDiff] {
        // Merge commits show nothing by default; diff against the first parent.
        var args = ["show", "--patch", "--format=", "--no-color", "--diff-merges=first-parent", hash]
        if let path {
            args.append("--")
            args.append(path)
            // A rename needs both sides in the pathspec, or the pair breaks
            // and the file shows as a bare addition (or nothing at all).
            if let renamedFrom { args.append(renamedFrom) }
        }
        let (output, valid) = try await executor.runChecked(args)
        return DiffParser.parse(output, strictUTF8: valid)
    }

    func commitFileStats(_ hash: String) async throws -> [CommitFileStat] {
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

    // MARK: - File history

    /// Commits touching one file, following renames. `startHash` scopes the
    /// walk (nil = HEAD); `path` must be the file's name as of that revision.
    func fileHistory(path: String, startHash: String?, limit: Int) async throws -> [FileHistoryEntry] {
        // Leading NUL marks each record start, so splitting the whole output
        // on NUL yields clean 5-field groups even though the name-status
        // block trails the subject inside the last field. None of the fields
        // can contain a NUL; the subject *can* contain any other byte.
        let format = "%x00%H%x00%an%x00%ae%x00%ad%x00%s"
        var args = [
            "log", "--follow", "--name-status", "--date=relative",
            "-n", String(limit), "--pretty=format:\(format)",
        ]
        if let startHash { args.append(startHash) }
        // :(literal) — a bare pathspec globs, so "app/[id]/page.tsx" would
        // also pull in app/i/page.tsx's commits AND derail the rename
        // tracking onto that file. --follow keeps working with it.
        args.append(contentsOf: ["--", ":(literal)\(path)"])
        let output: String
        do {
            output = try await executor.run(args)
        } catch let error as GitError {
            // Unborn HEAD (fresh repo): no commits touch anything. Probed
            // like `log()` does rather than matching stderr wording.
            guard startHash == nil, await !headExists() else { throw error }
            return []
        }
        return Self.parseFileHistory(output, queryPath: path)
    }

    static func parseFileHistory(_ output: String, queryPath: String) -> [FileHistoryEntry] {
        let fields = output.components(separatedBy: "\u{0}")
        var entries: [FileHistoryEntry] = []
        // The name the file goes by in commits older than the ones parsed so
        // far; each rename record rewires it.
        var trackedPath = queryPath
        var index = 1  // fields[0] is the empty prefix before the first record's NUL
        while index + 4 < fields.count {
            let hash = fields[index]
            let author = fields[index + 1]
            let email = fields[index + 2]
            let date = fields[index + 3]
            let tail = fields[index + 4]
            index += 5
            guard !hash.isEmpty else { continue }

            // components, not split: split(separator: "\n") treats a CRLF
            // pair as one grapheme and would fuse a "\r"-ending subject with
            // the name-status line after it.
            var tailLines = tail.components(separatedBy: "\n")
            let subject = tailLines.isEmpty ? "" : tailLines.removeFirst()

            // At most one name-status entry follows (single pathspec); merge
            // commits list none and keep the tracked name.
            var status: FileChange.Status?
            var entryPath = trackedPath
            var previousPath: String?
            for line in tailLines {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 2, let statusChar = parts[0].first else { continue }
                status = changeStatus(statusChar)
                if (statusChar == "R" || statusChar == "C"), parts.count >= 3 {
                    previousPath = unquotePath(String(parts[1]))
                    entryPath = unquotePath(String(parts[2]))
                } else {
                    entryPath = unquotePath(String(parts[1]))
                }
                break
            }

            entries.append(FileHistoryEntry(
                hash: hash,
                author: author,
                authorEmail: email,
                relativeDate: date,
                subject: subject,
                path: entryPath,
                previousPath: previousPath,
                status: status
            ))
            trackedPath = previousPath ?? entryPath
        }
        return entries
    }

    /// Reverses git's C-style path quoting (`"a\tb.txt"`). quotepath=false
    /// keeps non-ASCII raw, but tabs, quotes, and control bytes in a path are
    /// still escaped — and a tab inside an unquoted path would break the
    /// name-status field split.
    static func unquotePath(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        let escaped = Array(raw.dropFirst().dropLast().utf8)
        var bytes: [UInt8] = []
        var i = 0
        while i < escaped.count {
            let byte = escaped[i]
            guard byte == UInt8(ascii: "\\"), i + 1 < escaped.count else {
                bytes.append(byte)
                i += 1
                continue
            }
            i += 1
            let code = escaped[i]
            switch code {
            case UInt8(ascii: "a"): bytes.append(7)
            case UInt8(ascii: "b"): bytes.append(8)
            case UInt8(ascii: "t"): bytes.append(9)
            case UInt8(ascii: "n"): bytes.append(10)
            case UInt8(ascii: "v"): bytes.append(11)
            case UInt8(ascii: "f"): bytes.append(12)
            case UInt8(ascii: "r"): bytes.append(13)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = 0
                var digits = 0
                while i < escaped.count, digits < 3,
                      (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(escaped[i]) {
                    value = value * 8 + Int(escaped[i] - UInt8(ascii: "0"))
                    i += 1
                    digits += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                continue
            default: bytes.append(code)  // \" and \\ fall through here
            }
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Blame

    /// Blames the file as of `hash`, or the working tree when nil (which is
    /// what surfaces not-yet-committed lines). Blame follows whole-file
    /// renames on its own, so `path` is simply the name valid at `hash`.
    func blame(path: String, at hash: String?) async throws -> BlameFile {
        var args = ["blame", "--porcelain"]
        if let hash { args.append(hash) }
        args.append(contentsOf: ["--", path])
        let output = try await executor.run(args)
        return Self.parseBlame(output)
    }

    static func parseBlame(_ output: String) -> BlameFile {
        var lines: [BlameLine] = []
        var metadata: [String: [String: String]] = [:]
        var currentHash: String?
        var currentLineNumber = 0
        var currentIsGroupStart = false

        // components, not split: content lines of a CRLF file end in "\r",
        // and split(separator: "\n") treats that "\r\n" as one grapheme —
        // the content line and the next group's header would fuse, dropping
        // every other line of the file.
        for rawLine in output.components(separatedBy: "\n") {
            if rawLine.hasPrefix("\t") {
                guard let hash = currentHash else { continue }
                lines.append(BlameLine(
                    number: currentLineNumber,
                    hash: hash,
                    isGroupStart: currentIsGroupStart,
                    text: String(rawLine.dropFirst())
                ))
                currentHash = nil
                continue
            }
            let parts = rawLine.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            // Header: <full-hex> <orig-line> <final-line> [<group-length>].
            // The group-length field appears exactly on each group's first
            // line. Metadata keys ("author", …) can never parse as one.
            if parts.count >= 3,
               parts[0].count >= 40, parts[0].allSatisfy(\.isHexDigit),
               Int(parts[1]) != nil, let finalLine = Int(parts[2]) {
                currentHash = String(parts[0])
                currentLineNumber = finalLine
                currentIsGroupStart = parts.count >= 4 && !parts[3].isEmpty
            } else if let hash = currentHash, let key = parts.first, !key.isEmpty {
                let value = rawLine.dropFirst(key.count + 1)
                metadata[hash, default: [:]][String(key)] = String(value)
            }
        }

        var annotations: [String: BlameAnnotation] = [:]
        for (hash, info) in metadata {
            annotations[hash] = BlameAnnotation(
                author: info["author"] ?? "",
                date: blameDate(epoch: info["author-time"], timeZone: info["author-tz"]),
                summary: info["summary"] ?? ""
            )
        }
        return BlameFile(lines: lines, annotations: annotations)
    }

    /// Formats porcelain's epoch + "+0900"-style offset as a short local-to-
    /// the-author date.
    static func blameDate(epoch: String?, timeZone: String?) -> String {
        guard let epoch, let seconds = TimeInterval(epoch) else { return "" }
        var offsetSeconds = 0
        if let timeZone, timeZone.count == 5, let value = Int(timeZone) {
            offsetSeconds = (abs(value) / 100 * 3600 + abs(value) % 100 * 60) * (value < 0 ? -1 : 1)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: offsetSeconds) ?? .current
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
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
        // `reset -- <paths>` instead of `restore --staged`: identical for a
        // normal HEAD, but also works on an unborn branch (fresh repo), where
        // restore fails with "could not resolve 'HEAD'".
        try await executor.run(["reset", "-q", "--"] + paths)
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

    // MARK: - Remote operations

    func fetch() async throws {
        try await executor.run(["fetch", "--all", "--prune", "--tags"])
    }

    /// Fetches a GitHub pull request's commits into the object store via the
    /// `refs/pull/<n>/head` ref, without creating a local branch. This is the
    /// only way to reach commits of PRs from forks (their remote is never
    /// configured locally); the ref namespace is GitHub-specific.
    func fetchPullRequestHead(number: Int) async throws {
        try await executor.run(["fetch", "origin", "refs/pull/\(number)/head"])
    }

    func pull() async throws {
        try await executor.run(["pull", "--ff-only"])
    }

    func push(force: Bool = false) async throws {
        let branch = try await currentBranch()
        var remote: String?
        var merge: String?
        if branch != "HEAD" {
            remote = try await configValue("branch.\(branch).remote")
            merge = try await configValue("branch.\(branch).merge")
        }
        try await executor.run(Self.pushArguments(
            currentBranch: branch, upstreamRemote: remote, upstreamMerge: merge, force: force
        ))
    }

    /// Builds the `git push` invocation for the current branch. `force` uses
    /// `--force-with-lease`, never bare `--force`: it refuses to overwrite
    /// remote commits that were never fetched locally. A forced push always
    /// carries an explicit refspec — a bare `push --force-with-lease` obeys
    /// `push.default`, and under "matching" that force-pushes every matching
    /// branch, not just the one the user confirmed.
    static func pushArguments(currentBranch: String?, upstreamRemote: String?, upstreamMerge: String?, force: Bool) -> [String] {
        var args = ["push"]
        if force { args.append("--force-with-lease") }
        // Detached HEAD ("HEAD" pseudo-branch): plain push lets git report
        // the real problem instead of creating a branch literally named "HEAD".
        guard let branch = currentBranch, branch != "HEAD" else { return args }
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
        ))
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

    // MARK: - Branches / tags / remotes / stashes

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

    private static let stashListFormat = "%gd\u{1f}%H\u{1f}%gs"

    func stashes() async throws -> [Stash] {
        let output = try await executor.run(["stash", "list", "--format=\(Self.stashListFormat)"])
        return Self.parseStashes(output)
    }

    static func parseStashes(_ output: String) -> [Stash] {
        output.split(separator: "\n").enumerated().compactMap { index, line in
            let fields = line.components(separatedBy: "\u{1f}")
            guard fields.count >= 3 else { return nil }
            return Stash(index: index, reference: fields[0], commitHash: fields[1], message: fields[2])
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
    /// second-guess a delete the user already confirmed.
    func deleteBranch(name: String) async throws {
        try await executor.run(["branch", "-D", "--", name])
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
        try await executor.run(["push", remote, "--delete", "refs/heads/\(branch)"])
    }

    /// `--` separator: name and URL are free text from the add-remote prompt.
    func addRemote(name: String, url: String) async throws {
        try await executor.run(["remote", "add", "--", name, url])
    }

    func removeRemote(name: String) async throws {
        try await executor.run(["remote", "remove", name])
    }

    func createTag(name: String, at hash: String) async throws {
        try await executor.run(["tag", name, hash])
    }

    // MARK: - Merge / rebase / conflicts

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
            // Relative --git-path output is relative to the repo root (the
            // executor's cwd). Not resolved via URL(fileURLWithPath:relativeTo:):
            // a base URL without the directory hint drops its last component.
            let url = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
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
    func continueOperation(_ operation: RepoOperation) async throws {
        try await executor.run(["-c", "core.editor=true", operation.rawValue, "--continue"])
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
        try await executor.run([operation.rawValue, "--skip"])
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
            try await executor.run(["ls-files", "-u", "-z", "--"] + paths)
        )
        let sideExists = Set(unmerged.filter { $0.stage == stage }.map(\.path))
        let checkoutPaths = paths.filter { sideExists.contains($0) }
        let deletePaths = paths.filter { !sideExists.contains($0) }
        if !checkoutPaths.isEmpty {
            try await executor.run(["checkout", "--\(side.rawValue)", "--"] + checkoutPaths)
            try await executor.run(["add", "--"] + checkoutPaths)
        }
        if !deletePaths.isEmpty {
            // -f: the worktree copy holds the other side's content, which git
            // otherwise refuses to remove as "local modifications".
            try await executor.run(["rm", "-f", "--"] + deletePaths)
        }
    }

    /// Whether the working-tree file still contains unresolved conflict
    /// markers. Used to warn before "Mark as Resolved" stages the file as is.
    func containsConflictMarkers(path: String) -> Bool {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(path), options: .mappedIfSafe) else {
            return false
        }
        return Self.hasConflictMarkers(in: data)
    }

    static func hasConflictMarkers(in data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        var foundStart = false
        var foundEnd = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
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

    func stashPush(message: String?) async throws {
        var args = ["stash", "push", "--include-untracked"]
        if let message, !message.isEmpty {
            args.append("-m")
            args.append(message)
        }
        try await executor.run(args)
    }

    /// Re-resolves a stash's positional `stash@{N}` reference by commit hash
    /// right before use. The stored reference goes stale the moment the stash
    /// list changes (another drop, a `git stash push` in a terminal), and a
    /// positional drop against a stale list destroys the wrong stash.
    private func resolveStashRef(_ stash: Stash) async throws -> String {
        let output = try await executor.run(["stash", "list", "--format=\(Self.stashListFormat)"])
        if let match = Self.parseStashes(output).first(where: { $0.commitHash == stash.commitHash }) {
            return match.reference
        }
        throw GitError(
            command: "stash",
            exitCode: 1,
            stderr: "This stash no longer exists — the stash list changed."
        )
    }

    func stashApply(_ stash: Stash, pop: Bool) async throws {
        let reference = try await resolveStashRef(stash)
        try await executor.run(["stash", pop ? "pop" : "apply", reference])
    }

    func stashDrop(_ stash: Stash) async throws {
        let reference = try await resolveStashRef(stash)
        try await executor.run(["stash", "drop", reference])
    }

    func stashDiff(_ stash: Stash) async throws -> [FileDiff] {
        let reference = try await resolveStashRef(stash)
        // --include-untracked: stashes are pushed with untracked files, so the
        // detail view must show them too.
        let (output, valid) = try await executor.runChecked(
            ["stash", "show", "--patch", "--include-untracked", reference]
        )
        return DiffParser.parse(output, strictUTF8: valid)
    }
}
