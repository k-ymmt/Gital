import SwiftUI

/// Sidebar shell: tab strip and the scroll container for the per-tab
/// sections (which live in SidebarXxxSection files). Collapse state stays
/// here so it survives tab switches. The repository identity/switcher lives
/// in the window toolbar (see RepositorySwitcher in ContentView).
///
/// Deliberately a custom ScrollView, not List: on macOS 27 beta, List rows
/// inside NavigationSplitView render outdented/clipped.
struct SidebarView: View {
    @Bindable var model: RepoViewModel

    @State private var expandedSections: Set<String> = ["branches", "remotes", "tags", "stashes"]
    @State private var collapsedBranchFolders: Set<String> = []
    @State private var collapsedFileFolders: Set<String> = []
    @State private var collapsedPRSections: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            Divider()
                .opacity(0.5)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch model.navTab {
                    case .changes:
                        SidebarWorkingCopySection(model: model, collapsedFileFolders: $collapsedFileFolders)
                    case .branches:
                        SidebarBranchesSection(
                            model: model,
                            expandedSections: $expandedSections,
                            collapsedBranchFolders: $collapsedBranchFolders
                        )
                    case .pullRequests:
                        SidebarPullRequestsSection(model: model, collapsedPRSections: $collapsedPRSections)
                    case .stashes:
                        SidebarStashesSection(model: model, expandedSections: $expandedSections)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .safeAreaPadding(.top, 2)
    }

    // MARK: - Tab strip

    private var tabStrip: some View {
        HStack(spacing: 5) {
            ForEach(NavTab.allCases) { tab in
                Button {
                    model.navTab = tab
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .background(
                    model.navTab == tab ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .foregroundStyle(model.navTab == tab ? Color.accentColor : Color.secondary)
                .help(tab.help)
                .overlay(alignment: .topTrailing) {
                    if tab == .changes {
                        let count = model.status.staged.count + model.status.unstaged.count
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor, in: Capsule())
                                .foregroundStyle(.white)
                                .offset(x: 3, y: -3)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}
