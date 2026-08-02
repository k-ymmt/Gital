import SwiftUI
import WebKit

/// WKWebView-backed read-only diff renderer (experimental).
///
/// Compared with the `Text`-per-line SwiftUI renderer this gives real
/// multi-line text selection, and copies come out clean because line
/// numbers/signs are CSS pseudo-elements the selection can't include.
struct WebDiffView: NSViewRepresentable {
    let diff: FileDiff
    let mode: DiffMode

    final class Coordinator: NSObject, WKNavigationDelegate {
        var renderedDiff: FileDiff?
        var renderedMode: DiffMode?
        /// Kept to recover from a web-content-process crash: SwiftUI won't
        /// call `updateNSView` for it, so the delegate reloads directly.
        var renderedHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            // `loadHTMLString(_:baseURL: nil)` navigates to about:blank. Any
            // other navigation is a hijack — a file or URL dropped onto the
            // view, which WKWebView loads by default — and must not replace
            // the diff (the rendered-diff cache would then refuse to repaint
            // it for as long as the same file stays selected).
            let isOwnLoad = navigationAction.request.url?.absoluteString == "about:blank"
            decisionHandler(isOwnLoad ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // Without this the pane stays blank forever: updateNSView keeps
            // seeing an unchanged diff and skips the reload.
            if let html = renderedHTML {
                webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        DiffSyntaxHighlighting.install(into: configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Transparent page over the native window background — no KVC-safe
        // public API for this on macOS; the private key is long-stable.
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // SwiftUI calls update on every unrelated state change; reloading the
        // page each time would reset scroll and selection, so skip unless the
        // content actually differs.
        guard context.coordinator.renderedDiff != diff
            || context.coordinator.renderedMode != mode else { return }
        let html = DiffHTMLBuilder.page(for: diff, mode: mode)
        context.coordinator.renderedDiff = diff
        context.coordinator.renderedMode = mode
        context.coordinator.renderedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }
}
