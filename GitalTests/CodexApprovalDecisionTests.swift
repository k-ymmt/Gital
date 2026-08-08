import Foundation
import Testing
@testable import Gital

/// Unit coverage for the approval policy — a wrong answer here grants
/// repository write access to a turn contracted not to touch anything.
/// The single-turn happy paths are also covered end-to-end against a fake
/// codex in `CodexAppServerLaunchTests`; these pin the mixed-turn branches.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CodexApprovalDecisionTests {

    @Test func singleAgentTurnApproves() {
        let decision = CodexAppServer.approvalDecision(
            requestThreadID: nil,
            running: [(threadID: "t1", textOnly: false)]
        )
        #expect(decision == "approved")
    }

    @Test func singleTextOnlyTurnDenies() {
        let decision = CodexAppServer.approvalDecision(
            requestThreadID: nil,
            running: [(threadID: "t1", textOnly: true)]
        )
        #expect(decision == "denied")
    }

    @Test func threadIDAttributesToTheTextOnlyTurn() {
        // The request names the text-only turn's thread: denied, even though
        // an agent turn is also running.
        let decision = CodexAppServer.approvalDecision(
            requestThreadID: "text",
            running: [(threadID: "agent", textOnly: false), (threadID: "text", textOnly: true)]
        )
        #expect(decision == "denied")
    }

    @Test func threadIDAttributesToTheAgentTurn() {
        // The request names the agent turn's thread: approved, even though a
        // text-only turn is also running.
        let decision = CodexAppServer.approvalDecision(
            requestThreadID: "agent",
            running: [(threadID: "agent", textOnly: false), (threadID: "text", textOnly: true)]
        )
        #expect(decision == "approved")
    }

    @Test func unattributableRequestFailsClosedWhenAnyTextOnlyTurnRuns() {
        // Unknown threadId and more than one running turn: any running
        // text-only turn denies — wrongly approving grants repository
        // changes nobody asked for.
        let decision = CodexAppServer.approvalDecision(
            requestThreadID: "unknown",
            running: [(threadID: "agent", textOnly: false), (threadID: "text", textOnly: true)]
        )
        #expect(decision == "denied")
    }

    @Test func unattributableRequestApprovesWhenAllTurnsAreAgentTurns() {
        let decision = CodexAppServer.approvalDecision(
            requestThreadID: "unknown",
            running: [(threadID: "a", textOnly: false), (threadID: "b", textOnly: false)]
        )
        #expect(decision == "approved")
    }

    @Test func missingThreadIDWithSingleRunningTurnUsesThatTurn() {
        #expect(CodexAppServer.approvalDecision(
            requestThreadID: nil,
            running: [(threadID: nil, textOnly: true)]
        ) == "denied")
        #expect(CodexAppServer.approvalDecision(
            requestThreadID: nil,
            running: [(threadID: nil, textOnly: false)]
        ) == "approved")
    }

    @Test func noRunningTurnsApproves() {
        // Nothing to protect: an approval with no live turn cannot belong to
        // a text-only contract.
        #expect(CodexAppServer.approvalDecision(requestThreadID: nil, running: []) == "approved")
    }
}
