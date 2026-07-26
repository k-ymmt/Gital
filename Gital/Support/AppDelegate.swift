import AppKit

/// Receives open-document Apple events — the `gital` command-line tool opens
/// directories via `open -b app.kymmt.Gital <path>`, which lands here both on
/// cold launch and while the app is already running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// URLs can arrive before SwiftUI has attached the model on a cold launch;
    /// buffer them until it does.
    var appModel: AppModel? {
        didSet { openPendingURL() }
    }
    private var pendingURL: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        // Single-repository app: with several folders selected at once, each
        // open would immediately replace the previous, so keep only the last.
        pendingURL = urls.last
        openPendingURL()
    }

    private func openPendingURL() {
        guard let appModel, let url = pendingURL else { return }
        pendingURL = nil

        var directory = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        {
            directory.deleteLastPathComponent()
        }
        appModel.openRepository(at: directory)
    }
}
