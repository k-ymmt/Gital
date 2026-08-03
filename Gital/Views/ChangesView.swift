import SwiftUI

struct ChangesView: View {
    @Bindable var model: RepoViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if let operation = model.pendingOperation {
                ConflictBannerView(model: model, operation: operation)
                Divider()
            }

            if model.workingDiffs.isEmpty {
                emptyState
            } else {
                WorkingDiffPane(model: model)
            }

            Divider()
            CommitComposerView(model: model)
        }
        .task {
            await model.loadWorkingDiffsIfNeeded()
        }
    }

    private var headerBar: some View {
        PaneHeader {
            Text(headerTitle)
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if model.selectedChange != nil {
                Button {
                    model.selectedChange = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show all changes")
            }
            Spacer()
            DiffModePicker(mode: $model.diffMode)
        }
    }

    private var headerTitle: String {
        guard let selection = model.selectedChange else { return "All changes" }
        // A partially staged file exists on both sides; say which one is shown.
        let inBoth = model.status.staged.contains { $0.path == selection.path }
            && model.status.unstaged.contains { $0.path == selection.path }
        guard inBoth else { return selection.path }
        return selection.path + (selection.staged ? " — staged" : " — unstaged")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No changes in the working copy")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Conflict banner

/// Shown while a merge/rebase/cherry-pick/revert is stopped: names the
/// operation, counts the remaining conflicts, and offers Continue/Abort.
/// Continue stays disabled until every conflict is resolved — git would
/// reject it anyway, with a less helpful error.
struct ConflictBannerView: View {
    var model: RepoViewModel
    let operation: RepoOperation

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(operation.displayName) in progress")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(statusText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Abort…") { model.requestAbort() }
                .disabled(model.isSyncing)
            if operation != .merge {
                // Sequencer/rebase escape hatch: a cherry-pick or revert whose
                // resolution matches HEAD becomes empty, and `--continue`
                // refuses an empty commit forever — skip is the way forward.
                Button("Skip Commit") { model.skipPendingOperation() }
                    .disabled(model.isSyncing)
                    .help("Skip the commit this \(operation.displayName.lowercased()) is stopped on")
            }
            Button("Continue \(operation.displayName)") { model.continuePendingOperation() }
                .buttonStyle(.glassProminent)
                .disabled(!conflictsResolved || model.isSyncing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.orange.opacity(0.09))
    }

    private var conflictsResolved: Bool {
        model.conflictedChanges.isEmpty
    }

    private var statusText: String {
        let count = model.conflictedChanges.count
        if count == 0 {
            return "All conflicts resolved — ready to continue"
        }
        return "\(count) conflicted file\(count == 1 ? "" : "s") — resolve them, then continue"
    }
}

// MARK: - Hunk stage/unstage button

struct HunkActionButton: View {
    let title: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint))
                .padding(.horizontal, 7)
                .padding(.vertical, 1.5)
                .background(.background.opacity(0.7), in: Capsule())
                .overlay(Capsule().strokeBorder((tint ?? .accentColor).opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

// MARK: - Commit composer

struct CommitComposerView: View {
    @Bindable var model: RepoViewModel

    var body: some View {
        VStack(spacing: 10) {
            PlaceholderTextEditor(text: $model.commitMessage, placeholder: "Summary (required)")
                // Every codex delta rewrites the whole field; keystrokes made
                // between deltas would be silently destroyed.
                .disabled(model.isGeneratingCommitMessage)

            HStack(spacing: 12) {
                Toggle("Amend", isOn: $model.amend)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                Spacer()
                generateButton
                Button {
                    model.commit()
                } label: {
                    if model.isCommitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(commitLabel)
                    }
                }
                .buttonStyle(.glassProminent)
                // Amend keeps the button usable with an empty message, so an
                // explicit isCommitting check must prevent double-committing.
                .disabled((!model.canCommit && !model.amend) || model.isCommitting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// Sparkles = generate a message from the staged changes via codex;
    /// while a generation runs the same button becomes Cancel.
    private var generateButton: some View {
        Button {
            if model.isGeneratingCommitMessage {
                model.cancelCommitMessageGeneration()
            } else {
                model.generateCommitMessage()
            }
        } label: {
            if model.isGeneratingCommitMessage {
                Label("Cancel", systemImage: "stop.fill")
            } else {
                Label("Generate", systemImage: "sparkles")
            }
        }
        .disabled(!model.isGeneratingCommitMessage && (!model.canGenerateCommitMessage || model.isCommitting))
        .help(model.isGeneratingCommitMessage
            ? "Stop generating the commit message"
            : "Generate a commit message from the staged changes with Codex")
    }

    private var commitLabel: String {
        let count = model.status.staged.count
        if count == 0 { return "Commit" }
        return "Commit \(count) file\(count == 1 ? "" : "s")"
    }
}
