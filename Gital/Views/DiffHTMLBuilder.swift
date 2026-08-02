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
        let language = DiffSyntaxHighlighting.language(for: diff)
        switch mode {
        case .unified:
            return assemble(body: render(items: unifiedItems(for: diff), options: nil), bodyClass: "", interactive: false, language: language)
        case .split:
            return assemble(body: splitBody(for: diff, options: nil), bodyClass: splitBodyClass, interactive: false, language: language)
        }
    }

    /// Read-only page for a height-fitting `WebDiffChunkView` (stash detail):
    /// no line interactions, but the page must still report its laid-out
    /// height because the outer SwiftUI ScrollView does the scrolling.
    static func chunkPage(for diff: FileDiff, mode: DiffMode) -> String {
        let language = DiffSyntaxHighlighting.language(for: diff)
        switch mode {
        case .unified:
            return assemble(body: render(items: unifiedItems(for: diff), options: nil), bodyClass: "", interactive: false, reportsHeight: true, language: language)
        case .split:
            return assemble(body: splitBody(for: diff, options: nil), bodyClass: splitBodyClass, interactive: false, reportsHeight: true, language: language)
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
        /// Every line carries its ID, so the hover/selection frames' "+" can
        /// ask the AI agent about the range it spans.
        var askLines = false
        /// Buttons rendered on every hunk header (Stage/Unstage/Discard).
        var hunkButtons: [HunkButton] = []
        /// Buttons shown next to the text-selection frame's "+", acting on
        /// the changed lines the selection spans.
        var selectionButtons: [HunkButton] = []
        /// Shiki language id for syntax highlighting (`data-lang` on <body>);
        /// nil leaves the page uncolored.
        var language: String?
    }

    /// One row of a unified diff; segments of these render between native
    /// interleaves (agent composer/threads), so a page is not always a
    /// whole file.
    enum UnifiedItem {
        case header(DiffHunk)
        case line(DiffLine)
    }

    static func interactiveUnifiedPage(items: [UnifiedItem], options: InteractiveOptions) -> String {
        assemble(
            body: render(items: items, options: options) + selectionButtonsTemplate(options.selectionButtons),
            bodyClass: "",
            interactive: true,
            language: options.language
        )
    }

    static func interactiveSplitPage(for diff: FileDiff, options: InteractiveOptions) -> String {
        assemble(
            body: splitBody(for: diff, options: options),
            bodyClass: splitBodyClass,
            interactive: true,
            language: options.language ?? DiffSyntaxHighlighting.language(for: diff)
        )
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
        if let options {
            classes += " i"
            if options.selectableLines && line.kind != .context {
                classes += " selable"
            }
            if options.selectableLines || options.askLines {
                attrs = " data-id=\"\(escapeAttr(line.id))\""
            }
        }
        return """
        <div class="\(classes)"\(attrs)>\
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

    /// Inert clone source for the buttons the selection script drops next to
    /// the frame's "+" — rendering them in Swift keeps titles/actions out of
    /// hand-built JS strings.
    private static func selectionButtonsTemplate(_ buttons: [HunkButton]) -> String {
        guard !buttons.isEmpty else { return "" }
        let rendered = buttons.map { button in
            "<button class=\"hb selb\(button.destructive ? " destructive" : "")\" data-act=\"\(escapeAttr(button.action))\">\(escape(button.title))</button>"
        }.joined()
        return "<template id=\"selbtns\">\(rendered)</template>\n"
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

    private static func assemble(body: String, bodyClass: String, interactive: Bool, reportsHeight: Bool = false, language: String? = nil) -> String {
        // data-lang tells the injected Shiki user script what grammar to
        // tokenize with; without it the page stays uncolored.
        let langAttr = language.map { " data-lang=\"\(escapeAttr($0))\"" } ?? ""
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>\(css)\(interactive ? interactiveCSS : "")</style>
        </head>
        <body\(bodyClass)\(langAttr)>
        \(body)
        <script>\(script)\(interactive ? bridgeScript : reportsHeight ? heightScript : "")</script>
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

    /// Hover/selection affordances for the Working Copy: hover tint, accent
    /// overlay + left bar on selected lines, capsule hunk-action buttons, and
    /// the frame corner buttons (all matching the SwiftUI renderer they
    /// replace).
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
        z-index: 2;
    }
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
    .tsel, .hsel { position: relative; }
    .tsel::after, .hsel::after {
        content: "";
        position: absolute;
        inset: 0;
        pointer-events: none;
        border: 0 solid rgb(47, 111, 237);
        border-left-width: 1.5px;
        border-right-width: 1.5px;
    }
    .tsel-first::after, .hsel-first::after { border-top-width: 1.5px; }
    .tsel-last::after, .hsel-last::after { border-bottom-width: 1.5px; }
    .selbar {
        position: absolute;
        left: 24px;
        top: 1px;
        display: flex;
        gap: 4px;
        z-index: 2;
        -webkit-user-select: none;
        user-select: none;
    }
    @supports (color: AccentColor) {
        .line.sel, .line.sel:hover {
            background-image: linear-gradient(color-mix(in srgb, AccentColor 14%, transparent), color-mix(in srgb, AccentColor 14%, transparent));
            box-shadow: inset 2.5px 0 0 0 AccentColor;
        }
        .ask { background: AccentColor; }
        .hb { border-color: color-mix(in srgb, AccentColor 40%, transparent); color: AccentColor; }
        .tsel::after, .hsel::after { border-color: AccentColor; }
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

    /// Height reporting alone, for read-only pages hosted in a
    /// `WebDiffChunkView`. `gitalSetSelected` is a stub: the host applies its
    /// (always empty) selection after every load, and the call must not throw.
    private static let heightScript = """
    const post = (m) => window.webkit.messageHandlers.gital.postMessage(m);
    const reportHeight = () => post({type: 'height', height: document.body.scrollHeight});
    new ResizeObserver(reportHeight).observe(document.body);
    window.addEventListener('load', reportHeight);
    window.gitalSetSelected = () => {};
    """

    /// Interactive pages talk to `WebDiffChunkView` through the `gital`
    /// message handler: height reports (the chunk always matches content
    /// height; the outer SwiftUI ScrollView scrolls), line selection clicks,
    /// and hunk/frame-button clicks. Selection highlight is
    /// pushed back in via `gitalSetSelected` so a click never reloads the page.
    /// The page also frames the rows a mouse text selection spans (`.tsel`)
    /// and, while no text is selected, the hunk under the pointer (`.hsel`),
    /// both with the same corner buttons ("+" / Stage / Unstage / Discard).
    private static let bridgeScript = """
    const post = (m) => window.webkit.messageHandlers.gital.postMessage(m);
    const reportHeight = () => post({type: 'height', height: document.body.scrollHeight});
    new ResizeObserver(reportHeight).observe(document.body);
    window.addEventListener('load', reportHeight);
    document.addEventListener('mousedown', (e) => {
        // Clicking the frame's ask/stage/discard buttons must not collapse
        // the text selection that defines their range.
        if (e.target.closest('.askr, .selbar')) { e.preventDefault(); return; }
        // Shift-click means "extend the line selection", not "extend the
        // text selection". Also drop any existing text selection:
        // preventDefault preserves it, and a non-collapsed selection would
        // make the click handler swallow the extend.
        if (e.shiftKey && e.target.closest('.selable')) {
            e.preventDefault();
            window.getSelection().removeAllRanges();
        }
    });
    document.addEventListener('click', (e) => {
        // Before .hb — frame buttons share its capsule styling but have no
        // .hunk ancestor to read an ID from.
        const selb = e.target.closest('.selb');
        if (selb) {
            const bar = selb.closest('.selbar');
            post({type: selb.dataset.act, start: bar.dataset.start, end: bar.dataset.end});
            return;
        }
        const hb = e.target.closest('.hb');
        if (hb) { post({type: hb.dataset.act, id: hb.closest('.hunk').dataset.hid}); return; }
        const askr = e.target.closest('.askr');
        if (askr) { post({type: 'askRange', start: askr.dataset.start, end: askr.dataset.end}); return; }
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
    // Corner buttons for a row-range frame — the range "+" plus the Stage/
    // Unstage/Discard capsules cloned from the Swift-rendered template.
    // Shared by the text-selection frame and the hover-hunk frame; "hov"
    // marks the hover frame's elements so selection cleanup spares them.
    const frameButtons = (rows, hover) => {
        const first = rows[0];
        if (!first.dataset.id) { return; }
        const suffix = hover ? ' hov' : '';
        const btn = document.createElement('span');
        btn.className = 'ask askr' + suffix;
        btn.textContent = '+';
        btn.title = 'Ask AI Agent about ' + (hover ? 'this hunk' : 'the selected lines');
        btn.dataset.start = first.dataset.id;
        btn.dataset.end = rows[rows.length - 1].dataset.id;
        first.appendChild(btn);
        // Stage/Unstage/Discard act on the range's changed lines — only when
        // the page stages lines at all and the range spans a changed line.
        const tpl = document.getElementById('selbtns');
        if (tpl && rows.some((el) => el.classList.contains('selable'))) {
            const bar = document.createElement('span');
            bar.className = 'selbar' + suffix;
            bar.dataset.start = btn.dataset.start;
            bar.dataset.end = btn.dataset.end;
            bar.appendChild(tpl.content.cloneNode(true));
            first.appendChild(bar);
        }
    };
    // Hovering a hunk's lines frames the whole hunk with the same accent box
    // and corner buttons as a text selection. Suppressed while text is
    // selected — two frames would stack two button bars on one corner.
    let hoveredHunk = null;
    let hoverButtonTimer = null;
    const clearHover = () => {
        hoveredHunk = null;
        clearTimeout(hoverButtonTimer);
        hoverButtonTimer = null;
        document.querySelectorAll('.hsel').forEach((el) => el.classList.remove('hsel', 'hsel-first', 'hsel-last'));
        document.querySelectorAll('.askr.hov, .selbar.hov').forEach((el) => el.remove());
    };
    document.addEventListener('mouseover', (e) => {
        const line = e.target.closest('.line');
        const sel = window.getSelection();
        if (!line || (sel.rangeCount && !sel.isCollapsed)) {
            if (hoveredHunk) { clearHover(); }
            return;
        }
        // Headers and lines are siblings, so a hunk is the contiguous .line
        // run around the hovered line (a chunk split mid-hunk frames only
        // its own rows — the native interleave bounds the page).
        let first = line;
        while (first.previousElementSibling && first.previousElementSibling.classList.contains('line')) {
            first = first.previousElementSibling;
        }
        if (hoveredHunk === first) { return; }
        clearHover();
        hoveredHunk = first;
        const rows = [];
        for (let el = first; el && el.classList.contains('line'); el = el.nextElementSibling) { rows.push(el); }
        rows.forEach((el) => el.classList.add('hsel'));
        first.classList.add('hsel-first');
        rows[rows.length - 1].classList.add('hsel-last');
        // The corner buttons overlay the first row's number gutter, where a
        // click means "select this line" — appearing the instant the pointer
        // enters the hunk would let that click land on Stage instead. The
        // frame shows immediately; the buttons wait out a short dwell.
        hoverButtonTimer = setTimeout(() => {
            hoverButtonTimer = null;
            frameButtons(rows, true);
        }, 350);
    });
    document.documentElement.addEventListener('mouseleave', () => clearHover());
    document.addEventListener('selectionchange', () => {
        // The buttons' own label text must never count as selected text below.
        document.querySelectorAll('.askr:not(.hov), .selbar:not(.hov)').forEach((el) => el.remove());
        document.querySelectorAll('.tsel').forEach((el) => el.classList.remove('tsel', 'tsel-first', 'tsel-last'));
        const sel = window.getSelection();
        if (!sel.rangeCount || sel.isCollapsed) { return; }
        clearHover();
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
        // A "+" on the frame's top-left corner asks the AI agent about the
        // whole selected range, with the Stage/Unstage/Discard capsules
        // beside it (split rows carry no line IDs — no buttons).
        if (hits.length) { frameButtons(hits, false); }
    });
    """
}
