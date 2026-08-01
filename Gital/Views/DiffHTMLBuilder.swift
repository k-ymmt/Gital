import Foundation

/// Renders a `FileDiff` into a self-contained HTML page for `WebDiffView`
/// (read-only) and `WebDiffChunkView` (interactive, Working Copy).
///
/// Line numbers and +/- signs are drawn with CSS pseudo-elements from data
/// attributes, so text selection (and therefore copy) picks up only the code
/// itself — the main capability the SwiftUI `Text`-per-line renderer lacks.
enum DiffHTMLBuilder {
    // MARK: - Read-only pages

    static func page(for diff: FileDiff, mode: DiffMode) -> String {
        switch mode {
        case .unified:
            return assemble(body: render(items: unifiedItems(for: diff), options: nil), bodyClass: "", interactive: false)
        case .split:
            return assemble(body: splitBody(for: diff, options: nil), bodyClass: splitBodyClass, interactive: false)
        }
    }

    // MARK: - Interactive pages (Working Copy)

    struct HunkButton {
        /// Bridge message `type` posted when the button is clicked.
        let action: String
        let title: String
        var destructive: Bool = false
    }

    struct InteractiveOptions {
        /// Non-context lines become click-to-select for line staging.
        var selectableLines = false
        /// Lines grow a hover "+" button that opens the AI agent composer.
        var askLines = false
        /// Buttons rendered on every hunk header (Stage/Unstage/Discard).
        var hunkButtons: [HunkButton] = []
    }

    /// One row of a unified diff; segments of these render between native
    /// interleaves (agent composer/threads), so a page is not always a
    /// whole file.
    enum UnifiedItem {
        case header(DiffHunk)
        case line(DiffLine)
    }

    static func interactiveUnifiedPage(items: [UnifiedItem], options: InteractiveOptions) -> String {
        assemble(body: render(items: items, options: options), bodyClass: "", interactive: true)
    }

    static func interactiveSplitPage(for diff: FileDiff, options: InteractiveOptions) -> String {
        assemble(body: splitBody(for: diff, options: options), bodyClass: splitBodyClass, interactive: true)
    }

    // MARK: - Bodies

    static func unifiedItems(for diff: FileDiff) -> [UnifiedItem] {
        diff.hunks.flatMap { hunk in
            [.header(hunk)] + hunk.lines.map(UnifiedItem.line)
        }
    }

    private static func render(items: [UnifiedItem], options: InteractiveOptions?) -> String {
        var out = ""
        for item in items {
            switch item {
            case .header(let hunk):
                out += hunkHeader(hunk.header, hunkID: options != nil ? hunk.id : nil, buttons: options?.hunkButtons ?? [])
            case .line(let line):
                out += unifiedLine(line, options: options)
            }
        }
        return out
    }

    private static func unifiedLine(_ line: DiffLine, options: InteractiveOptions?) -> String {
        var classes = "line \(kindClass(line.kind))"
        var attrs = ""
        var ask = ""
        if let options {
            classes += " i"
            if options.selectableLines && line.kind != .context {
                classes += " selable"
            }
            if options.selectableLines || options.askLines {
                attrs = " data-id=\"\(escapeAttr(line.id))\""
            }
            if options.askLines {
                ask = "<span class=\"ask\" title=\"Ask AI Agent about this line (⇧-click to extend range)\">+</span>"
            }
        }
        return """
        <div class="\(classes)"\(attrs)>\
        \(ask)\
        <span class="num" data-n="\(line.oldNumber.map(String.init) ?? "")"></span>\
        <span class="num" data-n="\(line.newNumber.map(String.init) ?? "")"></span>\
        <span class="sign" data-s="\(line.kind == .context ? "" : line.sign)"></span>\
        <span class="text">\(textContent(line.text))</span>\
        </div>\n
        """
    }

    /// An empty span copies as nothing — the blank line would vanish from
    /// multi-line copies — so empty lines carry a real space (exactly what
    /// the SwiftUI renderer put in its `Text`).
    private static func textContent(_ text: String) -> String {
        text.isEmpty ? " " : escape(text)
    }

