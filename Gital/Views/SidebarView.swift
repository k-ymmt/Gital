import SwiftUI

/// Sidebar shell: repository header, tab strip, and the scroll container for
/// the per-tab sections (which live in SidebarXxxSection files). Collapse
/// state stays here so it survives tab switches.
///
/// Deliberately a custom ScrollView, not List: on macOS 27 beta, List rows
/// inside NavigationSplitView render outdented/clipped.
struct SidebarView: View {
    @Bindable var model: RepoViewModel
    @Environment(AppModel.self) private var appModel

    @State private var expandedSections: Set<String> = ["branches", "remotes", "tags", "stashes"]
    @State private var collapsedBranchFolders: Set<String> = []
    @State private var collapsedFileFolders: Set<String> = []
    @State private var collapsedPRSections: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            repoHeader
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

    // MARK: - Header

    private var repoHeader: some View {
        HStack(spacing: 9) {
            Text(String(model.repository.name.prefix(1)).uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(
                    LinearGradient(
                        colors: [DesignStyle.linkBlue, DesignStyle.brandBlue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 6)
                )

            VStack(alignment: .leading, spacing: 0) {
                Text(model.repository.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(model.repository.displayPath)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Menu {
                Button("Open Another Repository…") {
                    appModel.pickRepository()
                }
                ForEach(appModel.recentRepositories, id: \.path) { url in
                    Button {
                        appModel.openRepository(at: url)
                    } label: {
                        Text(url.lastPathComponent)
                        Text(Self.abbreviatedPath(for: url))
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Menu items ignore Text line-limit/truncation modifiers, so ellipsize the string itself.
    private static func abbreviatedPath(for url: URL, maxLength: Int = 48) -> String {
        let path = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        guard path.count > maxLength else { return path }
        let head = path.prefix((maxLength - 1) / 2)
        let tail = path.suffix(maxLength / 2)
        return "\(head)…\(tail)"
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
        .padding(.bottom, 8)
    }
}
