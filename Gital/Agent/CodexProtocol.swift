import Foundation

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

/// Accumulates raw stdout chunks and yields complete newline-terminated
/// lines; a partial trailing line stays buffered until its newline arrives.
/// `nonisolated`: pure value type used from the CodexAppServer actor, which
/// must not hop to the main actor to buffer stdout.
nonisolated struct NewlineBuffer {
    private var buffer = Data()

    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0a) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if !lineData.isEmpty { lines.append(lineData) }
        }
        return lines
    }
}

/// A JSON-RPC request id, which the spec allows to be a number or a string.
/// Server-initiated requests must be echoed back with the exact same id.
nonisolated enum CodexRequestID: Equatable {
    case number(Int)
    case string(String)

    init?(_ raw: Any) {
        if let number = raw as? Int {
            self = .number(number)
        } else if let string = raw as? String {
            self = .string(string)
        } else {
            return nil
        }
    }

    var jsonValue: Any {
        switch self {
        case .number(let number): number
        case .string(let string): string
        }
    }
}

/// The app-server notifications this client reacts to, decoded into typed
/// payloads at the parse boundary so the turn observer is a plain switch.
nonisolated enum CodexNotification {
    enum ItemKind {
        case commandExecution(command: String)
        case fileChange
        case mcpToolCall
        case webSearch
        case reasoning
        /// Item types known to produce no side effects (agentMessage,
        /// todoList, error). Listed explicitly so that everything NOT listed
        /// falls through to `.unrecognized` — a new codex item type must be
        /// classified before it can be ignored.
        case benign
        /// An item type this client has never seen. Text-only consumers
        /// treat it as a side effect (fail closed): the old `.other` bucket
        /// silently swallowed mcpToolCall, letting codex run MCP tools
        /// during commit-message generation without tripping the guard.
        case unrecognized(type: String)
    }

    case agentMessageDelta(threadID: String?, delta: String)
    case itemStarted(threadID: String?, kind: ItemKind)
    /// `item/completed` for an agentMessage item — carries the full final text.
    case agentMessageCompleted(threadID: String?, text: String)
    case turnCompleted(threadID: String?)
    case turnFailed(threadID: String?, message: String)
    /// Anything not handled above, kept so observers can ignore it explicitly.
    case unknown(method: String, threadID: String?)

    var threadID: String? {
        switch self {
        case .agentMessageDelta(let threadID, _),
             .itemStarted(let threadID, _),
             .agentMessageCompleted(let threadID, _),
             .turnCompleted(let threadID),
             .turnFailed(let threadID, _),
             .unknown(_, let threadID):
            threadID
        }
    }
}

/// One parsed line of the codex app-server's newline-delimited JSON-RPC.
nonisolated enum CodexServerMessage {
    /// Response to one of our requests: has an id and no method. Matching on
    /// the id alone would let a server-initiated request with a colliding id
    /// swallow a pending continuation.
    case response(id: Int, result: [String: Any], errorMessage: String?)
    /// Server→client request that must be answered (has both id and method).
    /// Params ride along so approval requests can be attributed to their
    /// turn (text-only turns answer them with a denial).
    case serverRequest(id: CodexRequestID, method: String, params: [String: Any])
    /// Notification: has a method and no id.
    case notification(CodexNotification)

    /// Returns nil for lines that are not valid JSON-RPC objects.
    static func parse(_ lineData: Data) -> CodexServerMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return nil
        }
        let method = object["method"] as? String

        if method == nil {
            guard let id = object["id"] as? Int else { return nil }
            let errorMessage = (object["error"] as? [String: Any]).map {
                ($0["message"] as? String) ?? "unknown error"
            }
            return .response(
                id: id,
                result: object["result"] as? [String: Any] ?? [:],
                errorMessage: errorMessage
            )
        }

        guard let method else { return nil }
        if let rawID = object["id"], let id = CodexRequestID(rawID) {
            return .serverRequest(id: id, method: method, params: object["params"] as? [String: Any] ?? [:])
        }
        return .notification(Self.parseNotification(method: method, object: object))
    }

    private static func parseNotification(method: String, object: [String: Any]) -> CodexNotification {
        let params = object["params"] as? [String: Any] ?? [:]
        let threadID = params["threadId"] as? String

        switch method {
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String {
                return .agentMessageDelta(threadID: threadID, delta: delta)
            }
        case "item/started":
            let item = params["item"] as? [String: Any]
            switch item?["type"] as? String {
            case "commandExecution":
                return .itemStarted(threadID: threadID, kind: .commandExecution(command: item?["command"] as? String ?? ""))
            case "fileChange":
                return .itemStarted(threadID: threadID, kind: .fileChange)
            case "mcpToolCall":
                return .itemStarted(threadID: threadID, kind: .mcpToolCall)
            case "webSearch":
                return .itemStarted(threadID: threadID, kind: .webSearch)
            case "reasoning":
                return .itemStarted(threadID: threadID, kind: .reasoning)
            case "agentMessage", "todoList", "error":
                return .itemStarted(threadID: threadID, kind: .benign)
            case let type:
                return .itemStarted(threadID: threadID, kind: .unrecognized(type: type ?? "untyped item"))
            }
        case "item/completed":
            if let item = params["item"] as? [String: Any],
               item["type"] as? String == "agentMessage",
               let text = item["text"] as? String {
                return .agentMessageCompleted(threadID: threadID, text: text)
            }
        case "turn/completed":
            return .turnCompleted(threadID: threadID)
        case "turn/failed":
            let reason = ((params["error"] as? [String: Any])?["message"] as? String) ?? "unknown error"
            return .turnFailed(threadID: threadID, message: reason)
        default:
            break
        }
        return .unknown(method: method, threadID: threadID)
    }
}