    private static let splitBodyClass = " class=\"sel-right\""

    private static func splitBody(for diff: FileDiff, options: InteractiveOptions?) -> String {
        var out = ""
        for hunk in diff.hunks {
            out += hunkHeader(hunk.header, hunkID: options != nil ? hunk.id : nil, buttons: options?.hunkButtons ?? [])
            for row in SplitDiffRow.rows(for: [hunk]) where !row.isHunkHeader {
                out += """
                <div class="row">\
                \(splitSide(row.left, position: "left"))\
                \(splitSide(row.right, position: "right"))\
                </div>\n
                """
            }
        }
        return out
    }

    private static func splitSide(_ side: SplitDiffRow.Side, position: String) -> String {
        """
        <div class="side \(position) \(side.kind.map(kindClass) ?? "")">\
        <span class="num" data-n="\(side.number.map(String.init) ?? "")"></span>\
        <span class="text">\(side.text.map(textContent) ?? "")</span>\
        </div>
        """
    }

    private static func hunkHeader(_ text: String, hunkID: String? = nil, buttons: [HunkButton] = []) -> String {
        let idAttr = hunkID.map { " data-hid=\"\(escapeAttr($0))\"" } ?? ""
        let rendered = buttons.map { button in
            "<button class=\"hb\(button.destructive ? " destructive" : "")\" data-act=\"\(escapeAttr(button.action))\">\(escape(button.title))</button>"
        }.joined()
        let buttonSpan = rendered.isEmpty ? "" : "<span class=\"hunkbtns\">\(rendered)</span>"
        return "<div class=\"hunk\"\(idAttr)><span class=\"htext\">\(escape(text))</span>\(buttonSpan)</div>\n"
    }

