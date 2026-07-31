import Foundation

/// Renders a `FileDiff` into a self-contained HTML page for `WebDiffView`.
///
/// Line numbers and +/- signs are drawn with CSS pseudo-elements from data
/// attributes, so text selection (and therefore copy) picks up only the code
/// itself — the main capability the SwiftUI `Text`-per-line renderer lacks.
enum DiffHTMLBuilder {
    static func page(for diff: FileDiff, mode: DiffMode) -> String {
        let body: String
        switch mode {
        case .unified: body = unifiedBody(for: diff)
        case .split: body = splitBody(for: diff)
        }
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>\(css)</style>
        </head>
        <body>
        \(body)
        <script>\(script)</script>
        </body>
        </html>
        """
    }

    // MARK: - Bodies

    private static func unifiedBody(for diff: FileDiff) -> String {
        var out = ""
        for hunk in diff.hunks {
            out += hunkHeader(hunk.header)
            for line in hunk.lines {
                out += """
                <div class="line \(kindClass(line.kind))">\
                <span class="num" data-n="\(line.oldNumber.map(String.init) ?? "")"></span>\
                <span class="num" data-n="\(line.newNumber.map(String.init) ?? "")"></span>\
                <span class="sign" data-s="\(line.kind == .context ? "" : line.sign)"></span>\
                <span class="text">\(escape(line.text))</span>\
                </div>\n
                """
            }
        }
        return out
    }

    private static func splitBody(for diff: FileDiff) -> String {
        var out = ""
        for row in SplitDiffRow.rows(for: diff.hunks) {
            if row.isHunkHeader {
                out += hunkHeader(row.hunkText)
            } else {
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
        <span class="text">\(side.text.map(escape) ?? "")</span>\
        </div>
        """
    }

    private static func hunkHeader(_ text: String) -> String {
        "<div class=\"hunk\">\(escape(text))</div>\n"
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
    .line .num { flex: 0 0 46px; padding-right: 10px; text-align: right; opacity: 0.45; }
    .sign { flex: 0 0 14px; text-align: center; }
    .text { flex: 1 1 auto; min-width: 0; white-space: pre-wrap; word-break: break-all; padding-right: 16px; }
    .text:empty::before { content: "\\00a0"; }
    .line.add, .side.add { background: rgba(46, 160, 67, 0.15); }
    .line.del, .side.del { background: rgba(248, 81, 73, 0.12); }
    .line.add .sign { color: #3fb950; }
    .line.del .sign { color: #f85149; }
    .hunk {
        height: 19px;
        padding-left: 12px;
        background: rgba(56, 139, 253, 0.10);
        color: #6ea8fe;
        white-space: nowrap;
        overflow: hidden;
    }
    .row { display: flex; align-items: stretch; }
    .side { flex: 1 1 50%; }
    .side .num { flex: 0 0 40px; padding-right: 9px; text-align: right; opacity: 0.45; }
    .side.left { border-right: 1px solid color-mix(in srgb, CanvasText 15%, transparent); }
    body.sel-left .side.right, body.sel-right .side.left { -webkit-user-select: none; user-select: none; }
    """

    /// Split view: a drag that starts on one side must not smear selection
    /// across the other column, so mousedown disables selection on the
    /// opposite side (the GitHub approach).
    private static let script = """
    document.addEventListener('mousedown', (e) => {
        document.body.classList.remove('sel-left', 'sel-right');
        const side = e.target.closest('.side');
        if (side) {
            document.body.classList.add(side.classList.contains('left') ? 'sel-left' : 'sel-right');
        }
    });
    """
}
