import Foundation
import Observation

struct AgentMessage: Identifiable, Hashable {
    enum Role: Hashable {
        case user, agent
    }

    let id = UUID()
    let role: Role
    var text: String
}

/// One "Ask AI Agent" conversation anchored to a range of diff lines.
@Observable
final class AgentThread: Identifiable {
    let id = UUID()
    let filePath: String
    let lineRange: ClosedRange<Int>
    let anchorLineID: String
    /// PR-review threads only: the PR the question was asked in, and the
    /// anchor line's content at ask time. Display requires coordinates AND
    /// content to match — commit diffs number files differently than the
    /// whole-PR diff, so a bare positional ID could resurface the thread
    /// under an unrelated line (same rule as review comments). Both nil for
    /// working-copy threads.
    let prNumber: Int?
    let anchorLineText: String?

    var messages: [AgentMessage] = []
    var statusText: String?
    var isRunning = false

    init(
        filePath: String, lineRange: ClosedRange<Int>, anchorLineID: String,
        prNumber: Int? = nil, anchorLineText: String? = nil
    ) {
        self.filePath = filePath
        self.lineRange = lineRange
        self.anchorLineID = anchorLineID
        self.prNumber = prNumber
        self.anchorLineText = anchorLineText
    }

    var rangeLabel: String {
        let file = (filePath as NSString).lastPathComponent
        if lineRange.count == 1 {
            return "\(file) · line \(lineRange.lowerBound)"
        }
        return "\(file) · lines \(lineRange.lowerBound)–\(lineRange.upperBound)"
    }
}
