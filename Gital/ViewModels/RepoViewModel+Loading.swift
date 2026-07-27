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
        logGeneration += 1
        let generation = logGeneration
        do {
            // Re-fetch at least as many commits as are already loaded so a
            // refresh (fetch/pull/commit) doesn't collapse the paged-in history.
            let limit = max(Self.logPageSize, commits.count)
            let loaded = try await repository.log(limit: limit)
            guard generation == logGeneration else { return }
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
        logGeneration += 1
        let generation = logGeneration
        do {
            let page = try await repository.log(limit: Self.logPageSize, skip: commits.count)
            // A refresh that started later has replaced `commits`; appending a
            // page computed against the old offsets would rewind or duplicate.
            guard generation == logGeneration else { return }
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

    func loadCommitDetail() async {
        guard let hash = selectedCommitHash else {
            commitDetail = nil
            commitFiles = []
            commitDiffs = []
            return
        }
        commitDetailGeneration += 1
        let generation = commitDetailGeneration
        do {
            async let detailTask = repository.commitDetail(hash)
            async let filesTask = repository.commitFileStats(hash)
            async let diffsTask = repository.diffCommit(hash)
            let detail = try await detailTask
            let files = try await filesTask
            let diffs = try await diffsTask
            // A newer selection's load may already have finished — never let
            // this slower result overwrite it.
            guard generation == commitDetailGeneration, selectedCommitHash == hash else { return }
            commitDetail = detail
            commitFiles = files
            commitDiffs = diffs
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
        workingDiffsGeneration += 1
        let generation = workingDiffsGeneration
        let selection = selectedChange
        do {
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
            }
            guard generation == workingDiffsGeneration, selection == selectedChange else { return }

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
            selectedDiffLineIDs = selectedDiffLineIDs.filter { id in
                guard let current = currentLines[id] else { return false }
                return previousLines[id] == current
            }
        } catch {
            report(error)
        }
    }

    func loadStashDiff() async {
        guard let ref = selectedStashRef,
              let stash = stashes.first(where: { $0.id == ref }) else {
            stashDiffs = []
            return
        }
        stashDiffGeneration += 1
        let generation = stashDiffGeneration
        do {
            let diffs = try await repository.stashDiff(stash)
            guard generation == stashDiffGeneration, selectedStashRef == ref else { return }
            stashDiffs = diffs
        } catch {
            report(error)
        }
    }

    func loadPRDetail() async {
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

    func loadPRItemDiffs() async {
        prItemGeneration += 1
        let generation = prItemGeneration
        guard let item = selectedPRItem, let number = selectedPRNumber else {
            prItemDiffs = []
            prItemLoadError = nil
            return
        }
        prItemDiffs = []
        prItemLoadError = nil
        do {
            let diffs: [FileDiff]
            switch item {
            case .commit(let hash):
                // PR commits live in the local object store once the remote
                // branch has been fetched. When the object is missing (fork
                // PRs, never-fetched branches), pull it in via the PR head
                // ref and retry once.
                do {
                    diffs = try await repository.diffCommit(hash)
                } catch {
                    try await repository.fetchPullRequestHead(number: number)
                    guard generation == prItemGeneration else { return }
                    diffs = try await repository.diffCommit(hash)
                }
            case .file(let path):
                let all: [FileDiff]
                if let cached = prDiffsCache[number] {
                    all = cached
                } else {
                    let raw = try await github.pullRequestDiff(number: number)
                    all = DiffParser.parse(raw, scope: .snapshot)
                    guard generation == prItemGeneration else { return }
                    prDiffsCache[number] = all
                }
                diffs = all.filter { $0.path == path }
            }
            guard generation == prItemGeneration, selectedPRItem == item else { return }
            prItemDiffs = diffs
            if diffs.isEmpty {
                prItemLoadError = "No changes found for this item."
            }
        } catch {
            guard generation == prItemGeneration, selectedPRItem == item else { return }
            switch item {
            case .commit:
                prItemLoadError = "Could not load this commit, even after fetching the pull request from origin.\n\(error.localizedDescription)"
            case .file:
                prItemLoadError = error.localizedDescription
            }
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
}
