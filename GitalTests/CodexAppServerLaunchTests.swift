import Foundation
import Testing
@testable import Gital

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
}
