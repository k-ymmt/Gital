import Testing
import WebKit
@testable import Gital

/// Runtime proof that `content-visibility: auto` on self-scrolling pages
/// cannot corrupt Select All + Copy — the one capability those pages exist
/// for. `Selection.toString()` runs WebKit's TextIterator over layout, the
/// same walk the copy command serializes, so a complete toString across
/// thousands of skipped rows means copies stay complete too.
@MainActor
struct WebDiffLazyRenderTests {
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    private func largeDiff(lineCount: Int) -> FileDiff {
        let lines = (0..<lineCount).map { n in
            DiffLine(
                id: "A.swift@\(n)",
                kind: n.isMultiple(of: 2) ? .context : .addition,
                // Distinct per-line text so a dropped row is detectable.
                text: n.isMultiple(of: 7) ? "" : "line \(n) content",
                oldNumber: n.isMultiple(of: 2) ? n : nil,
                newNumber: n
            )
        }
        let hunk = DiffHunk(id: "A.swift@h0", header: "@@ -1,\(lineCount) +1,\(lineCount) @@", oldStart: 1, newStart: 1, lines: lines)
        return FileDiff(path: "A.swift", oldPath: nil, isBinary: false, hunks: [hunk])
    }

    @Test func selectAllCoversSkippedRows() async throws {
        let lineCount = 3000
        let html = DiffHTMLBuilder.page(for: largeDiff(lineCount: lineCount), mode: .unified)
        #expect(html.contains("content-visibility: auto"), "page under test must carry the lazy-render CSS")

        // A small viewport over a ~57,000px document: virtually every row is
        // outside the relevancy margin, so this exercises the skipped path.
        // The view sits in an ordered (offscreen) window — an unparented
        // WKWebView throttles its rendering updates, and relevancy is
        // recomputed in the rendering update.
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(
            contentRect: webView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }

        // Select all, then serialize the selection through the layout walk.
        // Poll briefly: the spec lets relevancy (selection makes skipped
        // content relevant) land on the next rendering update, so the very
        // first toString may legitimately run before that update.
        let script = """
        (() => {
            const sel = window.getSelection();
            sel.selectAllChildren(document.body);
            const text = sel.toString();
            return [text.length, text.includes('line 1 content'), text.includes('line \(lineCount - 1) content')];
        })()
        """
        var result: [Any] = []
        for _ in 0..<50 {
            result = try await webView.evaluateJavaScript(script) as? [Any] ?? []
            if result.count == 3, (result[1] as? Bool) == true, (result[2] as? Bool) == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(result[1] as? Bool == true, "first line present in the selection text")
        #expect(result[2] as? Bool == true, "last line — thousands of rows below the viewport — present in the selection text")
        // Every row contributes at least its newline; a wholesale drop of
        // skipped rows would collapse the length far below one char per line.
        let length = (result[0] as? Int) ?? (result[0] as? NSNumber)?.intValue ?? 0
        #expect(length >= lineCount, "selection text spans all \(lineCount) rows (got \(length) chars)")
    }
}
