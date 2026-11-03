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

    @Test func noRunningTurnsDenies() {
        // A cancelled text-only turn's record leaves activeTurns before the
        // interrupt reaches codex; a late approval request then arrives with
        // nothing running. Approving it would execute a repository-changing
        // command nobody is watching — fail closed.
        #expect(CodexAppServer.approvalDecision(requestThreadID: nil, running: []) == "denied")
    }

    // Each approval method has its own answer vocabulary: v2 item approvals
    // take accept/decline, only the legacy v1 methods take approved/denied,
    // and a permissions request answers with the granted profile. Sending the
    // v1 words to a v2 request made every agent-turn approval undecodable.
    @Test func answerUsesTheMethodsVocabulary() {
        func decision(_ method: String, _ approve: Bool) -> String? {
            CodexAppServer.approvalResult(method: method, params: [:], approve: approve)["decision"] as? String
        }
        #expect(decision("item/commandExecution/requestApproval", true) == "accept")
        #expect(decision("item/commandExecution/requestApproval", false) == "decline")
        #expect(decision("item/fileChange/requestApproval", true) == "accept")
        #expect(decision("item/fileChange/requestApproval", false) == "decline")
        #expect(decision("execCommandApproval", true) == "approved")
        #expect(decision("applyPatchApproval", false) == "denied")
    }

    @Test func permissionsRequestGrantsRequestedProfileOrNothing() {
        let requested: [String: Any] = ["network": ["enabled": true]]
        let params: [String: Any] = ["threadId": "t1", "permissions": requested]
        let granted = CodexAppServer.approvalResult(
            method: "item/permissions/requestApproval", params: params, approve: true
        )
        #expect((granted["permissions"] as? [String: Any])?["network"] as? [String: Bool] == ["enabled": true])
        let denied = CodexAppServer.approvalResult(
            method: "item/permissions/requestApproval", params: params, approve: false
        )
        #expect((denied["permissions"] as? [String: Any])?.isEmpty == true, "a denial grants an empty profile")
        #expect(denied["decision"] == nil)
    }
}
