//
//  AppCommands.swift
//  Gital
//

import AppKit
import SwiftUI

/// Menu-bar commands. Every shortcut is read from the `ShortcutStore` so the
/// user can rebind it in Settings; menu items rebuild when a binding changes.
struct AppCommands: Commands {
    let appModel: AppModel
    let shortcuts: ShortcutStore

    private var repo: RepoViewModel? { appModel.repoViewModel }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Repository…") {
                appModel.pickRepository()
            }
            .keyboardShortcut(shortcuts.combo(for: .openRepository)?.keyboardShortcut)

            Divider()

            Button("Install “gital” Command-Line Tool") {
                appModel.installCommandLineTool()
            }
        }

        CommandMenu("Repository") {
            Button("Fetch") { repo?.fetch() }
                .keyboardShortcut(shortcuts.combo(for: .fetch)?.keyboardShortcut)
                .disabled(repo == nil || repo?.isSyncing == true)

            Button("Pull") { repo?.pull() }
                .keyboardShortcut(shortcuts.combo(for: .pull)?.keyboardShortcut)
                .disabled(repo == nil || repo?.isSyncing == true)

            Button("Push") { repo?.push() }
                .keyboardShortcut(shortcuts.combo(for: .push)?.keyboardShortcut)
                .disabled(repo == nil || repo?.isSyncing == true)

            Divider()

            // The title mirrors the amend checkbox: ⌘↩ works from any tab,
            // where the checkbox is out of sight — "Commit" silently running
            // `--amend` would rewrite HEAD without warning.
            Button(repo?.amend == true ? "Amend Last Commit" : "Commit") { repo?.commit() }
                .keyboardShortcut(shortcuts.combo(for: .commit)?.keyboardShortcut)
                .disabled({
                    guard let repo else { return true }
                    return (!repo.canCommit && !repo.amend) || repo.isCommitting
                }())

            Button("Stage All") { repo?.stageAll() }
                .keyboardShortcut(shortcuts.combo(for: .stageAll)?.keyboardShortcut)
                .disabled(repo == nil)

            Button("Unstage All") { repo?.unstageAll() }
                .keyboardShortcut(shortcuts.combo(for: .unstageAll)?.keyboardShortcut)
                .disabled(repo == nil)

            Divider()

            Button("New Branch…") { presentPopover { $0.isCreatingBranch = true } }
                .keyboardShortcut(shortcuts.combo(for: .newBranch)?.keyboardShortcut)
                .disabled(repo == nil)

            Button("Stash Changes…") { presentPopover { $0.isStashing = true } }
                .keyboardShortcut(shortcuts.combo(for: .stashChanges)?.keyboardShortcut)
                .disabled(repo == nil)

            Divider()

            Button("Refresh") {
                guard let repo else { return }
                Task { await repo.refreshAll() }
            }
            .keyboardShortcut(shortcuts.combo(for: .refresh)?.keyboardShortcut)
            .disabled(repo == nil)
        }

        CommandGroup(after: .sidebar) {
            Divider()

            navButton("Show Working Copy", .showWorkingCopy, tab: .changes)
            navButton("Show History", .showHistory, tab: .branches)
            navButton("Show Pull Requests", .showPullRequests, tab: .pullRequests)
            navButton("Show Stashes", .showStashes, tab: .stashes)

            Divider()

            Button("Toggle Unified/Split Diff") {
                guard let repo else { return }
                repo.diffMode = repo.diffMode == .unified ? .split : .unified
            }
            .keyboardShortcut(shortcuts.combo(for: .toggleDiffLayout)?.keyboardShortcut)
            .disabled(repo == nil)
        }
    }

    /// The branch/stash popovers anchor to toolbar buttons in the repo
    /// window. Firing the flag while that window is miniaturized would leave
    /// it wedged `true` with nothing presented (and the toolbar button dead
    /// until something resets it), so restore the window first.
    private func presentPopover(_ present: (RepoViewModel) -> Void) {
        guard let repo else { return }
        for window in NSApp.windows where window.isMiniaturized {
            window.deminiaturize(nil)
        }
        present(repo)
    }

    private func navButton(_ title: String, _ action: ShortcutAction, tab: NavTab) -> some View {
        Button(title) { repo?.navTab = tab }
            .keyboardShortcut(shortcuts.combo(for: action)?.keyboardShortcut)
            .disabled(repo == nil)
    }
}
