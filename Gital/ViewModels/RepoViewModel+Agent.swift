import Foundation

// MARK: - AI Agent

extension RepoViewModel {
    func openComposer(file: String, lines: ClosedRange<Int>, anchorID: String) {
        composerFile = file
        composerRange = lines
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
                case .status(let text), .sideEffect(let text):
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

    // MARK: - Commit message generation

    /// There is something to describe: staged changes, or an amend (whose
    /// content is HEAD's even with an empty index).
    var canGenerateCommitMessage: Bool {
        !status.staged.isEmpty || amend
    }

    func generateCommitMessage() {
        guard !isGeneratingCommitMessage, canGenerateCommitMessage else { return }
        isGeneratingCommitMessage = true
        let amending = amend
        commitMessageTask = Task {
            defer {
                isGeneratingCommitMessage = false
                commitMessageTask = nil
            }
            await runCommitMessageGeneration(amending: amending)
        }
    }

    func cancelCommitMessageGeneration() {
        commitMessageTask?.cancel()
    }

    private func runCommitMessageGeneration(amending: Bool) async {
        do {
            let diff = try await repository.pendingCommitDiffText(amend: amending)
            guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "There are no staged changes to describe."
                return
            }
            // Context only — an unreadable HEAD message (unborn branch) must
            // not abort the generation itself.
            let current = amending ? try? await repository.headCommitMessage() : nil
            let prompt = CommitMessageGenerator.prompt(diff: diff, amend: amending, currentMessage: current)
            // Cancellation during the awaits above must not still start a
            // codex turn (`try?` on the message fetch swallows it).
            try Task.checkCancellation()
            // A fresh one-shot conversation every time: earlier generations
            // must not bias this one, and codex drops the thread mapping
            // when the turn ends.
            var reply = ""
            for try await event in await codex.runTurn(
                prompt: prompt, repoRoot: repository.root, conversationID: UUID(), oneShot: true
            ) {
                switch event {
                case .status:
                    break
                case .sideEffect(let activity):
                    // Generation is text-only, but approvals are auto-granted
                    // server-wide — a codex that starts running commands or
                    // editing files has broken the prompt contract and must
                    // be stopped (exiting the loop sends turn/interrupt),
                    // not silently tolerated.
                    throw CodexError.turnFailed(
                        "codex attempted repository changes during commit message generation (\(activity)) and was stopped. Review your working copy."
                    )
                case .delta(let delta):
                    reply += delta
                    commitMessage = reply
                case .completed(let text):
                    if !text.isEmpty { reply = text }
                }
            }
            // A cancelled stream ends without throwing; whatever streamed in
            // stays editable, but don't overwrite the field again.
            try Task.checkCancellation()
            let message = CommitMessageGenerator.extractMessage(reply)
            guard !message.isEmpty else {
                errorMessage = "Codex returned an empty commit message."
                return
            }
            commitMessage = message
        } catch is CancellationError {
        } catch {
            report(error)
        }
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
