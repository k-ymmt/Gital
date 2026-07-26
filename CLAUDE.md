# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# Gital

A native macOS Git client built with SwiftUI (macOS 26+ Liquid Glass design language).

## Build & test

```sh
xcodebuild -project Gital.xcodeproj -scheme Gital -configuration Debug build
./Scripts/run-tests.sh   # parser/graph tests; exits non-zero on failure
```

There is no XCTest target. Tests live in `Tests/main.swift` as plain assertions (`expect(...)`); `Scripts/run-tests.sh` compiles them with `swiftc` together with the `Gital/Git/` layer. To test a new Git-layer file, add it to the `swiftc` file list in that script. There is no way to run a single test — the whole suite runs in seconds.

## Architecture

- `Gital/Git/` — git CLI layer. `GitExecutor` (actor) runs `git` as a subprocess with `--no-optional-locks` and color disabled; `GitRepository` exposes typed operations (status, log, diff, stage, commit, fetch/pull/push, branches, stashes); `DiffParser` parses unified diffs; `CommitGraph` computes lane layout for the history graph.
- `Gital/Agent/` — `CodexAppServer` is a JSON-RPC client for `codex app-server` (newline-delimited JSON over stdio). Flow: `initialize` → `thread/start {cwd}` → `turn/start {threadId, input}`, streaming `item/agentMessage/delta` until `turn/completed`. `turn/start`'s `input` must be an **array** of `{type: "text", text}` items, not an object. `AgentThread` models an "Ask AI Agent" conversation anchored to diff lines.
- `Gital/GitHub/` — `GitHubService` wraps the `gh` CLI for pull request list/detail/merge.
- `Gital/ViewModels/` — `AppModel` (repo selection, recents), `RepoViewModel` (all screen state + actions for the open repo; views own no git state of their own).
- `Gital/Views/` — SwiftUI views. Sidebar (Changes/Branches/PRs/Stashes tabs), History (commit graph + detail + diff), Changes (interactive diff with per-line AI agent composer + commit composer), Pull Request detail, Stash detail.

## Conventions

- Git is always invoked via CLI (`/usr/bin/env git`), never a library. Same for `gh` and `codex` — the app shells out for everything.
- Diff row IDs embed the file path (`path@n`) — required so SwiftUI never reuses rows across files. Do not revert to per-file integer IDs.
- App Sandbox is disabled (`ENABLE_APP_SANDBOX = NO`) because the app spawns `git`, `gh`, and `codex` against arbitrary repositories.
- UI follows the Fork-style reference design; system chrome (toolbar, sidebar) uses native Liquid Glass; content colors come from `DesignStyle`.

## Environment gotchas

- The sidebar deliberately uses a custom `ScrollView`, not `List`: on macOS 27 beta, `List` rows inside `NavigationSplitView` render outdented/clipped. Don't "simplify" it back to `List`.
- If `UserDefaults`/`defaults` changes seem ignored, delete the stale sandbox container at `~/Library/Containers/app.kymmt.Gital` — the `defaults` CLI writes to the container plist while the non-sandboxed app reads `~/Library/Preferences`.
