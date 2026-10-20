# TODO

Deferred from the 2026-10-20 audit session (bug hunt / performance / refactoring sweeps). All confirmed bugs and the main performance findings were fixed in that session; these are the items deliberately left out because they need a design decision or weren't worth the churn yet.

## Performance

- [ ] `refreshLog` re-fetches and re-parses the entire paged-in history on every refresh (`RepoViewModel+Loading.swift`, `limit = max(logPageSize, commits.count)`). With 10k+ commits paged in, every refresh re-runs the full `git log` plus a graph rebuild. Deferred: needs a splice design — refresh only the first page and reattach the unchanged tail by boundary hash, falling back to a full reload on history rewrites. Watch out: decorations on old commits can change (a fetched tag deep in history), which a naive splice would miss.
- [ ] `loadCommitDetail` always fetches the whole-commit patch (`diffCommit(hash)`) on every history selection, even when the Files tab is never opened — a 2k-file commit is a multi-MB `git show`. Defer the patch fetch to the first Files-tab entry while keeping the current one-fetch-per-commit reuse (`RepoViewModel+Loading.swift`).
- [ ] Commit Edit Session re-resolves `rev-parse --git-path` (one subprocess) on every state-file access and on the per-refresh `rebase-merge` probe while a session is active (`GitRepository+EditSession.swift`). Cache the resolved git-dir URL per `GitRepository` instance.
- [ ] `PullRequestsModel.detailsCache` is unbounded within a session (`expand()` inserts, collapse never evicts; trimmed only in `reloadAll`). Entries are KB-scale so impact is low; apply the existing `diffsCache` LRU pattern when touching that file.

## Refactoring (low value — do opportunistically)

- [ ] `ConflictBannerView` and `EditSessionBannerView` (`ChangesView.swift`) share the same banner skeleton; extract a `StatusBanner(icon:tint:title:subtitle:)` container when a third banner appears.
- [ ] `String(hash.prefix(7))` short-hash derivation is duplicated across 7 types (`GitModels.swift`, `RepoViewModel+SourceControl.swift`, `CommitEditSession.shortTargetHash`); a single `gitShortHash` extension would cover them.
- [ ] The `isEditingCommit → "Save Commit"` label branch exists in both `AppCommands.swift` (`commitMenuTitle`) and `ChangesView.swift` (`commitLabel`); the surrounding display requirements differ, but that one branch can drift.
