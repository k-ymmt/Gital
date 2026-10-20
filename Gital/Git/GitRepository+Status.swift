import Foundation

// MARK: - Status

extension GitRepository {
    @concurrent func status() async throws -> WorkingStatus {
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
}
