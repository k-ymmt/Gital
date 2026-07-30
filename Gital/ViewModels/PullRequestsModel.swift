import Foundation
import Observation

/// Screen state and actions for the Pull Requests tab. Owns everything PR:
/// the gh-backed list/detail/diff caches, filtering, per-PR "Viewed" review
/// progress, and the merge action. Split out of RepoViewModel — the PR domain
/// talks only to GitHubService/PRViewedStore, plus the repository for commit
/// diffs of fetched PR heads.
@MainActor
@Observable
final class PullRequestsModel {
    /// A selected row inside a PR's sidebar expansion: one of its commits or
    /// one of its changed files.
    enum ItemSelection: Equatable, Hashable {
        case commit(hash: String)
        case file(path: String)
    }

    enum StateFilter: String, CaseIterable, Identifiable {
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

    private let repository: GitRepository
    private let github: GitHubService

    var pullRequests: [PullRequestSummary] = []
    var loadError: String?
    var searchText = ""
    /// Authenticated `gh` login, fetched alongside the PR list; nil until
    /// loaded (the "awaiting your review" filter matches nothing then).
    var viewerLogin: String?
    var stateFilter: StateFilter = .all {
        didSet { saveStateFilter() }
    }

    /// UserDefaults key for a `[repo path: StateFilter raw value]` map so
    /// each repository remembers its own filter across launches. Entries are
    /// removed when the filter returns to `.all` to keep the map from
    /// accumulating stale paths.
    private static let stateFilterDefaultsKey = "prStateFilterByRepo"

    private func saveStateFilter() {
        var map = UserDefaults.standard.dictionary(forKey: Self.stateFilterDefaultsKey) as? [String: String] ?? [:]
        if stateFilter == .all {
            map.removeValue(forKey: repository.root.path)
        } else {
            map[repository.root.path] = stateFilter.rawValue
        }
        UserDefaults.standard.set(map, forKey: Self.stateFilterDefaultsKey)
    }

    private static func storedStateFilter(for root: URL) -> StateFilter {
        let map = UserDefaults.standard.dictionary(forKey: stateFilterDefaultsKey) as? [String: String]
        return map?[root.path].flatMap(StateFilter.init(rawValue:)) ?? .all
    }

