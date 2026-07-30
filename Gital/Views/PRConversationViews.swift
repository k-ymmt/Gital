import SwiftUI

/// A published review thread shown inline under its anchor line in the PR
/// diff: the conversation so far, a reply composer, and resolve/unresolve.
struct ReviewThreadCard: View {
    var model: RepoViewModel
    let thread: ReviewThread
    let number: Int

    private var isResolving: Bool {
        model.prs.resolvingThreadIDs.contains(thread.id)
    }

    private var isCollapsed: Bool {
        thread.isResolved && !model.prs.expandedThreadIDs.contains(thread.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed {
                ForEach(thread.comments) { comment in
                    Divider()
                    commentRow(comment)
                }
                if thread.hasMoreComments {
                    Divider()
                    Text("This conversation has more comments than were fetched — open it on GitHub to read the rest.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
                Divider()
                if model.prs.replyingThreadID == thread.id {
                    replyComposer
                } else {
                    footer
                }
            }
            // Outside the collapse: a failed unresolve on a collapsed card
            // must still be able to say why nothing happened.
            if let error = model.prs.threadErrors[thread.id] {
                Divider()
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignStyle.deletion)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
        }
        .cardStyle()
        .padding(.leading, 60)
        .padding(.trailing, 16)
        .padding(.vertical, 5)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if thread.isResolved {
                threadChip("Resolved", color: DesignStyle.addition)
            }
            if thread.isOutdated {
                threadChip("Outdated", color: .secondary)
            }
            if isCollapsed, let first = thread.comments.first {
                Text("\(Text(first.displayName).foregroundStyle(.primary)): \(first.body)")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("^[\(thread.comments.count) comment](inflect: true)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isResolving {
                ProgressView().controlSize(.mini)
            } else {
                Button(thread.isResolved ? "Unresolve" : "Resolve") {
                    Task {
                        await model.prs.setThreadResolved(thread, resolved: !thread.isResolved, in: number)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(DesignStyle.linkBlue)
                .help(thread.isResolved
                    ? "Reopen this conversation"
                    : "Mark this conversation as resolved")
            }
            if thread.isResolved {
                Button {
                    if isCollapsed {
                        model.prs.expandedThreadIDs.insert(thread.id)
                    } else {
                        model.prs.expandedThreadIDs.remove(thread.id)
                    }
                } label: {
                    Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Show the resolved conversation" : "Collapse")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.3))
    }

    private func threadChip(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func commentRow(_ comment: ReviewThread.Comment) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                AvatarView(name: comment.displayName, size: 20, url: model.avatarURL(login: comment.authorLogin, size: 20))
                Text(comment.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Text(comment.createdAt)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            MarkdownPreview(markdown: comment.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Button("Reply") {
                model.prs.openReply(for: thread)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(DesignStyle.linkBlue)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var replyComposer: some View {
        @Bindable var prs = model.prs
        return VStack(alignment: .leading, spacing: 8) {
            PlaceholderTextEditor(text: $prs.replyText, placeholder: "Reply to this conversation")
                .focused($replyFocused)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    model.prs.closeReply()
                }
                .controlSize(.small)
                Button {
                    Task { await model.prs.sendReply(to: thread, in: number) }
                } label: {
                    if model.prs.isSendingReply {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Reply")
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(model.prs.isSendingReply
                    || prs.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .onAppear { replyFocused = true }
    }

    @FocusState private var replyFocused: Bool
}

/// Overview list of every review conversation on the PR, including outdated
/// threads that no longer anchor to any line of the current diff. Clicking a
/// row opens the file's diff in Files Changed.
struct ConversationsCard: View {
    var model: RepoViewModel
    let detail: PullRequestDetail

    private var threads: [ReviewThread] {
        model.prs.threads(for: detail.number)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(threads) { thread in
                row(thread)
                if thread.id != threads.last?.id {
                    Divider()
                }
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private func row(_ thread: ReviewThread) -> some View {
        // Only rows whose file is still part of the PR get click affordances;
        // an outdated thread on a since-removed change has nowhere to go.
        if detail.files.contains(where: { $0.path == thread.path }) {
            rowContent(thread)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.prs.selectItem(.file(path: thread.path), in: detail.number)
                }
                .help("Open this file's diff")
        } else {
            rowContent(thread)
        }
    }

    private func rowContent(_ thread: ReviewThread) -> some View {
        HStack(spacing: 10) {
            Image(systemName: thread.isResolved ? "checkmark.bubble" : "bubble.left")
                .font(.system(size: 12))
                .foregroundStyle(thread.isResolved ? DesignStyle.addition : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(thread.path)
                        .font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if thread.isOutdated {
                        Text("Outdated")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                if let first = thread.comments.first {
                    Text("\(Text(first.displayName).fontWeight(.medium)): \(first.body)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text("^[\(thread.comments.count) comment](inflect: true)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
