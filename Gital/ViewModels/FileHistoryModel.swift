import Foundation
import Observation

/// State for the file-history sheet: the commits touching one file (renames
/// followed), the selected commit's diff of that file, and its blame.
/// Snapshot semantics on purpose — the sheet is modal and does not chase the
/// repository while open.
@MainActor
@Observable
final class FileHistoryModel: Identifiable {
    enum Tab: String, CaseIterable, Identifiable {
        case history = "History"
        case blame = "Blame"

        var id: String { rawValue }
    }

    private static let pageSize = 400

    let repository: GitRepository
    /// Path of the file as of `startHash` (or the working copy when nil).
    let path: String
    /// Commit the history walk starts from; nil = HEAD.
    let startHash: String?

    var tab: Tab
    var entries: [FileHistoryEntry] = []
    var hasMore = false
    var isLoadingEntries = false
    /// The last entry load failed — the empty state must say so instead of
    /// claiming "no commits touch this file".
    var entriesLoadFailed = false
    var errorMessage: String?

    var selectedHash: String? {
        didSet { if oldValue != selectedHash { Task { await loadDiff() } } }
    }
    var diffs: [FileDiff] = []

    var blame: BlameFile?
    var isLoadingBlame = false
    /// Key of the blame currently held/being loaded (selection hash, or ""
    /// for the working tree) — the view re-triggers loading when it drifts
    /// from the selection, and failure/cancellation clears it so the same
    /// target can be retried.
    var loadedBlameKey: String?

    /// Re-walk limit; growing it and re-running is how "Load More" works.
    /// Offset paging (`--skip`) is not reliable under `--follow`'s rename
    /// tracking, and a re-walk of a single file's history is cheap.
    private var limit = FileHistoryModel.pageSize

    /// Set by `close()`: the sheet is gone, so loads must neither start nor
    /// keep paging.
    private var isClosed = false

    /// Whether the file was on disk when the sheet opened. Captured once —
    /// computing it per access would stat() during body evaluation and make
    /// the blame target flip on external deletes mid-session.
    @ObservationIgnored private let worktreeFileExists: Bool

    @ObservationIgnored private let entriesLoader = LatestLoader()
    @ObservationIgnored private let diffLoader = LatestLoader()
    @ObservationIgnored private let blameLoader = LatestLoader()

    init(repository: GitRepository, path: String, startHash: String?, tab: Tab = .history) {
        self.repository = repository
        self.path = path
        self.startHash = startHash
        self.tab = tab
        self.worktreeFileExists = FileManager.default
            .fileExists(atPath: repository.root.appendingPathComponent(path).path)
    }

    /// Cancels all in-flight git work. Called when the sheet is dismissed —
    /// the loads would otherwise run to completion on the serialized
    /// executor, delaying the main window's next refresh behind them.
    func close() {
        isClosed = true
        entriesLoader.invalidate()
        diffLoader.invalidate()
        blameLoader.invalidate()
    }

    var selectedEntry: FileHistoryEntry? {
        entries.first { $0.hash == selectedHash }
    }

    /// Whether blame should target the working tree instead of a commit:
    /// opened from the working copy with the newest commit still selected —
    /// and the file actually on disk (blaming a deleted file's worktree copy
    /// can only error; its last commit still blames fine).
    private var blamesWorkingTree: Bool {
        startHash == nil && selectedHash == entries.first?.hash && worktreeFileExists
    }

    /// Key describing what blame should currently show; "" = working tree.
    var blameTargetKey: String? {
        guard selectedHash != nil else { return nil }
        return blamesWorkingTree ? "" : selectedHash
    }

