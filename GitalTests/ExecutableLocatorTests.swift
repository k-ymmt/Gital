import Foundation
import Testing
@testable import Gital

@MainActor
struct ExecutableLocatorTests {
    private let begin = ExecutableLocator.envBeginMarker
    private let end = ExecutableLocator.envEndMarker

    @Test func parsesPathInsideFence() {
        let output = """
        Now using node v22.1.0 (npm v10.7.0)
        \(begin)
        HOME=/Users/me
        PATH=/Users/me/.local/share/mise/shims:/opt/homebrew/bin:/usr/bin
        SHELL=/bin/zsh
        \(end)
        """
        let entries = ExecutableLocator.parsePathEntries(fromEnvOutput: output)
        #expect(entries == ["/Users/me/.local/share/mise/shims", "/opt/homebrew/bin", "/usr/bin"],
                "PATH inside the fence parses into its entries")
    }

    @Test func ignoresPathShapedNoiseBeforeFence() {
        let output = """
        PATH=/fake/from/profile/banner
        \(begin)
        PATH=/real/bin
        \(end)
        """
        let entries = ExecutableLocator.parsePathEntries(fromEnvOutput: output)
        #expect(entries == ["/real/bin"], "profile noise before the fence is not mistaken for PATH")
    }

    @Test func dropsRelativeEntries() {
        let output = "\(begin)\nPATH=/usr/bin:.:relative/bin:/bin\n\(end)"
        let entries = ExecutableLocator.parsePathEntries(fromEnvOutput: output)
        #expect(entries == ["/usr/bin", "/bin"], "only absolute PATH entries survive")
    }

    @Test func failsWithoutPathOrFence() {
        #expect(ExecutableLocator.parsePathEntries(fromEnvOutput: "\(begin)\nHOME=/Users/me\n\(end)") == nil,
                "a fence without PATH is a failed capture")
        #expect(ExecutableLocator.parsePathEntries(fromEnvOutput: "PATH=/usr/bin") == nil,
                "output without the fence is a failed capture")
        #expect(ExecutableLocator.parsePathEntries(fromEnvOutput: "\(begin)\nPATH=only-relative\n\(end)") == nil,
                "a PATH with no absolute entries is a failed capture")
    }

    @Test func ignoresPathAfterFenceEnd() {
        let output = "\(begin)\nHOME=/Users/me\n\(end)\nPATH=/too/late"
        #expect(ExecutableLocator.parsePathEntries(fromEnvOutput: output) == nil,
                "PATH after the closing marker is not trusted")
    }
}
