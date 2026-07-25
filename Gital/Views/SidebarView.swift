import SwiftUI

struct SidebarView: View {
    @Bindable var model: RepoViewModel
    @Environment(AppModel.self) private var appModel

    @State private var expandedSections: Set<String> = ["branches", "remotes", "tags", "stashes"]

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
                    case .source:
                        sourceContent
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
                    Button(url.lastPathComponent) {
                        appModel.openRepository(at: url)
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
        ForEach(model.status.unstaged) { change in
            fileRow(change, staged: false)
        }

        sectionHeader("Staged (\(model.status.staged.count))") {
            AnyView(
                Button("Unstage All") { model.unstageAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tint)
                    .disabled(model.status.staged.isEmpty)
            )
        }
        ForEach(model.status.staged) { change in
            fileRow(change, staged: true)
        }
    }

    private func fileRow(_ change: FileChange, staged: Bool) -> some View {
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

            VStack(alignment: .leading, spacing: 0) {
                Text(change.fileName)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                if !change.directory.isEmpty {
                    Text(change.directory)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(rowBackground(model.selectedChangePath == change.path))
        .onTapGesture {
            model.selectedChangePath = change.path
            model.navTab = .changes
        }
        .contextMenu {
            if !staged, change.status != .untracked {
                Button("Discard Changes", role: .destructive) {
                    Task {
                        try? await model.repository.discardChanges([change.path])
                        await model.refreshStatus()
                        await model.loadWorkingDiffs()
                    }
                }
            }
        }
    }

    // MARK: - Source

    @ViewBuilder
    private var sourceContent: some View {
        collapsibleHeader("Branches", key: "branches")
        if expandedSections.contains("branches") {
            ForEach(model.branches) { branch in
                HStack(spacing: 9) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 12))
                        .foregroundStyle(branch.isCurrent ? Color.accentColor : Color.secondary)
                    Text(branch.name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Spacer()
                    if branch.isCurrent {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(DesignStyle.addition)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(rowBackground(model.selectedBranchName == branch.name))
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
        }

        collapsibleHeader("Remotes", key: "remotes")
        if expandedSections.contains("remotes") {
            ForEach(model.remotes) { remote in
                HStack(spacing: 9) {
                    Image(systemName: "globe")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(remote.name)
                        .font(.system(size: 12.5))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)

                ForEach(remote.branches, id: \.self) { branch in
                    Text(branch)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 37)
                        .padding(.trailing, 16)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Checkout Tracking Branch") {
                                Task {
                                    try? await model.repository.checkoutRemote(branch: branch, remote: remote.name)
                                    await model.refreshAll()
                                }
                            }
                        }
                }
            }
        }

        collapsibleHeader("Tags", key: "tags")
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
            }
        }
    }

    // MARK: - Pull requests

    @ViewBuilder
    private var pullRequestContent: some View {
        sectionHeader("Pull Requests \(model.pullRequests.count)")

        if let error = model.prLoadError, model.pullRequests.isEmpty {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        }

        ForEach(model.pullRequests) { pr in
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
            .background(rowBackground(model.selectedPRNumber == pr.number))
            .onTapGesture {
                model.selectedPRNumber = pr.number
            }

            if model.expandedPRs.contains(pr.number), let detail = model.prDetailsCache[pr.number] {
                prExpansion(detail)
            }
        }
    }

    @ViewBuilder
    private func prExpansion(_ detail: PullRequestDetail) -> some View {
        Text("Commits \(detail.commits.count)")
            .font(.system(size: 10, weight: .bold))
            .kerning(0.5)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.leading, 34)
            .padding(.top, 6)
            .padding(.bottom, 3)

        ForEach(detail.commits) { commit in
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
            .padding(.leading, 34)
            .padding(.trailing, 16)
            .padding(.vertical, 3)
        }

        Text("Files Changed \(detail.files.count)")
            .font(.system(size: 10, weight: .bold))
            .kerning(0.5)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.leading, 34)
            .padding(.top, 8)
            .padding(.bottom, 3)

        ForEach(detail.files) { file in
            HStack(spacing: 7) {
                StatusBadge(status: file.deletions > 0 && file.additions == 0 ? .deleted : .modified)
                Text((file.path as NSString).lastPathComponent)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.leading, 34)
            .padding(.trailing, 16)
            .padding(.vertical, 3)
        }
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
                .background(rowBackground(model.selectedStashRef == stash.reference))
                .onTapGesture {
                    model.selectedStashRef = stash.reference
                }
                .contextMenu {
                    Button("Apply") { model.stashApply(stash, pop: false) }
                    Button("Pop") { model.stashApply(stash, pop: true) }
                    Divider()
                    Button("Drop", role: .destructive) { model.stashDrop(stash) }
                }
            }
        }
    }
}
