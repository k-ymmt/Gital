//
//  ContentView.swift
//  Gital
//

import SwiftUI

struct ContentView: View {
    @Bindable var model: RepoViewModel

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

                Menu {
                    Button("Force Push (with Lease)…") {
                        model.pendingForcePush = true
                    }
                } label: {
                    Label("Push", systemImage: "arrow.up.to.line")
                } primaryAction: {
                    model.push()
                }
                .badge(model.status.ahead)
                .help("Push (ahead \(model.status.ahead))")
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
                if model.isSyncing {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    model.isCreatingBranch = true
                } label: {
                    Label("Branch", systemImage: "arrow.triangle.branch")
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
        .onAppear { model.isWindowHosted = true }
        .onDisappear { model.isWindowHosted = false }
    }

}

/// Xcode-style repository switcher in the center of the window toolbar:
/// the open repository's name and current branch, with a menu of recent
/// repositories to switch to.
private struct RepositorySwitcher: View {
    let model: RepoViewModel
    @Environment(AppModel.self) private var appModel

    var body: some View {
        // The texts sit OUTSIDE the Menu: a Menu label in a toolbar renders
        // icon-only on macOS 27 beta (the Texts silently disappear), so only
        // the chevron is the Menu and the badge/name/branch are plain views.
        HStack(spacing: 8) {
            Text(String(model.repository.name.prefix(1)).uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(
                    LinearGradient(
                        colors: [DesignStyle.linkBlue, DesignStyle.brandBlue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 5)
                )

            VStack(alignment: .leading, spacing: 0) {
                Text(Self.middleEllipsized(model.repository.name, maxLength: 36))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(Self.middleEllipsized(subtitle, maxLength: 44))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Menu {
                Button("Open Another Repository…") {
                    appModel.pickRepository()
                }
                ForEach(appModel.recentRepositories, id: \.path) { url in
                    Button {
                        appModel.openRepository(at: url)
                    } label: {
                        Text(url.lastPathComponent)
                        Text(Self.abbreviatedPath(for: url))
                    }
                    // The open repo is always the first recent; reopening it
                    // would tear down and rebuild the whole repo state for
                    // nothing.
                    .disabled(url.standardizedFileURL.path == model.repository.root.standardizedFileURL.path)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Switch repository")
        }
        // minWidth gives the control an Xcode-like wide footprint even for
        // short names (content stays centered inside). fixedSize is
        // load-bearing: the toolbar compresses a flexible item to its
        // minimum, which collapses the texts to nothing (verified on macOS
        // 27 beta). Under fixedSize the frame resolves to
        // max(minWidth, ideal), and Text truncation can never engage —
        // overlong names are ellipsized in the string itself instead.
        .frame(minWidth: 320)
        .padding(.vertical, 5)
        // Own capsule: the item opts out of the toolbar's shared glass
        // background (sharedBackgroundVisibility(.hidden) in ContentView).
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
        .help(model.repository.displayPath)
    }

    /// Detached HEAD shows where HEAD actually is — a bare "detached HEAD"
    /// gives no way to tell which commit the working copy reflects.
    private var subtitle: String {
        if let branch = model.status.branch { return branch }
        if let oid = model.status.headOID { return "Detached HEAD at \(String(oid.prefix(7)))" }
        return "Detached HEAD"
    }

    /// Menu items ignore Text line-limit/truncation modifiers, so ellipsize the string itself.
    private static func abbreviatedPath(for url: URL, maxLength: Int = 48) -> String {
        middleEllipsized(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), maxLength: maxLength)
    }

    private static func middleEllipsized(_ string: String, maxLength: Int) -> String {
        guard string.count > maxLength else { return string }
        let head = string.prefix((maxLength - 1) / 2)
        let tail = string.suffix(maxLength / 2)
        return "\(head)…\(tail)"
    }
}

/// Popover bodies are standalone structs, not computed properties of the
/// presenting view: observable state accessed inline in a presentation
/// closure inside NavigationSplitView trips an AppKit constraint-
/// invalidation loop (uncaught exception in _postWindowNeedsUpdateConstraints,
/// FB re macOS 15.4+; structure per Apple DTS workaround).
private struct NewBranchPopover: View {
    let model: RepoViewModel
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Branch")
                .font(.headline)
            TextField("Branch name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel") { model.isCreatingBranch = false }
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func create() {
        model.createBranch(name: name)
        model.isCreatingBranch = false
    }
}

private struct StashPopover: View {
    let model: RepoViewModel
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stash Changes")
                .font(.headline)
            TextField("Message (optional)", text: $message)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(stash)
            HStack {
                Spacer()
                Button("Cancel") { model.isStashing = false }
                Button("Stash") { stash() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.status.staged.isEmpty && model.status.unstaged.isEmpty)
            }
        }
        .padding(16)
    }

    private func stash() {
        model.stashPush(message: message)
        model.isStashing = false
    }
}

/// Confirmation alerts for destructive working-copy actions (discard, hard
/// reset, stash drop).
private struct WorkingCopyConfirmationAlerts: ViewModifier {
    @Bindable var model: RepoViewModel

    func body(content: Content) -> some View {
        content
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
                    model.performReset(toHash: pending.hash, mode: pending.mode)
                }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text("“\(model.status.branch ?? "HEAD")” will be reset to \(pending.shortHash) and all working copy changes will be discarded. This cannot be undone.")
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
    }
}

/// Alerts for the merge/rebase conflict flow (abort confirmation, staging a
/// file that still contains conflict markers) plus the generic git error.
private struct ConflictFlowAlerts: ViewModifier {
    @Bindable var model: RepoViewModel

