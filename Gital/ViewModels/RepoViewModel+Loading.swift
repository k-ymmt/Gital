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
        do {
            status = try await repository.status()
        } catch {
            report(error)
        }
    }

    func refreshLog() async {
        // Re-fetch at least as many commits as are already loaded so a
        // refresh (fetch/pull/commit) doesn't collapse the paged-in history.
        let limit = max(Self.logPageSize, commits.count)
        switch await logLoader.run({ try await self.repository.log(limit: limit) }) {
        case .success(let loaded):
            commits = loaded
            hasMoreCommits = loaded.count >= limit
            graph = CommitGraph(commits: commits)
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
        let skip = commits.count
        // Shares logLoader with refreshLog: a refresh that started later has
        // replaced `commits`, and appending a page computed against the old
        // offsets would rewind or duplicate.
        switch await logLoader.run({ try await self.repository.log(limit: Self.logPageSize, skip: skip) }) {
        case .success(let page):
            hasMoreCommits = page.count >= Self.logPageSize
            let known = Set(commits.map(\.hash))
            commits.append(contentsOf: page.filter { !known.contains($0.hash) })
            graph = CommitGraph(commits: commits)
        case .failure(let error):
            report(error)
        case nil:
            break
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
        guard let hash = selectedCommitHash else {
            commitDetail = nil
            commitFiles = []
            commitDiffs = []
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
            if let selected = selectedCommitFilePath,
               commitFiles.contains(where: { $0.path == selected }) == false {
                selectedCommitFilePath = commitFiles.first?.path
            } else if selectedCommitFilePath == nil {
                selectedCommitFilePath = commitFiles.first?.path
            }
        case .failure(let error):
            report(error)
        case nil:
            break
        }
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
