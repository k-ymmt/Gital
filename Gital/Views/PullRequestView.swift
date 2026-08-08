import SwiftUI

struct PullRequestView: View {
    @Bindable var model: RepoViewModel

    var body: some View {
        Group {
            if let item = model.prs.selectedItem {
                PullRequestItemDiffView(model: model, item: item)
            } else if let detail = model.prs.detail {
                PullRequestDetailView(model: model, detail: detail)
            } else if model.prs.selectedNumber != nil {
                ProgressView("Loading pull request…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(model.prs.loadError ?? "Select a pull request", maxTextWidth: 420) {
                    GitGlyph(kind: .pullRequest, size: 36)
                }
            }
        }
        // Entering the tab shows the cached list immediately and re-fetches
        // it in the background (throttled inside).
        .task {
            await model.prs.refreshIfStale()
        }
    }
}
