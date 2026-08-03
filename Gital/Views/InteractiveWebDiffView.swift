import SwiftUI
import WebKit

/// A click routed out of an interactive diff page (Working Copy).
enum WebDiffAction {
    case toggleLine(id: String, extend: Bool)
    /// The "+" on a text-selection or hover-hunk frame: ask about every
    /// line the frame spans, first to last.
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

/// Hashing is O(html length) — the Working Copy page can be megabytes, and
/// heights are reported on every layout change, so callers with a long-lived
/// page precompute the key once instead of re-hashing per report.
func heightCacheKey(for html: String) -> String {
    String(html.hashValue)
}

func cachedHeight(forKey key: String) -> CGFloat? {
    heightCache.object(forKey: key as NSString).map { CGFloat($0.doubleValue) }
}

func cacheHeight(_ height: CGFloat, forKey key: String) {
    heightCache.setObject(NSNumber(value: height), forKey: key as NSString)
}

func cachedHeight(for html: String) -> CGFloat? {
    cachedHeight(forKey: heightCacheKey(for: html))
}

func cacheHeight(_ height: CGFloat, for html: String) {
    cacheHeight(height, forKey: heightCacheKey(for: html))
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
            // Chunk pages cache unconditionally: they are small (hashing is
            // cheap) and post no guaranteed post-didFinish report, so gating
            // on readiness could leave the cache cold across recycles.
            onHeight: { height, _ in
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

/// Space the page reserves for one native overlay (see `gitalSetSpacers` in
/// `DiffHTMLBuilder`): static spacers (file headers, binary previews) exist
/// in the HTML and only resize; dynamic ones (`line` non-nil) are inserted
/// after the diff line they anchor to.
struct WebDiffSpacer: Equatable {
    let id: String
    var line: String? = nil
    let height: CGFloat
}

struct InteractiveWebView: NSViewRepresentable {
    let html: String
    var selectedLineIDs: Set<String> = []
    /// Native-overlay space requests, pushed via JS so a card opening or
    /// resizing never reloads the page.
    var spacers: [WebDiffSpacer] = []
    let onAction: (WebDiffAction) -> Void
    /// Second argument is whether the report arrived after the current
    /// page's didFinish. During a reload the OLD page can still post heights
    /// (they keep the frame from collapsing, so they are delivered either
    /// way) — but persisting one under the NEW page's cache key would poison
    /// the warm-start height, so cache writers only trust ready reports.
    let onHeight: (CGFloat, _ pageReady: Bool) -> Void
    /// Laid-out document offsets of every spacer, reported by the page after
    /// each load/layout change — where the native overlays position themselves.
    var onAnchors: (([String: CGFloat]) -> Void)? = nil

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        // Re-pointed on every update so bridge messages never run stale
        // closures captured at makeNSView time.
        var onAction: (WebDiffAction) -> Void = { _ in }
        var onHeight: (CGFloat, Bool) -> Void = { _, _ in }
        var onAnchors: (([String: CGFloat]) -> Void)?
        var loadedHTML: String?
        weak var webView: WKWebView?
        /// Selection can arrive before the page finishes loading; it is kept
        /// pending and applied from didFinish. Spacers work the same way.
        private var pageReady = false
        private var appliedSelection: Set<String>?
        private var pendingSelection: Set<String> = []
        private var appliedSpacers: [WebDiffSpacer]?
        private var pendingSpacers: [WebDiffSpacer] = []

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
            if type != "height" && type != "anchors" {
                guard pageReady else { return }
            }
            switch type {
            case "height":
                if let height = body["height"] as? Double, height > 0 {
                    onHeight(CGFloat(height), pageReady)
                }
            case "anchors":
                if let anchors = body["anchors"] as? [String: Double] {
                    onAnchors?(anchors.mapValues { CGFloat($0) })
                }
            case "toggleLine":
                if let id = body["id"] as? String {
                    onAction(.toggleLine(id: id, extend: body["extend"] as? Bool ?? false))
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
            appliedSpacers = nil
            applySelectionIfNeeded()
            applySpacersIfNeeded()
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

        func setSpacers(_ spacers: [WebDiffSpacer]) {
            pendingSpacers = spacers
            applySpacersIfNeeded()
        }

        func markLoading() {
            pageReady = false
            appliedSelection = nil
            appliedSpacers = nil
        }

        private func applySelectionIfNeeded() {
            guard pageReady, pendingSelection != appliedSelection, let webView else { return }
            appliedSelection = pendingSelection
            guard let data = try? JSONSerialization.data(withJSONObject: Array(pendingSelection)),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.gitalSetSelected(\(json))")
        }

        private func applySpacersIfNeeded() {
            guard pageReady, pendingSpacers != appliedSpacers, let webView else { return }
            // Pages that never host overlays (PR/stash chunks) skip the call
            // entirely instead of poking their stub on every load.
            if appliedSpacers == nil && pendingSpacers.isEmpty { return }
            appliedSpacers = pendingSpacers
            let specs: [[String: Any]] = pendingSpacers.map { spacer in
                var spec: [String: Any] = ["id": spacer.id, "height": Double(spacer.height)]
                if let line = spacer.line { spec["line"] = line }
                return spec
            }
            guard let data = try? JSONSerialization.data(withJSONObject: specs),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.gitalSetSpacers(\(json))")
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
        coordinator.onAnchors = onAnchors
        if coordinator.loadedHTML != html {
            coordinator.loadedHTML = html
            coordinator.markLoading()
            webView.loadHTMLString(html, baseURL: nil)
        }
        coordinator.setSelection(selectedLineIDs)
        coordinator.setSpacers(spacers)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // The content controller retains its handlers; without this the
        // coordinator (and web view) would leak on every recycled chunk.
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "gital")
    }
}
