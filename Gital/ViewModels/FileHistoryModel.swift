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
    var errorMessage: String?

    var selectedHash: String? {
        didSet { if oldValue != selectedHash { Task { await loadDiff() } } }
    }
    var diffs: [FileDiff] = []

    var blame: BlameFile?
    var isLoadingBlame = false
    /// Key of the blame currently held/being loaded (selection hash, or ""
    /// for the working tree) — the view re-triggers loading when it drifts
    /// from the selection.
    var loadedBlameKey: String?

    /// Re-walk limit; growing it and re-running is how "Load More" works.
    /// Offset paging (`--skip`) is not reliable under `--follow`'s rename
    /// tracking, and a re-walk of a single file's history is cheap.
    private var limit = FileHistoryModel.pageSize

    @ObservationIgnored private let diffLoader = LatestLoader()
    @ObservationIgnored private let blameLoader = LatestLoader()

    init(repository: GitRepository, path: String, startHash: String?, tab: Tab = .history) {
        self.repository = repository
        self.path = path
        self.startHash = startHash
        self.tab = tab
    }

    var selectedEntry: FileHistoryEntry? {
        entries.first { $0.hash == selectedHash }
    }

    /// Whether blame should target the working tree instead of a commit:
    /// opened from the working copy with the newest commit still selected —
    /// and the file actually on disk (blaming a deleted file's worktree copy
    /// can only error; its last commit still blames fine).
    private var blamesWorkingTree: Bool {
        guard startHash == nil, selectedHash == entries.first?.hash else { return false }
        return FileManager.default.fileExists(atPath: repository.root.appendingPathComponent(path).path)
    }

    /// Key describing what blame should currently show; "" = working tree.
    var blameTargetKey: String? {
        guard selectedHash != nil else { return nil }
        return blamesWorkingTree ? "" : selectedHash
    }

    func load() async {
        isLoadingEntries = true
        defer { isLoadingEntries = false }
        do {
            let loaded = try await repository.fileHistory(path: path, startHash: startHash, limit: limit)
            entries = loaded
            hasMore = loaded.count >= limit
            if selectedHash == nil || !entries.contains(where: { $0.hash == selectedHash }) {
                selectedHash = entries.first?.hash
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingEntries else { return }
        limit += Self.pageSize
        await load()
    }

    private func loadDiff() async {
        guard let entry = selectedEntry else {
            diffs = []
            diffLoader.invalidate()
            return
        }
        let result = await diffLoader.run { [repository] in
            try await repository.diffCommit(entry.hash, path: entry.path, renamedFrom: entry.previousPath)
        }
        switch result {
        case .success(let loaded):
            diffs = loaded
        case .failure(let error):
            errorMessage = error.localizedDescription
        case nil:
            break
        }
    }

    /// Loads blame for the current selection when not already shown; the view
    /// calls this whenever the blame tab is visible and the target changes.
    func loadBlameIfNeeded() async {
        guard let key = blameTargetKey, key != loadedBlameKey, let entry = selectedEntry else { return }
        loadedBlameKey = key
        isLoadingBlame = true
        defer { isLoadingBlame = false }
        // Working-tree blame uses the sheet's opening path: the on-disk file,
        // not the (identical) path recorded at the newest commit.
        let result = await blameLoader.run { [repository, path] in
            key.isEmpty
                ? try await repository.blame(path: path, at: nil)
                : try await repository.blame(path: entry.path, at: entry.hash)
        }
        switch result {
        case .success(let loaded):
            blame = loaded
        case .failure(let error):
            blame = nil
            loadedBlameKey = nil
            errorMessage = error.localizedDescription
        case nil:
            break
        }
    }

    /// Annotation click: jump to that commit's entry in the History tab.
    func revealCommit(_ hash: String) {
        guard entries.contains(where: { $0.hash == hash }) else { return }
        tab = .history
        selectedHash = hash
    }
}

// MARK: - Opening from the repo view model

extension RepoViewModel {
    func showFileHistory(path: String, at hash: String? = nil, tab: FileHistoryModel.Tab = .history) {
        fileHistory = FileHistoryModel(repository: repository, path: path, startHash: hash, tab: tab)
    }
}
