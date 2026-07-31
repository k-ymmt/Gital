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

    final class Coordinator {
        var renderedDiff: FileDiff?
        var renderedMode: DiffMode?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        // Transparent page over the native window background — no KVC-safe
        // public API for this on macOS; the private key is long-stable.
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // SwiftUI calls update on every unrelated state change; reloading the
        // page each time would reset scroll and selection, so skip unless the
        // content actually differs.
        guard context.coordinator.renderedDiff != diff
            || context.coordinator.renderedMode != mode else { return }
        context.coordinator.renderedDiff = diff
        context.coordinator.renderedMode = mode
        webView.loadHTMLString(DiffHTMLBuilder.page(for: diff, mode: mode), baseURL: nil)
    }
}
