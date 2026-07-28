import SwiftUI

// MARK: - Agent composer

struct AgentComposerView: View {
    @Bindable var model: RepoViewModel
    let range: ClosedRange<Int>
    let fileName: String

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
                Text("Shift-click + to extend range")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }

            PlaceholderTextEditor(
                text: $model.agentDraft,
                placeholder: "Describe the change you want for these lines…",
                height: 54
            )
            .focused($focused)

            HStack {
                Spacer()
                Button("Cancel") {
                    model.cancelComposer()
                }
                Button("Send to Agent") {
                    model.sendToAgent()
                }
                .buttonStyle(.glassProminent)
                .disabled(model.agentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
    let thread: AgentThread

    @State private var replyText = ""

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
                    TextField("Reply to the agent…", text: $replyText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit(sendReply)
                    Button("Send", action: sendReply)
                        .controlSize(.small)
                        .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
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
        let text = replyText
        replyText = ""
        model.reply(to: thread, text: text)
    }
}
