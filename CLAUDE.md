# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Gital

A native macOS Git client built with SwiftUI (macOS 26+ Liquid Glass design language).

## Build & test

```sh
xcodebuild -project Gital.xcodeproj -scheme Gital -configuration Debug build
./Scripts/run-tests.sh   # parser/graph tests; exits non-zero on failure
```

There is no XCTest target. Tests live in `Tests/main.swift` as plain assertions (`expect(...)`); `Scripts/run-tests.sh` compiles them with `swiftc` together with the `Gital/Git/` layer plus the other files listed in the script (`Subprocess`, `GitHubService`, `CodexProtocol`, …). To test a new file, add it to the `swiftc` file list in that script. There is no way to run a single test — the whole suite runs in seconds.

## Release (Homebrew cask)

Distributed via the `k-ymmt/homebrew-tap` tap (`brew install --cask k-ymmt/tap/gital`). The `/release` skill automates the whole flow (bump → build/notarize via `Scripts/release.sh` → GitHub release on `k-ymmt/Gital` → cask update in the tap). Signing uses team `8HUWJ2ZRK2` and the `gital-notary` notarytool keychain profile; `SKIP_NOTARIZE=1 Scripts/release.sh` builds without notarizing for local testing.

## Architecture

- `Gital/Git/` — git CLI layer. `GitExecutor` (actor) serializes `git` subprocess runs (with `--no-optional-locks`, color disabled, cancellation terminating the child); `GitRepository` exposes typed operations (status, log, diff, stage, commit, fetch/pull/push, branches, stashes) with output parsing in static `parseXxx` funcs so the test harness can reach it; `DiffParser` parses unified diffs; `CommitGraph` computes lane layout for the history graph.
- `Gital/Agent/` — `CodexAppServer` is a JSON-RPC client for `codex app-server` (newline-delimited JSON over stdio). Flow: `initialize` → `thread/start {cwd}` → `turn/start {threadId, input}`, streaming `item/agentMessage/delta` until `turn/completed`. `turn/start`'s `input` must be an **array** of `{type: "text", text}` items, not an object. Line buffering and message classification live in `CodexProtocol.swift` (`NewlineBuffer`, `CodexServerMessage`, typed `CodexNotification`) and are unit-tested. `AgentThread` models an "Ask AI Agent" conversation anchored to diff lines.
- `Gital/GitHub/` — `GitHubService` wraps the `gh` CLI for pull request list/detail/merge. `GitHubAvatars` derives github.com avatar URLs (by login, by commit email); avatars only activate when the default remote's host is github.com. `PRViewedState`/`PRViewedStore` track per-PR "Viewed" review progress (commit-level and file-level flags that promote/demote each other), persisted in a SQLite database (built-in SQLite3, one row per flag keyed by repo path + PR number) in Application Support; a toggle writes only the row delta of that mutation, so a second app instance can never wipe rows it didn't touch.
- `Gital/ViewModels/` — `AppModel` (repo selection, recents), `RepoViewModel` (screen state + actions for the open repo; views own no git state of their own), `PullRequestsModel` (the whole PR domain, owned by `RepoViewModel` as `prs`), `LatestLoader` (supersedes stale async loads and cancels the superseded operation — use it instead of hand-rolled generation counters).
- `Gital/Support/` — `Subprocess` (the one spawn/drain implementation every CLI call goes through: concurrent pipe drain, terminationHandler-based exit, post-exit grace period, terminate-on-cancellation); `ExecutableLocator` (actor; finds gh/codex, caching hits and — briefly — misses); `AppDelegate` receives open-document events (the `gital` CLI opens directories via `open`); `CommandLineToolInstaller` writes the `gital` script to `/usr/local/bin` with the installing app's path baked in — `open -b` alone is ambiguous when multiple copies (DerivedData builds) exist.
- `Gital/Views/` — SwiftUI views. Sidebar shell (`SidebarView`) + per-tab sections (`SidebarWorkingCopySection`/`BranchesSection`/`PullRequestsSection`/`StashesSection`, shared rows in `SidebarShared.swift`), History (commit graph + detail + diff), Changes (interactive diff with per-line AI agent composer + commit composer), Pull Request detail, Stash detail. Shared building blocks (`DisclosureRow`, `ViewedToggle`, `PaneHeader`, `.cardStyle()`) live in `Controls.swift`; colors come from `DesignStyle` — no raw hex values in views.

## Conventions

- Git is always invoked via CLI (`/usr/bin/env git`), never a library. Same for `gh` and `codex` — the app shells out for everything.
- Diff row IDs embed the file path (`path@n`) — required so SwiftUI never reuses rows across files. Do not revert to per-file integer IDs.
- App Sandbox is disabled (`ENABLE_APP_SANDBOX = NO`) because the app spawns `git`, `gh`, and `codex` against arbitrary repositories.
- UI follows the Fork-style reference design; system chrome (toolbar, sidebar) uses native Liquid Glass; content colors come from `DesignStyle`.

## Environment gotchas

- The sidebar deliberately uses a custom `ScrollView`, not `List`: on macOS 27 beta, `List` rows inside `NavigationSplitView` render outdented/clipped. Don't "simplify" it back to `List`.
- If `UserDefaults`/`defaults` changes seem ignored, delete the stale sandbox container at `~/Library/Containers/app.kymmt.Gital` — the `defaults` CLI writes to the container plist while the non-sandboxed app reads `~/Library/Preferences`.
