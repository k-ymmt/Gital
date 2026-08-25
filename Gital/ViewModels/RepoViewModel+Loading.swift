import Foundation

// MARK: - Loading repository data

extension RepoViewModel {
    private static let logPageSize = 400

    func refreshAll() async {
        async let statusTask: () = refreshStatus()
        async let logTask: () = refreshLog()
        async let refsTask: () = refreshRefs()
        _ = await (statusTask, logTask, refsTask)
        // The working diff is part of "all": after a checkout/pull/commit the
        // previous branch's diff would otherwise linger until FSEvents fires.
        await loadWorkingDiffs()

        if selectedCommitHash == nil {
            selectedCommitHash = commits.first?.hash
        }
        Task { await prs.refresh() }
    }

    func refreshStatus() async {
        // Independent do/catch blocks: a failing operation probe must not
        // leave `status` unrefreshed, nor vice versa — a half-updated pair
        // shows conflicted rows with a stale (or missing) banner.
        do {
            status = try await repository.status()
        } catch {
            report(error)
        }
        do {
            pendingOperation = try await repository.pendingOperation()
        } catch {
            report(error)
        }
    }

    func refreshLog() async {
        // Re-fetch at least as many commits as are already loaded so a
        // refresh (fetch/pull/commit) doesn't collapse the paged-in history.
        let limit = max(Self.logPageSize, commits.count)
        // Graph layout is O(commits × lanes) — computed inside the
        // supersedable load, off the main thread, so a 10k-commit refresh
        // doesn't stall the UI (and a superseded layout is just dropped).
        switch await logLoader.run({ [repository] in
            let loaded = try await repository.log(limit: limit)
            let graph = await Task.detached { CommitGraph(commits: loaded) }.value
            return (loaded, graph)
        }) {
        case .success(let (loaded, graph)):
            commits = loaded
            hasMoreCommits = loaded.count >= limit
            self.graph = graph
        case .failure(let error):
            report(error)
        case nil:
            break
        }
    }

    func loadMoreCommits() async {
        guard hasMoreCommits, !isLoadingMoreCommits, !commits.isEmpty else { return }
        isLoadingMoreCommits = true
        defer { isLoadingMoreCommits = false }
        var skip = commits.count
        // A page can dedupe to nothing (history rewritten between pages):
        // keep advancing the offset until something new lands or the log
        // runs out. The view's trigger is keyed on the commit count, which
        // an all-duplicate page leaves unchanged — returning without
        // progress would strand the spinner row forever.
        while true {
            // Shares logLoader with refreshLog: a refresh that started later
            // has replaced `commits`, and appending a page computed against
            // the old offsets would rewind or duplicate.
            switch await logLoader.run({ try await self.repository.log(limit: Self.logPageSize, skip: skip) }) {
            case .success(let page):
                hasMoreCommits = page.count >= Self.logPageSize
                let known = Set(commits.map(\.hash))
                let fresh = page.filter { !known.contains($0.hash) }
                if !fresh.isEmpty {
                    let merged = commits + fresh
                    commits = merged
                    let graph = await Task.detached { CommitGraph(commits: merged) }.value
                    // A refresh that landed during the off-main layout owns
                    // `commits` now — its own graph must not be overwritten.
                    if commits == merged { self.graph = graph }
                    return
                }
                guard hasMoreCommits else { return }
                skip += Self.logPageSize
            case .failure(let error):
                report(error)
                return
            case nil:
                return
            }
        }
    }

    func refreshRefs() async {
        do {
            async let branchesTask = repository.branches()
            async let remotesTask = repository.remotes()
            async let tagsTask = repository.tags()
            async let stashesTask = repository.stashes()
            async let remoteURLTask = repository.defaultRemoteURL()
            branches = try await branchesTask
            remotes = try await remotesTask
            tags = try await tagsTask
            stashes = try await stashesTask
            isGitHubRemote = ((try? await remoteURLTask) ?? nil)
                .map(GitHubAvatars.isGitHub(remoteURL:)) ?? false
        } catch {
            report(error)
        }
    }

