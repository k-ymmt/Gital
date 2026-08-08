import Foundation
import Testing
@testable import Gital

@MainActor
struct CodexProtocolTests {
    private func parse(_ json: String) -> CodexServerMessage? {
        CodexServerMessage.parse(Data(json.utf8))
    }

    @Test func newlineBuffer() {
        var lineBuffer = NewlineBuffer()
        let lines1 = lineBuffer.append(Data("{\"a\":1}\n{\"b\"".utf8))
        #expect(lines1.count == 1 && String(decoding: lines1[0], as: UTF8.self) == "{\"a\":1}",
                "newline buffer yields complete line, holds partial")
        let lines2 = lineBuffer.append(Data(":2}\n\n".utf8))
        #expect(lines2.count == 1 && String(decoding: lines2[0], as: UTF8.self) == "{\"b\":2}",
                "newline buffer completes split line, skips empty")
    }

    @Test func responses() {
        if case .response(let id, let result, let errorMessage)? = parse(#"{"jsonrpc":"2.0","id":10,"result":{"ok":true}}"#) {
            #expect(id == 10 && errorMessage == nil && result["ok"] as? Bool == true, "codex response parses")
        } else { Issue.record("codex response parses") }
        if case .response(_, _, let errorMessage)? = parse(#"{"jsonrpc":"2.0","id":11,"error":{"message":"boom"}}"#) {
            #expect(errorMessage == "boom", "codex error response carries message")
        } else { Issue.record("codex error response parses") }
        if case .serverRequest(let id, let method, let params)? = parse(#"{"jsonrpc":"2.0","id":"srv-1","method":"execCommandApproval","params":{"threadId":"t1"}}"#) {
            #expect(id == .string("srv-1") && method == "execCommandApproval", "codex server request keeps string id")
            #expect(params["threadId"] as? String == "t1", "codex server request carries params for turn attribution")
        } else { Issue.record("codex server request parses") }
    }

    @Test func notifications() {
        if case .notification(.agentMessageDelta(let threadID, let delta))? = parse(#"{"method":"item/agentMessage/delta","params":{"threadId":"t1","delta":"Hi"}}"#) {
            #expect(threadID == "t1" && delta == "Hi", "codex delta notification parses")
        } else { Issue.record("codex delta notification parses") }
        if case .notification(.itemStarted(_, .commandExecution(let command)))? = parse(#"{"method":"item/started","params":{"threadId":"t1","item":{"type":"commandExecution","command":"ls"}}}"#) {
            #expect(command == "ls", "codex commandExecution item parses")
        } else { Issue.record("codex commandExecution item parses") }
        if case .notification(.agentMessageCompleted(_, let text))? = parse(#"{"method":"item/completed","params":{"threadId":"t1","item":{"type":"agentMessage","text":"Done"}}}"#) {
            #expect(text == "Done", "codex agentMessage completion parses")
        } else { Issue.record("codex agentMessage completion parses") }
        if case .notification(.turnFailed(_, let message))? = parse(#"{"method":"turn/failed","params":{"threadId":"t1","error":{"message":"bad"}}}"#) {
            #expect(message == "bad", "codex turn/failed carries reason")
        } else { Issue.record("codex turn/failed parses") }
        if case .notification(.unknown(let method, _))? = parse(#"{"method":"thread/tokenCount","params":{"threadId":"t1"}}"#) {
            #expect(method == "thread/tokenCount", "unhandled codex notification classified as unknown")
        } else { Issue.record("unknown codex notification parses") }
    }

    // Side-effecting item types must classify as themselves, benign ones as
    // benign, and anything unheard-of as unrecognized — the old catch-all
    // `.other` silently swallowed mcpToolCall, letting codex run MCP tools
    // during text-only turns without tripping the side-effect guard.
    @Test func itemStartedClassification() {
        func kind(_ type: String) -> CodexNotification.ItemKind? {
            if case .notification(.itemStarted(_, let kind))? =
                parse(#"{"method":"item/started","params":{"threadId":"t1","item":{"type":"\#(type)"}}}"#) {
                return kind
            }
            return nil
        }
        #expect({ if case .mcpToolCall? = kind("mcpToolCall") { true } else { false } }(), "mcpToolCall is a side effect")
        #expect({ if case .webSearch? = kind("webSearch") { true } else { false } }(), "webSearch is a side effect")
        #expect({ if case .reasoning? = kind("reasoning") { true } else { false } }(), "reasoning is a status")
        for benign in ["agentMessage", "todoList", "error"] {
            #expect({ if case .benign? = kind(benign) { true } else { false } }(), "\(benign) is benign")
        }
        if case .unrecognized(let type)? = kind("shinyNewThing") {
            #expect(type == "shinyNewThing", "unknown item type carries its name")
        } else { Issue.record("unknown item type classifies as unrecognized (fail closed)") }
    }

    @Test func requestIDEchoesNumberAndStringExactly() {
        // JSON-RPC ids may be numbers or strings; a wrong-typed echo makes
        // codex ignore the response and the turn hangs silently.
        #expect(CodexRequestID(7) == .number(7))
        #expect(CodexRequestID(7)?.jsonValue as? Int == 7)
        #expect(CodexRequestID("srv-1") == .string("srv-1"))
        #expect(CodexRequestID("srv-1")?.jsonValue as? String == "srv-1")
        #expect(CodexRequestID(1.5) == nil)
        #expect(CodexRequestID([1]) == nil)
    }

    @Test func garbageInput() {
        #expect(parse("not json") == nil, "garbage codex line yields nil")
        #expect(parse(#"{"jsonrpc":"2.0"}"#) == nil, "empty codex object yields nil")
    }
}
