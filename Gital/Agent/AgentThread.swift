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

    var messages: [AgentMessage] = []
    var statusText: String?
    var isRunning = false

    init(filePath: String, lineRange: ClosedRange<Int>, anchorLineID: String) {
        self.filePath = filePath
        self.lineRange = lineRange
        self.anchorLineID = anchorLineID
    }

    var rangeLabel: String {
        let file = (filePath as NSString).lastPathComponent
        if lineRange.count == 1 {
            return "\(file) · line \(lineRange.lowerBound)"
        }
        return "\(file) · lines \(lineRange.lowerBound)–\(lineRange.upperBound)"
    }
}