    func loadCommitDetail() async {
        commitDetailError = nil
        guard let hash = selectedCommitHash else {
            commitDetail = nil
            commitFiles = []
            commitDiffs = []
            commitDiffsHash = nil
            commitDetailLoader.invalidate()
            return
        }
        let result = await commitDetailLoader.run { [repository] in
            async let detailTask = repository.commitDetail(hash)
            async let filesTask = repository.commitFileStats(hash)
            async let diffsTask = repository.diffCommit(hash)
            return (try await detailTask, try await filesTask, try await diffsTask)
        }
        switch result {
        case .success(let (detail, files, diffs)):
            commitDetail = detail
            commitFiles = files
            commitDiffs = diffs
            commitDiffsHash = hash
            if let selected = selectedCommitFilePath,
               commitFiles.contains(where: { $0.path == selected }) == false {
                selectedCommitFilePath = commitFiles.first?.path
            } else if selectedCommitFilePath == nil {
                selectedCommitFilePath = commitFiles.first?.path
            }
        case .failure(let error):
            // The previous commit's data must not keep rendering under the
            // failed selection's header, and the pane needs a visible,
            // persistent failure state — a dismissed alert alone left an
            // eternal spinner with no retry short of re-selecting.
            commitDetail = nil
            commitFiles = []
            commitDiffs = []
            commitDiffsHash = nil
            commitDetailError = error.localizedDescription
        case nil:
            break
        }
    }

    /// Entry-point for the Changes tab appearing. Uses the cached
    /// `workingDiffs` when a load has already happened — selection changes,
    /// the file watcher, and refreshAll all keep it current — so switching
    /// tabs doesn't spawn git (or cancel an in-flight load, as the
    /// select-file-from-another-tab path otherwise would via its `didSet`).
    /// Reloads when file watching is down: the cache goes stale silently then.
    func loadWorkingDiffsIfNeeded() async {
        guard !hasLoadedWorkingDiffs || !isWatchingFileSystem else { return }
        await loadWorkingDiffs()
    }

    func loadWorkingDiffs() async {
        let selection = selectedChange
        let status = self.status
        let result = await workingDiffsLoader.run { [repository] in
            var diffs: [FileDiff]
            if let selection {
                let side = selection.staged ? status.staged : status.unstaged
                let change = side.first { $0.path == selection.path }
                    ?? (status.staged + status.unstaged).first { $0.path == selection.path }
                if change?.status == .untracked {
                    diffs = (try? await repository.diffUntracked(path: selection.path)) ?? []
                } else {
                    diffs = try await repository.diffWorking(staged: selection.staged, path: selection.path)
                }
            } else {
                diffs = try await repository.diffWorking(staged: false)
                let stagedDiffs = try await repository.diffWorking(staged: true)
                var knownPaths = Set(diffs.map(\.path))
                for diff in stagedDiffs where knownPaths.insert(diff.path).inserted {
                    diffs.append(diff)
                }
                // Untracked files never appear in `git diff`; show them as
                // all-additions like Fork does.
                for change in status.unstaged where change.status == .untracked {
                    guard !knownPaths.contains(change.path),
                          let untracked = try? await repository.diffUntracked(path: change.path) else { continue }
                    diffs.append(contentsOf: untracked)
                    knownPaths.formUnion(untracked.map(\.path))
                }
            }
            return diffs
        }
        switch result {
        case .success(let diffs):
            // Line IDs are positional: after a re-parse the same ID can denote
            // a *different physical line* (an edit earlier in the file shifts
            // everything below). Keep a selected ID only when the line it now
            // denotes is exactly the line it denoted before — otherwise a
            // later "Discard/Stage lines" would hit lines the user never chose.
            let previousLines = Dictionary(
                workingDiffs.flatMap { $0.hunks.flatMap(\.lines) }.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let currentLines = Dictionary(
                diffs.flatMap { $0.hunks.flatMap(\.lines) }.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            workingDiffs = diffs
            workingDiffLineIDs = Set(currentLines.keys)
            hasLoadedWorkingDiffs = true
            selectedDiffLineIDs = selectedDiffLineIDs.filter { id in
                guard let current = currentLines[id] else { return false }
                return previousLines[id] == current
            }
        case .failure(let error):
            report(error)
        case nil:
            break
        }
    }

    func loadStashDiff() async {
        guard let ref = selectedStashRef,
              let stash = stashes.first(where: { $0.id == ref }) else {
            stashDiffs = []
            stashDiffLoader.invalidate()
            return
        }
        switch await stashDiffLoader.run({ try await self.repository.stashDiff(stash) }) {
        case .success(let diffs):
            stashDiffs = diffs
        case .failure(let error):
            report(error)
        case nil:
            break
        }
    }
}
