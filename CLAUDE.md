# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Gital

A native macOS Git client built with SwiftUI (macOS 26+ Liquid Glass design language).

## Build & test

```sh
xcodebuild -project Gital.xcodeproj -scheme Gital -configuration Debug build
./Scripts/run-tests.sh   # runs the GitalTests bundle via `xcodebuild test`; exits non-zero on failure
```

Tests live in the `GitalTests` unit-test target as Swift Testing suites (`@Test` / `#expect`), hosted in Gital.app with `@testable import Gital`. The target uses a synchronized folder group, so a new `.swift` file dropped into `GitalTests/` joins the target automatically — no pbxproj edits. The app module builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so test suites are annotated `@MainActor` to call into it. Run a subset with `./Scripts/run-tests.sh -only-testing:GitalTests/DiffParserTests` (extra args pass through to xcodebuild). `AppModel` skips auto-opening the most recent repository when XCTest is loaded, so hosted test runs don't spawn git/codex against a real repo.

## Release (Homebrew cask)

Distributed via the `k-ymmt/homebrew-tap` tap (`brew install --cask k-ymmt/tap/gital`). The `/release` skill automates the whole flow (bump → build/notarize via `Scripts/release.sh` → GitHub release on `k-ymmt/Gital` → cask update in the tap). Signing uses team `8HUWJ2ZRK2` and the `gital-notary` notarytool keychain profile; `SKIP_NOTARIZE=1 Scripts/release.sh` builds without notarizing for local testing.

## Architecture

- `Gital/Git/` — git CLI layer. `GitExecutor` (actor) serializes `git` subprocess runs (with `--no-optional-locks`, color disabled, cancellation terminating the child); `GitRepository` exposes typed operations (status, log, diff, stage, commit, fetch/pull/push, branches, stashes, merge/rebase — stopped-operation state is detected by probing git-dir marker files via `rev-parse --git-path`, never by parsing localized status text) with output parsing in static `parseXxx` funcs so the test harness can reach it; per-file history (`log --follow` with rename tracking, so older commits diff under the file's old name) and blame (`--porcelain`) feed the file-history sheet; `DiffParser` parses unified diffs; `CommitGraph` computes lane layout for the history graph.
- `Gital/Agent/` — `CodexAppServer` is a JSON-RPC client for `codex app-server` (newline-delimited JSON over stdio). Flow: `initialize` → `thread/start {cwd}` → `turn/start {threadId, input}`, streaming `item/agentMessage/delta` until `turn/completed`. `turn/start`'s `input` must be an **array** of `{type: "text", text}` items, not an object. Line buffering and message classification live in `CodexProtocol.swift` (`NewlineBuffer`, `CodexServerMessage`, typed `CodexNotification`) and are unit-tested. `AgentThread` models an "Ask AI Agent" conversation anchored to diff lines.
- `Gital/GitHub/` — `GitHubService` wraps the `gh` CLI for pull request list/detail/merge/review submission. `PRReview.swift` models draft review comments GitHub-style: `ReviewCommentAnchor` addresses a diff line by path + side (LEFT = old file, RIGHT = new file) + line number, and each draft also records its line's text — display requires coordinates AND content to match (commit diffs number files differently than the whole-PR diff), and `resolvedAnchor(in:)` re-anchors drafts against a freshly fetched whole-PR diff at submit time (GitHub interprets review coordinates against the base…head diff; an unresolvable draft aborts the submission instead of landing on the wrong line). Drafts persist per repo via `PendingReviewStore` (JSON in Application Support) until submitted together with a verdict via one `POST /pulls/{n}/reviews` (`gh api --input -` with a JSON body from `reviewSubmissionBody`; the API requires a summary body for COMMENT/REQUEST_CHANGES, which the submit form enforces). `GitHubAvatars` derives github.com avatar URLs (by login, by commit email); avatars only activate when the default remote's host is github.com. `PRViewedState`/`PRViewedStore` track per-PR "Viewed" review progress (commit-level and file-level flags that promote/demote each other), persisted in a SQLite database (built-in SQLite3, one row per flag keyed by repo path + PR number) in Application Support; a toggle writes only the row delta of that mutation, so a second app instance can never wipe rows it didn't touch.
- `Gital/ViewModels/` — `AppModel` (repo selection, recents), `RepoViewModel` (screen state + actions for the open repo; views own no git state of their own), `PullRequestsModel` (the whole PR domain, owned by `RepoViewModel` as `prs`), `LatestLoader` (supersedes stale async loads and cancels the superseded operation — use it instead of hand-rolled generation counters).
- `Gital/Support/` — `Subprocess` (the one spawn/drain implementation every CLI call goes through: concurrent pipe drain, terminationHandler-based exit, post-exit grace period, terminate-on-cancellation); `ExecutableLocator` (actor; finds gh/codex, caching hits and — briefly — misses); `AppDelegate` receives open-document events (the `gital` CLI opens directories via `open`); `CommandLineToolInstaller` writes the `gital` script to `/usr/local/bin` with the installing app's path baked in — `open -b` alone is ambiguous when multiple copies (DerivedData builds) exist.
- `Gital/Views/` — SwiftUI views. Sidebar shell (`SidebarView`) + per-tab sections (`SidebarWorkingCopySection`/`BranchesSection`/`PullRequestsSection`/`StashesSection`, shared rows in `SidebarShared.swift`), History (commit graph + detail + diff), Changes (interactive diff with per-line AI agent composer + commit composer), Pull Request detail, Stash detail, and the file-history/blame sheet (`FileHistoryView`, opened from file context menus, state in `FileHistoryModel`). Shared building blocks (`DisclosureRow`, `ViewedToggle`, `PaneHeader`, `.cardStyle()`) live in `Controls.swift`; colors come from `DesignStyle` — no raw hex values in views.

## Conventions

- Git is always invoked via CLI (`/usr/bin/env git`), never a library. Same for `gh` and `codex` — the app shells out for everything.
- Diff row IDs embed the file path (`path@n`) — required so SwiftUI never reuses rows across files. Do not revert to per-file integer IDs.
- App Sandbox is disabled (`ENABLE_APP_SANDBOX = NO`) because the app spawns `git`, `gh`, and `codex` against arbitrary repositories.
- UI follows the Fork-style reference design; system chrome (toolbar, sidebar) uses native Liquid Glass; content colors come from `DesignStyle`.

## Environment gotchas

- The sidebar deliberately uses a custom `ScrollView`, not `List`: on macOS 27 beta, `List` rows inside `NavigationSplitView` render outdented/clipped. Don't "simplify" it back to `List`.
- If `UserDefaults`/`defaults` changes seem ignored, delete the stale sandbox container at `~/Library/Containers/app.kymmt.Gital` — the `defaults` CLI writes to the container plist while the non-sandboxed app reads `~/Library/Preferences`.
