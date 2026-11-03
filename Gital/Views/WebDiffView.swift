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
        /// In-flight off-main page build for a large diff (see updateNSView).
        var buildTask: Task<Void, Never>?

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

    func makeNSView(context: Context) -> DiffWebView {
        let configuration = WKWebViewConfiguration()
        DiffSyntaxHighlighting.install(into: configuration)
        let webView = DiffWebView(frame: .zero, configuration: configuration)
        // Transparent page over the native window background — no KVC-safe
        // public API for this on macOS; the private key is long-stable.
        webView.setValue(false, forKey: "drawsBackground")
        webView.keepRenderingWhileOccluded()
        webView.allowsMagnification = true
        webView.navigationDelegate = context.coordinator
        return webView
    }

    /// Diffs above this many lines build their page off the main thread.
    /// The build is O(lines) string assembly — ~3ms per 1k lines in a debug
    /// build, so a 50k-line commit file stalled the UI for a good part of a
    /// second on selection. Smaller diffs stay synchronous: they load in the
    /// same update, with no frame showing the previous file's page.
    static let asyncBuildLineThreshold = 3_000

    func updateNSView(_ webView: DiffWebView, context: Context) {
        // SwiftUI calls update on every unrelated state change; reloading the
        // page each time would reset scroll and selection, so skip unless the
        // content actually differs.
        let coordinator = context.coordinator
        guard coordinator.renderedDiff != diff
            || coordinator.renderedMode != mode else { return }
        coordinator.renderedDiff = diff
        coordinator.renderedMode = mode
        coordinator.buildTask?.cancel()
        coordinator.buildTask = nil
        let diff = diff
        let mode = mode
        let lineCount = diff.hunks.reduce(0) { $0 + $1.lines.count }
        guard lineCount > Self.asyncBuildLineThreshold else {
            Self.load(DiffHTMLBuilder.page(for: diff, mode: mode), into: webView, coordinator: coordinator)
            return
        }
        coordinator.buildTask = Task { [weak webView] in
            let html = await Task.detached { DiffHTMLBuilder.page(for: diff, mode: mode) }.value
            // A newer update (another file, a mode switch) superseded this
            // build while it ran; its own load owns the view now.
            guard !Task.isCancelled, let webView,
                  coordinator.renderedDiff == diff, coordinator.renderedMode == mode else { return }
            Self.load(html, into: webView, coordinator: coordinator)
        }
    }

    private static func load(_ html: String, into webView: DiffWebView, coordinator: Coordinator) {
        coordinator.renderedHTML = html
        webView.momentumFilter.pageWillLoad()
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleNSView(_ webView: DiffWebView, coordinator: Coordinator) {
        coordinator.buildTask?.cancel()
    }
}

extension WKWebView {
    /// Stops WebKit from treating the page as hidden whenever the window
    /// server reports the window occluded.
    ///
    /// WebKit folds `NSWindow.occlusionState` into the page's visibility: an
    /// occluded window makes `document.visibilityState` "hidden", stalls
    /// requestAnimationFrame, and after a few seconds drops the page's tiles,
    /// so the pane paints blank until some input (a scroll) wakes it. The
    /// window server marks a window occluded while another app's window
    /// covers it, and it has been seen reporting this for a Gital window
    /// that was partly visible — a freshly selected file then rendered as an
    /// empty pane that only appeared once the user scrolled. Turning the
    /// detection off keeps every diff page live; the cost is a little idle
    /// work while the window really is covered. The key is private, like
    /// `drawsBackground` above, and equally long-stable.
    func keepRenderingWhileOccluded() {
        setValue(false, forKey: "windowOcclusionDetectionEnabled")
    }
}

/// `WKWebView` that keeps a scroll gesture started on one page from
/// scrolling the next.
///
/// A trackpad flick keeps delivering momentum wheel events for a second or
/// more after the finger lifts. WebKit routes them to whatever document the
/// view holds *now*, so picking another file mid-flick loads the new diff
/// and immediately scrolls it by the old page's leftover momentum — a long
/// diff opens at its bottom (and a short one past its only hunk), which
/// reads as "the preview didn't switch" until the user scrolls back up.
/// Every load arms `momentumFilter`; it drops the rest of that gesture and
/// lets the next one the user starts through untouched.
final class DiffWebView: WKWebView {
    var momentumFilter = InheritedScrollMomentumFilter()

    override func scrollWheel(with event: NSEvent) {
        guard momentumFilter.allows(phase: event.phase, momentumPhase: event.momentumPhase) else { return }
        super.scrollWheel(with: event)
    }
}

/// Decides, per wheel event, whether it belongs to a gesture that started
/// before the current page loaded. Pure state machine so the policy is unit
/// testable without synthesizing `NSEvent`s.
///
/// Trackpad gestures arrive as `phase` events (`mayBegin`/`began`, `changed`…,
/// `ended`) followed by `momentumPhase` events (`began`, `changed`…, `ended`).
/// After `pageWillLoad()` everything is dropped until the user starts a new
/// gesture (a `began`/`mayBegin` phase) or turns a legacy wheel (no phases at
/// all); from then on events pass through. A gesture that ends without
/// momentum leaves the filter armed, which is harmless: the next gesture's
/// `began` disarms it before any scrolling event.
nonisolated struct InheritedScrollMomentumFilter {
    private(set) var isDroppingInheritedGesture = false

    mutating func pageWillLoad() {
        isDroppingInheritedGesture = true
    }

    mutating func allows(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) -> Bool {
        let startsGesture = !phase.isDisjoint(with: [.began, .mayBegin])
        let legacyWheel = phase.isEmpty && momentumPhase.isEmpty
        if startsGesture || legacyWheel {
            isDroppingInheritedGesture = false
            return true
        }
        return !isDroppingInheritedGesture
    }
}
