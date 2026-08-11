//
//  ContentView.swift
//  Gital
//

import SwiftUI

struct ContentView: View {
    @Bindable var model: RepoViewModel
    @AppStorage(AutoFetchPreference.defaultsKey)
    private var autoFetchInterval = AutoFetchPreference.defaultInterval

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 230, ideal: 265, max: 360)
        } detail: {
            MainView(model: model)
        }
        .navigationTitle(model.repository.name)
        // The repository identity lives in the centered toolbar switcher
        // (Xcode-style); the inline title would duplicate it. The window
        // title itself (Mission Control, window menu) keeps the repo name.
        .toolbar(removing: .title)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search commits, files…")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    model.fetch()
                } label: {
                    Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Fetch from all remotes")
                .disabled(model.isSyncing)

                Button {
                    model.pull()
                } label: {
                    Label("Pull", systemImage: "arrow.down.to.line")
                }
                .badge(model.status.behind)
                .help("Pull (behind \(model.status.behind))")
                .disabled(model.isSyncing)

                // Push is a plain Button + a separate options Menu, not a
                // single Menu with primaryAction: on the split control the
                // badge lands on the chevron segment, and moving it onto the
                // label gets dropped entirely (toolbar Menu labels render
                // icon-only on macOS 27 beta).
                Button {
                    model.push()
                } label: {
                    Label("Push", systemImage: "arrow.up.to.line")
                }
                .badge(model.status.ahead)
                .help("Push (ahead \(model.status.ahead))")
                .disabled(model.isSyncing)

                Menu {
                    Button("Force Push (with Lease)…") {
                        model.pendingForcePush = true
                    }
                } label: {
                    Label("Push Options", systemImage: "chevron.down")
                }
                .menuIndicator(.hidden)
                .help("Push options")
                .disabled(model.isSyncing)
            }

            // .principal is not actually centered on macOS (the item lands
            // wherever the default section starts); flexible spacers on both
            // sides balance the switcher into the middle, Xcode-style.
            ToolbarSpacer(.flexible)

            // Detached from the shared glass background: on macOS 27 beta
            // the flexible spacers stretch INSIDE the shared capsule, fusing
            // the switcher with the branch/stash buttons into one blob. The
            // switcher draws its own capsule instead (see RepositorySwitcher).
            ToolbarItem {
                RepositorySwitcher(model: model)
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarSpacer(.flexible)

            // Explicit trailing placement: with .automatic these buttons
            // fuse into the switcher's glass capsule despite the flexible
            // spacer between them.
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.isCreatingBranch = true
                } label: {
                    Label { Text("Branch") } icon: { GitGlyph(kind: .branch) }
                }
                .help("Create a new branch")
                .popover(isPresented: $model.isCreatingBranch, arrowEdge: .bottom) {
                    NewBranchPopover(model: model)
                }

                Button {
                    model.isStashing = true
                } label: {
                    Label("Stash", systemImage: "archivebox")
                }
                .help("Stash working copy changes")
                .popover(isPresented: $model.isStashing, arrowEdge: .bottom) {
                    StashPopover(model: model)
                }
            }
        }
        // Alert chains live in separate ViewModifiers: inlining them all here
        // blows past the type checker's budget for one body expression.
        .sheet(item: $model.fileHistory) { history in
            FileHistorySheet(model: history)
        }
        .modifier(WorkingCopyConfirmationAlerts(model: model))
        .modifier(ConflictFlowAlerts(model: model))
        .modifier(BranchManagementAlerts(model: model))
        .modifier(RemoteManagementAlerts(model: model))
        .task {
            if model.commits.isEmpty {
                await model.refreshAll()
            }
        }
        // Auto fetch: one tick loop per window, restarted when the Settings
        // interval changes (`id:`) and cancelled when the window closes.
        // A second window on the same repository runs its own loop; the
        // duplicate ticks are collapsed inside autoFetchTick.
        .task(id: autoFetchInterval) {
            guard autoFetchInterval > 0 else { return }
            while (try? await Task.sleep(for: .seconds(autoFetchInterval))) != nil {
                await model.autoFetchTick(interval: autoFetchInterval)
            }
        }
        .onAppear { model.windowDidAppear() }
        .onDisappear { model.windowDidDisappear() }
    }

}

/// Routes the detail area based on the selected navigation tab.
struct MainView: View {
    @Bindable var model: RepoViewModel

    var body: some View {
        Group {
            switch model.navTab {
            case .changes:
                ChangesView(model: model)
            case .branches:
                HistoryView(model: model)
            case .pullRequests:
                PullRequestView(model: model)
            case .stashes:
                StashDetailView(model: model)
            }
        }
        // Hosted here, not on HistoryView: prep completes asynchronously,
        // and a sheet whose host only exists on one tab would silently wait
        // for a tab switch and then pop out of nowhere.
        .sheet(item: $model.interactiveRebasePrep) { prep in
            InteractiveRebaseSheet(prep: prep) { steps in
                model.startInteractiveRebase(prep: prep, stepsNewestFirst: steps)
            }
        }
        .sheet(item: $model.reflogSnapshot) { snapshot in
            ReflogSheet(model: model, snapshot: snapshot)
        }
    }
}
