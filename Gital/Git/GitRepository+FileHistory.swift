import Foundation

// MARK: - File history / blame

extension GitRepository {
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

    /// Reverses git's C-style path quoting; a tab inside an unquoted path
    /// would break the name-status field split. Delegates to the shared
    /// implementation so file-history paths and diff-header paths can never
    /// resolve differently.
    static func unquotePath(_ raw: String) -> String {
        GitPathQuoting.unquote(raw)
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

    // Shared instance: blameDate runs once per unique commit in a blame, and
    // DateFormatter construction dominates the cost. Mutating the time zone
    // per call is safe — the type is MainActor-isolated.
    private static let blameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// Formats porcelain's epoch + "+0900"-style offset as a short local-to-
    /// the-author date.
    static func blameDate(epoch: String?, timeZone: String?) -> String {
        guard let epoch, let seconds = TimeInterval(epoch) else { return "" }
        var offsetSeconds = 0
        if let timeZone, timeZone.count == 5, let value = Int(timeZone) {
            offsetSeconds = (abs(value) / 100 * 3600 + abs(value) % 100 * 60) * (value < 0 ? -1 : 1)
        }
        blameDateFormatter.timeZone = TimeZone(secondsFromGMT: offsetSeconds) ?? .current
        return blameDateFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }
}
