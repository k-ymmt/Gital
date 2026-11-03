import SwiftUI

struct HistoryView: View {
    @Bindable var model: RepoViewModel

    var body: some View {
        // ResizableSplit, not VSplitView/HSplitView — see its doc comment
        // for why NSSplitView-backed splits misbehave in this column.
        ResizableSplit(axis: .vertical, firstPane: .init(min: 220), secondPane: .init(min: 240, ideal: 360)) {
            commitList
        } second: {
            CommitDetailView(model: model)
        }
        // Anchors live on the model, not local @State: `isPresentingSheet`
        // must know these sheets are up so a shortcut-raised sheet (reflog)
        // can't queue invisibly beneath them.
        .sheet(item: $model.branchSheetAnchor) { commit in
            RefCreationSheet(
                title: "New Branch at \(commit.shortHash)",
                placeholder: "Branch name",
                showCheckoutToggle: true
            ) { name, checkout in
                model.createBranch(name: name, at: commit, checkout: checkout)
            }
        }
        .sheet(item: $model.tagSheetAnchor) { commit in
            RefCreationSheet(
                title: "New Tag at \(commit.shortHash)",
                placeholder: "Tag name",
                showCheckoutToggle: false
            ) { name, _ in
                model.createTag(name: name, at: commit)
            }
        }
    }

    // MARK: - Commit list

    /// Selected hash still waiting for its row to be paged in (see
    /// `RepoViewModel.ensureCommitLoaded`); nil once scrolled to.
    @State private var pendingScrollHash: String?

    private func scrollToSelection(_ hash: String, proxy: ScrollViewProxy) {
        guard model.filteredCommits.contains(where: { $0.hash == hash }) else {
            pendingScrollHash = hash
            return
        }
        pendingScrollHash = nil
        withAnimation {
            proxy.scrollTo(hash)
        }
    }

    private var commitList: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.filteredCommits) { commit in
                            CommitRowView(
                                commit: commit,
                                row: model.graph.rows[commit.hash],
                                isSelected: model.selectedCommitHash == commit.hash,
                                avatarURL: model.avatarURL(
                                    email: commit.authorEmail,
                                    size: CommitRowView.avatarSize
                                )
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectedCommitHash = commit.hash
                            }
                            .contextMenu { commitMenu(commit) }
                            .id(commit.hash)
                        }
                        if model.searchText.isEmpty, model.hasMoreCommits {
                            loadMoreRow
                        }
                    }
                }
                .onChange(of: model.selectedCommitHash) { _, hash in
                    guard let hash else {
                        pendingScrollHash = nil
                        return
                    }
                    scrollToSelection(hash, proxy: proxy)
                }
                // A sidebar ref whose tip lies beyond the loaded page selects
                // a row that doesn't exist yet; `ensureCommitLoaded` pages it
                // in, and the scroll happens once the list actually has it.
                .onChange(of: model.commits.count) { _, _ in
                    guard let hash = pendingScrollHash else { return }
                    scrollToSelection(hash, proxy: proxy)
                }
                // Tab switches rebuild this list at the top; jump straight
                // back to the selection instead of losing the position.
                .onAppear {
                    if let hash = model.selectedCommitHash {
                        proxy.scrollTo(hash, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func commitMenu(_ commit: Commit) -> some View {
        CopyCommitSHAButton(hash: commit.hash)
        Divider()
        Button("Create Branch Here…") { model.branchSheetAnchor = commit }
        Button("Create Tag Here…") { model.tagSheetAnchor = commit }
        Divider()
        // Disabled while a merge/rebase/… is stopped on conflicts, matching
        // the branch menu's merge/rebase items — git would refuse anyway.
        DetachedCheckoutButton(shortHash: commit.shortHash, isBlocked: model.pendingOperation != nil) {
            model.requestCheckoutDetached(hash: commit.hash, subject: commit.subject)
        }
        Button("Cherry-pick \(commit.shortHash)") { model.cherryPick(commit) }
            .disabled(model.pendingOperation != nil)
        Button("Revert \(commit.shortHash)") { model.revertCommit(commit) }
            .disabled(model.pendingOperation != nil)
        Button("Edit Commit \(commit.shortHash)…") { model.requestEditCommit(from: commit) }
            .disabled(model.pendingOperation != nil)
        Button("Interactive Rebase from \(commit.shortHash)…") { model.requestInteractiveRebase(from: commit) }
            .disabled(model.pendingOperation != nil)
        ResetToCommitMenu(branch: model.status.branch, isBlocked: model.pendingOperation != nil) { mode in
            model.requestReset(toHash: commit.hash, mode: mode)
        }
    }

    private var loadMoreRow: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Spacer()
        }
        .frame(height: 32)
        // Keyed on the commit count so the trigger re-fires after each page
        // lands while the row is still on screen. An all-duplicate page
        // leaves the count unchanged — loadMoreCommits itself advances past
        // those, so every call either makes progress or ends the paging.
        .task(id: model.commits.count) {
            await model.loadMoreCommits()
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Description")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Author")
                .frame(width: 150, alignment: .leading)
            Text("Date")
                .frame(width: 130, alignment: .leading)
            Text("Commit")
                .frame(width: 84, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 7)
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(0.4))
    }
}

// MARK: - Branch / tag creation sheet

struct RefCreationSheet: View {
    let title: String
    let placeholder: String
    let showCheckoutToggle: Bool
    let onCreate: (_ name: String, _ checkout: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var checkout = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(create)
            if showCheckoutToggle {
                Toggle("Check out after creating", isOn: $checkout)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed, checkout)
        dismiss()
    }
}
