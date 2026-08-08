import SwiftUI

/// Popover bodies are standalone structs, not computed properties of the
/// presenting view: observable state accessed inline in a presentation
/// closure inside NavigationSplitView trips an AppKit constraint-
/// invalidation loop (uncaught exception in _postWindowNeedsUpdateConstraints,
/// FB re macOS 15.4+; structure per Apple DTS workaround).
struct NewBranchPopover: View {
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

struct StashPopover: View {
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
