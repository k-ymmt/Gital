import Foundation
import Testing
@testable import Gital

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CodexAppServerLaunchTests {
    /// Writes a fake `codex app-server` that answers the handshake and one
    /// turn, returning its URL.
    private func makeFakeCodex() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("codex")
        // JSONSerialization escapes "/" as "\\/", so the wire form of the
        // method is `"thread\/start"` — the patterns must match both forms.
        let body = """
        #!/bin/zsh
        while IFS= read -r line; do
          id=$(echo "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *'"initialize"'*) echo '{"id":'$id',"result":{}}' ;;
            *'"thread/start"'*|*'"thread\\/start"'*) echo '{"id":'$id',"result":{"thread":{"id":"t1"}}}' ;;
            *'"turn/start"'*|*'"turn\\/start"'*)
              echo '{"id":'$id',"result":{}}'
              echo '{"method":"item/agentMessage/delta","params":{"threadId":"t1","delta":"fake message"}}'
              echo '{"method":"turn/completed","params":{"threadId":"t1"}}'
              ;;
          esac
        done
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    // The very first turn is registered in activeTurns before the process
    // launch runs. The launch replaces any stale previous process; it must
    // not sweep that fresh turn ("The Codex app-server process exited
    // unexpectedly" on every Generate press that triggers a launch).
    @Test func firstTurnSurvivesProcessLaunch() async throws {
        let fake = try makeFakeCodex()
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }
        let server = CodexAppServer(executableOverride: fake)

        var deltas = ""
        var completed: String?
        for try await event in await server.runTurn(
            prompt: "hi", repoRoot: URL(fileURLWithPath: "/tmp"), conversationID: UUID(), oneShot: true
        ) {
            switch event {
            case .delta(let d): deltas += d
            case .completed(let text): completed = text
            case .status, .sideEffect: break
            }
        }
        #expect(deltas == "fake message", "first turn streams deltas instead of dying at launch")
        #expect(completed == "fake message", "first turn completes with the streamed text")
        await server.shutdown()
    }

    /// A fake codex that answers turn/start with an approval request and
    /// echoes back whatever decision the client sent, as a delta.
    private func makeApprovalProbingCodex() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("codex")
        let body = """
        #!/bin/zsh
        while IFS= read -r line; do
          id=$(echo "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *'"initialize"'*) echo '{"id":'$id',"result":{}}' ;;
            *'"thread/start"'*|*'"thread\\/start"'*) echo '{"id":'$id',"result":{"thread":{"id":"t1"}}}' ;;
            *'"turn/start"'*|*'"turn\\/start"'*)
              echo '{"id":'$id',"result":{}}'
              echo '{"jsonrpc":"2.0","id":"srv-1","method":"execCommandApproval","params":{"threadId":"t1"}}'
              ;;
            *'"srv-1"'*)
              decision=$(echo "$line" | sed -n 's/.*"decision":"\\([a-z]*\\)".*/\\1/p')
              echo '{"method":"item/agentMessage/delta","params":{"threadId":"t1","delta":"decision='$decision'"}}'
              echo '{"method":"turn/completed","params":{"threadId":"t1"}}'
              ;;
          esac
        done
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    // The approval auto-grant must not extend to text-only turns: commit-
    // message generation asking codex "may I run a command?" and getting
    // "yes" defeats its own contract.
    @Test func textOnlyTurnDeniesApprovalsAgentTurnApproves() async throws {
        let fake = try makeApprovalProbingCodex()
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }
        let server = CodexAppServer(executableOverride: fake)

        func decision(textOnly: Bool) async throws -> String {
            var reply = ""
            for try await event in await server.runTurn(
                prompt: "hi", repoRoot: URL(fileURLWithPath: "/tmp"), conversationID: UUID(),
                oneShot: true, textOnly: textOnly
            ) {
                if case .delta(let delta) = event { reply += delta }
            }
            return reply
        }

        let denied = try await decision(textOnly: true)
        #expect(denied == "decision=denied", "text-only turn answers approval requests with a denial")
        let approved = try await decision(textOnly: false)
        #expect(approved == "decision=approved", "agent turns keep the approval auto-grant")
        await server.shutdown()
    }

    // Read-only turns must also deny approvals: an approval there is an
    // escalation out of the read-only sandbox — or, on an old codex whose
    // thread/start ignored the sandbox parameters, the only write
    // protection left.
    @Test func readOnlyTurnDeniesApprovals() async throws {
        let fake = try makeApprovalProbingCodex()
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }
        let server = CodexAppServer(executableOverride: fake)

        var reply = ""
        for try await event in await server.runTurn(
            prompt: "hi", repoRoot: URL(fileURLWithPath: "/tmp"), conversationID: UUID(),
            oneShot: true, readOnly: true
        ) {
            if case .delta(let delta) = event { reply += delta }
        }
        #expect(reply == "decision=denied", "read-only turn answers approval requests with a denial")
        await server.shutdown()
    }

    /// A fake codex that echoes back — as the turn's delta — whether the
    /// thread/start request carried the read-only sandbox parameters.
    private func makeSandboxProbingCodex() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("codex")
        let body = """
        #!/bin/zsh
        sandbox=absent
        approval=absent
        while IFS= read -r line; do
          id=$(echo "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *'"initialize"'*) echo '{"id":'$id',"result":{}}' ;;
            *'"thread/start"'*|*'"thread\\/start"'*)
              case "$line" in *'"sandbox":"read-only"'*) sandbox=read-only ;; esac
              case "$line" in *'"approvalPolicy":"never"'*) approval=never ;; esac
              echo '{"id":'$id',"result":{"thread":{"id":"t1"}}}' ;;
            *'"turn/start"'*|*'"turn\\/start"'*)
              echo '{"id":'$id',"result":{}}'
              echo '{"method":"item/agentMessage/delta","params":{"threadId":"t1","delta":"sandbox='$sandbox' approval='$approval'"}}'
              echo '{"method":"turn/completed","params":{"threadId":"t1"}}'
              ;;
          esac
        done
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    // Read-only conversations start their codex thread in the read-only
    // sandbox with approvals disabled; regular turns keep the bare
    // thread/start (the sandbox must never leak into working-copy threads).
    @Test func readOnlyTurnStartsThreadInReadOnlySandbox() async throws {
        let fake = try makeSandboxProbingCodex()
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }
        let server = CodexAppServer(executableOverride: fake)

        func probe(readOnly: Bool) async throws -> String {
            var reply = ""
            for try await event in await server.runTurn(
                prompt: "hi", repoRoot: URL(fileURLWithPath: "/tmp"), conversationID: UUID(),
                oneShot: true, readOnly: readOnly
            ) {
                if case .delta(let delta) = event { reply += delta }
            }
            return reply
        }

        // The regular turn runs FIRST: its bare thread/start must be bare
        // because the turn isn't read-only, not because the probe script
        // hadn't seen a sandboxed request yet.
        let bare = try await probe(readOnly: false)
        #expect(bare == "sandbox=absent approval=absent", "regular turns send a bare thread/start")
        let sandboxed = try await probe(readOnly: true)
        #expect(sandboxed == "sandbox=read-only approval=never", "read-only turns request the sandbox and disable approvals")
        await server.shutdown()
    }

    /// A fake codex predating thread/start's sandbox parameters: any
    /// thread/start mentioning them is rejected; a bare one succeeds.
    private func makeSandboxRejectingCodex() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("codex")
        let body = """
        #!/bin/zsh
        rejected=0
        while IFS= read -r line; do
          id=$(echo "$line" | sed -n 's/.*"id":\\([0-9]*\\).*/\\1/p')
          case "$line" in
            *'"initialize"'*) echo '{"id":'$id',"result":{}}' ;;
            *'"thread/start"'*|*'"thread\\/start"'*)
              case "$line" in
                *'"sandbox"'*)
                  rejected=$((rejected+1))
                  echo '{"id":'$id',"error":{"code":-32602,"message":"unknown field sandbox"}}' ;;
                *) echo '{"id":'$id',"result":{"thread":{"id":"t1"}}}' ;;
              esac ;;
            *'"turn/start"'*|*'"turn\\/start"'*)
              echo '{"id":'$id',"result":{}}'
              echo '{"method":"item/agentMessage/delta","params":{"threadId":"t1","delta":"rejections='$rejected'"}}'
              echo '{"method":"turn/completed","params":{"threadId":"t1"}}'
              ;;
          esac
        done
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    // An old codex rejecting the sandbox parameters must not break PR
    // questions: the thread retries bare (falling back to approval-denial
    // protection), and the failed probe is remembered so later read-only
    // threads skip straight to the bare form.
    @Test func sandboxRejectionFallsBackToBareThreadStart() async throws {
        let fake = try makeSandboxRejectingCodex()
        defer { try? FileManager.default.removeItem(at: fake.deletingLastPathComponent()) }
        let server = CodexAppServer(executableOverride: fake)

        func probe() async throws -> String {
            var reply = ""
            for try await event in await server.runTurn(
                prompt: "hi", repoRoot: URL(fileURLWithPath: "/tmp"), conversationID: UUID(),
                oneShot: true, readOnly: true
            ) {
                if case .delta(let delta) = event { reply += delta }
            }
            return reply
        }

        let first = try await probe()
        #expect(first == "rejections=1", "first read-only thread retries bare after the rejection")
        let second = try await probe()
        #expect(second == "rejections=1", "the rejection is remembered — no second sandboxed attempt")
        await server.shutdown()
    }
}
