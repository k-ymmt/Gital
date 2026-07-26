import Foundation

// MARK: - AI Agent

extension RepoViewModel {
    func openComposer(file: String, line: Int, anchorID: String) {
        composerFile = file
        composerRange = line...line
        composerAnchorID = anchorID
    }

    func extendComposer(file: String, line: Int, anchorID: String) {
        guard composerFile == file, let range = composerRange else {
            openComposer(file: file, line: line, anchorID: anchorID)
            return
        }
        // The composer stays anchored to the last-picked line.
        composerRange = min(range.lowerBound, line)...max(range.upperBound, line)
        composerAnchorID = anchorID
    }

    func cancelComposer() {
        composerFile = nil
        composerRange = nil
        composerAnchorID = nil
        agentDraft = ""
    }

    func sendToAgent() {
        guard let file = composerFile, let range = composerRange, let anchorID = composerAnchorID else { return }
        let instruction = agentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }

        let thread = AgentThread(filePath: file, lineRange: range, anchorLineID: anchorID)
        thread.messages.append(AgentMessage(role: .user, text: instruction))
        thread.isRunning = true
        thread.statusText = "Waiting for Codex…"
        agentThreads.append(thread)
        cancelComposer()

        let contextLines = diffContext(file: file, range: range)
        let prompt = """
        You are assisting inside the Gital git client. The user selected lines \
        \(range.lowerBound)-\(range.upperBound) of `\(file)` in their working-copy diff and asked:

        \(instruction)

        Relevant diff context:
        ```
        \(contextLines)
        ```

        Apply the requested change directly to the file(s) in this repository. \
        Keep the change minimal and focused on the selected lines. \
        When done, summarize what you changed in 1-3 sentences.
        """

        Task {
            await runAgentTurn(thread: thread, prompt: prompt)
        }
    }

    func reply(to thread: AgentThread, text: String) {
        let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !thread.isRunning else { return }
        thread.messages.append(AgentMessage(role: .user, text: instruction))
        thread.isRunning = true
        thread.statusText = "Waiting for Codex…"
        Task {
            await runAgentTurn(thread: thread, prompt: instruction)
        }
    }

    private func runAgentTurn(thread: AgentThread, prompt: String) async {
        var agentMessage = AgentMessage(role: .agent, text: "")
        var appended = false

        func upsert(_ message: AgentMessage) {
            if appended {
                thread.messages[thread.messages.count - 1] = message
            } else {
                thread.messages.append(message)
                appended = true
            }
        }

        do {
            for try await event in await codex.runTurn(prompt: prompt, repoRoot: repository.root, conversationID: thread.id) {
                switch event {
                case .status(let text):
                    thread.statusText = text
                case .delta(let delta):
                    thread.statusText = nil
                    agentMessage.text += delta
                    upsert(agentMessage)
                case .completed(let text):
                    if !text.isEmpty {
                        agentMessage.text = text
                        upsert(agentMessage)
                    }
                }
            }
        } catch {
            thread.messages.append(AgentMessage(role: .agent, text: "⚠️ \(error.localizedDescription)"))
        }

        thread.isRunning = false
        thread.statusText = nil
        await refreshStatus()
        await loadWorkingDiffs()
    }

    private func diffContext(file: String, range: ClosedRange<Int>) -> String {
        guard let diff = workingDiffs.first(where: { $0.path == file }) else { return "" }
        var lines: [String] = []
        for hunk in diff.hunks {
            let relevant = hunk.lines.contains { line in
                let number = line.newNumber ?? line.oldNumber ?? 0
                return range.contains(number)
            }
            guard relevant else { continue }
            lines.append(hunk.header)
            for line in hunk.lines {
                lines.append(line.sign + line.text)
            }
        }
        return lines.joined(separator: "\n")
    }
}
