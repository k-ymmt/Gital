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
                VStack(spacing: 10) {
                    GitGlyph(kind: .pullRequest, size: 36)
                        .foregroundStyle(.secondary)
                    Text(model.prs.loadError ?? "Select a pull request")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Entering the tab shows the cached list immediately and re-fetches
        // it in the background (throttled inside).
        .task {
            await model.prs.refreshIfStale()
        }
    }
}
