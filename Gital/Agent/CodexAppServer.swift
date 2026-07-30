import Foundation
import os

enum CodexError: LocalizedError {
    case notInstalled
    case protocolError(String)
    case turnFailed(String)
    case terminated

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "codex CLI not found. Install it with `npm install -g @openai/codex`."
        case .protocolError(let message):
            "Codex app-server protocol error: \(message)"
        case .turnFailed(let message):
            "Codex turn failed: \(message)"
        case .terminated:
            "The Codex app-server process exited unexpectedly."
        }
    }
}

enum CodexTurnEvent {
    case status(String)
    case delta(String)
    case completed(String)
}

/// JSON-RPC client for `codex app-server` speaking newline-delimited JSON over stdio.
actor CodexAppServer {
    /// Book-keeping for one in-flight turn, including its notification
    /// handler. Mutated only on the actor's executor (dispatch + actor
    /// methods), so plain vars are safe. The handler captures the record
    /// weakly — a strong capture would be a retain cycle.
    private nonisolated final class TurnRecord: @unchecked Sendable {
        let threadID: String
        let continuation: AsyncThrowingStream<CodexTurnEvent, Error>.Continuation
        var completed = false
        var handle: ((CodexNotification) -> Void)?

        init(threadID: String, continuation: AsyncThrowingStream<CodexTurnEvent, Error>.Continuation) {
            self.threadID = threadID
            self.continuation = continuation
        }
    }

    private static let logger = Logger(subsystem: "app.kymmt.Gital", category: "CodexAppServer")

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextRequestID = 10
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    /// The single turn registry: each record owns its notification handler,
    /// so registration and cleanup are one map operation (the old separate
    /// handler dictionary invited drift between the two).
    private var activeTurns: [UUID: TurnRecord] = [:]
    private var lineBuffer = NewlineBuffer()
    private var initTask: Task<Void, Error>?
    /// Bumped whenever `initTask` is replaced; lets awaiting callers detect
    /// that the task they waited on is no longer the current one.
    private var initGeneration = 0
    private var threadIDsByConversation: [UUID: String] = [:]

    // MARK: - Public API

    /// Starts (or reuses) a codex thread for the conversation and runs one
    /// turn, streaming events. Each conversation gets its own codex thread —
    /// sharing one per repo made concurrent turns cross-talk (both observers
    /// received both answers and the first completion closed both streams).
    func runTurn(prompt: String, repoRoot: URL, conversationID: UUID) -> AsyncThrowingStream<CodexTurnEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.performTurn(
                        prompt: prompt,
                        repoRoot: repoRoot,
                        conversationID: conversationID,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Forgets the thread mapping of a one-shot conversation (commit-message
    /// generation) so the map does not grow with every use. The codex-side
    /// thread simply goes idle; a running turn is unaffected.
    func endConversation(_ id: UUID) {
        threadIDsByConversation[id] = nil
    }

    func shutdown() {
        let old = process
        process = nil
        stdinHandle = nil
        initTask = nil
        threadIDsByConversation = [:]
        failEverything(with: CodexError.terminated)
        old?.terminationHandler = nil
        old?.terminate()
    }

    // MARK: - Turn plumbing

    private func performTurn(
        prompt: String,
        repoRoot: URL,
        conversationID: UUID,
        continuation: AsyncThrowingStream<CodexTurnEvent, Error>.Continuation
    ) async throws {
        try await ensureInitialized()
        let threadID = try await ensureThread(conversationID: conversationID, repoRoot: repoRoot)

        let turnID = UUID()
        let record = TurnRecord(threadID: threadID, continuation: continuation)
        var finalText = ""
        // Thread routing happens in deliver(_:); this handler only sees
        // notifications meant for this turn.
        record.handle = { [weak self, weak record] notification in
            guard let record else { return }
            switch notification {
            case .agentMessageDelta(_, let delta):
                finalText += delta
                continuation.yield(.delta(delta))
            case .itemStarted(_, let kind):
                switch kind {
                case .commandExecution(let command):
                    continuation.yield(.status("$ \(command)"))
                case .fileChange:
                    continuation.yield(.status("Editing files…"))
                case .reasoning:
                    continuation.yield(.status("Thinking…"))
                case .other:
                    break
                }
            case .agentMessageCompleted(_, let text):
                finalText = text
            case .turnCompleted:
                record.completed = true  // before finish: onTermination must not send an interrupt
                continuation.yield(.completed(finalText))
                continuation.finish()
                Task { [weak self] in await self?.cleanUpTurn(turnID) }
            case .turnFailed(_, let message):
                record.completed = true
                continuation.finish(throwing: CodexError.turnFailed(message))
                Task { [weak self] in await self?.cleanUpTurn(turnID) }
            case .unknown:
                break
            }
        }
        activeTurns[turnID] = record

        continuation.onTermination = { [weak self] _ in
            Task { await self?.turnTerminated(turnID) }
        }

        do {
            _ = try await sendRequest(method: "turn/start", params: [
                "threadId": threadID,
                "input": [["type": "text", "text": prompt]],
            ])
        } catch {
            cleanUpTurn(turnID)
            throw error
        }
    }

    private func cleanUpTurn(_ id: UUID) {
        activeTurns[id] = nil
    }

    /// Called when the stream's consumer goes away (view dismissed, task
    /// cancelled) — and also after a normal finish. If the turn is still
    /// running, tell codex to stop: it edits repository files and would keep
    /// going with nobody watching.
    private func turnTerminated(_ id: UUID) {
        guard let record = activeTurns.removeValue(forKey: id) else { return }
        guard !record.completed else { return }
        let threadID = record.threadID
        Task {
            _ = try? await self.sendRequest(method: "turn/interrupt", params: ["threadId": threadID])
        }
    }

    private func ensureThread(conversationID: UUID, repoRoot: URL) async throws -> String {
        if let existing = threadIDsByConversation[conversationID] { return existing }
        let result = try await sendRequest(method: "thread/start", params: [
            "cwd": repoRoot.path,
        ])
        guard let thread = result["thread"] as? [String: Any],
              let threadID = thread["id"] as? String else {
            throw CodexError.protocolError("thread/start returned no thread id")
        }
        threadIDsByConversation[conversationID] = threadID
        return threadID
    }

    // MARK: - Process lifecycle

    private func ensureInitialized() async throws {
        // Single-flight: without this, two first turns interleave (the actor
        // suspends awaiting `initialize`), the second launch kills the first
        // process, and the first request hangs forever.
        while let task = initTask {
            let generation = initGeneration
            do {
                try await task.value
            } catch {
                if initGeneration == generation { initTask = nil }
                throw error
            }
            if process?.isRunning == true { return }
            if initGeneration == generation { initTask = nil }  // launched earlier but died since
        }
        initGeneration += 1
        let generation = initGeneration
        let task = Task { try await self.launchAndInitialize() }
        initTask = task
        do {
            try await task.value
        } catch {
            if initGeneration == generation { initTask = nil }
            throw error
        }
    }

    private func launchAndInitialize() async throws {
        try await launchProcess()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        _ = try await sendRequest(method: "initialize", params: [
            "clientInfo": ["name": "gital", "title": "Gital", "version": version],
        ])
    }

    private func launchProcess() async throws {
        shutdown()

        guard let codexURL = await ExecutableLocator.shared.find("codex") else {
            throw CodexError.notInstalled
        }
        let process = Process()
        process.executableURL = codexURL
        process.arguments = ["app-server"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: clear the handler or GCD spins on the closed pipe at
                // 100% CPU until the app exits.
                handle.readabilityHandler = nil
                return
            }
            Task { [weak self] in
                await self?.consume(data)
            }
        }
        // stderr must be drained too: a chatty codex blocks after ~64KB of
        // unread stderr and the whole protocol stalls. The content is noise.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty {
                handle.readabilityHandler = nil
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { [weak self] in
                await self?.processDidExit(process)
            }
        }

        do {
            try process.run()
        } catch {
            throw CodexError.notInstalled
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
    }

    private func processDidExit(_ exited: Process) {
        guard exited === process else { return }  // stale handler after a restart
        process = nil
        stdinHandle = nil
        initTask = nil
        threadIDsByConversation = [:]
        failEverything(with: CodexError.terminated)
    }

    /// Fails every pending request and finishes every active turn stream —
    /// nothing may be left waiting on a process that no longer exists.
    private func failEverything(with error: Error) {
        let pending = pendingRequests
        pendingRequests = [:]
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
        let turns = activeTurns
        activeTurns = [:]
        for record in turns.values {
            record.completed = true
            record.continuation.finish(throwing: error)
        }
    }

    // MARK: - JSON-RPC

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = nextRequestID
        nextRequestID += 1

        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        try write(message)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
        }
    }

    private func write(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0a)
        guard let stdinHandle, process?.isRunning == true else {
            throw CodexError.protocolError("app-server not running")
        }
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            throw CodexError.terminated
        }
    }

    private func consume(_ data: Data) {
        for lineData in lineBuffer.append(data) {
            guard let message = CodexServerMessage.parse(lineData) else {
                // Never drop a line silently — an unexpected shape here is
                // the first symptom of a protocol change.
                Self.logger.warning("Dropped undecodable app-server line (\(lineData.count) bytes)")
                continue
            }
            dispatch(message)
        }
    }

    private func dispatch(_ message: CodexServerMessage) {
        switch message {
        case .response(let id, let result, let errorMessage):
            guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
            if let errorMessage {
                continuation.resume(throwing: CodexError.protocolError(errorMessage))
            } else {
                continuation.resume(returning: result)
            }
        case .serverRequest(let id, let method):
            respond(toServerRequest: method, id: id)
        case .notification(let notification):
            deliver(notification)
        }
    }

    /// Routes a notification to the turns of its thread. A notification
    /// without a threadId cannot be attributed, so it is delivered only when
    /// exactly one turn is active — fanning it out to every turn recreated
    /// the cross-talk the per-conversation-thread design exists to prevent.
    private func deliver(_ notification: CodexNotification) {
        if let threadID = notification.threadID {
            for record in activeTurns.values where record.threadID == threadID {
                record.handle?(notification)
            }
        } else if activeTurns.count == 1, let record = activeTurns.values.first {
            record.handle?(notification)
        }
    }

    /// Server→client requests must be answered or codex blocks forever
    /// waiting (the turn silently hangs). Approval requests are approved:
    /// every turn in this app is an explicit user instruction to change the
    /// repository. Anything unknown gets a method-not-found error.
    private func respond(toServerRequest method: String, id: CodexRequestID) {
        let response: [String: Any]
        if method.localizedCaseInsensitiveContains("approval") {
            response = ["jsonrpc": "2.0", "id": id.jsonValue, "result": ["decision": "approved"]]
        } else {
            response = [
                "jsonrpc": "2.0", "id": id.jsonValue,
                "error": ["code": -32601, "message": "method not supported: \(method)"],
            ]
        }
        try? write(response)
    }
}
