import SwiftUI

/// Confirmation alerts for destructive working-copy actions (discard, hard
/// reset, stash drop).
struct WorkingCopyConfirmationAlerts: ViewModifier {
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
struct ConflictFlowAlerts: ViewModifier {
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

/// Alerts for the Commit Edit Session: the pushed-commit warning before a
/// session starts, and the abort confirmation from the session banner.
struct CommitEditAlerts: ViewModifier {
    @Bindable var model: RepoViewModel

    func body(content: Content) -> some View {
        content
            .alert(
                "Edit Pushed Commit?",
                isPresented: Binding(
                    get: { model.pendingPushedCommitEdit != nil },
                    set: { if !$0 { model.pendingPushedCommitEdit = nil } }
                ),
                presenting: model.pendingPushedCommitEdit
            ) { prep in
                Button("Edit Anyway", role: .destructive) { model.startCommitEdit(prep) }
                Button("Cancel", role: .cancel) {}
            } message: { prep in
                Text("Commit \(prep.target.shortHash) (“\(prep.target.subject)”) is already on the upstream branch. Editing it rewrites history from that commit on, and the branch will need a force push afterwards.")
            }
            .alert(
                "Abort Commit Edit?",
                isPresented: $model.pendingEditAbort,
                presenting: model.editSession
            ) { session in
                Button("Abort Edit", role: .destructive) { model.abortEditSession() }
                Button("Cancel", role: .cancel) {}
            } message: { session in
                Text("The edit of commit \(session.shortTargetHash) will be aborted and the branch restored to how it was before the edit started. The original commit comes back unchanged, but changes made to the working copy during the edit will be discarded.")
            }
            // The session can end underneath the confirmation (the rebase
            // aborted or concluded in a terminal); confirming then would run
            // a doomed `rebase --abort`.
            .onChange(of: model.editSession) {
                if model.editSession == nil {
                    model.pendingEditAbort = false
                }
            }
    }
}

/// Alerts for branch management: force push, branch delete (with an
/// unmerged-commits warning computed up front), and rename.
struct BranchManagementAlerts: ViewModifier {
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
                let stale = pending.entries.contains { entry in
                    model.branches.first { $0.name == entry.branch.name }?.tipHash != entry.branch.tipHash
                }
                if stale || model.branches.first(where: \.isCurrent)?.name != pending.head {
                    model.pendingBranchDelete = nil
                }
            }
            .alert(
                Text(model.pendingBranchDelete?.title ?? "Delete Branch?"),
                isPresented: Binding(
                    get: { model.pendingBranchDelete != nil },
                    set: { if !$0 { model.pendingBranchDelete = nil } }
                ),
                presenting: model.pendingBranchDelete
            ) { pending in
                Button(pending.confirmButtonLabel, role: .destructive) {
                    model.deleteBranches(pending.branches)
                }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(pending.message)
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
struct RemoteManagementAlerts: ViewModifier {
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
