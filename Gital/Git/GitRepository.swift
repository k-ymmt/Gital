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
        // --untracked-files=all: without it git collapses an untracked
        // directory into one "dir/" entry, so the sidebar would show a folder
        // pseudo-file instead of the files inside it.
        let data = try await executor.runData(["status", "--porcelain=v2", "--branch", "--untracked-files=all", "-z"])
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
            } else if token.hasPrefix("# branch.oid ") {
                let value = String(token.dropFirst("# branch.oid ".count))
                status.headOID = value == "(initial)" ? nil : value
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
            let attributes = try FileManager.default.attributesOfItem(
                atPath: root.appendingPathComponent(path).path
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

    /// Full message of the HEAD commit, shown to the AI as context when
    /// generating a message for an amend.
    func headCommitMessage() async throws -> String {
        // --no-show-signature: log.showSignature=true would prepend the
        // verification block to stdout ahead of %B.
        try await executor.run(["log", "-1", "--no-show-signature", "--format=%B"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Remote operations

    func fetch() async throws {
        // --no-write-fetch-head (git 2.29+): nothing in the app reads
        // FETCH_HEAD, and writing it turns even a no-change fetch into an
        // FSEvents event that sends the watcher into a full refresh.
        try await executor.run(["fetch", "--all", "--prune", "--tags", "--no-write-fetch-head"])
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

    // MARK: - Interactive rebase

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
        try await executor.run([
            "-c", "sequence.editor=/bin/cp -f \(Self.shellQuote(todoFile.path))",
            "-c", "core.editor=true",
            // A comment char like `p` or `d` would turn todo commands into
            // comments; pin the default.
            "-c", "core.commentChar=#",
            // A transiently failing amend exec (e.g. broken gpg signing) is
            // retried on --continue instead of being silently dropped, which
            // would lose the message rewrite while reporting success.
            "-c", "rebase.rescheduleFailedExec=true",
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
        ])
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
