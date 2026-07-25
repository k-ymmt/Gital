import Foundation

// MARK: - Loading repository data

extension RepoViewModel {
    private static let logPageSize = 400

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

    func loadCommitDetail() async {
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
            // Positional line IDs stay stable while content does, so the
            // selection survives spurious refreshes; drop IDs that vanished.
            let validIDs = Set(workingDiffs.flatMap { $0.hunks.flatMap(\.lines) }.map(\.id))
            selectedDiffLineIDs.formIntersection(validIDs)
        } catch {
            report(error)
        }
    }

    func loadStashDiff() async {
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
