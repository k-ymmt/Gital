import Foundation
import Testing
@testable import Gital

@MainActor
struct ExecutableLocatorTests {
    private let begin = ExecutableLocator.envBeginMarker
    private let end = ExecutableLocator.envEndMarker

    /// Builds the exact byte shape the capture command produces: marker
    /// line, `env -0` output (each entry NUL-terminated), closing marker.
    private func dump(_ entries: [String], noise: String = "") -> String {
        noise + begin + "\n" + entries.map { $0 + "\0" }.joined() + end + "\n"
    }

    @Test func parsesPathInsideFence() {
        let output = dump(
            ["HOME=/Users/me",
             "PATH=/Users/me/.local/share/mise/shims:/opt/homebrew/bin:/usr/bin",
             "SHELL=/bin/zsh"],
            noise: "Now using node v22.1.0 (npm v10.7.0)\n"
        )
        let entries = ExecutableLocator.parsePathEntries(fromEnvOutput: output)
        #expect(entries == ["/Users/me/.local/share/mise/shims", "/opt/homebrew/bin", "/usr/bin"],
                "PATH inside the fence parses into its entries")
    }

    @Test func ignoresPathShapedNoiseBeforeFence() {
        let output = dump(["PATH=/real/bin"], noise: "PATH=/fake/from/profile/banner\n")
        #expect(ExecutableLocator.parsePathEntries(fromEnvOutput: output) == ["/real/bin"],
                "profile noise before the fence is not mistaken for PATH")
    }

    @Test func multilineValueCannotForgePath() {
        // An exported bash function's value spans lines and contains a
        // PATH= line at column zero; NUL separation keeps it one entry.
        let output = dump(
            ["BASH_FUNC_x%%=() {\nPATH=/evil/bin:$PATH;\n}",
             "PATH=/real/bin"]
        )
        #expect(ExecutableLocator.parsePathEntries(fromEnvOutput: output) == ["/real/bin"],
                "a PATH-shaped line inside another value is not an entry")
    }

    @Test func dropsRelativeEntries() {
        let output = dump(["PATH=/usr/bin:.:relative/bin:/bin"])
        #expect(ExecutableLocator.parsePathEntries(fromEnvOutput: output) == ["/usr/bin", "/bin"],
                "only absolute PATH entries survive")
    }

    @Test func requiresClosingMarker() {
        let truncated = begin + "\n" + "PATH=/usr/bin\0HOME=/Users/me\0"
        #expect(ExecutableLocator.parsePathEntries(fromEnvOutput: truncated) == nil,
                "a dump cut off before the closing marker is never trusted")
    }

    @Test func failsWithoutPathOrFence() {
        #expect(ExecutableLocator.parsePathEntries(fromEnvOutput: dump(["HOME=/Users/me"])) == nil,
                "a fence without PATH is a failed capture")
        #expect(ExecutableLocator.parsePathEntries(fromEnvOutput: "PATH=/usr/bin\0") == nil,
                "output without the fence is a failed capture")
        #expect(ExecutableLocator.parsePathEntries(fromEnvOutput: dump(["PATH=only-relative"])) == nil,
                "a PATH with no absolute entries is a failed capture")
    }

    @Test func ignoresPathAfterFenceEnd() {
        let output = dump(["HOME=/Users/me"]) + "PATH=/too/late\0"
        #expect(ExecutableLocator.parsePathEntries(fromEnvOutput: output) == nil,
                "PATH after the closing marker is not trusted")
    }
}

@MainActor
struct SubprocessKillEscalationTests {
    // Interactive shells ignore SIGTERM, so cancellation must escalate to
    // SIGKILL — otherwise a shell hung in its profile would survive the
    // capture timeout and wedge every locator lookup behind it forever.
    @Test func cancellationKillsSigtermImmuneChild() async throws {
        let task = Task {
            try? await Subprocess.run(
                executable: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-c", "trap '' TERM; sleep 30"]
            )
        }
        try await Task.sleep(for: .milliseconds(300))
        let start = Date()
        task.cancel()
        let result = await task.value
        let elapsed = Date().timeIntervalSince(start)
        #expect(result != nil && result?.status != 0, "killed child reports signal death, not success")
        #expect(elapsed < Subprocess.terminateGracePeriod + Subprocess.drainGracePeriod + 4,
                "SIGKILL escalation reaps a SIGTERM-immune child (took \(String(format: "%.1f", elapsed))s)")
    }
}
