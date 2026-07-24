# Gital

A native macOS Git client built with SwiftUI (macOS 26+ Liquid Glass design language).

## Architecture

- `Gital/Git/` — git CLI layer. `GitExecutor` runs `git` as a subprocess; `GitRepository` exposes typed operations (status, log, diff, stage, commit, fetch/pull/push, branches, stashes); `DiffParser` parses unified diffs; `CommitGraph` computes lane layout for the history graph.
- `Gital/Agent/` — `CodexAppServer` is a JSON-RPC client for `codex app-server` (stdio). Flow: `initialize` → `thread/start` → `turn/start`, streaming `item/agentMessage/delta` events. `AgentThread` models an "Ask AI Agent" conversation anchored to diff lines.
- `Gital/GitHub/` — `GitHubService` wraps the `gh` CLI for pull request list/detail/merge.
- `Gital/ViewModels/` — `AppModel` (repo selection, recents), `RepoViewModel` (all screen state + actions).
- `Gital/Views/` — SwiftUI views. Sidebar (Changes/Source/PRs/Stashes tabs), History (commit graph + detail + diff), Changes (interactive diff with per-line AI agent composer + commit composer), Pull Request detail, Stash detail.

## Conventions

- Git is always invoked via CLI (`/usr/bin/env git`), never a library.
- Diff row IDs embed the file path (`path@n`) — required so SwiftUI never reuses rows across files. Do not revert to per-file integer IDs.
- App Sandbox is disabled (`ENABLE_APP_SANDBOX = NO`) because the app spawns `git`, `gh`, and `codex` against arbitrary repositories.
- UI follows the Fork-style reference design; system chrome (toolbar, sidebar) uses native Liquid Glass; content colors come from `DesignStyle`.

## Build & test

```sh
xcodebuild -project Gital.xcodeproj -scheme Gital -configuration Debug build
./Scripts/run-tests.sh   # standalone parser/graph tests (Tests/main.swift via swiftc)
```
