import Foundation
import Testing
@testable import Gital

@MainActor
struct DiffHTMLBuilderTests {
    private var diff: FileDiff {
        let lines = [
            DiffLine(id: "l0", kind: .context, text: "let a = 1", oldNumber: 10, newNumber: 10),
            DiffLine(id: "l1", kind: .deletion, text: "if a < 2 && b > 3 {", oldNumber: 11, newNumber: nil),
            DiffLine(id: "l2", kind: .addition, text: "if a <= 2 {", oldNumber: nil, newNumber: 11),
            DiffLine(id: "l3", kind: .addition, text: "", oldNumber: nil, newNumber: 12),
        ]
        let hunk = DiffHunk(id: "h0", header: "@@ -10,3 +10,4 @@ func f()", oldStart: 10, newStart: 10, lines: lines)
        return FileDiff(path: "Sources/A.swift", oldPath: nil, isBinary: false, hunks: [hunk])
    }

    @Test func escapesHTMLMetacharacters() {
        #expect(DiffHTMLBuilder.escape("if a < 2 && b > 3 {") == "if a &lt; 2 &amp;&amp; b &gt; 3 {")
        let page = DiffHTMLBuilder.page(for: diff, mode: .unified)
        #expect(page.contains("if a &lt; 2 &amp;&amp; b &gt; 3 {"), "line text is escaped")
        #expect(!page.contains("if a < 2 &&"), "raw metacharacters never reach the page")
    }

    @Test func unifiedRendersNumbersAsDataAttributes() {
        let page = DiffHTMLBuilder.page(for: diff, mode: .unified)
        // Numbers/signs must live in data attributes (drawn via ::before), so
        // copying a selection yields only the code text.
        #expect(page.contains(#"data-n="11""#), "old line number present as data attribute")
        #expect(page.contains(#"data-s="+""#), "addition sign present as data attribute")
        #expect(page.contains(#"class="line del""#), "deletion row is classed for styling")
        #expect(page.contains("@@ -10,3 +10,4 @@ func f()"), "hunk header rendered")
    }

    @Test func splitPairsDeletionWithAddition() {
        let page = DiffHTMLBuilder.page(for: diff, mode: .split)
        // The deletion and its paired addition share one row: left del, right add.
        #expect(page.contains(#"class="side left del""#), "deletion lands on the left side")
        #expect(page.contains(#"class="side right add""#), "addition lands on the right side")
        #expect(page.contains("sel-left"), "one-side selection guard script is included")
    }

    @Test func emptyAdditionLineStillRendersARow() {
        let page = DiffHTMLBuilder.page(for: diff, mode: .unified)
        #expect(page.contains(#"data-n="12""#), "empty added line keeps its number")
    }
}
