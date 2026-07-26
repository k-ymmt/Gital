import Foundation

struct PullRequestSummary: Identifiable, Hashable {
    let number: Int
    let title: String
    let author: String
    let state: String        // OPEN / MERGED / CLOSED
    let isDraft: Bool
    let headRefName: String

    var id: Int { number }

    var statusLabel: String {
        if isDraft && state == "OPEN" { return "Draft" }
        return state.capitalized
    }
}

struct PullRequestDetail: Hashable {
    struct Label: Hashable, Identifiable {
        let name: String
        let color: String
        var id: String { name }
    }

    struct Reviewer: Hashable, Identifiable {
        let name: String
        let state: String    // APPROVED / PENDING / CHANGES_REQUESTED / COMMENTED
        var id: String { name }
    }

    struct CommitInfo: Hashable, Identifiable {
        let hash: String
        let message: String
        let author: String
        var id: String { hash }
    }

    struct FileInfo: Hashable, Identifiable {
        let path: String
        let additions: Int
        let deletions: Int
        var id: String { path }
    }

    let number: Int
    let title: String
    let author: String
    let state: String
    let isDraft: Bool
    let base: String
    let head: String
    let createdAt: String
    let body: String
    let additions: Int
    let deletions: Int
    let changedFiles: Int
    let mergeable: String
    let labels: [Label]
    let reviewers: [Reviewer]
    let commits: [CommitInfo]
    let files: [FileInfo]

    var statusLabel: String {
        if isDraft && state == "OPEN" { return "Draft" }
        return state.capitalized
    }
}

enum GitHubError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        }
    }
}

/// Pull request data backed by the `gh` CLI.
struct GitHubService {
    let repoRoot: URL

    func listPullRequests() async throws -> [PullRequestSummary] {
        let data = try await runGH([
            "pr", "list", "--state", "all", "--limit", "30",
            "--json", "number,title,author,state,isDraft,headRefName",
        ])

        struct Row: Decodable {
            struct Author: Decodable { let login: String; let name: String? }
            let number: Int
            let title: String
            let author: Author?
            let state: String
            let isDraft: Bool
            let headRefName: String
        }

        let rows = try JSONDecoder().decode([Row].self, from: data)
        return rows.map { row in
            PullRequestSummary(
                number: row.number,
                title: row.title,
                author: row.author.map { $0.name?.isEmpty == false ? $0.name! : $0.login } ?? "unknown",
                state: row.state,
                isDraft: row.isDraft,
                headRefName: row.headRefName
            )
        }
    }

    func pullRequestDetail(number: Int) async throws -> PullRequestDetail {
        let data = try await runGH([
            "pr", "view", String(number),
            "--json", "number,title,author,state,isDraft,baseRefName,headRefName,createdAt,body,additions,deletions,changedFiles,mergeable,labels,latestReviews,reviewRequests,commits,files",
        ])

        struct Row: Decodable {
            struct Author: Decodable { let login: String; let name: String? }
            struct Label: Decodable { let name: String; let color: String }
            struct Review: Decodable { let author: Author?; let state: String }
            struct ReviewRequest: Decodable { let login: String? }
            struct CommitRow: Decodable {
                struct CommitAuthor: Decodable { let name: String? ; let login: String? }
                let oid: String
                let messageHeadline: String
                let authors: [CommitAuthor]?
            }
            struct FileRow: Decodable { let path: String; let additions: Int; let deletions: Int }

            let number: Int
            let title: String
            let author: Author?
            let state: String
            let isDraft: Bool
            let baseRefName: String
            let headRefName: String
            let createdAt: String
            let body: String
            let additions: Int
            let deletions: Int
            let changedFiles: Int
            let mergeable: String?
            let labels: [Label]?
            let latestReviews: [Review]?
            let reviewRequests: [ReviewRequest]?
            let commits: [CommitRow]?
            let files: [FileRow]?
        }

        let row = try JSONDecoder().decode(Row.self, from: data)
        func displayName(_ author: Row.Author?) -> String {
            guard let author else { return "unknown" }
            return author.name?.isEmpty == false ? author.name! : author.login
        }

        var reviewers: [PullRequestDetail.Reviewer] = (row.latestReviews ?? []).map {
            PullRequestDetail.Reviewer(name: displayName($0.author), state: $0.state)
        }
        for request in row.reviewRequests ?? [] {
            if let login = request.login, !reviewers.contains(where: { $0.name == login }) {
                reviewers.append(PullRequestDetail.Reviewer(name: login, state: "PENDING"))
            }
        }

        return PullRequestDetail(
            number: row.number,
            title: row.title,
            author: displayName(row.author),
            state: row.state,
            isDraft: row.isDraft,
            base: row.baseRefName,
            head: row.headRefName,
            createdAt: Self.relativeDate(from: row.createdAt),
            body: row.body,
            additions: row.additions,
            deletions: row.deletions,
            changedFiles: row.changedFiles,
            mergeable: row.mergeable ?? "UNKNOWN",
            labels: (row.labels ?? []).map { PullRequestDetail.Label(name: $0.name, color: $0.color) },
            reviewers: reviewers,
            commits: (row.commits ?? []).map {
                PullRequestDetail.CommitInfo(
                    hash: String($0.oid.prefix(7)),
                    message: $0.messageHeadline,
                    author: $0.authors?.first?.name ?? $0.authors?.first?.login ?? ""
                )
            },
            files: (row.files ?? []).map {
                PullRequestDetail.FileInfo(path: $0.path, additions: $0.additions, deletions: $0.deletions)
            }
        )
    }

    func merge(number: Int) async throws {
        _ = try await runGH(["pr", "merge", String(number), "--merge"])
    }

    private static func relativeDate(from iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        return relative.localizedString(for: date, relativeTo: Date())
    }

    private func runGH(_ arguments: [String]) async throws -> Data {
        let repoRoot = self.repoRoot
        // gh runs directly (no `zsh -lc`): a login profile that prints to
        // stdout would prepend garbage to gh's JSON and break every decode,
        // and the shell indirection also made the "gh not installed" branch
        // unreachable (zsh itself always launches).
        guard let ghURL = ExecutableLocator.shared.find("gh") else {
            throw GitHubError.unavailable("gh CLI not found. Install it with `brew install gh`.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = ghURL
                process.arguments = arguments
                process.currentDirectoryURL = repoRoot
                process.standardInput = FileHandle.nullDevice

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                // Drain both pipes concurrently; sequential reads deadlock
                // when gh fills the stderr pipe buffer while stdout is open.
                final class Buffer: @unchecked Sendable {
                    private let lock = NSLock()
                    private var data = Data()
                    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
                    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
                }
                let stdoutBuffer = Buffer()
                let stderrBuffer = Buffer()
                let drained = DispatchGroup()
                for (pipe, buffer) in [(stdoutPipe, stdoutBuffer), (stderrPipe, stderrBuffer)] {
                    drained.enter()
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                            drained.leave()
                        } else {
                            buffer.append(chunk)
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    for pipe in [stdoutPipe, stderrPipe] {
                        pipe.fileHandleForReading.readabilityHandler = nil
                    }
                    continuation.resume(throwing: GitHubError.unavailable("Failed to launch gh: \(error.localizedDescription)"))
                    return
                }

                process.waitUntilExit()
                drained.wait()

                if process.terminationStatus == 0 {
                    continuation.resume(returning: stdoutBuffer.value)
                } else {
                    let message = String(decoding: stderrBuffer.value, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: GitHubError.unavailable(
                        message.isEmpty ? "gh exited with status \(process.terminationStatus)" : message
                    ))
                }
            }
        }
    }
}
