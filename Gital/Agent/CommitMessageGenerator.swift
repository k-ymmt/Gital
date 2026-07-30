import Foundation

/// Builds the codex prompt for AI commit-message generation and cleans up
/// the model's reply. Pure functions so the test harness can reach them.
enum CommitMessageGenerator {
    /// Cap on diff characters embedded in the prompt. The diffstat rides in
    /// front of the patch (see `pendingCommitDiffText`), so even a truncated
    /// prompt still names every file.
    static let diffCharacterLimit = 30_000

    static func prompt(diff: String, amend: Bool, currentMessage: String?) -> String {
        let (diffText, wasTruncated) = truncate(diff)
        var sections: [String] = [
            """
            You are generating a git commit message inside the Gital git client.

            Rules:
            - Reply with ONLY the commit message text: no code fences, no surrounding quotes, no commentary before or after it.
            - First line: an imperative-mood summary of at most 72 characters.
            - Add a body only when the change needs explanation beyond the summary; separate it with a blank line and wrap it at 72 columns.
            - Do not run any commands and do not modify any files — everything needed is below.
            """
        ]
        if amend {
            var note = "The user is amending the HEAD commit; the diff below is the full content of the amended commit."
            if let currentMessage, !currentMessage.isEmpty {
                note += "\n\nThe commit's current message, for reference:\n\(currentMessage)"
            }
            sections.append(note)
        }
        var diffSection = "Diff of the commit's content:\n```\n\(diffText)\n```"
        if wasTruncated {
            diffSection += "\n(The patch was truncated to \(diffCharacterLimit) characters; the diffstat at the top covers every file.)"
        }
        sections.append(diffSection)
        return sections.joined(separator: "\n\n")
    }

    static func truncate(_ diff: String, limit: Int = diffCharacterLimit) -> (text: String, truncated: Bool) {
        guard diff.count > limit else { return (diff, false) }
        return (String(diff.prefix(limit)), true)
    }

    /// Extracts the usable message from a model reply: unwraps a reply that
    /// is entirely one fenced code block, strips matching quotes from a
    /// single-line reply, and trims surrounding whitespace.
    static func extractMessage(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = unwrapFence(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("\n") {
            for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'"), ("`", "`")] {
                if text.count > 2, text.hasPrefix(open), text.hasSuffix(close) {
                    text = String(text.dropFirst(open.count).dropLast(close.count))
                        .trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }
        return text
    }

    /// If the whole reply is one fenced block (the opening fence may carry a
    /// language tag, the closing fence must be bare), returns its body.
    private static func unwrapFence(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return text }
        let first = lines[0].trimmingCharacters(in: .whitespaces)
        let last = lines[lines.count - 1].trimmingCharacters(in: .whitespaces)
        for fence in ["```", "~~~"] where first.hasPrefix(fence) && last == fence {
            return lines[1..<(lines.count - 1)].joined(separator: "\n")
        }
        return text
    }
}
