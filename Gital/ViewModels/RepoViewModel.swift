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
    private static let logPageSize = 400
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

    // MARK: - Loading

    func refreshAll() async {
        async let statusTask: () = refreshStatus()
        async let logTask: () = refreshLog()
        async let refsTask: () = refreshRefs()
        _ = await (statusTask, logTask, refsTask)

        if selectedCommitHash == nil {
            selectedCommitHash = commits.first?.hash
        }
        Task { await refreshPullRequests() }
    }

    func refreshStatus() async {
        do {
            status = try await repository.status()
        } catch {
            report(error)
        }
    }

    func refreshLog() async {
        do {
            // Re-fetch at least as many commits as are already loaded so a
            // refresh (fetch/pull/commit) doesn't collapse the paged-in history.
            let limit = max(Self.logPageSize, commits.count)
            let loaded = try await repository.log(limit: limit)
            commits = loaded
            hasMoreCommits = loaded.count >= limit
            graph = CommitGraph(commits: commits)
        } catch {
            report(error)
        }
    }

    func loadMoreCommits() async {
        guard hasMoreCommits, !isLoadingMoreCommits, !commits.isEmpty else { return }
        isLoadingMoreCommits = true
        defer { isLoadingMoreCommits = false }
        do {
            let page = try await repository.log(limit: Self.logPageSize, skip: commits.count)
            hasMoreCommits = page.count >= Self.logPageSize
            let known = Set(commits.map(\.hash))
            commits.append(contentsOf: page.filter { !known.contains($0.hash) })
            graph = CommitGraph(commits: commits)
        } catch {
            report(error)
        }
    }

    func refreshRefs() async {
        do {
            async let branchesTask = repository.branches()
            async let remotesTask = repository.remotes()
            async let tagsTask = repository.tags()
            async let stashesTask = repository.stashes()
            branches = try await branchesTask
            remotes = try await remotesTask
            tags = try await tagsTask
            stashes = try await stashesTask
        } catch {
            report(error)
        }
    }

    func refreshPullRequests() async {
        do {
            pullRequests = try await github.listPullRequests()
            prLoadError = nil
        } catch {
            pullRequests = []
            prLoadError = error.localizedDescription
        }
    }

    private func loadCommitDetail() async {
        guard let hash = selectedCommitHash else {
            commitFiles = []
            commitDiffs = []
            return
        }
        do {
            async let filesTask = repository.commitFileStats(hash)
            async let diffsTask = repository.diffCommit(hash)
            commitFiles = try await filesTask
            commitDiffs = try await diffsTask
            if let selected = selectedCommitFilePath,
               commitFiles.contains(where: { $0.path == selected }) == false {
                selectedCommitFilePath = commitFiles.first?.path
            } else if selectedCommitFilePath == nil {
                selectedCommitFilePath = commitFiles.first?.path
            }
        } catch {
            report(error)
        }
    }

    func loadWorkingDiffs() async {
        do {
            if let path = selectedChangePath {
                let isStaged = status.staged.contains { $0.path == path }
                let change = (status.staged + status.unstaged).first { $0.path == path }
                if change?.status == .untracked {
                    workingDiffs = (try? await repository.diffUntracked(path: path)) ?? []
                } else {
                    workingDiffs = try await repository.diffWorking(staged: isStaged, path: path)
                }
            } else {
                var diffs = try await repository.diffWorking(staged: false)
                let stagedDiffs = try await repository.diffWorking(staged: true)
                for diff in stagedDiffs where !diffs.contains(where: { $0.path == diff.path }) {
                    diffs.append(diff)
                }
                // Untracked files never appear in `git diff`; show them as
                // all-additions like Fork does.
                for change in status.unstaged where change.status == .untracked {
                    guard !diffs.contains(where: { $0.path == change.path }),
                          let untracked = try? await repository.diffUntracked(path: change.path) else { continue }
                    diffs.append(contentsOf: untracked)
                }
                workingDiffs = diffs
            }
        } catch {
            report(error)
        }
    }

    private func loadStashDiff() async {
        guard let ref = selectedStashRef,
              let stash = stashes.first(where: { $0.reference == ref }) else {
            stashDiffs = []
            return
        }
        do {
            stashDiffs = try await repository.stashDiff(stash)
        } catch {
            report(error)
        }
    }

    private func loadPRDetail() async {
        guard let number = selectedPRNumber else {
            prDetail = nil
            return
        }
        if let cached = prDetailsCache[number] {
            prDetail = cached
            return
        }
        prDetail = nil
        do {
            let detail = try await github.pullRequestDetail(number: number)
            prDetailsCache[number] = detail
            if selectedPRNumber == number {
                prDetail = detail
            }
        } catch {
            prLoadError = error.localizedDescription
        }
    }

    func expandPR(_ number: Int) async {
        if expandedPRs.contains(number) {
            expandedPRs.remove(number)
            return
        }
        expandedPRs.insert(number)
        if prDetailsCache[number] == nil {
            do {
                prDetailsCache[number] = try await github.pullRequestDetail(number: number)
            } catch {
                prLoadError = error.localizedDescription
            }
        }
    }

    // MARK: - Staging / committing

    func stage(_ change: FileChange) {
        Task {
            do {
                try await repository.stage([change.path])
                await refreshStatus()
                await loadWorkingDiffs()
            } catch { report(error) }
        }
    }

    func unstage(_ change: FileChange) {
        Task {
            do {
                try await repository.unstage([change.path])
                await refreshStatus()
                await loadWorkingDiffs()
            } catch { report(error) }
        }
    }

    func stageAll() {
        Task {
            do {
                try await repository.stageAll()
                await refreshStatus()
                await loadWorkingDiffs()
            } catch { report(error) }
        }
    }

    func unstageAll() {
        Task {
            do {
                try await repository.unstageAll()
                await refreshStatus()
                await loadWorkingDiffs()
            } catch { report(error) }
        }
    }

    func commit() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || amend else { return }
        isCommitting = true
        Task {
            defer { isCommitting = false }
            do {
                try await repository.commit(message: message, amend: amend)
                commitMessage = ""
                amend = false
                await refreshAll()
            } catch { report(error) }
        }
    }

    var canCommit: Bool {
        !status.staged.isEmpty && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isCommitting
    }

    // MARK: - Sync operations

    func fetch() { runSync("Fetching…") { try await $0.repository.fetch() } }
    func pull() { runSync("Pulling…") { try await $0.repository.pull() } }
    func push() { runSync("Pushing…") { try await $0.repository.push() } }

    private func runSync(_ activity: String, _ operation: @escaping (RepoViewModel) async throws -> Void) {
        guard !isSyncing else { return }
        isSyncing = true
        syncActivity = activity
        Task {
            defer {
                isSyncing = false
                syncActivity = nil
            }
            do {
                try await operation(self)
                await refreshAll()
            } catch { report(error) }
        }
    }

    // MARK: - Branch / stash operations

    func selectBranch(_ branch: Branch) {
        selectedTagName = nil
        selectedBranchName = branch.name
        selectedCommitHash = branch.tipHash
    }

    func selectTag(_ tag: Tag) {
        selectedBranchName = nil
        selectedTagName = tag.name
        selectedCommitHash = tag.tipHash
    }

    func checkout(branch: Branch) {
        guard !branch.isCurrent else { return }
        Task {
            do {
                try await repository.checkout(branch: branch.name)
                await refreshAll()
            } catch { report(error) }
        }
    }

    func createBranch(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                try await repository.createBranch(name: trimmed, checkout: true)
                await refreshAll()
            } catch { report(error) }
        }
    }

    func stashPush(message: String) {
        Task {
            do {
                try await repository.stashPush(message: message)
                await refreshAll()
            } catch { report(error) }
        }
    }

    func stashApply(_ stash: Stash, pop: Bool) {
        Task {
            do {
                try await repository.stashApply(stash, pop: pop)
                if pop, selectedStashRef == stash.reference {
                    selectedStashRef = nil
                }
                await refreshAll()
            } catch { report(error) }
        }
    }

    func stashDrop(_ stash: Stash) {
        Task {
            do {
                try await repository.stashDrop(stash)
                if selectedStashRef == stash.reference {
                    selectedStashRef = nil
                }
                await refreshAll()
            } catch { report(error) }
        }
    }

    // MARK: - AI Agent

    func openComposer(file: String, line: Int, anchorID: String) {
        composerFile = file
        composerRange = line...line
        composerAnchorID = anchorID
    }

    func extendComposer(file: String, line: Int, anchorID: String) {
        guard composerFile == file, let range = composerRange else {
            openComposer(file: file, line: line, anchorID: anchorID)
            return
        }
        // The composer stays anchored to the last-picked line.
        composerRange = min(range.lowerBound, line)...max(range.upperBound, line)
        composerAnchorID = anchorID
    }

    func cancelComposer() {
        composerFile = nil
        composerRange = nil
        composerAnchorID = nil
        agentDraft = ""
    }

    func sendToAgent() {
        guard let file = composerFile, let range = composerRange, let anchorID = composerAnchorID else { return }
        let instruction = agentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }

        let thread = AgentThread(filePath: file, lineRange: range, anchorLineID: anchorID)
        thread.messages.append(AgentMessage(role: .user, text: instruction))
        thread.isRunning = true
        thread.statusText = "Waiting for Codex…"
        agentThreads.append(thread)
        cancelComposer()

        let contextLines = diffContext(file: file, range: range)
        let prompt = """
        You are assisting inside the Gital git client. The user selected lines \
        \(range.lowerBound)-\(range.upperBound) of `\(file)` in their working-copy diff and asked:

        \(instruction)

        Relevant diff context:
        ```
        \(contextLines)
        ```

        Apply the requested change directly to the file(s) in this repository. \
        Keep the change minimal and focused on the selected lines. \
        When done, summarize what you changed in 1-3 sentences.
        """

        Task {
            await runAgentTurn(thread: thread, prompt: prompt)
        }
    }

    func reply(to thread: AgentThread, text: String) {
        let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !thread.isRunning else { return }
        thread.messages.append(AgentMessage(role: .user, text: instruction))
        thread.isRunning = true
        thread.statusText = "Waiting for Codex…"
        Task {
            await runAgentTurn(thread: thread, prompt: instruction)
        }
    }

    private func runAgentTurn(thread: AgentThread, prompt: String) async {
        var agentMessage = AgentMessage(role: .agent, text: "")
        var appended = false

        do {
            for try await event in await codex.runTurn(prompt: prompt, repoRoot: repository.root) {
                switch event {
                case .status(let text):
                    thread.statusText = text
                case .delta(let delta):
                    thread.statusText = nil
                    agentMessage.text += delta
                    if appended {
                        thread.messages[thread.messages.count - 1] = agentMessage
                    } else {
                        thread.messages.append(agentMessage)
                        appended = true
                    }
                case .completed(let text):
                    if !text.isEmpty {
                        agentMessage.text = text
                        if appended {
                            thread.messages[thread.messages.count - 1] = agentMessage
                        } else {
                            thread.messages.append(agentMessage)
                            appended = true
                        }
                    }
                }
            }
        } catch {
            thread.messages.append(AgentMessage(role: .agent, text: "⚠️ \(error.localizedDescription)"))
        }

        thread.isRunning = false
        thread.statusText = nil
        await refreshStatus()
        await loadWorkingDiffs()
    }

    private func diffContext(file: String, range: ClosedRange<Int>) -> String {
        guard let diff = workingDiffs.first(where: { $0.path == file }) else { return "" }
        var lines: [String] = []
        for hunk in diff.hunks {
            let relevant = hunk.lines.contains { line in
                let number = line.newNumber ?? line.oldNumber ?? 0
                return range.contains(number)
            }
            guard relevant else { continue }
            lines.append(hunk.header)
            for line in hunk.lines {
                lines.append(line.sign + line.text)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Errors

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
    }
}
