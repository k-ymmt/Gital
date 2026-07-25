import Foundation
import Observation

enum NavTab: String, CaseIterable, Identifiable {
    case changes, source, pullRequests, stashes

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .changes: "doc.text"
        case .source: "arrow.triangle.branch"
        case .pullRequests: "arrow.triangle.pull"
        case .stashes: "archivebox"
        }
    }

    var help: String {
        switch self {
        case .changes: "Working Copy"
        case .source: "Source"
        case .pullRequests: "Pull Requests"
        case .stashes: "Stashes"
        }
    }
}

enum DiffMode: String, CaseIterable, Identifiable {
    case unified = "Unified"
    case split = "Split"

    var id: String { rawValue }
}

/// Screen state and actions for the open repository. Split across extensions:
/// loading (`+Loading`), staging/committing (`+WorkingCopy`), branches and
/// history operations (`+SourceControl`), and the AI agent (`+Agent`).
@MainActor
@Observable
final class RepoViewModel {
    let repository: GitRepository
    let github: GitHubService
    let codex: CodexAppServer

    // MARK: Navigation

    var navTab: NavTab = .source
    var diffMode: DiffMode = .unified
    var searchText = ""

    // MARK: Repository data

    var status: WorkingStatus = .empty
    var commits: [Commit] = []
    var graph = CommitGraph(commits: [])
    var hasMoreCommits = true
    var isLoadingMoreCommits = false
    var branches: [Branch] = []
    var remotes: [RemoteInfo] = []
    var tags: [Tag] = []
    var stashes: [Stash] = []

    // MARK: History selection

    var selectedCommitHash: String? {
        didSet {
            if oldValue != selectedCommitHash {
                if let name = selectedBranchName,
                   branches.first(where: { $0.name == name })?.tipHash != selectedCommitHash {
                    selectedBranchName = nil
                }
                if let name = selectedTagName,
                   tags.first(where: { $0.name == name })?.tipHash != selectedCommitHash {
                    selectedTagName = nil
                }
                Task { await loadCommitDetail() }
            }
        }
    }
    var selectedBranchName: String?
    var selectedTagName: String?

    /// Branch row to highlight in the sidebar: the explicitly clicked branch,
    /// falling back to the current branch when nothing else is selected.
    var highlightedBranchName: String? {
        selectedBranchName ?? (selectedTagName == nil ? branches.first(where: \.isCurrent)?.name : nil)
    }
    var commitFiles: [CommitFileStat] = []
    var commitDiffs: [FileDiff] = []
    var selectedCommitFilePath: String?

    var selectedCommit: Commit? {
        commits.first { $0.hash == selectedCommitHash }
    }

    var selectedCommitDiff: FileDiff? {
        guard let path = selectedCommitFilePath else { return commitDiffs.first }
        return commitDiffs.first { $0.path == path } ?? commitDiffs.first
    }

    // MARK: Changes selection

    var selectedChangePath: String? {
        didSet { if oldValue != selectedChangePath { Task { await loadWorkingDiffs() } } }
    }
    var workingDiffs: [FileDiff] = []
    var commitMessage = ""
    var amend = false
    var isCommitting = false

    /// Diff lines picked for line-level staging. IDs embed the file path, so
    /// one set can span files; each file header offers its own action.
    var selectedDiffLineIDs: Set<String> = []
    @ObservationIgnored var lineSelectionAnchor: (path: String, id: String)?

    // MARK: Stash selection

    var selectedStashRef: String? {
        didSet { if oldValue != selectedStashRef { Task { await loadStashDiff() } } }
    }
    var stashDiffs: [FileDiff] = []

    // MARK: Pull requests

    var pullRequests: [PullRequestSummary] = []
    var prLoadError: String?
    var selectedPRNumber: Int? {
        didSet { if oldValue != selectedPRNumber { Task { await loadPRDetail() } } }
    }
    var prDetail: PullRequestDetail?
    var prDetailsCache: [Int: PullRequestDetail] = [:]
    var expandedPRs: Set<Int> = []

    // MARK: Agent

    var agentThreads: [AgentThread] = []
    var composerFile: String?
    var composerRange: ClosedRange<Int>?
    var composerAnchorID: String?
    var agentDraft = ""

    // MARK: Pending confirmations

    var pendingDiscard: DiscardTarget?
    var pendingReset: PendingReset?

    // MARK: Busy / errors

    var isSyncing = false
    var syncActivity: String?
    var errorMessage: String?

    @ObservationIgnored private var watcher: RepoWatcher?

    init(repository: GitRepository) {
        self.repository = repository
        self.github = GitHubService(repoRoot: repository.root)
        self.codex = CodexAppServer()
        startWatching()
    }

    /// Refreshes the working copy whenever files change on disk (editors,
    /// terminals, agents). FSEvents coalesces bursts via its latency window.
    private func startWatching() {
        watcher = RepoWatcher(root: repository.root) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.refreshStatus()
                await self.loadWorkingDiffs()
            }
        }
    }

    // MARK: - Filtering

    var filteredCommits: [Commit] {
        guard !searchText.isEmpty else { return commits }
        let needle = searchText.lowercased()
        return commits.filter {
            $0.subject.lowercased().contains(needle)
                || $0.author.lowercased().contains(needle)
                || $0.hash.hasPrefix(needle)
        }
    }

    // MARK: - Operation plumbing

    /// What to reload after a git operation succeeds.
    enum RefreshScope {
        case workingCopy
        case refs
        case all
    }

    /// Runs a git operation off the main thread of control, refreshes the
    /// given scope on success, and surfaces failures via `errorMessage`.
    func perform(refresh: RefreshScope, _ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await operation()
                switch refresh {
                case .workingCopy:
                    await refreshStatus()
                    await loadWorkingDiffs()
                case .refs:
                    await refreshRefs()
                case .all:
                    await refreshAll()
                }
            } catch { report(error) }
        }
    }

    /// Like `perform`, but drives the toolbar busy indicator; used by the
    /// long-running sync and history operations.
    func runSync(_ activity: String, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !isSyncing else { return }
        isSyncing = true
        syncActivity = activity
        Task {
            defer {
                isSyncing = false
                syncActivity = nil
            }
            do {
                try await operation()
                await refreshAll()
            } catch { report(error) }
        }
    }

    // MARK: - Errors

    func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
