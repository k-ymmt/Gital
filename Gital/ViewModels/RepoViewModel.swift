import Foundation
import Observation

/// Screen state and actions for the open repository. Split across extensions:
/// loading (`+Loading`), staging/committing (`+WorkingCopy`), branches and
/// history operations (`+SourceControl`), and the AI agent (`+Agent`).
/// Pull request state lives in the owned `prs` sub-model.
@MainActor
@Observable
final class RepoViewModel {
    let repository: GitRepository
    let github: GitHubService
    let codex: CodexAppServer
    let prs: PullRequestsModel

    // MARK: Navigation

    var navTab: NavTab = .branches
    var diffMode: DiffMode = .unified
    var searchText = ""

    // MARK: Repository data

    var status: WorkingStatus = .empty
    /// Stopped multi-step operation (merge/rebase/cherry-pick/revert) that
    /// must be continued or aborted; drives the conflict banner.
    var pendingOperation: RepoOperation?
    var commits: [Commit] = []
    var graph = CommitGraph(commits: [])
    var hasMoreCommits = true
    var isLoadingMoreCommits = false
    var branches: [Branch] = []
    var remotes: [RemoteInfo] = []
    /// True when the default remote is hosted on github.com; switches avatars
    /// from colored initials to real github.com account icons.
    var isGitHubRemote = false
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
    var commitDetailTab: CommitDetailTab = .commit
    var commitDetail: CommitDetail?
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
    /// IDs of every visible line in `workingDiffs`, maintained by
    /// `loadWorkingDiffs` — views must not rebuild this O(all lines) set on
    /// every render.
    var workingDiffLineIDs: Set<String> = []
    var commitMessage = ""
    var amend = false
    var isCommitting = false

    /// Diff lines picked for line-level staging. IDs embed the file path, so
    /// one set can span files; each file header offers its own action.
    var selectedDiffLineIDs: Set<String> = []
    @ObservationIgnored var lineSelectionAnchor: (path: String, id: String)?

    // MARK: File history

    /// Non-nil while the file-history/blame sheet is up; owns that sheet's
    /// whole state so dismissing drops it wholesale.
    var fileHistory: FileHistoryModel?

    // MARK: Stash selection

    var selectedStashRef: String? {
        didSet { if oldValue != selectedStashRef { Task { await loadStashDiff() } } }
    }
    var stashDiffs: [FileDiff] = []

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
    /// Operation whose abort awaits user confirmation — aborting throws away
    /// every conflict resolution made so far.
    var pendingAbort: RepoOperation?
    /// Conflicted file whose "Mark as Resolved" awaits confirmation because
    /// the working-tree copy still contains conflict markers — staging it
    /// as-is would let the markers be committed.
    var pendingMarkResolved: FileChange?
    /// True while the force-push confirmation is up — rewriting remote
    /// history affects everyone tracking the branch.
    var pendingForcePush = false
    var pendingBranchDelete: PendingBranchDelete?
    /// Branch whose rename prompt is up; the draft name lives in the alert.
    var renamingBranch: Branch?
    var pendingRemoteBranchDelete: RemoteBranchRef?
    var pendingRemoteRemoval: RemoteInfo?
    /// True while the add-remote prompt (name + URL) is up.
    var isAddingRemote = false

    // MARK: Busy / errors

    var isSyncing = false
    var syncActivity: String?
    var errorMessage: String?

    // MARK: Load supersession
    //
    // Each load kind runs through its own LatestLoader — a slow stale load
    // can never overwrite the state a newer one produced. refreshLog and
    // loadMoreCommits share one loader on purpose: a refresh must invalidate
    // an in-flight page load and vice versa (offsets shift under both).

    /// True once `loadWorkingDiffs` has delivered a result. Entering the
    /// Changes tab consults this instead of always re-running `git diff`:
    /// the model keeps `workingDiffs` across tab switches and the file
    /// watcher refreshes it on every change, so a switch normally has
    /// nothing to fetch.
    @ObservationIgnored var hasLoadedWorkingDiffs = false
    @ObservationIgnored let workingDiffsLoader = LatestLoader()
    @ObservationIgnored let commitDetailLoader = LatestLoader()
    @ObservationIgnored let logLoader = LatestLoader()
    @ObservationIgnored let stashDiffLoader = LatestLoader()
    @ObservationIgnored private var syncCount = 0
    @ObservationIgnored var pendingDiscardSnapshot: [FileDiff]?

    @ObservationIgnored private var watcher: RepoWatcher?

    /// Whether FSEvents-based refresh is running. When it isn't, cached
    /// working diffs can go stale silently, so tab entry must reload.
    var isWatchingFileSystem: Bool { watcher?.isWatching == true }

    init(repository: GitRepository) {
        self.repository = repository
        let github = GitHubService(repoRoot: repository.root)
        self.github = github
        self.codex = CodexAppServer()
        self.prs = PullRequestsModel(repository: repository, github: github)
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

    // MARK: - Avatars

    /// github.com avatar for a commit author email, or nil when the default
    /// remote is not GitHub (the view then shows colored initials). `size` is
    /// the view's point size; the request doubles it for Retina.
    func avatarURL(email: String, size: CGFloat) -> URL? {
        guard isGitHubRemote else { return nil }
        return GitHubAvatars.url(email: email, pixelSize: Int(size) * 2)
    }

    /// github.com avatar for a GitHub login (PR authors, reviewers).
    func avatarURL(login: String?, size: CGFloat) -> URL? {
        guard isGitHubRemote, let login else { return nil }
        return GitHubAvatars.url(login: login, pixelSize: Int(size) * 2)
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
