import SwiftUI

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
                        workingCopyContent
                    case .branches:
                        branchesContent
                    case .pullRequests:
                        pullRequestContent
                    case .stashes:
                        stashContent
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
                        colors: [Color(hex: 0x6ea8fe), Color(hex: 0x2f6fed)],
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

    // MARK: - Building blocks

    private func sectionHeader(_ title: String, trailing: (() -> AnyView)? = nil) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
            if let trailing {
                trailing()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 5)
    }

    private func collapsibleHeader(_ title: String, key: String) -> some View {
        Button {
            if expandedSections.contains(key) {
                expandedSections.remove(key)
            } else {
                expandedSections.insert(key)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(expandedSections.contains(key) ? 90 : 0))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 10.5, weight: .bold))
                    .kerning(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 5)
    }

    private func rowBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Color.accentColor.opacity(0.25) : .clear)
            .padding(.horizontal, 8)
    }

    // MARK: - Working copy

    @ViewBuilder
    private var workingCopyContent: some View {
        sectionHeader("Unstaged (\(model.status.unstaged.count))") {
            AnyView(
                Button("Stage All") { model.stageAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tint)
                    .disabled(model.status.unstaged.isEmpty)
            )
        }
        fileTreeRows(model.status.unstaged, keyPrefix: "wc-unstaged", staged: false)

        sectionHeader("Staged (\(model.status.staged.count))") {
            AnyView(
                Button("Unstage All") { model.unstageAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tint)
                    .disabled(model.status.staged.isEmpty)
            )
        }
        fileTreeRows(model.status.staged, keyPrefix: "wc-staged", staged: true)
    }

    @ViewBuilder
    private func fileTreeRows(_ changes: [FileChange], keyPrefix: String, staged: Bool) -> some View {
        let rows = BranchTree.rows(
            changes.map { ($0.path, $0) },
            keyPrefix: keyPrefix,
            collapsed: collapsedFileFolders
        )
        ForEach(rows) { row in
            switch row {
            case .folder(let path, let name, let depth):
                folderRow(path: path, name: name, depth: depth, baseIndent: 16, collapsed: $collapsedFileFolders)
            case .leaf(let change, let name, _, let depth):
                fileRow(change, displayName: name, depth: depth, staged: staged)
            }
        }
    }

    private func fileRow(_ change: FileChange, displayName: String, depth: Int, staged: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                staged ? model.unstage(change) : model.stage(change)
            } label: {
                Image(systemName: staged ? "minus.square.fill" : "plus.square")
                    .font(.system(size: 13))
                    .foregroundStyle(staged ? DesignStyle.addition : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(staged ? "Unstage" : "Stage")

            StatusBadge(status: change.status)

            Text(displayName)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 16 + CGFloat(depth) * 14)
        .padding(.trailing, 16)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(rowBackground(model.selectedChange == RepoViewModel.ChangeSelection(path: change.path, staged: staged)))
        .onTapGesture {
            model.selectedChange = RepoViewModel.ChangeSelection(path: change.path, staged: staged)
            model.navTab = .changes
        }
        .contextMenu {
            if !staged {
                Button(change.status == .untracked ? "Delete File…" : "Discard Changes…", role: .destructive) {
                    model.requestDiscard(.file(change))
                }
            }
        }
    }

    // MARK: - Branches

    @ViewBuilder
    private var branchesContent: some View {
        collapsibleHeader("Branches", key: "branches")
        if expandedSections.contains("branches") {
            let rows = BranchTree.rows(
                model.branches.map { ($0.name, $0) },
                keyPrefix: "branches",
                collapsed: collapsedBranchFolders
            )
            ForEach(rows) { row in
                switch row {
                case .folder(let path, let name, let depth):
                    folderRow(path: path, name: name, depth: depth, baseIndent: 16, collapsed: $collapsedBranchFolders)
                case .leaf(let branch, let name, _, let depth):
                    localBranchRow(branch, displayName: name, depth: depth)
                }
            }
        }

        collapsibleHeader("Remotes", key: "remotes")
        if expandedSections.contains("remotes") {
            ForEach(model.remotes) { remote in
                let remoteKey = "remote:\(remote.name)"
                Button {
                    if collapsedBranchFolders.contains(remoteKey) {
                        collapsedBranchFolders.remove(remoteKey)
                    } else {
                        collapsedBranchFolders.insert(remoteKey)
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(collapsedBranchFolders.contains(remoteKey) ? 0 : 90))
                            .foregroundStyle(.secondary)
                        Image(systemName: "globe")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(remote.name)
                            .font(.system(size: 12.5))
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if !collapsedBranchFolders.contains(remoteKey) {
                    let rows = BranchTree.rows(
                        remote.branches.map { ($0, $0) },
                        keyPrefix: remoteKey,
                        collapsed: collapsedBranchFolders
                    )
                    ForEach(rows) { row in
                        switch row {
                        case .folder(let path, let name, let depth):
                            folderRow(path: path, name: name, depth: depth, baseIndent: 37, collapsed: $collapsedBranchFolders)
                        case .leaf(let branch, let name, _, let depth):
                            remoteBranchRow(branch, displayName: name, depth: depth, remote: remote.name)
                        }
                    }
                }
            }
        }

        collapsibleHeader("Tags", key: "tags")
        tagsSection
    }

    private func folderRow(path: String, name: String, depth: Int, baseIndent: CGFloat, collapsed: Binding<Set<String>>) -> some View {
        Button {
            if collapsed.wrappedValue.contains(path) {
                collapsed.wrappedValue.remove(path)
            } else {
                collapsed.wrappedValue.insert(path)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(collapsed.wrappedValue.contains(path) ? 0 : 90))
                    .foregroundStyle(.secondary)
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.leading, baseIndent + CGFloat(depth) * 14)
            .padding(.trailing, 16)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func localBranchRow(_ branch: Branch, displayName: String, depth: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12))
                .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.secondary)
            Text(displayName)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer()
            if branch.isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DesignStyle.addition)
            }
        }
        .padding(.leading, 16 + CGFloat(depth) * 14)
        .padding(.trailing, 16)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(rowBackground(model.highlightedBranchName == branch.name))
        .onTapGesture(count: 2) {
            model.checkout(branch: branch)
        }
        .onTapGesture {
            model.selectBranch(branch)
        }
        .contextMenu {
            Button("Checkout") { model.checkout(branch: branch) }
                .disabled(branch.isCurrent)
        }
        .help(branch.isCurrent ? "Current branch" : "Click to show latest commit, double-click to checkout")
    }

    private func remoteBranchRow(_ branch: String, displayName: String, depth: Int, remote: String) -> some View {
        Text(displayName)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.leading, 37 + CGFloat(depth) * 14)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Checkout Tracking Branch") {
                    Task {
                        try? await model.repository.checkoutRemote(branch: branch, remote: remote)
                        await model.refreshAll()
                    }
                }
            }
    }

    @ViewBuilder
    private var tagsSection: some View {
        if expandedSections.contains("tags") {
            ForEach(model.tags) { tag in
                HStack(spacing: 9) {
                    Image(systemName: "tag")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignStyle.tagAmber)
                    Text(tag.name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(rowBackground(model.selectedTagName == tag.name))
                .onTapGesture {
                    model.selectTag(tag)
                }
                .help("Click to show tagged commit")
            }
        }
    }

    // MARK: - Pull requests

    @ViewBuilder
    private var pullRequestContent: some View {
        let filtered = model.filteredPullRequests
        let isFiltering = model.isPRFilterActive

        sectionHeader(isFiltering
            ? "Pull Requests \(filtered.count)/\(model.pullRequests.count)"
            : "Pull Requests \(model.pullRequests.count)"
        ) {
            AnyView(
                Menu {
                    Picker("State", selection: $model.prStateFilter) {
                        ForEach(RepoViewModel.PRStateFilter.allCases) { filter in
                            Text(filter.label).tag(filter)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 11))
                        Text(model.prStateFilter.shortLabel)
                            .font(.system(size: 10.5))
                    }
                    .foregroundStyle(model.prStateFilter == .all ? Color.secondary : Color.accentColor)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Filter by state")
            )
        }

        prSearchField

        if let error = model.prLoadError, model.pullRequests.isEmpty {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        }

        if filtered.isEmpty, model.prLoadError == nil {
            Text(isFiltering ? "No matching pull requests" : "No pull requests")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        }

        ForEach(filtered) { pr in
            HStack(alignment: .top, spacing: 7) {
                Button {
                    Task { await model.expandPR(pr.number) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(model.expandedPRs.contains(pr.number) ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)

                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 12))
                    .foregroundStyle(prColor(pr))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 1) {
                    Text(pr.title)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Text("#\(pr.number) · \(pr.author)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(rowBackground(model.selectedPRNumber == pr.number && model.selectedPRItem == nil))
            .onTapGesture {
                model.selectedPRNumber = pr.number
                model.selectedPRItem = nil
            }

            if model.expandedPRs.contains(pr.number), let detail = model.prDetailsCache[pr.number] {
                prExpansion(detail)
            }
        }
    }

    private var prSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            TextField("Filter pull requests", text: $model.prSearchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !model.prSearchText.isEmpty {
                Button {
                    model.prSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func prExpansion(_ detail: PullRequestDetail) -> some View {
        let commitsKey = "pr:\(detail.number):commits"
        prSectionHeader("Commits \(detail.commits.count)", key: commitsKey, topPadding: 6)
        if !collapsedPRSections.contains(commitsKey) {
            ForEach(detail.commits) { commit in
                let viewed = model.isPRCommitViewed(commit.hash, in: detail.number)
                HStack(spacing: 7) {
                    HStack(spacing: 7) {
                        Image(systemName: "circle")
                            .font(.system(size: 6))
                            .foregroundStyle(.secondary)
                        Text(commit.message)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        Text(commit.hash)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .opacity(viewed ? 0.4 : 1)
                    viewedToggle(viewed) {
                        model.togglePRCommitViewed(commit.hash, in: detail.number)
                    }
                }
                .padding(.leading, 34)
                .padding(.trailing, 16)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .background(rowBackground(isPRItemSelected(.commit(hash: commit.hash), in: detail.number)))
                .onTapGesture {
                    model.selectPRItem(.commit(hash: commit.hash), in: detail.number)
                }
            }
        }

        let filesKey = "pr:\(detail.number):files"
        prSectionHeader("Files Changed \(detail.files.count)", key: filesKey, topPadding: 8)
        if !collapsedPRSections.contains(filesKey) {
            ForEach(detail.files) { file in
                let viewed = model.isPRFileViewed(file.path, in: detail.number)
                HStack(spacing: 7) {
                    HStack(spacing: 7) {
                        StatusBadge(status: file.deletions > 0 && file.additions == 0 ? .deleted : .modified)
                        Text((file.path as NSString).lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                    }
                    .opacity(viewed ? 0.4 : 1)
                    viewedToggle(viewed) {
                        model.togglePRFileViewed(file.path, in: detail.number)
                    }
                }
                .padding(.leading, 34)
                .padding(.trailing, 16)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .background(rowBackground(isPRItemSelected(.file(path: file.path), in: detail.number)))
                .onTapGesture {
                    model.selectPRItem(.file(path: file.path), in: detail.number)
                }
            }
        }
    }

    /// Checkmark button toggling a row's "Viewed" flag. Kept outside the
    /// grayed-out portion so it stays legible on viewed rows.
    private func viewedToggle(_ viewed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: viewed ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(viewed ? DesignStyle.addition : Color.secondary.opacity(0.55))
        }
        .buttonStyle(.plain)
        .help(viewed ? "Mark as not viewed" : "Mark as viewed")
    }

    private func isPRItemSelected(_ item: RepoViewModel.PRItemSelection, in number: Int) -> Bool {
        model.selectedPRNumber == number && model.selectedPRItem == item
    }

    private func prSectionHeader(_ title: String, key: String, topPadding: CGFloat) -> some View {
        Button {
            if collapsedPRSections.contains(key) {
                collapsedPRSections.remove(key)
            } else {
                collapsedPRSections.insert(key)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(collapsedPRSections.contains(key) ? 0 : 90))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.leading, 34)
            .padding(.trailing, 16)
            .padding(.top, topPadding)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func prColor(_ pr: PullRequestSummary) -> Color {
        switch pr.state {
        case "MERGED": Color(hex: 0x8957e5)
        case "CLOSED": DesignStyle.deletion
        default: pr.isDraft ? Color.secondary : DesignStyle.addition
        }
    }

    // MARK: - Stashes

    @ViewBuilder
    private var stashContent: some View {
        collapsibleHeader("Stashes", key: "stashes")
        if expandedSections.contains("stashes") {
            if model.stashes.isEmpty {
                Text("No stashes")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
            ForEach(model.stashes) { stash in
                HStack(spacing: 9) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(stash.message)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(rowBackground(model.selectedStashRef == stash.id))
                .onTapGesture {
                    model.selectedStashRef = stash.id
                }
                .contextMenu {
                    Button("Apply") { model.stashApply(stash, pop: false) }
                    Button("Pop") { model.stashApply(stash, pop: true) }
                    Divider()
                    // Dropping destroys the stash permanently — confirm like
                    // every other destructive action.
                    Button("Drop…", role: .destructive) { model.pendingStashDrop = stash }
                }
            }
        }
    }
}