    func body(content: Content) -> some View {
        content
            .alert(
                "Abort \(model.pendingAbort?.displayName ?? "Operation")?",
                isPresented: Binding(
                    get: { model.pendingAbort != nil },
                    set: { if !$0 { model.pendingAbort = nil } }
                ),
                presenting: model.pendingAbort
            ) { operation in
                Button("Abort \(operation.displayName)", role: .destructive) {
                    model.abortOperation(operation)
                }
                Button("Cancel", role: .cancel) {}
            } message: { operation in
                Text("The \(operation.displayName.lowercased()) will be aborted and the repository restored to its previous state. Conflict resolutions made so far will be lost.")
            }
            .alert(
                "Conflict Markers Remain",
                isPresented: Binding(
                    get: { model.pendingMarkResolved != nil },
                    set: { if !$0 { model.pendingMarkResolved = nil } }
                ),
                presenting: model.pendingMarkResolved
            ) { change in
                Button("Mark as Resolved Anyway") { model.stage(change) }
                Button("Cancel", role: .cancel) {}
            } message: { change in
                Text("“\(change.path)” still contains “<<<<<<<” conflict markers. Marking it resolved will stage the file as is, and the markers can end up in the next commit.")
            }
            // The stopped operation can be concluded or aborted from a
            // terminal while the abort confirmation sits open; confirming
            // then would run a doomed `--abort`. Dismiss the alert when the
            // operation disappears.
            .onChange(of: model.pendingOperation) {
                if model.pendingOperation == nil {
                    model.pendingAbort = nil
                }
            }
            .alert("Git Error", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
    }
}

/// Alerts for branch management: force push, branch delete (with an
/// unmerged-commits warning computed up front), and rename.
private struct BranchManagementAlerts: ViewModifier {
    @Bindable var model: RepoViewModel
    @State private var renameDraft = ""

