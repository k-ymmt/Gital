import Foundation
import Testing
@testable import Gital

@MainActor
struct PRConversationTests {
    static let sampleResponse = """
    {
      "data": {
        "repository": {
          "pullRequest": {
            "reviewThreads": {
              "nodes": [
                {
                  "id": "RT_kwDO1",
                  "isResolved": false,
                  "isOutdated": false,
                  "path": "Sources/App.swift",
                  "line": 12,
                  "diffSide": "RIGHT",
                  "comments": {
                    "nodes": [
                      {
                        "databaseId": 101,
                        "body": "Should this be optional?",
                        "createdAt": "2026-07-28T10:00:00Z",
                        "author": { "login": "alice" },
                        "diffHunk": "@@ -10,3 +10,4 @@ func run() {\\n context\\n-    old()\\n+    new()"
                      },
                      {
                        "databaseId": 102,
                        "body": "Yes, will fix.",
                        "createdAt": "2026-07-28T11:00:00Z",
                        "author": null,
                        "diffHunk": "@@ -10,3 +10,4 @@ func run() {\\n context\\n-    old()\\n+    new()"
                      }
                    ]
                  }
                },
                {
                  "id": "RT_kwDO2",
                  "isResolved": true,
                  "isOutdated": true,
                  "path": "README.md",
                  "line": null,
                  "diffSide": "LEFT",
                  "comments": {
                    "nodes": [
                      {
                        "databaseId": 201,
                        "body": "Typo here",
                        "createdAt": "2026-07-20T09:00:00Z",
                        "author": { "login": "bob" },
                        "diffHunk": "@@ -3,2 +3,1 @@\\n-Ths line"
                      }
                    ]
                  }
                },
                {
                  "id": "RT_kwDO3",
                  "isResolved": false,
                  "isOutdated": false,
                  "path": "Sources/App.swift",
                  "line": 30,
                  "diffSide": "RIGHT",
                  "comments": {
                    "nodes": [
                      {
                        "databaseId": null,
                        "body": "pending-review draft on the server",
                        "createdAt": "2026-07-29T09:00:00Z",
                        "author": { "login": "carol" },
                        "diffHunk": null
                      }
                    ]
                  }
                }
              ]
            }
          }
        }
      }
    }
    """

    @Test func parseThreads() throws {
        let threads = try GitHubService.parseReviewThreads(Data(Self.sampleResponse.utf8))
        // The third thread's only comment has no databaseId (a server-side
        // pending draft) — it can't be replied to and the thread is dropped.
        #expect(threads.count == 2)

        let first = threads[0]
        #expect(first.id == "RT_kwDO1")
        #expect(first.path == "Sources/App.swift")
        #expect(first.side == .right)
        #expect(first.line == 12)
        #expect(first.lineText == "    new()", "line content comes from the anchor comment's diffHunk, prefix stripped")
        #expect(!first.isResolved)
        #expect(!first.isOutdated)
        #expect(first.comments.map(\.id) == [101, 102])
        #expect(first.comments[0].authorLogin == "alice")
        #expect(first.comments[1].authorLogin == "unknown", "deleted accounts come through with a null author")
        #expect(first.comments[0].body == "Should this be optional?")
        #expect(!first.comments[0].createdAt.isEmpty)

        let outdated = threads[1]
        #expect(outdated.line == nil, "outdated threads carry no current-diff line")
        #expect(outdated.side == .left)
        #expect(outdated.isResolved && outdated.isOutdated)
        #expect(outdated.lineText == "Ths line")
    }

    @Test func parseThreadsMissingPR() throws {
        let json = #"{"data": {"repository": {"pullRequest": null}}}"#
        let threads = try GitHubService.parseReviewThreads(Data(json.utf8))
        #expect(threads.isEmpty)
    }

    @Test func lineTextFromDiffHunk() {
        #expect(ReviewThread.lineText(fromDiffHunk: "@@ -1,2 +1,2 @@\n context\n+added") == "added")
        #expect(ReviewThread.lineText(fromDiffHunk: "@@ -1,1 +1,1 @@\n-removed") == "removed")
        // An empty context line in the original file is a lone space in the
        // hunk — it strips to "" just like DiffParser's output.
        #expect(ReviewThread.lineText(fromDiffHunk: "@@ -1,1 +1,1 @@\n ") == "")
        // "\ No newline at end of file" trails the real content line.
        #expect(ReviewThread.lineText(fromDiffHunk: "@@ -1,1 +1,1 @@\n+last\n\\ No newline at end of file") == "last")
        #expect(ReviewThread.lineText(fromDiffHunk: "@@ -0,0 +1 @@") == nil, "header-only excerpt has no content line")
        #expect(ReviewThread.lineText(fromDiffHunk: nil) == nil)
    }

    @Test func threadAnchoring() {
        func thread(line: Int?, side: ReviewCommentAnchor.Side = .right, lineText: String?) -> ReviewThread {
            ReviewThread(
                id: "t", path: "a.swift", side: side, line: line, lineText: lineText,
                isResolved: false, isOutdated: false,
                comments: [.init(id: 1, authorLogin: "alice", body: "hi", createdAt: "now")]
            )
        }
        let addition = DiffLine(id: "a.swift@0", kind: .addition, text: "new", oldNumber: nil, newNumber: 12)
        let deletion = DiffLine(id: "a.swift@1", kind: .deletion, text: "old", oldNumber: 12, newNumber: nil)

        #expect(thread(line: 12, lineText: "new").isAnchored(to: addition, path: "a.swift"))
        #expect(!thread(line: 12, lineText: "new").isAnchored(to: addition, path: "b.swift"), "path must match")
        #expect(!thread(line: 12, lineText: "other").isAnchored(to: addition, path: "a.swift"),
                "same coordinates with different content stay hidden — the commit diff numbers files differently")
        #expect(thread(line: 12, lineText: nil).isAnchored(to: addition, path: "a.swift"),
                "without recovered content, coordinates alone decide")
        #expect(!thread(line: nil, lineText: nil).isAnchored(to: addition, path: "a.swift"),
                "outdated threads never anchor inline")
        #expect(thread(line: 12, side: .left, lineText: "old").isAnchored(to: deletion, path: "a.swift"))
        #expect(!thread(line: 12, side: .left, lineText: "old").isAnchored(to: addition, path: "a.swift"))
    }

    @Test func replyBody() throws {
        let data = try GitHubService.replyBody("Sounds good \"quoted\"")
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: String]
        #expect(decoded == ["body": "Sounds good \"quoted\""])
    }
}
