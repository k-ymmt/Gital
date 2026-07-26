import Foundation
import Observation

enum NavTab: String, CaseIterable, Identifiable {
    case changes, branches, pullRequests, stashes

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .changes: "doc.text"
        case .branches: "arrow.triangle.branch"
        case .pullRequests: "arrow.triangle.pull"
        case .stashes: "archivebox"
        }
    }

    var help: String {
        switch self {
        case .changes: "Working Copy"
        case .branches: "Branches"
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

    var navTab: NavTab = .branches
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

    /// A working-copy file selection. Carries whether the staged or unstaged
    /// side was clicked: a partially staged file appears in both sidebar
    /// sections, and a bare path can't distinguish them.
    struct ChangeSelection: Equatable, Hashable {
        let path: String
        let staged: Bool
    }

    var selectedChange: ChangeSelection? {
        didSet { if oldValue != selectedChange { Task { await loadWorkingDiffs() } } }
    }

    var selectedChangePath: String? { selectedChange?.path }
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
    var pendingStashDrop: Stash?

    // MARK: Busy / errors

    var isSyncing = false
    var syncActivity: String?
    var errorMessage: String?

    // MARK: Load generations
    //
    // Every async load bumps its generation before awaiting and only assigns
    // its result while still current — a slow stale load can never overwrite
    // the state a newer one produced.

    @ObservationIgnored var workingDiffsGeneration = 0
    @ObservationIgnored var commitDetailGeneration = 0
    @ObservationIgnored var logGeneration = 0
    @ObservationIgnored var stashDiffGeneration = 0
    @ObservationIgnored private var syncCount = 0
    @ObservationIgnored var pendingDiscardSnapshot: [FileDiff]?

    @ObservationIgnored private var watcher: RepoWatcher?

    init(repository: GitRepository) {
        self.repository = repository
        self.github = GitHubService(repoRoot: repository.root)
        self.codex = CodexAppServer()
        startWatching()
    }

    /// Releases resources owned by this view model. Must be called when the
    /// repository is closed or switched — the codex app-server subprocess is
    /// not tied to our lifetime and would linger as an orphan otherwise.
    func close() {
        watcher = nil
        let codex = self.codex
        Task.detached { await codex.shutdown() }
    }

    /// Refreshes state whenever files change on disk (editors, terminals,
    /// agents). FSEvents coalesces bursts via its latency window. Refs, log,
    /// and stashes refresh too: external commits, branches, and `git stash`
    /// runs must be reflected, or positional references (stash@{N}) in the UI
    /// go stale and target the wrong object.
    private func startWatching() {
        watcher = RepoWatcher(root: repository.root) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.refreshStatus()
                await self.loadWorkingDiffs()
                await self.refreshLog()
                await self.refreshRefs()
            }
        }
        if watcher?.isWatching != true {
            errorMessage = "File watching could not be started — external changes will not refresh automatically."
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
    /// long-running sync and history operations. Operations queue up behind
    /// the serialized git executor instead of being dropped: silently
    /// discarding a user-confirmed reset/cherry-pick because a fetch was in
    /// flight left the user believing it happened.
    func runSync(_ activity: String, _ operation: @escaping @MainActor () async throws -> Void) {
        syncCount += 1
        isSyncing = true
        syncActivity = activity
        Task {
            defer {
                syncCount -= 1
                if syncCount == 0 {
                    isSyncing = false
                    syncActivity = nil
                }
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
