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
        // A truly empty span copies as nothing, silently dropping blank lines
        // from multi-line copies — empty lines must carry a real space.
        #expect(page.contains(#"<span class="text"> </span>"#), "empty line text is a space, not an empty span")
    }

    // WebKit on macOS 27 rejects `-webkit-focus-ring-color`, and one unknown
    // color silently kills its whole declaration (selected-line highlight
    // was invisible). Accent styling must use the standard `AccentColor`
    // system color with a plain-rgb fallback.
    @Test func accentStylingAvoidsWebkitFocusRingColor() {
        let page = DiffHTMLBuilder.interactiveUnifiedPage(
            items: DiffHTMLBuilder.unifiedItems(for: diff),
            options: interactiveOptions
        )
        #expect(!page.contains("-webkit-focus-ring-color"), "unsupported color keyword never appears")
        #expect(page.contains("@supports (color: AccentColor)"), "accent styling upgrades via AccentColor")
    }

    @Test func splitDefaultsToRightSideSelection() {
        // Keyboard Select All never passes the mousedown guard, so split
        // must start with one side (the new side) already selectable-only.
        #expect(DiffHTMLBuilder.page(for: diff, mode: .split).contains(#"<body class="sel-right">"#))
        #expect(!DiffHTMLBuilder.page(for: diff, mode: .unified).contains("sel-right\">"), "unified body carries no side class")
    }

    // MARK: - Interactive pages (Working Copy)

    private var interactiveOptions: DiffHTMLBuilder.InteractiveOptions {
        var options = DiffHTMLBuilder.InteractiveOptions()
        options.selectableLines = true
        options.askLines = true
        options.hunkButtons = [
            DiffHTMLBuilder.HunkButton(action: "discardHunk", title: "Discard", destructive: true),
            DiffHTMLBuilder.HunkButton(action: "stageHunk", title: "Stage"),
        ]
        return options
    }

    @Test func interactiveUnifiedCarriesLineIDsAndAffordances() {
        let page = DiffHTMLBuilder.interactiveUnifiedPage(
            items: DiffHTMLBuilder.unifiedItems(for: diff),
            options: interactiveOptions
        )
        #expect(page.contains(#"data-id="l1""#), "changed lines carry their ID for the bridge")
        #expect(page.contains(#"class="line del i selable""#), "changed lines are selectable")
        #expect(page.contains(#"class="line ctx i""#) && !page.contains("ctx i selable"), "context lines are never selectable")
        #expect(page.contains(#"class="ask""#), "hover ask button present")
        #expect(page.contains(#"data-hid="h0""#), "hunk header carries the hunk ID")
        #expect(page.contains(#"data-act="stageHunk""#) && page.contains(#"data-act="discardHunk""#), "hunk buttons post their actions")
        #expect(page.contains("hb destructive"), "discard is styled destructive")
        #expect(page.contains("gitalSetSelected") && page.contains("messageHandlers.gital"), "bridge script included")
    }

    @Test func interactiveSplitHasHunkButtonsButNoLineInteractivity() {
        var options = DiffHTMLBuilder.InteractiveOptions()
        options.hunkButtons = [DiffHTMLBuilder.HunkButton(action: "unstageHunk", title: "Unstage")]
        let page = DiffHTMLBuilder.interactiveSplitPage(for: diff, options: options)
        #expect(page.contains(#"data-act="unstageHunk""#) && page.contains(#"data-hid="h0""#))
        #expect(!page.contains("data-id="), "split has no per-line interactions")
        #expect(page.contains(#"<body class="sel-right">"#), "split keeps the one-side selection default")
    }

    @Test func readOnlyPagesHaveNoBridge() {
        for mode in DiffMode.allCases {
            let page = DiffHTMLBuilder.page(for: diff, mode: mode)
            #expect(!page.contains("messageHandlers"), "\(mode.rawValue): no bridge script")
            #expect(!page.contains("data-id=") && !page.contains("data-hid=") && !page.contains("data-act="), "\(mode.rawValue): no interactive attributes")
        }
    }

    // Line/hunk IDs embed the file path, which can contain quotes — they land
    // in attribute values, so escaping must cover the quote too.
    @Test func attributeSinksEscapeQuotes() {
        #expect(DiffHTMLBuilder.escapeAttr(#"a"b<c>&"#) == "a&quot;b&lt;c&gt;&amp;")
        let lines = [DiffLine(id: #"we"ird.swift@0"#, kind: .addition, text: "x", oldNumber: nil, newNumber: 1)]
        let hunk = DiffHunk(id: #"we"ird.swift@h0"#, header: "@@ -1 +1 @@", oldStart: 1, newStart: 1, lines: lines)
        let hostile = FileDiff(path: #"we"ird.swift"#, oldPath: nil, isBinary: false, hunks: [hunk])
        let page = DiffHTMLBuilder.interactiveUnifiedPage(
            items: DiffHTMLBuilder.unifiedItems(for: hostile),
            options: interactiveOptions
        )
        #expect(page.contains(#"data-id="we&quot;ird.swift@0""#), "line ID quote is escaped")
        #expect(page.contains(#"data-hid="we&quot;ird.swift@h0""#), "hunk ID quote is escaped")
        #expect(!page.contains(#"data-id="we"ird"#), "raw quote never reaches an attribute")
    }

    // Hunk headers carry raw source as function context (`@@ … @@ <context>`),
    // and split renders line text through its own sink — every one of those
    // paths must escape, not just the unified line path.
    @Test func escapesHunkHeaderAndSplitSinks() {
        let lines = [
            DiffLine(id: "l0", kind: .deletion, text: "<script>alert(1)</script>", oldNumber: 1, newNumber: nil),
            DiffLine(id: "l1", kind: .addition, text: "a && b", oldNumber: nil, newNumber: 1),
        ]
        let hunk = DiffHunk(id: "h0", header: "@@ -1 +1 @@ <script>doEvil() && more</script>", oldStart: 1, newStart: 1, lines: lines)
        let hostile = FileDiff(path: "evil.html", oldPath: nil, isBinary: false, hunks: [hunk])
        for mode in DiffMode.allCases {
            let page = DiffHTMLBuilder.page(for: hostile, mode: mode)
            #expect(!page.contains("<script>alert"), "\(mode.rawValue): line text must not reach the page raw")
            #expect(!page.contains("<script>doEvil"), "\(mode.rawValue): hunk header must not reach the page raw")
            #expect(page.contains("&lt;script&gt;alert(1)&lt;/script&gt;"), "\(mode.rawValue): line text is escaped")
            #expect(page.contains("&lt;script&gt;doEvil() &amp;&amp; more&lt;/script&gt;"), "\(mode.rawValue): hunk header is escaped")
        }
    }
}
