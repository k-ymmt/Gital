import SwiftUI

// MARK: - Agent composer

struct AgentComposerView: View {
    @Binding var text: String
    let range: ClosedRange<Int>
    let fileName: String
    /// Trailing hint in the header row; the panes teach different range
    /// gestures (working copy: shift-click; PR review: text selection).
    var hint: String?
    var placeholder = "Describe the change you want for these lines…"
    let onCancel: () -> Void
    let onSend: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(.tint)
                Text("Ask AI Agent")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(rangeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if let hint {
                    Text(hint)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }

            PlaceholderTextEditor(
                text: $text,
                placeholder: placeholder,
                height: 54
            )
            .focused($focused)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Send to Agent", action: onSend)
                    .buttonStyle(.glassProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(13)
        .glassEffect(in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .onAppear { focused = true }
    }

    private var rangeLabel: String {
        range.count == 1
            ? "\(fileName) · line \(range.lowerBound)"
            : "\(fileName) · lines \(range.lowerBound)–\(range.upperBound)"
    }
}

// MARK: - Agent thread

struct AgentThreadView: View {
    @Bindable var model: RepoViewModel
    @Bindable var thread: AgentThread

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(thread.rangeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if thread.isRunning {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.3))

            Divider()

            ForEach(thread.messages) { message in
                HStack(alignment: .top, spacing: 10) {
                    if message.role == .agent {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(DesignStyle.mergedPurple, in: Circle())
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.accentColor, in: Circle())
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.role == .agent ? "Codex" : "You")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(message.text)
                            .font(.system(size: 12.5))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            if let status = thread.statusText, thread.isRunning {
                Text(status)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            if !thread.isRunning {
                Divider()
                HStack(spacing: 8) {
                    TextField("Reply to the agent…", text: $thread.replyDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit(sendReply)
                    Button("Send", action: sendReply)
                        .controlSize(.small)
                        .disabled(thread.replyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
        .cardStyle(cornerRadius: 10)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func sendReply() {
        let text = thread.replyDraft
        thread.replyDraft = ""
        model.reply(to: thread, text: text)
    }
}