    private static func kindClass(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .addition: "add"
        case .deletion: "del"
        case .context: "ctx"
        }
    }

    // MARK: - Escaping

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for char in text {
            switch char {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(char)
            }
        }
        return out
    }

    /// Attribute values additionally need quote escaping — line and hunk IDs
    /// embed the file path, which can contain anything.
    static func escapeAttr(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - Page assembly

    private static func assemble(body: String, bodyClass: String, interactive: Bool) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>\(css)\(interactive ? interactiveCSS : "")</style>
        </head>
        <body\(bodyClass)>
        \(body)
        <script>\(script)\(interactive ? bridgeScript : "")</script>
        </body>
        </html>
        """
    }

    // MARK: - Style / behavior

    /// Palette mirrors `DesignStyle`; text and dividers use CSS system colors
    /// so the page tracks the native light/dark appearance for free.
    private static let css = """
    :root { color-scheme: light dark; }
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
        font: 12px/19px ui-monospace, "SF Mono", Menlo, monospace;
        color: CanvasText;
        background: transparent;
        cursor: text;
    }
    .num, .sign { -webkit-user-select: none; user-select: none; }
    .num::before { content: attr(data-n); }
    .sign::before { content: attr(data-s); }
    .line, .side { display: flex; align-items: flex-start; min-height: 19px; }
    .line { position: relative; }
    .line .num { flex: 0 0 46px; padding-right: 10px; text-align: right; opacity: 0.45; }
    .sign { flex: 0 0 14px; text-align: center; }
    .text { flex: 1 1 auto; min-width: 0; white-space: pre-wrap; word-break: break-all; padding-right: 16px; }
    .line.add, .side.add { background: rgba(46, 160, 67, 0.15); }
    .line.del, .side.del { background: rgba(248, 81, 73, 0.12); }
    .line.add .sign { color: #3fb950; }
    .line.del .sign { color: #f85149; }
    .hunk {
        display: flex;
        align-items: center;
        min-height: 19px;
        padding-left: 12px;
        background: rgba(56, 139, 253, 0.10);
        color: #6ea8fe;
    }
    .hunk .htext { flex: 1 1 auto; white-space: nowrap; overflow: hidden; }
    .row { display: flex; align-items: stretch; }
    .side { flex: 1 1 50%; }
    .side .num { flex: 0 0 40px; padding-right: 9px; text-align: right; opacity: 0.45; }
    .side.left { border-right: 1px solid color-mix(in srgb, CanvasText 15%, transparent); }
    body.sel-left .side.right, body.sel-right .side.left { -webkit-user-select: none; user-select: none; }
    """

    /// Hover/selection affordances for the Working Copy: hover tint and "+"
    /// button, accent overlay + left bar on selected lines, capsule
    /// hunk-action buttons (all matching the SwiftUI renderer they replace).
    /// The system accent is `AccentColor` (CSS system color) — WebKit on
    /// macOS 27 no longer accepts `-webkit-focus-ring-color`, and an unknown
    /// color silently drops the whole declaration. The rgb() fallbacks
    /// (DesignStyle.brandBlue) cover engines without AccentColor.
    private static let interactiveCSS = """
    .line.i:hover { background-image: linear-gradient(color-mix(in srgb, CanvasText 4%, transparent), color-mix(in srgb, CanvasText 4%, transparent)); }
    .line.sel, .line.sel:hover {
        background-image: linear-gradient(rgba(47, 111, 237, 0.16), rgba(47, 111, 237, 0.16));
        box-shadow: inset 2.5px 0 0 0 rgb(47, 111, 237);
    }
    .ask {
        display: none;
        position: absolute;
        left: 3px;
        top: 1px;
        width: 17px;
        height: 17px;
        border-radius: 4px;
        background: rgb(47, 111, 237);
        color: white;
        font: 700 11px/17px -apple-system, system-ui;
        text-align: center;
        cursor: pointer;
        -webkit-user-select: none;
        user-select: none;
        z-index: 1;
    }
    .line.i:hover .ask { display: block; }
    .hunkbtns {
        display: flex;
        gap: 6px;
        padding: 1px 8px;
        -webkit-user-select: none;
        user-select: none;
    }
    .hb {
        font: 500 10.5px -apple-system, system-ui;
        padding: 1.5px 7px;
        border-radius: 999px;
        background: color-mix(in srgb, Canvas 70%, transparent);
        border: 1px solid rgba(47, 111, 237, 0.4);
        color: rgb(47, 111, 237);
        cursor: pointer;
    }
    .hb.destructive { color: #f85149; border-color: rgba(248, 81, 73, 0.4); }
    .tsel { position: relative; }
    .tsel::after {
        content: "";
        position: absolute;
        inset: 0;
        pointer-events: none;
        border: 0 solid rgb(47, 111, 237);
        border-left-width: 1.5px;
        border-right-width: 1.5px;
    }
    .tsel-first::after { border-top-width: 1.5px; }
    .tsel-last::after { border-bottom-width: 1.5px; }
    @supports (color: AccentColor) {
        .line.sel, .line.sel:hover {
            background-image: linear-gradient(color-mix(in srgb, AccentColor 14%, transparent), color-mix(in srgb, AccentColor 14%, transparent));
            box-shadow: inset 2.5px 0 0 0 AccentColor;
        }
        .ask { background: AccentColor; }
        .hb { border-color: color-mix(in srgb, AccentColor 40%, transparent); color: AccentColor; }
        .tsel::after { border-color: AccentColor; }
    }
    """

    /// Split view: a drag that starts on one side must not smear selection
    /// across the other column, so mousedown disables selection on the
    /// opposite side (the GitHub approach). A mousedown outside any side
    /// (hunk header, empty space) keeps the current side — dropping both
    /// classes there would let a later Select All interleave the columns.
    private static let script = """
    document.addEventListener('mousedown', (e) => {
        const side = e.target.closest('.side');
        if (!side) { return; }
        document.body.classList.remove('sel-left', 'sel-right');
        document.body.classList.add(side.classList.contains('left') ? 'sel-left' : 'sel-right');
    });
    """

    /// Interactive pages talk to `WebDiffChunkView` through the `gital`
    /// message handler: height reports (the chunk always matches content
    /// height; the outer SwiftUI ScrollView scrolls), line selection clicks,
    /// "+" (ask agent) clicks, and hunk-button clicks. Selection highlight is
    /// pushed back in via `gitalSetSelected` so a click never reloads the page.
    /// The page also frames the rows a mouse text selection spans (`.tsel`).
    private static let bridgeScript = """
    const post = (m) => window.webkit.messageHandlers.gital.postMessage(m);
    const reportHeight = () => post({type: 'height', height: document.body.scrollHeight});
    new ResizeObserver(reportHeight).observe(document.body);
    window.addEventListener('load', reportHeight);
    document.addEventListener('mousedown', (e) => {
        // Shift-click means "extend the line selection / composer range",
        // not "extend the text selection". Also drop any existing text
        // selection: preventDefault preserves it, and a non-collapsed
        // selection would make the click handler swallow the extend.
        if (e.shiftKey && e.target.closest('.selable, .ask')) {
            e.preventDefault();
            window.getSelection().removeAllRanges();
        }
    });
    document.addEventListener('click', (e) => {
        const hb = e.target.closest('.hb');
        if (hb) { post({type: hb.dataset.act, id: hb.closest('.hunk').dataset.hid}); return; }
        const ask = e.target.closest('.ask');
        if (ask) { post({type: 'ask', id: ask.closest('.line').dataset.id, extend: e.shiftKey}); return; }
        const line = e.target.closest('.line.selable');
        if (line && window.getSelection().isCollapsed) {
            post({type: 'toggleLine', id: line.dataset.id, extend: e.shiftKey});
        }
    });
    window.gitalSetSelected = (ids) => {
        const set = new Set(ids);
        document.querySelectorAll('.line[data-id]').forEach((el) => {
            el.classList.toggle('sel', set.has(el.dataset.id));
        });
    };
    // Text selection outlines every row it spans with an accent frame:
    // side borders on each row, top/bottom only at contiguous-run edges, so
    // a multi-line selection reads as one box. A DOM range can *touch* the
    // row after a full-line selection (or, in split, pass through the
    // unselectable column and empty sides) — a row only counts when the
    // range actually contains some of its text.
    const rowAbove = (el) => {
        if (!el.classList.contains('side')) { return el.previousElementSibling; }
        const row = el.parentElement.previousElementSibling;
        if (!row || !row.classList.contains('row')) { return null; }
        return row.querySelector(el.classList.contains('left') ? '.side.left' : '.side.right');
    };
    const selectsTextIn = (range, el) => {
        const bounds = document.createRange();
        bounds.selectNodeContents(el);
        const r = range.cloneRange();
        if (r.compareBoundaryPoints(Range.START_TO_START, bounds) < 0) { r.setStart(bounds.startContainer, bounds.startOffset); }
        if (r.compareBoundaryPoints(Range.END_TO_END, bounds) > 0) { r.setEnd(bounds.endContainer, bounds.endOffset); }
        return r.toString().length > 0;
    };
    document.addEventListener('selectionchange', () => {
        document.querySelectorAll('.tsel').forEach((el) => el.classList.remove('tsel', 'tsel-first', 'tsel-last'));
        const sel = window.getSelection();
        if (!sel.rangeCount || sel.isCollapsed) { return; }
        const range = sel.getRangeAt(0);
        const rowSelector = document.body.classList.contains('sel-left') ? '.side.left'
            : document.body.classList.contains('sel-right') ? '.side.right' : '.line';
        const hits = [...document.querySelectorAll(rowSelector)]
            .filter((el) => range.intersectsNode(el) && selectsTextIn(range, el));
        hits.forEach((el, i) => {
            el.classList.add('tsel');
            if (i === 0 || rowAbove(el) !== hits[i - 1]) { el.classList.add('tsel-first'); }
            if (i === hits.length - 1 || rowAbove(hits[i + 1]) !== el) { el.classList.add('tsel-last'); }
        });
    });
    """
}
