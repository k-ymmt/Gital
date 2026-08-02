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
        #expect(DiffHTMLBuilder.page(for: diff, mode: .split).contains(#"<body class="sel-right""#))
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
        #expect(!page.contains(#"class="ask""#), "no per-line ask button — the frame's corner + asks about ranges")
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
        #expect(page.contains(#"<body class="sel-right""#), "split keeps the one-side selection default")
    }

    // The split page renders through its own sinks (`splitSide`, and
    // `hunkHeader` reached via `splitBody`) — the empty-line-space and
    // attribute-escaping invariants must be pinned there too, not only
    // through the unified path that happens to share code today.
    @Test func splitPageKeepsEmptyLinesAndEscapesHunkIDs() {
        let plain = DiffHTMLBuilder.interactiveSplitPage(for: diff, options: interactiveOptions)
        #expect(plain.contains(#"<span class="text"> </span>"#), "empty added line copies as a blank line in split too")

        let lines = [DiffLine(id: #"we"ird.swift@0"#, kind: .addition, text: "", oldNumber: nil, newNumber: 1)]
        let hunk = DiffHunk(id: #"we"ird.swift@h0"#, header: "@@ -1 +1 @@", oldStart: 1, newStart: 1, lines: lines)
        let hostile = FileDiff(path: #"we"ird.swift"#, oldPath: nil, isBinary: false, hunks: [hunk])
        let page = DiffHTMLBuilder.interactiveSplitPage(for: hostile, options: interactiveOptions)
        #expect(page.contains(#"data-hid="we&quot;ird.swift@h0""#), "split hunk ID quote is escaped")
        #expect(!page.contains(#"data-hid="we"ird"#), "raw quote never reaches a split attribute")
    }

    // The selection frame's Stage/Unstage/Discard capsules clone from a
    // Swift-rendered <template>, so titles/actions never live in JS strings.
    @Test func selectionFrameButtonsRenderAsTemplate() {
        var options = interactiveOptions
        options.selectionButtons = [
            DiffHTMLBuilder.HunkButton(action: "stageLines", title: "Stage"),
            DiffHTMLBuilder.HunkButton(action: "discardLines", title: "Discard", destructive: true),
        ]
        let page = DiffHTMLBuilder.interactiveUnifiedPage(items: DiffHTMLBuilder.unifiedItems(for: diff), options: options)
        #expect(page.contains(#"<template id="selbtns">"#), "clone template present")
        #expect(page.contains(#"data-act="stageLines""#) && page.contains(#"data-act="discardLines""#), "buttons post their actions")
        #expect(page.contains("hb selb destructive"), "discard capsule is destructive")

        let bare = DiffHTMLBuilder.interactiveUnifiedPage(items: DiffHTMLBuilder.unifiedItems(for: diff), options: interactiveOptions)
        #expect(!bare.contains("<template"), "no template when the page has no selection buttons")
    }

    // Mouse text selection frames the rows it spans (blue outline). The
    // machinery lives in the bridge script/CSS, so it must reach both
    // interactive layouts and never the read-only pages.
    @Test func interactivePagesFrameTextSelectedRows() {
        let unified = DiffHTMLBuilder.interactiveUnifiedPage(
            items: DiffHTMLBuilder.unifiedItems(for: diff),
            options: interactiveOptions
        )
        let split = DiffHTMLBuilder.interactiveSplitPage(for: diff, options: interactiveOptions)
        for page in [unified, split] {
            #expect(page.contains("selectionchange"), "selection tracking script included")
            #expect(page.contains(".tsel::after"), "selection frame CSS included")
            #expect(page.contains("tsel-first") && page.contains("tsel-last"), "run edges draw top/bottom borders")
            #expect(page.contains("askRange"), "frame's + button posts the selected range")
        }
        for mode in DiffMode.allCases {
            let page = DiffHTMLBuilder.page(for: diff, mode: mode)
            #expect(!page.contains("tsel"), "\(mode.rawValue): read-only pages have no selection frame")
            #expect(!page.contains("askRange"), "\(mode.rawValue): read-only pages have no range-ask button")
        }
    }

    // Hovering a hunk frames its whole line run like a text selection, with
    // the same corner buttons ("+" / Stage / Unstage / Discard). The frame
    // is interactive-only machinery and must never reach read-only pages.
    @Test func interactivePagesFrameHoveredHunks() {
        let page = DiffHTMLBuilder.interactiveUnifiedPage(
            items: DiffHTMLBuilder.unifiedItems(for: diff),
            options: interactiveOptions
        )
        #expect(page.contains(".tsel::after, .hsel::after"), "hover frame shares the selection frame's border styling")
        #expect(page.contains("hsel-first") && page.contains("hsel-last"), "hover frame draws its top/bottom edges")
        #expect(page.contains("mouseover") && page.contains("clearHover"), "hover tracking script included")
        #expect(page.contains("frameButtons"), "hover and selection frames share one corner-button builder")
        #expect(page.contains("hoverButtonTimer = setTimeout"), "corner buttons wait out a dwell so gutter clicks can't land on Stage")
        for mode in DiffMode.allCases {
            #expect(!DiffHTMLBuilder.page(for: diff, mode: mode).contains("hsel"), "\(mode.rawValue): read-only pages have no hover frame")
        }
    }

    // The production unified configuration (ChangesView) puts no buttons on
    // hunk headers for line-stageable files — hunk actions live on the hover
    // frame's capsules instead — while headers keep their IDs.
    @Test func unifiedWithoutHunkButtonsRendersBareHeaders() {
        var options = interactiveOptions
        options.hunkButtons = []
        options.selectionButtons = [DiffHTMLBuilder.HunkButton(action: "stageLines", title: "Stage")]
        let page = DiffHTMLBuilder.interactiveUnifiedPage(items: DiffHTMLBuilder.unifiedItems(for: diff), options: options)
        #expect(!page.contains(#"<span class="hunkbtns">"#), "hunk headers carry no button span")
        #expect(page.contains(#"data-hid="h0""#), "headers keep their hunk ID")
        #expect(page.contains(#"<template id="selbtns">"#), "frame capsules come from the template instead")
    }

    // The injected Shiki user script reads the grammar id off <body
    // data-lang>; pages for unknown file types must omit the attribute so
    // the script exits without building a highlighter.
    @Test func pagesCarryTheShikiLanguageAttribute() {
        for mode in DiffMode.allCases {
            #expect(DiffHTMLBuilder.page(for: diff, mode: mode).contains(#"data-lang="swift""#), "\(mode.rawValue): .swift page tags its language")
        }
        let unknown = FileDiff(path: "LICENSE", oldPath: nil, isBinary: false, hunks: diff.hunks)
        for mode in DiffMode.allCases {
            #expect(!DiffHTMLBuilder.page(for: unknown, mode: mode).contains("data-lang"), "\(mode.rawValue): unknown file type gets no language attribute")
        }

        var options = interactiveOptions
        options.language = "swift"
        let unified = DiffHTMLBuilder.interactiveUnifiedPage(items: DiffHTMLBuilder.unifiedItems(for: diff), options: options)
        #expect(unified.contains(#"data-lang="swift""#), "interactive unified page tags its language")
        // Split derives from the diff path when options carry no language.
        let split = DiffHTMLBuilder.interactiveSplitPage(for: diff, options: interactiveOptions)
        #expect(split.contains(#"data-lang="swift""#), "interactive split page derives the language from the path")
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
