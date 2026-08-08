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
    /// Progress that changes nothing ("Thinking…").
    case status(String)
    /// Codex started running a command or editing files. Separate from
    /// `.status` so text-only consumers (commit-message generation) can treat
    /// repository side effects as a contract violation instead of pattern-
    /// matching on display strings.
    case sideEffect(String)
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
        /// Empty until setup (initialize + thread/start) completes; an empty
        /// thread ID means there is no started turn to interrupt yet.
        var threadID = ""
        /// Set for one-shot conversations: the conversation→thread mapping is
        /// dropped when this turn ends, whichever path ends it.
        let oneShotConversationID: UUID?
        /// The turn's contract is "reply with text, touch nothing". Approval
        /// requests attributed to a text-only turn are denied instead of
        /// auto-approved: the blanket "every turn is an explicit user
        /// instruction to change the repository" justification does not hold
        /// for commit-message generation.
        let textOnly: Bool
        let continuation: AsyncThrowingStream<CodexTurnEvent, Error>.Continuation
        var completed = false
        var handle: ((CodexNotification) -> Void)?

        init(
            oneShotConversationID: UUID?,
            textOnly: Bool,
            continuation: AsyncThrowingStream<CodexTurnEvent, Error>.Continuation
        ) {
            self.oneShotConversationID = oneShotConversationID
            self.textOnly = textOnly
            self.continuation = continuation
        }
    }

    private static let logger = Logger(subsystem: "app.kymmt.Gital", category: "CodexAppServer")

    /// Test hook: bypasses the locator so the launch/turn plumbing can run
    /// against a scripted fake instead of a real codex install.
    private let executableOverride: URL?

    init(executableOverride: URL? = nil) {
        self.executableOverride = executableOverride
    }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextRequestID = 10
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    /// The single turn registry: each record owns its notification handler,
    /// so registration and cleanup are one map operation (the old separate
    /// handler dictionary invited drift between the two).
    private var activeTurns: [UUID: TurnRecord] = [:]
    private var lineBuffer = NewlineBuffer()
    /// Bumped on every process replacement; stamps stdout drains so a
    /// straggling flush from a previous process's pipe cannot feed the new
    /// process's line buffer.
    private var pipeGeneration = 0
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
    /// `oneShot` marks a throwaway conversation (commit-message generation):
    /// its conversation→thread mapping is dropped when the turn ends, so the
    /// map does not grow with every use. Cleanup lives here, on the producer
    /// side, because only the actor knows whether `ensureThread` has inserted
    /// the mapping yet — a caller-side cleanup raced that insertion.
    /// `textOnly` marks a turn whose contract is "reply with text, touch
    /// nothing" (commit-message generation): its approval requests are
    /// denied instead of auto-approved.
    func runTurn(
        prompt: String, repoRoot: URL, conversationID: UUID, oneShot: Bool = false, textOnly: Bool = false
    ) -> AsyncThrowingStream<CodexTurnEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.performTurn(
                        prompt: prompt,
                        repoRoot: repoRoot,
                        conversationID: conversationID,
                        oneShot: oneShot,
                        textOnly: textOnly,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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
        oneShot: Bool,
        textOnly: Bool,
        continuation: AsyncThrowingStream<CodexTurnEvent, Error>.Continuation
    ) async throws {
        let turnID = UUID()
        let record = TurnRecord(
            oneShotConversationID: oneShot ? conversationID : nil,
            textOnly: textOnly,
            continuation: continuation
        )
        // Registered before the (slow) setup awaits: this producer task is
        // unstructured, so it survives the consumer being cancelled, and a
        // consumer that went away while codex was still launching must be
        // noticed before turn/start — or the turn runs with nobody watching
        // (and with approvals still auto-granted).
        activeTurns[turnID] = record
        continuation.onTermination = { [weak self] _ in
            Task { await self?.turnTerminated(turnID) }
        }

        let threadID: String
        do {
            try await ensureInitialized()
            threadID = try await ensureThread(conversationID: conversationID, repoRoot: repoRoot)
        } catch {
            cleanUpTurn(turnID)
            throw error
        }
        guard activeTurns[turnID] != nil else {
            // The consumer terminated during setup. turnTerminated already
            // ran, but before `ensureThread` inserted the mapping — drop it
            // here, where the insertion is known to have happened.
            endOneShot(record)
            return
        }
        record.threadID = threadID
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
                    continuation.yield(.sideEffect("$ \(command)"))
                case .fileChange:
                    continuation.yield(.sideEffect("Editing files…"))
                case .mcpToolCall:
                    continuation.yield(.sideEffect("Running a tool…"))
                case .webSearch:
                    continuation.yield(.sideEffect("Searching the web…"))
                case .reasoning:
                    continuation.yield(.status("Thinking…"))
                case .benign:
                    break
                case .unrecognized(let type):
                    // Fail closed: an unknown item type may be a new kind of
                    // side effect, so text-only consumers must get the chance
                    // to abort rather than have it silently swallowed.
                    continuation.yield(.sideEffect("Running \(type)…"))
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
        guard let record = activeTurns.removeValue(forKey: id) else { return }
        endOneShot(record)
    }

    /// Called when the stream's consumer goes away (view dismissed, task
    /// cancelled) — and also after a normal finish. If the turn is still
    /// running, tell codex to stop: it edits repository files and would keep
    /// going with nobody watching. An empty thread ID means setup hadn't
    /// finished — there is no turn to interrupt, and `performTurn` sees the
    /// removed record and never starts one (nor leaves a one-shot mapping).
    private func turnTerminated(_ id: UUID) {
        guard let record = activeTurns.removeValue(forKey: id) else { return }
        let threadID = record.threadID
        guard !threadID.isEmpty else { return }
        endOneShot(record)
        guard !record.completed else { return }
        Task {
            _ = try? await self.sendRequest(method: "turn/interrupt", params: ["threadId": threadID])
        }
    }

    /// Drops the conversation→thread mapping of a one-shot turn so the map
    /// does not grow with every commit-message generation.
    private func endOneShot(_ record: TurnRecord) {
        guard let conversationID = record.oneShotConversationID else { return }
        threadIDsByConversation[conversationID] = nil
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
        // Newer codex releases (observed on 0.145.0) queue every subsequent
        // request until the client confirms the handshake with this
        // notification — without it, thread/start never gets an answer.
        try write([
            "jsonrpc": "2.0",
            "method": "initialized",
        ])
    }

    private func launchProcess() async throws {
        // Replace any previous (dead or stale) process WITHOUT sweeping
        // turns still in setup: a first turn registers itself in
        // `activeTurns` before setup reaches this point, and the full
        // `shutdown()` that used to run here failed that fresh turn with
        // "exited unexpectedly" on every launch — while codex itself came
        // up fine underneath. Everything owned by the OLD process is swept:
        // its pending requests and started turns (normally already failed by
        // `processDidExit`, but that sweep is skipped when the exit races a
        // relaunch past the identity guard — without this, such turns leak
        // as spinners that never finish), its buffered partial output (a
        // half-line from a crashed codex would glue onto the new process's
        // first response and hang `initialize` forever), and the thread-ID
        // map.
        let old = process
        process = nil
        stdinHandle = nil
        threadIDsByConversation = [:]
        lineBuffer = NewlineBuffer()
        pipeGeneration += 1
        failPendingRequests(with: CodexError.terminated)
        failStartedTurns(with: CodexError.terminated)
        old?.terminationHandler = nil
        old?.terminate()

        let codexURL: URL
        if let executableOverride {
            codexURL = executableOverride
        } else if let found = await ExecutableLocator.shared.find("codex") {
            codexURL = found
        } else {
            throw CodexError.notInstalled
        }
        let process = Process()
        process.executableURL = codexURL
        process.arguments = ["app-server"]
        // The captured shell PATH rides along: codex itself may be a
        // PATH-dependent launcher (an npm install is `#!/usr/bin/env node`),
        // and the agent spawns git/editors/helpers that should resolve the
        // way they do in the user's terminal. Overridden launches (tests)
        // skip the capture — a unit test must not source the developer's
        // interactive shell profile.
        if executableOverride == nil {
            process.environment = await ExecutableLocator.shared.toolEnvironment()
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // The generation stamp keeps a straggling drain of the OLD pipe
        // (its handler can still be flushing when the replacement above has
        // already reset the line buffer) from corrupting the new process's
        // stream.
        let generation = pipeGeneration
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF: clear the handler or GCD spins on the closed pipe at
                // 100% CPU until the app exits.
                handle.readabilityHandler = nil
                return
            }
            Task { [weak self] in
                await self?.consume(data, generation: generation)
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
        lineBuffer = NewlineBuffer()
        failPendingRequests(with: CodexError.terminated)
        // Only turns already attached to a codex thread die with the
        // process. A turn still in setup rides on the launch/request
        // continuations — if it was waiting on this process, the request
        // failure above reaches it through its own throw path, and if it
        // had not sent anything yet it simply relaunches. Sweeping it here
        // reintroduced the launch-kills-fresh-turn bug through the
        // death-races-relaunch ordering.
        failStartedTurns(with: CodexError.terminated)
    }

    /// Fails every pending request and finishes every active turn stream —
    /// nothing may be left waiting on a process that no longer exists.
    /// Reserved for `shutdown()` (repo close), where even setup-phase turns
    /// must die; process replacement and exit use the narrower sweeps.
    private func failEverything(with error: Error) {
        failPendingRequests(with: error)
        let turns = activeTurns
        activeTurns = [:]
        for record in turns.values {
            record.completed = true
            record.continuation.finish(throwing: error)
        }
    }

    private func failPendingRequests(with error: Error) {
        let pending = pendingRequests
        pendingRequests = [:]
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }

    /// Finishes the turns already attached to a codex thread (non-empty
    /// `threadID`), sparing turns still in setup — the launch a setup turn
    /// itself triggered must never kill it.
    private func failStartedTurns(with error: Error) {
        for (id, record) in activeTurns where !record.threadID.isEmpty {
            activeTurns.removeValue(forKey: id)
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

    private func consume(_ data: Data, generation: Int) {
        guard generation == pipeGeneration else { return }  // old process's pipe
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
        case .serverRequest(let id, let method, let params):
            respond(toServerRequest: method, params: params, id: id)
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
    /// waiting (the turn silently hangs). Approval requests for agent turns
    /// are approved (those turns are an explicit user instruction to change
    /// the repository); approval requests for text-only turns are denied —
    /// commit-message generation must never grant repository changes.
    /// Anything unknown gets a method-not-found error.
    private func respond(toServerRequest method: String, params: [String: Any], id: CodexRequestID) {
        let response: [String: Any]
        if method.localizedCaseInsensitiveContains("approval") {
            response = ["jsonrpc": "2.0", "id": id.jsonValue, "result": ["decision": approvalDecision(params: params)]]
        } else {
            response = [
                "jsonrpc": "2.0", "id": id.jsonValue,
                "error": ["code": -32601, "message": "method not supported: \(method)"],
            ]
        }
        try? write(response)
    }

    private func approvalDecision(params: [String: Any]) -> String {
        // A completed record can linger in activeTurns until its async
        // cleanup runs; it must not speak for the thread it used to own.
        let running = activeTurns.values.filter { !$0.completed }
            .map { (threadID: $0.threadID, textOnly: $0.textOnly) }
        return Self.approvalDecision(
            requestThreadID: params["threadId"] as? String,
            running: running
        )
    }

    /// Denies when the approval belongs to a text-only turn. Attribution
    /// mirrors `deliver(_:)`: by threadId when the request carries one,
    /// otherwise by the single active turn. When attribution fails entirely,
    /// the presence of ANY running text-only turn denies — wrongly denying
    /// an agent turn degrades one answer, wrongly approving a text-only turn
    /// grants repository changes nobody asked for. Pure and static so the
    /// mixed-turn branches are unit-testable without a live codex process.
    static func approvalDecision(
        requestThreadID: String?,
        running: [(threadID: String?, textOnly: Bool)]
    ) -> String {
        let textOnly: Bool
        if let threadID = requestThreadID,
           running.contains(where: { $0.threadID == threadID }) {
            textOnly = running.contains { $0.threadID == threadID && $0.textOnly }
        } else if running.count == 1, let only = running.first {
            textOnly = only.textOnly
        } else {
            textOnly = running.contains { $0.textOnly }
        }
        return textOnly ? "denied" : "approved"
    }
}
