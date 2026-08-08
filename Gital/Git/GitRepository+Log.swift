import Foundation

// MARK: - Log

extension GitRepository {
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
}