    var isFilterActive: Bool {
        stateFilter != .all || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var filtered: [PullRequestSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fold full-width digits (Japanese IME) so "１２３" parses as a number.
        let folded = query.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? query
        let numberQuery = Int(folded.hasPrefix("#") ? String(folded.dropFirst()) : folded)
        return pullRequests.filter { pr in
            guard stateFilter.matches(pr, viewerLogin: viewerLogin) else { return false }
            guard !query.isEmpty else { return true }
            if let numberQuery, pr.number == numberQuery { return true }
            return pr.title.localizedStandardContains(query)
                || pr.author.localizedStandardContains(query)
                || pr.headRefName.localizedStandardContains(query)
        }
    }

    var selectedNumber: Int? {
        didSet {
            if oldValue != selectedNumber {
                selectedItem = nil
                // The open comment composer must not carry over: another PR
                // can contain the same path/line anchor, where it would
                // resurface with the previous PR's half-typed text.
                closeReviewComposer()
                closeReply()
                // The previous PR's fetch failure must not show under the
                // newly selected one while its threads load.
                threadsLoadError = nil
                Task { await loadDetail() }
            }
        }
    }
    var detail: PullRequestDetail?
    var detailsCache: [Int: PullRequestDetail] = [:]
    var expanded: Set<Int> = []
    var selectedItem: ItemSelection? {
        didSet {
            if oldValue != selectedItem {
                // Different items number the same file differently (commit
                // diff vs whole-PR diff), so an open composer would resurface
                // under an unrelated line that shares its coordinates.
                closeReviewComposer()
                closeReply()
                Task { await loadItemDiffs() }
            }
        }
    }
    var itemDiffs: [FileDiff] = []
    var itemLoadError: String?
    /// Parsed `gh pr diff` output per PR, so switching between files of the
    /// same PR doesn't re-run gh each time.
    var diffsCache: [Int: [FileDiff]] = [:]

    @ObservationIgnored private let itemDiffsLoader = LatestLoader()
    /// In-flight whole-PR diff fetches by PR number: the prefetch fired on
    /// selection and a file click landing mid-fetch share one gh invocation.
    @ObservationIgnored private var diffFetchTasks: [Int: Task<Result<[FileDiff], Error>, Never>] = [:]
    /// When the PR list was last fetched; lets tab entry skip a re-fetch
    /// that just ran (repo open, a merge, a recent entry).
    @ObservationIgnored private var lastListRefresh: Date?

    init(repository: GitRepository, github: GitHubService) {
        self.repository = repository
        self.github = github
        self.stateFilter = Self.storedStateFilter(for: repository.root)
        loadViewedStates()
        let store = PendingReviewStore(repoRoot: repository.root)
        pendingReviewStore = store
        pendingComments = store.load()
    }

    /// Selects a commit/file row of a PR, switching the shown PR if needed.
    func selectItem(_ item: ItemSelection, in number: Int) {
        selectedNumber = number
        selectedItem = item
    }

    // MARK: - Merging

    /// PR number currently being merged, or nil; drives the merge button's
    /// spinner and guards against double-submission.
    var mergingNumber: Int?

    func merge(_ number: Int) {
        guard mergingNumber == nil else { return }
        mergingNumber = number
        Task {
            defer { mergingNumber = nil }
            do {
                try await github.merge(number: number)
                // Reload the detail directly — flipping selectedNumber
                // nil→back spawned two loads that both hit gh.
                detailsCache[number] = nil
                diffsCache[number] = nil
                await loadDetail()
                await refresh()
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    // MARK: - Loading

    /// Tab-entry refresh: the cached list stays on screen and re-fetches in
    /// place, at most once per `interval` — every switch to the tab would
    /// otherwise spawn gh against the network.
    func refreshIfStale(interval: TimeInterval = 60) async {
        if let last = lastListRefresh, Date.now.timeIntervalSince(last) < interval { return }
        await refresh()
    }

    func refresh() async {
        lastListRefresh = .now
        do {
            // Fetched once per repo session; a failure (offline, gh not
            // authenticated) is non-fatal — the "awaiting your review"
            // filter just matches nothing until the next refresh.
            async let viewerTask = viewerLogin == nil ? github.viewerLogin() : nil
            pullRequests = try await github.listPullRequests()
            loadError = nil
            if let login = try? await viewerTask, !login.isEmpty {
                viewerLogin = login
            }
        } catch {
            pullRequests = []
            loadError = error.localizedDescription
        }
    }

    /// The PR's parsed whole diff, from cache or via a single shared gh
    /// fetch. Failures are never cached — the next call simply retries.
    private func wholeDiff(for number: Int) async throws -> [FileDiff] {
        if let cached = diffsCache[number] { return cached }
        let task = diffFetchTasks[number] ?? Task { [github] in
            do {
                let raw = try await github.pullRequestDiff(number: number)
                return .success(DiffParser.parse(raw, scope: .snapshot))
            } catch {
                return .failure(error)
            }
        }
        diffFetchTasks[number] = task
        let result = await task.value
        // Guard the removal: another caller may have already replaced a
        // failed task with a fresh retry, which must not be knocked out.
        if diffFetchTasks[number] == task {
            diffFetchTasks[number] = nil
        }
        if case .success(let diffs) = result {
            diffsCache[number] = diffs
        }
        return try result.get()
    }

    /// Fire-and-forget warm-up of the whole diff so the first file click of
    /// a PR doesn't wait on gh. Errors stay silent here — the click retries
    /// through `loadItemDiffs`, which does report them.
    func prefetchDiff(_ number: Int) {
        Task { _ = try? await wholeDiff(for: number) }
    }

    func loadDetail() async {
        guard let number = selectedNumber else {
            detail = nil
            return
        }
        prefetchDiff(number)
        // Threads refresh on every detail load (they change on GitHub's side
        // at any time). Keyed by PR number, a stale load can never clobber
        // another PR's threads, so no supersede guard is needed.
        Task { await loadThreads(number) }
        if let cached = detailsCache[number] {
            detail = cached
            return
        }
        detail = nil
        do {
            let loaded = try await github.pullRequestDetail(number: number)
            detailsCache[number] = loaded
            if selectedNumber == number {
                detail = loaded
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func loadItemDiffs() async {
        guard let item = selectedItem, let number = selectedNumber else {
            itemDiffs = []
            itemLoadError = nil
            itemDiffsLoader.invalidate()
            return
        }
        itemDiffs = []
        itemLoadError = nil
        let result = await itemDiffsLoader.run { [repository] in
            switch item {
            case .commit(let hash):
                // PR commits live in the local object store once the remote
                // branch has been fetched. When the object is missing (fork
                // PRs, never-fetched branches), pull it in via the PR head
                // ref and retry once.
                do {
                    return try await repository.diffCommit(hash)
                } catch {
                    try await repository.fetchPullRequestHead(number: number)
                    return try await repository.diffCommit(hash)
                }
            case .file(let path):
                return try await self.wholeDiff(for: number).filter { $0.path == path }
            }
        }
        switch result {
        case .success(let diffs):
            itemDiffs = diffs
            if diffs.isEmpty {
                itemLoadError = "No changes found for this item."
            }
        case .failure(let error):
            switch item {
            case .commit:
                itemLoadError = "Could not load this commit, even after fetching the pull request from origin.\n\(error.localizedDescription)"
            case .file:
                itemLoadError = error.localizedDescription
            }
        case nil:
            break  // superseded by a newer selection
        }
    }

    func expand(_ number: Int) async {
        if expanded.contains(number) {
            expanded.remove(number)
            return
        }
        expanded.insert(number)
        prefetchDiff(number)
        if detailsCache[number] == nil {
            do {
                detailsCache[number] = try await github.pullRequestDetail(number: number)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }

    // MARK: - Review

    /// Draft review comments per PR number. Like a GitHub pending review,
    /// they stay in the draft state until submitted all together with a
    /// verdict via `submitReview`; unlike GitHub's they live locally,
    /// persisted per repo by `PendingReviewStore`.
    var pendingComments: [Int: [PendingReviewComment]] = [:]
    @ObservationIgnored private var pendingReviewStore: PendingReviewStore?
    /// Anchor the review comment composer is currently open at, nil when
    /// closed. Owned by the model so the composer survives LazyVStack row
    /// recycling while the user scrolls.
    var reviewComposerAnchor: ReviewCommentAnchor?
    /// Content of the anchored diff line, captured when the composer opens;
    /// stored on the draft for display matching and submit-time re-anchoring.
    var reviewComposerLineText = ""
    var reviewComposerText = ""
    /// Save-time validation failure shown inside the composer.
    var reviewComposerError: String?
    /// When set, the composer is editing this existing draft instead of
    /// adding a new one.
    var editingCommentID: UUID?
    var isSubmittingReview = false
    var reviewSubmitError: String?

    func pendingComments(for number: Int) -> [PendingReviewComment] {
        pendingComments[number] ?? []
    }

    func pendingComments(on line: DiffLine, path: String, in number: Int) -> [PendingReviewComment] {
        pendingComments(for: number).filter { $0.isAnchored(to: line, path: path) }
    }

    func openReviewComposer(at anchor: ReviewCommentAnchor, lineText: String) {
        if reviewComposerAnchor == anchor && editingCommentID == nil { return }
        // Unsaved new-comment text travels to the new anchor instead of
        // being silently discarded; an edit in progress is dropped — its
        // draft still holds the saved body.
        if editingCommentID != nil {
            reviewComposerText = ""
        }
        editingCommentID = nil
        reviewComposerAnchor = anchor
        reviewComposerLineText = lineText
        reviewComposerError = nil
    }

    func editComment(_ comment: PendingReviewComment) {
        reviewComposerAnchor = comment.anchor
        reviewComposerLineText = comment.lineText
        reviewComposerText = comment.body
        reviewComposerError = nil
        editingCommentID = comment.id
    }

    func closeReviewComposer() {
        reviewComposerAnchor = nil
        reviewComposerLineText = ""
        reviewComposerText = ""
        reviewComposerError = nil
        editingCommentID = nil
    }

    /// Saves the composer's text as a new draft comment, or into the draft
    /// being edited; empty text is ignored (the UI disables the button).
    /// When the whole-PR diff is already cached, the anchor is validated
    /// against it up front so a comment GitHub could never accept (a
    /// commit-diff line missing from the PR's final diff) fails here, with
    /// the composer still open, instead of poisoning the submission later.
    func saveComposerComment(in number: Int) {
        guard let anchor = reviewComposerAnchor else { return }
        let body = reviewComposerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        var comments = pendingComments(for: number)
        if let id = editingCommentID, let index = comments.firstIndex(where: { $0.id == id }) {
            comments[index].body = body
        } else {
            let comment = PendingReviewComment(anchor: anchor, lineText: reviewComposerLineText, body: body)
            if let diffs = diffsCache[number], comment.resolvedAnchor(in: diffs) == nil {
                reviewComposerError = "This line isn't part of the pull request's final diff, so GitHub can't accept a comment here."
                return
            }
            comments.append(comment)
        }
        setPendingComments(comments, for: number)
        closeReviewComposer()
    }

    func deleteComment(_ id: UUID, in number: Int) {
        var comments = pendingComments(for: number)
        comments.removeAll { $0.id == id }
        setPendingComments(comments, for: number)
        if editingCommentID == id {
            closeReviewComposer()
        }
    }

    private func setPendingComments(_ comments: [PendingReviewComment], for number: Int) {
        pendingComments[number] = comments.isEmpty ? nil : comments
        pendingReviewStore?.save(pendingComments)
    }

    /// Submits the pending review: verdict, summary body, and all draft
    /// comments go to GitHub in one call. Every draft is first resolved
    /// against a freshly fetched whole-PR diff — GitHub interprets comment
    /// coordinates against that diff, while drafts may carry an individual
    /// commit's numbering or predate newly pushed commits. Returns true on
    /// success; the submitted drafts are cleared (only those — a comment
    /// added while the call was in flight was not sent and must survive)
    /// and the detail reloads so the reviewer list updates.
    func submitReview(_ event: ReviewEvent, body: String, for number: Int) async -> Bool {
        guard !isSubmittingReview else { return false }
        isSubmittingReview = true
        reviewSubmitError = nil
        defer { isSubmittingReview = false }
        let drafts = pendingComments(for: number)
        do {
            var resolved: [PendingReviewComment] = []
            if !drafts.isEmpty {
                diffsCache[number] = nil
                let diffs = try await wholeDiff(for: number)
                for draft in drafts {
                    guard let anchor = draft.resolvedAnchor(in: diffs) else {
                        reviewSubmitError = "The draft on \(draft.anchor.path) line \(draft.anchor.line) no longer matches the pull request diff (the code changed since it was written). Edit or delete that comment, then submit again."
                        return false
                    }
                    resolved.append(PendingReviewComment(id: draft.id, anchor: anchor, lineText: draft.lineText, body: draft.body))
                }
            }
            try await github.submitReview(number: number, event: event, body: body, comments: resolved)
            let sentIDs = Set(drafts.map(\.id))
            setPendingComments(pendingComments(for: number).filter { !sentIDs.contains($0.id) }, for: number)
            detailsCache[number] = nil
            if selectedNumber == number {
                await loadDetail()
            } else {
                // loadDetail refreshes threads itself; off-selection the
                // submitted drafts still just became published threads.
                await loadThreads(number)
            }
            return true
        } catch {
            reviewSubmitError = error.localizedDescription
            return false
        }
    }

    // MARK: - Conversations

    /// Published review threads per PR number, fetched from GitHub alongside
    /// the detail. Unlike `pendingComments` these already live on GitHub;
    /// the app shows them inline, replies, and resolves them.
    var reviewThreads: [Int: [ReviewThread]] = [:]
    /// Threads-fetch failure for the selected PR, shown in the overview's
    /// Conversations section (non-fatal — the rest of the PR still works).
    var threadsLoadError: String?
    /// Thread the reply composer is open under, nil when closed. Model-owned
    /// so the composer survives LazyVStack row recycling, like the review
    /// composer.
    var replyingThreadID: String?
    var replyText = ""
    var isSendingReply = false
    /// Threads with an in-flight resolve/unresolve; drives per-thread
    /// spinners and guards double-submission.
    var resolvingThreadIDs: Set<String> = []
    /// Per-thread action failures (reply/resolve), shown inside the card.
    var threadErrors: [String: String] = [:]
    /// Resolved threads collapse to one row; this records the ones the user
    /// expanded back open. Model-owned to survive row recycling.
    var expandedThreadIDs: Set<String> = []

    func threads(for number: Int) -> [ReviewThread] {
        reviewThreads[number] ?? []
    }

    func threads(on line: DiffLine, path: String, in number: Int) -> [ReviewThread] {
        threads(for: number).filter { $0.isAnchored(to: line, path: path) }
    }

    func loadThreads(_ number: Int) async {
        do {
            let threads = try await github.reviewThreads(number: number)
            reviewThreads[number] = threads
            if selectedNumber == number {
                threadsLoadError = nil
            }
        } catch {
            // Stale threads stay on screen; the error only surfaces for the
            // PR being looked at.
            if selectedNumber == number {
                threadsLoadError = error.localizedDescription
            }
        }
    }

    func openReply(for thread: ReviewThread) {
        guard replyingThreadID != thread.id else { return }
        // Unsaved text travels to the other thread instead of being silently
        // discarded, mirroring the review composer.
        replyingThreadID = thread.id
        threadErrors[thread.id] = nil
    }

    func closeReply() {
        replyingThreadID = nil
        replyText = ""
    }

    func sendReply(to thread: ReviewThread, in number: Int) async {
        guard !isSendingReply else { return }
        let body = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let rootID = thread.comments.first?.id else { return }
        isSendingReply = true
        threadErrors[thread.id] = nil
        defer { isSendingReply = false }
        do {
            try await github.replyToReviewComment(number: number, commentID: rootID, body: body)
            closeReply()
            await loadThreads(number)
        } catch {
            threadErrors[thread.id] = error.localizedDescription
        }
    }

    func setThreadResolved(_ thread: ReviewThread, resolved: Bool, in number: Int) async {
        guard !resolvingThreadIDs.contains(thread.id) else { return }
        resolvingThreadIDs.insert(thread.id)
        threadErrors[thread.id] = nil
        defer { resolvingThreadIDs.remove(thread.id) }
        do {
            try await github.setThreadResolved(thread.id, resolved: resolved)
            // A freshly resolved thread collapses; expanding it again is a
            // deliberate act, so drop any stale expansion.
            expandedThreadIDs.remove(thread.id)
            await loadThreads(number)
        } catch {
            threadErrors[thread.id] = error.localizedDescription
        }
    }

    // MARK: - "Viewed" flags

    /// Review-progress flags per PR number, persisted across launches.
    var viewedStates: [Int: PRViewedState] = [:]
    @ObservationIgnored private var viewedStore: PRViewedStore?

    func isFileViewed(_ path: String, in number: Int) -> Bool {
        viewedStates[number]?.files.contains(path) == true
    }

    func isCommitViewed(_ hash: String, in number: Int) -> Bool {
        viewedStates[number]?.isCommitViewed(hash) == true
    }

    func isCommitFileViewed(commit: String, path: String, in number: Int) -> Bool {
        viewedStates[number]?.isCommitFileViewed(commit: commit, path: path) == true
    }

    func toggleFileViewed(_ path: String, in number: Int) {
        mutateViewed(number) { $0.toggleFile(path) }
    }

    func toggleCommitViewed(_ hash: String, in number: Int) {
        mutateViewed(number) { state in
            state.setCommitViewed(!state.isCommitViewed(hash), hash: hash)
        }
    }

    /// Toggles one file inside a commit's diff. `allPaths` is the commit's
    /// complete file list (the caller has the loaded diff), so viewing the
    /// last file promotes the whole commit to viewed.
    func toggleCommitFileViewed(commit: String, path: String, allPaths: [String], in number: Int) {
        mutateViewed(number) { $0.toggleCommitFile(commit: commit, path: path, allPaths: allPaths) }
    }

    private func mutateViewed(_ number: Int, _ mutate: (inout PRViewedState) -> Void) {
        let old = viewedStates[number] ?? PRViewedState()
        var state = old
        mutate(&state)
        viewedStates[number] = state.isEmpty ? nil : state
        viewedStore?.apply(from: old, to: state, for: number)
    }

    private func loadViewedStates() {
        let store = PRViewedStore(repoRoot: repository.root)
        viewedStore = store
        viewedStates = store.load()
    }
}
