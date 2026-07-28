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

/// Tabs in the history detail pane: full commit metadata vs. changed files.
enum CommitDetailTab: String, CaseIterable, Identifiable {
    case commit = "Commit"
    case files = "Files"

    var id: String { rawValue }
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

    /// A selected row inside a PR's sidebar expansion: one of its commits or
    /// one of its changed files.
    enum PRItemSelection: Equatable, Hashable {
        case commit(hash: String)
        case file(path: String)
    }

    enum PRStateFilter: String, CaseIterable, Identifiable {
        case all, open, draft, awaitingYourReview, merged, closed

        var id: String { rawValue }

        var label: String {
            switch self {
            case .all: "All"
            case .open: "Open"
            case .draft: "Draft"
            case .awaitingYourReview: "Awaiting review from you"
            case .merged: "Merged"
            case .closed: "Closed"
            }
        }

        /// Compact variant for the sidebar header chip, where the full
        /// "Awaiting review from you" label would crowd out the section title.
        var shortLabel: String {
            self == .awaitingYourReview ? "Awaiting review" : label
        }

        func matches(_ pr: PullRequestSummary, viewerLogin: String?) -> Bool {
            switch self {
            case .all: true
            // GitHub counts drafts as open, so Open includes them; Draft
            // narrows to drafts only.
            case .open: pr.state == "OPEN"
            case .draft: pr.state == "OPEN" && pr.isDraft
            case .awaitingYourReview:
                pr.state == "OPEN" && viewerLogin.map { login in
                    pr.reviewRequestLogins.contains { $0.caseInsensitiveCompare(login) == .orderedSame }
                } ?? false
            case .merged: pr.state == "MERGED"
            case .closed: pr.state == "CLOSED"
            }
        }
    }

    var pullRequests: [PullRequestSummary] = []
    var prLoadError: String?
    var prSearchText = ""
    /// Authenticated `gh` login, fetched alongside the PR list; nil until
    /// loaded (the "awaiting your review" filter matches nothing then).
    var prViewerLogin: String?
    var prStateFilter: PRStateFilter = .all {
        didSet { savePRStateFilter() }
    }

    /// UserDefaults key for a `[repo path: PRStateFilter raw value]` map so
    /// each repository remembers its own filter across launches. Entries are
    /// removed when the filter returns to `.all` to keep the map from
    /// accumulating stale paths.
    private static let prStateFilterDefaultsKey = "prStateFilterByRepo"

    private func savePRStateFilter() {
        var map = UserDefaults.standard.dictionary(forKey: Self.prStateFilterDefaultsKey) as? [String: String] ?? [:]
        if prStateFilter == .all {
            map.removeValue(forKey: repository.root.path)
        } else {
            map[repository.root.path] = prStateFilter.rawValue
        }
        UserDefaults.standard.set(map, forKey: Self.prStateFilterDefaultsKey)
    }

    private static func storedPRStateFilter(for root: URL) -> PRStateFilter {
        let map = UserDefaults.standard.dictionary(forKey: prStateFilterDefaultsKey) as? [String: String]
        return map?[root.path].flatMap(PRStateFilter.init(rawValue:)) ?? .all
    }

    var isPRFilterActive: Bool {
        prStateFilter != .all || !prSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var filteredPullRequests: [PullRequestSummary] {
        let query = prSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fold full-width digits (Japanese IME) so "１２３" parses as a number.
        let folded = query.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? query
        let numberQuery = Int(folded.hasPrefix("#") ? String(folded.dropFirst()) : folded)
        return pullRequests.filter { pr in
            guard prStateFilter.matches(pr, viewerLogin: prViewerLogin) else { return false }
            guard !query.isEmpty else { return true }
            if let numberQuery, pr.number == numberQuery { return true }
            return pr.title.localizedStandardContains(query)
                || pr.author.localizedStandardContains(query)
                || pr.headRefName.localizedStandardContains(query)
        }
    }
    var selectedPRNumber: Int? {
        didSet {
            if oldValue != selectedPRNumber {
                selectedPRItem = nil
                Task { await loadPRDetail() }
            }
        }
    }
    var prDetail: PullRequestDetail?
    var prDetailsCache: [Int: PullRequestDetail] = [:]
    var expandedPRs: Set<Int> = []
    var selectedPRItem: PRItemSelection? {
        didSet { if oldValue != selectedPRItem { Task { await loadPRItemDiffs() } } }
    }
    var prItemDiffs: [FileDiff] = []
    var prItemLoadError: String?
    /// Parsed `gh pr diff` output per PR, so switching between files of the
    /// same PR doesn't re-run gh each time.
    var prDiffsCache: [Int: [FileDiff]] = [:]

    /// Selects a commit/file row of a PR, switching the shown PR if needed.
    func selectPRItem(_ item: PRItemSelection, in number: Int) {
        selectedPRNumber = number
        selectedPRItem = item
    }

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
    @ObservationIgnored var prItemGeneration = 0
    @ObservationIgnored private var syncCount = 0
    @ObservationIgnored var pendingDiscardSnapshot: [FileDiff]?

    @ObservationIgnored private var watcher: RepoWatcher?

    init(repository: GitRepository) {
        self.repository = repository
        self.github = GitHubService(repoRoot: repository.root)
        self.codex = CodexAppServer()
        self.prStateFilter = Self.storedPRStateFilter(for: repository.root)
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
