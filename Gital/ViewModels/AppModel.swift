import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    private static let recentsKey = "recentRepositories"

    var repoViewModel: RepoViewModel?
    var recentRepositories: [URL] = []
    var openError: String?

    /// Bumped on every open/close; a slow `discover` from an earlier click
    /// must not replace the repository the user opened afterwards.
    @ObservationIgnored private var openGeneration = 0

    init() {
        recentRepositories = (UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        if let mostRecent = recentRepositories.first {
            openRepository(at: mostRecent)
        }
    }

    func pickRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Git repository"
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            openRepository(at: url)
        }
    }

    func openRepository(at url: URL) {
        openGeneration += 1
        let generation = openGeneration
        Task {
            guard let repository = await GitRepository.discover(at: url) else {
                if generation == openGeneration {
                    openError = "“\(url.lastPathComponent)” is not a Git repository."
                }
                return
            }
            guard generation == openGeneration else { return }
            repoViewModel?.close()  // stop the old watcher and codex subprocess
            let viewModel = RepoViewModel(repository: repository)
            repoViewModel = viewModel
            rememberRecent(repository.root)
            await viewModel.refreshAll()
        }
    }

    func closeRepository() {
        openGeneration += 1
        repoViewModel?.close()
        repoViewModel = nil
    }

    private func rememberRecent(_ url: URL) {
        var recents = recentRepositories.filter { $0.path != url.path }
        recents.insert(url, at: 0)
        recentRepositories = Array(recents.prefix(8))
        UserDefaults.standard.set(recentRepositories.map(\.path), forKey: Self.recentsKey)
    }
}