    func body(content: Content) -> some View {
        content
            .alert(
                "Force Push?",
                isPresented: $model.pendingForcePush
            ) {
                Button("Force Push", role: .destructive) { model.push(force: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let upstream = model.status.upstream {
                    Text("“\(model.status.branch ?? "HEAD")” will overwrite “\(upstream)” with --force-with-lease. Commits that exist only on the remote will be discarded, and anyone tracking the branch will have to recover.")
                } else {
                    Text("“\(model.status.branch ?? "HEAD")” has no upstream yet — it will be published to origin. Nothing is overwritten.")
                }
            }
            // The confirmation's target is "the current branch", resolved at
            // execution time — if HEAD moves (terminal checkout) while the
            // alert is open, confirming would force-push a branch the alert
            // never named. Same for the delete confirmation: its unmerged
            // count is a snapshot relative to the branch tip and HEAD at
            // request time; commits arriving on the branch or a HEAD switch
            // would let the user confirm against a stale "safe" message.
            .onChange(of: model.status.branch) {
                model.pendingForcePush = false
            }
            .onChange(of: model.branches) {
                guard let pending = model.pendingBranchDelete else { return }
                let live = model.branches.first { $0.name == pending.branch.name }
                if live?.tipHash != pending.branch.tipHash
                    || model.branches.first(where: \.isCurrent)?.name != pending.head {
                    model.pendingBranchDelete = nil
                }
            }
            .alert(
                "Delete Branch?",
                isPresented: Binding(
                    get: { model.pendingBranchDelete != nil },
                    set: { if !$0 { model.pendingBranchDelete = nil } }
                ),
                presenting: model.pendingBranchDelete
            ) { pending in
                Button("Delete", role: .destructive) { model.deleteBranch(pending.branch) }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                switch pending.unmergedCount {
                case nil:
                    Text("“\(pending.branch.name)” will be deleted. Whether its commits are reachable elsewhere could not be determined — they may be lost. This cannot be undone.")
                case 0:
                    Text("“\(pending.branch.name)” will be deleted. Its commits are all reachable from “\(pending.head ?? "HEAD")”.")
                case let count?:
                    Text("“\(pending.branch.name)” has \(count) commit(s) not on “\(pending.head ?? "HEAD")”. Unless another branch or tag points at them, deleting the branch loses them. This cannot be undone.")
                }
            }
            .alert(
                "Checkout Commit?",
                isPresented: Binding(
                    get: { model.pendingDetachedCheckout != nil },
                    set: { if !$0 { model.pendingDetachedCheckout = nil } }
                ),
                presenting: model.pendingDetachedCheckout
            ) { request in
                Button("Checkout") { model.checkoutDetached(request) }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text("HEAD will detach at \(request.shortHash) (“\(request.subject)”) — you will be on no branch. Commits made here are kept in the reflog but easy to lose; create a branch to keep them. Check out any branch to return to normal.")
            }
            .alert(
                "Rename Branch",
                isPresented: Binding(
                    get: { model.renamingBranch != nil },
                    set: { if !$0 { model.renamingBranch = nil } }
                ),
                presenting: model.renamingBranch
            ) { branch in
                TextField("Branch name", text: $renameDraft)
                Button("Rename") { model.renameBranch(branch, to: renameDraft) }
                Button("Cancel", role: .cancel) {}
            } message: { branch in
                Text("Enter a new name for “\(branch.name)”.")
            }
            .onChange(of: model.renamingBranch) {
                if let branch = model.renamingBranch {
                    renameDraft = branch.name
                }
            }
    }
}

/// Alerts for remote management: add a remote, remove one, and delete a
/// branch on the remote.
private struct RemoteManagementAlerts: ViewModifier {
    @Bindable var model: RepoViewModel
    @State private var remoteNameDraft = ""
    @State private var remoteURLDraft = ""

    func body(content: Content) -> some View {
        content
            .alert("Add Remote", isPresented: $model.isAddingRemote) {
                TextField("Name (e.g. origin)", text: $remoteNameDraft)
                TextField("URL", text: $remoteURLDraft)
                Button("Add") { model.addRemote(name: remoteNameDraft, url: remoteURLDraft) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The remote will be added to this repository's configuration.")
            }
            .onChange(of: model.isAddingRemote) {
                if model.isAddingRemote {
                    remoteNameDraft = model.remotes.isEmpty ? "origin" : ""
                    remoteURLDraft = ""
                }
            }
            .alert(
                "Remove Remote?",
                isPresented: Binding(
                    get: { model.pendingRemoteRemoval != nil },
                    set: { if !$0 { model.pendingRemoteRemoval = nil } }
                ),
                presenting: model.pendingRemoteRemoval
            ) { remote in
                Button("Remove", role: .destructive) { model.removeRemote(remote) }
                Button("Cancel", role: .cancel) {}
            } message: { remote in
                Text("“\(remote.name)” and its remote-tracking branches will be removed from this repository. The remote repository itself is not touched.")
            }
            .alert(
                "Delete Remote Branch?",
                isPresented: Binding(
                    get: { model.pendingRemoteBranchDelete != nil },
                    set: { if !$0 { model.pendingRemoteBranchDelete = nil } }
                ),
                presenting: model.pendingRemoteBranchDelete
            ) { ref in
                Button("Delete on Remote", role: .destructive) { model.deleteRemoteBranch(ref) }
                Button("Cancel", role: .cancel) {}
            } message: { ref in
                Text("“\(ref.branch)” will be deleted on “\(ref.remote)” for everyone using that remote. This cannot be undone from this app.")
            }
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
