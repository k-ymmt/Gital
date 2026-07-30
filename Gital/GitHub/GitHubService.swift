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
        return try Self.parsePullRequestList(data)
    }

    static func parsePullRequestList(_ data: Data) throws -> [PullRequestSummary] {
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
        return try Self.parsePullRequestDetail(data)
    }

    static func parsePullRequestDetail(_ data: Data) throws -> PullRequestDetail {
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

    /// Submits a review with all of its draft comments in one shot, exactly
    /// like GitHub's "Review changes" button: comments and verdict travel in
    /// a single `POST /pulls/{n}/reviews` call. `{owner}/{repo}` placeholders
    /// are resolved by gh from the repository the command runs in.
    func submitReview(number: Int, event: ReviewEvent, body: String, comments: [PendingReviewComment]) async throws {
        let payload = try Self.reviewSubmissionBody(event: event, body: body, comments: comments)
        _ = try await runGH(
            ["api", "repos/{owner}/{repo}/pulls/\(number)/reviews", "--method", "POST", "--input", "-"],
            stdin: payload
        )
    }

    static func reviewSubmissionBody(event: ReviewEvent, body: String, comments: [PendingReviewComment]) throws -> Data {
        struct CommentPayload: Encodable {
            let path: String
            let side: String
            let line: Int
            let body: String
        }
        struct Payload: Encodable {
            let event: String
            let body: String?
            let comments: [CommentPayload]?
        }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = Payload(
            event: event.rawValue,
            body: trimmed.isEmpty ? nil : trimmed,
            comments: comments.isEmpty ? nil : comments.map {
                CommentPayload(path: $0.anchor.path, side: $0.anchor.side.rawValue, line: $0.anchor.line, body: $0.body)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    // MARK: - Review conversations

    /// GraphQL is the only API that exposes a thread's resolved state and the
    /// node ID the resolve/unresolve mutations take. `{owner}`/`{repo}`
    /// placeholders in `-F` values are substituted by gh from the repository
    /// the command runs in, same as in REST paths.
    static let reviewThreadsQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100) {
            nodes {
              id isResolved isOutdated path line diffSide
              comments(first: 100) {
                nodes { databaseId body createdAt author { login } diffHunk }
              }
            }
          }
        }
      }
    }
    """

    func reviewThreads(number: Int) async throws -> [ReviewThread] {
        let data = try await runGH([
            "api", "graphql",
            "-F", "owner={owner}", "-F", "name={repo}", "-F", "number=\(number)",
            "-f", "query=\(Self.reviewThreadsQuery)",
        ])
        return try Self.parseReviewThreads(data)
    }

    static func parseReviewThreads(_ data: Data) throws -> [ReviewThread] {
        struct Response: Decodable {
            struct DataObject: Decodable { let repository: Repository? }
            struct Repository: Decodable { let pullRequest: PullRequest? }
            struct PullRequest: Decodable { let reviewThreads: ThreadConnection }
            struct ThreadConnection: Decodable { let nodes: [ThreadNode] }
            struct ThreadNode: Decodable {
                let id: String
                let isResolved: Bool
                let isOutdated: Bool
                let path: String
                let line: Int?
                let diffSide: String
                let comments: CommentConnection
            }
            struct CommentConnection: Decodable { let nodes: [CommentNode] }
            struct CommentNode: Decodable {
                struct Author: Decodable { let login: String }
                let databaseId: Int?
                let body: String
                let createdAt: String
                let author: Author?
                let diffHunk: String?
            }
            let data: DataObject?
        }

        let response = try Self.decode(Response.self, from: data, command: "gh api graphql")
        let nodes = response.data?.repository?.pullRequest?.reviewThreads.nodes ?? []
        return nodes.compactMap { node in
            // Comments without a databaseId (only server-side pending-review
            // drafts have none) can't be replied to and are dropped; a thread
            // left without comments has nothing to show.
            let comments = node.comments.nodes.compactMap { comment -> ReviewThread.Comment? in
                guard let id = comment.databaseId else { return nil }
                return ReviewThread.Comment(
                    id: id,
                    authorLogin: comment.author?.login ?? "unknown",
                    body: comment.body,
                    createdAt: relativeDate(from: comment.createdAt)
                )
            }
            guard !comments.isEmpty else { return nil }
            return ReviewThread(
                id: node.id,
                path: node.path,
                side: node.diffSide == "LEFT" ? .left : .right,
                line: node.line,
                lineText: ReviewThread.lineText(fromDiffHunk: node.comments.nodes.first?.diffHunk),
                isResolved: node.isResolved,
                isOutdated: node.isOutdated,
                comments: comments
            )
        }
    }

    /// Replies to an existing thread. The REST replies endpoint takes the
    /// thread's root comment ID; GitHub attaches the reply to the thread
    /// regardless of which of its comments the ID names.
    func replyToReviewComment(number: Int, commentID: Int, body: String) async throws {
        _ = try await runGH(
            ["api", "repos/{owner}/{repo}/pulls/\(number)/comments/\(commentID)/replies",
             "--method", "POST", "--input", "-"],
            stdin: try Self.replyBody(body)
        )
    }

    static func replyBody(_ body: String) throws -> Data {
        struct Payload: Encodable { let body: String }
        return try JSONEncoder().encode(Payload(body: body))
    }

    func setThreadResolved(_ threadID: String, resolved: Bool) async throws {
        let mutation = resolved
            ? "mutation($id: ID!) { resolveReviewThread(input: {threadId: $id}) { thread { id } } }"
            : "mutation($id: ID!) { unresolveReviewThread(input: {threadId: $id}) { thread { id } } }"
        _ = try await runGH(["api", "graphql", "-f", "id=\(threadID)", "-f", "query=\(mutation)"])
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

    private func runGH(_ arguments: [String], stdin: Data? = nil) async throws -> Data {
        // gh runs directly (no `zsh -lc`): a login profile that prints to
        // stdout would prepend garbage to gh's JSON and break every decode,
        // and the shell indirection also made the "gh not installed" branch
        // unreachable (zsh itself always launches).
        guard let ghURL = await ExecutableLocator.shared.find("gh") else {
            throw GitHubError.notInstalled
        }

        let result: Subprocess.Output
        do {
            result = try await Subprocess.run(
                executable: ghURL,
                arguments: arguments,
                currentDirectory: repoRoot,
                stdin: stdin
            )
        } catch {
            throw GitHubError.launchFailed(error.localizedDescription)
        }

        guard result.status == 0 else {
            throw GitHubError.commandFailed(
                command: "gh " + arguments.prefix(2).joined(separator: " "),
                status: result.status,
                stderr: String(decoding: result.stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.stdout
    }
}
