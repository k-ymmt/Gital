import Foundation

enum CodexError: LocalizedError {
    case notInstalled
    case protocolError(String)
    case turnFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "codex CLI not found. Install it with `npm install -g @openai/codex`."
        case .protocolError(let message):
            "Codex app-server protocol error: \(message)"
        case .turnFailed(let message):
            "Codex turn failed: \(message)"
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
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var nextRequestID = 10
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var notificationHandlers: [UUID: ([String: Any]) -> Void] = [:]
    private var buffer = Data()
    private var initialized = false
    private var threadIDsByRoot: [String: String] = [:]

    // MARK: - Public API

    /// Starts (or reuses) a codex thread for the repo and runs one turn, streaming events.
    func runTurn(prompt: String, repoRoot: URL) -> AsyncThrowingStream<CodexTurnEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.performTurn(prompt: prompt, repoRoot: repoRoot, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func shutdown() {
        process?.terminate()
        process = nil
        initialized = false
        threadIDsByRoot = [:]
    }

    // MARK: - Turn plumbing

    private func performTurn(
        prompt: String,
        repoRoot: URL,
        continuation: AsyncThrowingStream<CodexTurnEvent, Error>.Continuation
    ) async throws {
        try await ensureInitialized()
        let threadID = try await ensureThread(repoRoot: repoRoot)

        var finalText = ""
        var observerID: UUID?
        let observer: ([String: Any]) -> Void = { message in
            guard let method = message["method"] as? String,
                  let params = message["params"] as? [String: Any] else { return }
            let messageThreadID = params["threadId"] as? String
            guard messageThreadID == nil || messageThreadID == threadID else { return }

            switch method {
            case "item/agentMessage/delta":
                if let delta = params["delta"] as? String {
                    finalText += delta
                    continuation.yield(.delta(delta))
                }
            case "item/started":
                if let item = params["item"] as? [String: Any],
                   let type = item["type"] as? String {
                    switch type {
                    case "commandExecution":
                        let command = item["command"] as? String ?? ""
                        continuation.yield(.status("$ \(command)"))
                    case "fileChange":
                        continuation.yield(.status("Editing files…"))
                    case "reasoning":
                        continuation.yield(.status("Thinking…"))
                    default:
                        break
                    }
                }
            case "item/completed":
                if let item = params["item"] as? [String: Any],
                   item["type"] as? String == "agentMessage",
                   let text = item["text"] as? String {
                    finalText = text
                }
            case "turn/completed":
                continuation.yield(.completed(finalText))
                continuation.finish()
            case "turn/failed":
                let reason = ((params["error"] as? [String: Any])?["message"] as? String) ?? "unknown error"
                continuation.finish(throwing: CodexError.turnFailed(reason))
            default:
                break
            }
        }
        observerID = addNotificationHandler(observer)

        continuation.onTermination = { _ in
            Task { [observerID] in
                if let observerID {
                    await self.removeNotificationHandler(observerID)
                }
            }
        }

        do {
            _ = try await sendRequest(method: "turn/start", params: [
                "threadId": threadID,
                "input": [["type": "text", "text": prompt]],
            ])
        } catch {
            if let observerID { removeNotificationHandler(observerID) }
            throw error
        }
    }

    private func ensureThread(repoRoot: URL) async throws -> String {
        if let existing = threadIDsByRoot[repoRoot.path] { return existing }
        let result = try await sendRequest(method: "thread/start", params: [
            "cwd": repoRoot.path,
        ])
        guard let thread = result["thread"] as? [String: Any],
              let threadID = thread["id"] as? String else {
            throw CodexError.protocolError("thread/start returned no thread id")
        }
        threadIDsByRoot[repoRoot.path] = threadID
        return threadID
    }

    // MARK: - Process lifecycle

    private func ensureInitialized() async throws {
        if initialized, process?.isRunning == true { return }
        try launchProcess()
        _ = try await sendRequest(method: "initialize", params: [
            "clientInfo": ["name": "gital", "title": "Gital", "version": "0.1.0"],
        ])
        initialized = true
    }

    private func launchProcess() throws {
        shutdown()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec codex app-server"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { [weak self] in
                await self?.consume(data)
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
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0a)

        guard let stdinHandle else { throw CodexError.protocolError("app-server not running") }
        try stdinHandle.write(contentsOf: data)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newlineIndex = buffer.firstIndex(of: 0x0a) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            guard !lineData.isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            dispatch(message)
        }
    }

    private func dispatch(_ message: [String: Any]) {
        if let id = message["id"] as? Int, let continuation = pendingRequests.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                let text = error["message"] as? String ?? "unknown error"
                continuation.resume(throwing: CodexError.protocolError(text))
            } else {
                continuation.resume(returning: message["result"] as? [String: Any] ?? [:])
            }
            return
        }
        for handler in notificationHandlers.values {
            handler(message)
        }
    }

    private func addNotificationHandler(_ handler: @escaping ([String: Any]) -> Void) -> UUID {
        let id = UUID()
        notificationHandlers[id] = handler
        return id
    }

    private func removeNotificationHandler(_ id: UUID) {
        notificationHandlers[id] = nil
    }
}
