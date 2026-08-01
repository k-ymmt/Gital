import SwiftUI
import WebKit

/// A click routed out of an interactive diff page (Working Copy).
enum WebDiffAction {
    case toggleLine(id: String, extend: Bool)
    case ask(id: String, extend: Bool)
    case hunk(action: String, id: String)
}

/// WKWebView that always matches its content height — the outer SwiftUI
/// ScrollView does all scrolling, so wheel events belong to the parent.
private final class HeightFittingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
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
            onHeight: { reportedHeight = $0 }
        )
        .frame(height: reportedHeight ?? estimatedHeight)
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
            default:
                // Hunk buttons post their Swift-provided action name as the
                // message type (stageHunk/unstageHunk/discardHunk).
                if let id = body["id"] as? String {
                    onAction(.hunk(action: type, id: id))
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
