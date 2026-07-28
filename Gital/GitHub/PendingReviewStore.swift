import CryptoKit
import Foundation

/// Persists draft review comments per repository so a pending review
/// survives app restarts and repo switches — GitHub keeps its pending
/// reviews server-side; ours live locally. One JSON file per repo (keyed by
/// a hash of the repo path) holding the `[PR number: drafts]` map; drafts
/// are small, so every mutation rewrites the whole file. Unlike
/// `PRViewedStore` there is no row-level merging: a second app instance on
/// the same repo is last-writer-wins, which for a single person drafting
/// one review is acceptable. Failures make the store inert rather than
/// surfacing — losing persistence is never worth failing a review action.
final class PendingReviewStore {
    private let fileURL: URL

    init(repoRoot: URL, fileURL: URL? = nil) {
        let digest = SHA256.hash(data: Data(repoRoot.path.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(16)
        self.fileURL = fileURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gital/pending-reviews/\(digest).json")
    }

    func load() -> [Int: [PendingReviewComment]] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Int: [PendingReviewComment]].self, from: data)
        else { return [:] }
        return decoded
    }

    func save(_ drafts: [Int: [PendingReviewComment]]) {
        do {
            if drafts.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(drafts)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Inert on failure; the in-memory drafts stay usable.
        }
    }
}
