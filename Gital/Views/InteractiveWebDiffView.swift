import SwiftUI
import WebKit

/// A click routed out of an interactive diff page (Working Copy).
enum WebDiffAction {
    case toggleLine(id: String, extend: Bool)
    case ask(id: String, extend: Bool)
    /// The "+" on a text-selection frame: ask about every line the
    /// selection spans, first to last.
    case askRange(startID: String, endID: String)
    /// A Stage/Unstage/Discard capsule on the frame: act on the changed
    /// lines the selection spans.
    case lines(action: String, startID: String, endID: String)
    case hunk(action: String, id: String)
}

/// WKWebView that always matches its content height — the outer SwiftUI
/// ScrollView does all scrolling, so wheel events belong to the parent.
private final class HeightFittingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// Last reported page height per HTML content. `@State` heights die with
/// their view, and chunk views die a lot — LazyVStack recycling, and every
/// composer open/close re-splits a file's segments — after which a rows×19
/// estimate (wrong whenever lines wrap) would visibly jump the layout.
/// Heights are width-dependent, but a stale entry only mis-sizes the chunk
/// until the live page re-reports.
private let heightCache = NSCache<NSString, NSNumber>()

private func cachedHeight(for html: String) -> CGFloat? {
    heightCache.object(forKey: String(html.hashValue) as NSString).map { CGFloat($0.doubleValue) }
}

private func cacheHeight(_ height: CGFloat, for html: String) {
    heightCache.setObject(NSNumber(value: height), forKey: String(html.hashValue) as NSString)
}

/// One self-sized, interactive diff chunk inside the Working Copy list.
/// Chunks split where native views (agent composer, agent threads) interleave
/// with diff lines, so those stay plain SwiftUI.
struct WebDiffChunkView: View {
    let html: String
    /// Currently selected line IDs; applied via JS so selection clicks never
    /// reload the page (a reload would drop scroll position and text
    /// selection, and flash).
    var selectedLineIDs: Set<String> = []
    /// Height to occupy until the page reports its real laid-out height —
    /// rows × 19 is exact unless lines wrap.
    let estimatedHeight: CGFloat
    let onAction: (WebDiffAction) -> Void

    @State private var reportedHeight: CGFloat?

    var body: some View {
        InteractiveWebView(
            html: html,
            selectedLineIDs: selectedLineIDs,
            onAction: onAction,
            onHeight: { height in
                reportedHeight = height
                cacheHeight(height, for: html)
            }
        )
        .frame(height: reportedHeight ?? cachedHeight(for: html) ?? estimatedHeight)
        // Same view identity, new content (a refresh reusing the segment ID):
        // the old page's height must not linger on the new page.
        .onChange(of: html) {
            reportedHeight = cachedHeight(for: html)
        }
    }
}

private struct InteractiveWebView: NSViewRepresentable {
    let html: String
    let selectedLineIDs: Set<String>
    let onAction: (WebDiffAction) -> Void
    let onHeight: (CGFloat) -> Void

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        // Re-pointed on every update so bridge messages never run stale
        // closures captured at makeNSView time.
        var onAction: (WebDiffAction) -> Void = { _ in }
        var onHeight: (CGFloat) -> Void = { _ in }
        var loadedHTML: String?
        weak var webView: WKWebView?
        /// Selection can arrive before the page finishes loading; it is kept
        /// pending and applied from didFinish.
        private var pageReady = false
        private var appliedSelection: Set<String>?
        private var pendingSelection: Set<String> = []

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "gital",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            // Between a content refresh (markLoading) and didFinish the web
            // view still shows the OLD page, while onAction closures already
            // capture the NEW diff. Line/hunk IDs are positional (path@N), so
            // an ID clicked on the stale page can resolve to a different
            // physical hunk/line in the refreshed diff — and stage or discard
            // something the user never saw. Drop those clicks; height reports
            // stay welcome (the fresh load re-reports anyway).
            if type != "height" {
                guard pageReady else { return }
            }
            switch type {
            case "height":
                if let height = body["height"] as? Double, height > 0 {
                    onHeight(CGFloat(height))
                }
            case "toggleLine":
                if let id = body["id"] as? String {
                    onAction(.toggleLine(id: id, extend: body["extend"] as? Bool ?? false))
                }
            case "ask":
                if let id = body["id"] as? String {
                    onAction(.ask(id: id, extend: body["extend"] as? Bool ?? false))
                }
            case "askRange":
                if let start = body["start"] as? String, let end = body["end"] as? String {
                    onAction(.askRange(startID: start, endID: end))
                }
            default:
                // Hunk and selection-frame buttons post their Swift-provided
                // action name as the message type; hunks carry an "id",
                // selection ranges a "start"/"end" pair.
                if let id = body["id"] as? String {
                    onAction(.hunk(action: type, id: id))
                } else if let start = body["start"] as? String, let end = body["end"] as? String {
                    onAction(.lines(action: type, startID: start, endID: end))
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            // Only the about:blank load from loadHTMLString; dropped files or
            // URLs must not replace the diff.
            decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            appliedSelection = nil
            applySelectionIfNeeded()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            pageReady = false
            if let html = loadedHTML {
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        func setSelection(_ ids: Set<String>) {
            pendingSelection = ids
            applySelectionIfNeeded()
        }

        func markLoading() {
            pageReady = false
            appliedSelection = nil
        }

        private func applySelectionIfNeeded() {
            guard pageReady, pendingSelection != appliedSelection, let webView else { return }
            appliedSelection = pendingSelection
            guard let data = try? JSONSerialization.data(withJSONObject: Array(pendingSelection)),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.gitalSetSelected(\(json))")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "gital")
        DiffSyntaxHighlighting.install(into: configuration)
        let webView = HeightFittingWebView(frame: .zero, configuration: configuration)
        // Transparent page over the native window background — no KVC-safe
        // public API for this on macOS; the private key is long-stable.
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onAction = onAction
        coordinator.onHeight = onHeight
        if coordinator.loadedHTML != html {
            coordinator.loadedHTML = html
            coordinator.markLoading()
            webView.loadHTMLString(html, baseURL: nil)
        }
        coordinator.setSelection(selectedLineIDs)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // The content controller retains its handlers; without this the
        // coordinator (and web view) would leak on every recycled chunk.
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "gital")
    }
}
