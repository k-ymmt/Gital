import Foundation

struct PullRequestSummary: Identifiable, Hashable {
    let number: Int
    let title: String
    let author: String
    let state: String        // OPEN / MERGED / CLOSED
    let isDraft: Bool
    let headRefName: String
    /// Logins with a pending review request. User requests only — team
    /// requests come through without a login and are dropped.
    let reviewRequestLogins: [String]

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
        let login: String?
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
    let authorLogin: String?
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
    /// The `gh` executable could not be found on this machine.
    case notInstalled
    /// The `gh` process could not be launched at all.
    case launchFailed(String)
    /// `gh` ran but exited non-zero.
    case commandFailed(command: String, status: Int32, stderr: String)
    /// `gh` succeeded but its output did not decode as expected — the JSON
    /// shape changed or the output was not JSON at all.
    case unexpectedOutput(command: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "gh CLI not found. Install it with `brew install gh`."
        case .launchFailed(let message):
            "Failed to launch gh: \(message)"
        case .commandFailed(let command, let status, let stderr):
            stderr.isEmpty ? "`\(command)` exited with status \(status)" : stderr
        case .unexpectedOutput(let command, let underlying):
            "`\(command)` returned unexpected output: \(underlying.localizedDescription)"
        }
    }
}

/// Pull request data backed by the `gh` CLI.
struct GitHubService {
    let repoRoot: URL

    func listPullRequests() async throws -> [PullRequestSummary] {
        let data = try await runGH([
            "pr", "list", "--state", "all", "--limit", "30",
            "--json", "number,title,author,state,isDraft,headRefName,reviewRequests",
        ])

        struct Row: Decodable {
            struct Author: Decodable { let login: String; let name: String? }
            struct ReviewRequest: Decodable { let login: String? }
            let number: Int
            let title: String
            let author: Author?
            let state: String
            let isDraft: Bool
            let headRefName: String
            let reviewRequests: [ReviewRequest]?
        }

        let rows = try Self.decode([Row].self, from: data, command: "gh pr list")
        return rows.map { row in
            PullRequestSummary(
                number: row.number,
                title: row.title,
                author: row.author.map { $0.name?.isEmpty == false ? $0.name! : $0.login } ?? "unknown",
                state: row.state,
                isDraft: row.isDraft,
                headRefName: row.headRefName,
                reviewRequestLogins: (row.reviewRequests ?? []).compactMap(\.login)
            )
        }
    }

    /// Login of the authenticated `gh` user, for "awaiting your review".
    func viewerLogin() async throws -> String {
        let data = try await runGH(["api", "user", "--jq", ".login"])
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

        let row = try Self.decode(Row.self, from: data, command: "gh pr view")
        func displayName(_ author: Row.Author?) -> String {
            guard let author else { return "unknown" }
            return author.name?.isEmpty == false ? author.name! : author.login
        }

        var reviewers: [PullRequestDetail.Reviewer] = (row.latestReviews ?? []).map {
            PullRequestDetail.Reviewer(name: displayName($0.author), login: $0.author?.login, state: $0.state)
        }
        for request in row.reviewRequests ?? [] {
            if let login = request.login, !reviewers.contains(where: { $0.name == login }) {
                reviewers.append(PullRequestDetail.Reviewer(name: login, login: login, state: "PENDING"))
            }
        }

        return PullRequestDetail(
            number: row.number,
            title: row.title,
            author: displayName(row.author),
            authorLogin: row.author?.login,
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

    /// Unified diff of the whole pull request, straight from GitHub — works
    /// even when the PR branch has not been fetched locally.
    func pullRequestDiff(number: Int) async throws -> String {
        let data = try await runGH(["pr", "diff", String(number)])
        return String(decoding: data, as: UTF8.self)
    }

    func merge(number: Int) async throws {
        _ = try await runGH(["pr", "merge", String(number), "--merge"])
    }

    /// Decodes gh JSON output, wrapping decode failures with the subcommand
    /// that produced the data — a raw `DecodingError` in the UI gives the
    /// user no clue which gh call broke.
    private static func decode<T: Decodable>(_ type: T.Type, from data: Data, command: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GitHubError.unexpectedOutput(command: command, underlying: error)
        }
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
            throw GitHubError.notInstalled
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
                // Exit is observed via `terminationHandler`, not `waitUntilExit`:
                // the latter polls the current thread's run loop, and on a GCD
                // worker thread the termination notification can be missed,
                // hanging forever after gh has already exited.
                let done = DispatchGroup()
                let stdoutGate = DrainGate()
                let stderrGate = DrainGate()
                for (pipe, buffer, gate) in [(stdoutPipe, stdoutBuffer, stdoutGate), (stderrPipe, stderrBuffer, stderrGate)] {
                    done.enter()
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                            if gate.finish() { done.leave() }
                        } else {
                            buffer.append(chunk)
                        }
                    }
                }
                done.enter()
                process.terminationHandler = { _ in
                    done.leave()
                    // Grace cutoff mirroring GitExecutor: a background child
                    // of gh holding the pipe write ends must not hang this
                    // request forever after gh itself exited.
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + GitExecutor.drainGracePeriod) {
                        for (pipe, gate) in [(stdoutPipe, stdoutGate), (stderrPipe, stderrGate)] {
                            if gate.finish() {
                                pipe.fileHandleForReading.readabilityHandler = nil
                                done.leave()
                            }
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    for (pipe, gate) in [(stdoutPipe, stdoutGate), (stderrPipe, stderrGate)] {
                        pipe.fileHandleForReading.readabilityHandler = nil
                        if gate.finish() { done.leave() }
                    }
                    process.terminationHandler = nil
                    done.leave()
                    continuation.resume(throwing: GitHubError.launchFailed(error.localizedDescription))
                    return
                }

                done.notify(queue: .global(qos: .userInitiated)) {
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: stdoutBuffer.value)
                    } else {
                        let message = String(decoding: stderrBuffer.value, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(throwing: GitHubError.commandFailed(
                            command: "gh " + arguments.prefix(2).joined(separator: " "),
                            status: process.terminationStatus,
                            stderr: message
                        ))
                    }
                }
            }
        }
    }
}