    func load() async {
        guard !isClosed else { return }
        isLoadingEntries = true
        defer { isLoadingEntries = false }
        let limit = self.limit
        let result = await entriesLoader.run { [repository, path, startHash] in
            try await repository.fileHistory(path: path, startHash: startHash, limit: limit)
        }
        switch result {
        case .success(let loaded):
            entriesLoadFailed = false
            entries = loaded
            hasMore = loaded.count >= limit
            if selectedHash == nil || !entries.contains(where: { $0.hash == selectedHash }) {
                selectedHash = entries.first?.hash
            }
        case .failure(let error):
            entriesLoadFailed = true
            errorMessage = error.localizedDescription
        case nil:
            break
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingEntries else { return }
        limit += Self.pageSize
        await load()
    }

    private func loadDiff() async {
        guard !isClosed, let entry = selectedEntry else {
            diffs = []
            diffLoader.invalidate()
            return
        }
        let result = await diffLoader.run { [repository] in
            try await repository.diffCommit(entry.hash, path: entry.path, renamedFrom: entry.previousPath)
        }
        switch result {
        case .success(let loaded):
            // The rename pathspec covers both names, and the old one can
            // match an unrelated file recreated in the same commit — keep
            // only the entry's own diff, never "whatever came first".
            diffs = loaded.first { $0.path == entry.path }.map { [$0] } ?? loaded
        case .failure(let error):
            // Cleared, not kept: the pane header already names the new
            // selection, and stale hunks under it would masquerade as its
            // content.
            diffs = []
            errorMessage = error.localizedDescription
        case nil:
            break
        }
    }

    /// Loads blame for the current selection when not already shown; the view
    /// calls this whenever the blame tab is visible and the target changes.
    func loadBlameIfNeeded() async {
        guard !isClosed, let key = blameTargetKey, key != loadedBlameKey,
              let entry = selectedEntry else { return }
        loadedBlameKey = key
        isLoadingBlame = true
        // The previous target's annotations must not sit under the new
        // target's header while the load runs.
        blame = nil
        // Working-tree blame uses the sheet's opening path: the on-disk file,
        // not the (identical) path recorded at the newest commit.
        let result = await blameLoader.run { [repository, path] in
            if key.isEmpty {
                return try await repository.blame(path: path, at: nil)
            }
            if entry.status == .deleted {
                // The file has no content at the deleting commit itself;
                // blame its last version, at the first parent.
                return try await repository.blame(path: entry.previousPath ?? entry.path, at: "\(entry.hash)^")
            }
            return try await repository.blame(path: entry.path, at: entry.hash)
        }
        switch result {
        case .success(let loaded):
            blame = loaded
            isLoadingBlame = false
        case .failure(let error):
            loadedBlameKey = nil
            isLoadingBlame = false
            errorMessage = error.localizedDescription
        case nil:
            // Superseded or cancelled. A newer call owns the flags now —
            // unless the key is still ours (the view's task was cancelled by
            // a tab switch): clear it so returning to the tab retries, and
            // don't leave a dead spinner behind.
            if loadedBlameKey == key {
                loadedBlameKey = nil
                isLoadingBlame = false
            }
        }
    }

    /// Retry hook for the blame pane's failure placeholder.
    func reloadBlame() {
        loadedBlameKey = nil
        Task { await loadBlameIfNeeded() }
    }

    /// Annotation click: jump to that commit's entry in the History tab.
    /// Blame sees the file's whole history, so the commit can lie beyond the
    /// pages loaded so far — keep paging until it shows up.
    func revealCommit(_ hash: String) {
        tab = .history
        if entries.contains(where: { $0.hash == hash }) {
            selectedHash = hash
            return
        }
        Task {
            while !isClosed, hasMore, !isLoadingEntries,
                  !entries.contains(where: { $0.hash == hash }) {
                await loadMore()
            }
            if entries.contains(where: { $0.hash == hash }) {
                selectedHash = hash
            }
        }
    }
}

// MARK: - Opening from the repo view model

extension RepoViewModel {
    func showFileHistory(path: String, at hash: String? = nil, tab: FileHistoryModel.Tab = .history) {
        fileHistory = FileHistoryModel(repository: repository, path: path, startHash: hash, tab: tab)
    }
}
