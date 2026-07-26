//
//  ContentView.swift
//  Gital
//

import SwiftUI

struct ContentView: View {
    @Bindable var model: RepoViewModel

    @State private var showBranchPopover = false
    @State private var showStashPopover = false
    @State private var newBranchName = ""
    @State private var stashMessage = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 230, ideal: 265, max: 360)
        } detail: {
            MainView(model: model)
        }
        .navigationTitle(model.repository.name)
        .navigationSubtitle(model.status.branch ?? "detached HEAD")
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

                Button {
                    model.push()
                } label: {
                    Label("Push", systemImage: "arrow.up.to.line")
                }
                .badge(model.status.ahead)
                .help("Push (ahead \(model.status.ahead))")
                .disabled(model.isSyncing)
            }

            ToolbarItemGroup {
                if model.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    showBranchPopover = true
                } label: {
                    Label("Branch", systemImage: "arrow.triangle.branch")
                }
                .help("Create a new branch")
                .popover(isPresented: $showBranchPopover, arrowEdge: .bottom) {
                    branchPopover
                }

                Button {
                    showStashPopover = true
                } label: {
                    Label("Stash", systemImage: "archivebox")
                }
                .help("Stash working copy changes")
                .popover(isPresented: $showStashPopover, arrowEdge: .bottom) {
                    stashPopover
                }
            }
        }
        .alert(
            model.pendingDiscard?.confirmationTitle ?? "",
            isPresented: Binding(
                get: { model.pendingDiscard != nil },
                set: { if !$0 { model.pendingDiscard = nil } }
            ),
            presenting: model.pendingDiscard
        ) { target in
            Button("Discard", role: .destructive) { model.performDiscard(target) }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            Text(target.confirmationMessage)
        }
        .alert(
            "Hard Reset?",
            isPresented: Binding(
                get: { model.pendingReset != nil },
                set: { if !$0 { model.pendingReset = nil } }
            ),
            presenting: model.pendingReset
        ) { pending in
            Button("Reset", role: .destructive) {
                model.performReset(to: pending.commit, mode: pending.mode)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("“\(model.status.branch ?? "HEAD")” will be reset to \(pending.commit.shortHash) and all working copy changes will be discarded. This cannot be undone.")
        }
        .alert(
            "Drop Stash?",
            isPresented: Binding(
                get: { model.pendingStashDrop != nil },
                set: { if !$0 { model.pendingStashDrop = nil } }
            ),
            presenting: model.pendingStashDrop
        ) { stash in
            Button("Drop", role: .destructive) { model.stashDrop(stash) }
            Button("Cancel", role: .cancel) {}
        } message: { stash in
            Text("“\(stash.message)” will be permanently deleted. This cannot be undone.")
        }
        .alert("Git Error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            if model.commits.isEmpty {
                await model.refreshAll()
            }
        }
    }

    private var branchPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Branch")
                .font(.headline)
            TextField("Branch name", text: $newBranchName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(createBranch)
            HStack {
                Spacer()
                Button("Cancel") { showBranchPopover = false }
                Button("Create") { createBranch() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newBranchName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private var stashPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stash Changes")
                .font(.headline)
            TextField("Message (optional)", text: $stashMessage)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(stashChanges)
            HStack {
                Spacer()
                Button("Cancel") { showStashPopover = false }
                Button("Stash") { stashChanges() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.status.staged.isEmpty && model.status.unstaged.isEmpty)
            }
        }
        .padding(16)
    }

    private func createBranch() {
        model.createBranch(name: newBranchName)
        newBranchName = ""
        showBranchPopover = false
    }

    private func stashChanges() {
        model.stashPush(message: stashMessage)
        stashMessage = ""
        showStashPopover = false
    }
}

/// Routes the detail area based on the selected navigation tab.
struct MainView: View {
    @Bindable var model: RepoViewModel

    var body: some View {
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
}
