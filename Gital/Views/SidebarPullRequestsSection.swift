import SwiftUI

/// Sidebar content for the Pull Requests tab: filterable PR list with
/// expandable commit/file rows and "Viewed" progress toggles.
struct SidebarPullRequestsSection: View {
    var model: RepoViewModel
    @Binding var collapsedPRSections: Set<String>

    var body: some View {
        let filtered = model.prs.filtered
        let isFiltering = model.prs.isFilterActive

        SidebarSectionHeader(isFiltering
            ? "Pull Requests \(filtered.count)/\(model.prs.pullRequests.count)"
            : "Pull Requests \(model.prs.pullRequests.count)"
        ) {
            stateFilterMenu
        }

        searchField

        if let error = model.prs.loadError, model.prs.pullRequests.isEmpty {
            Text(error)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        }

        if filtered.isEmpty, model.prs.loadError == nil {
            Text(isFiltering ? "No matching pull requests" : "No pull requests")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
        }

        ForEach(filtered) { pr in
            summaryRow(pr)
            if model.prs.expanded.contains(pr.number), let detail = model.prs.detailsCache[pr.number] {
                expansion(detail)
            }
        }
    }

    private var stateFilterMenu: some View {
        Menu {
            @Bindable var prs = model.prs
            Picker("State", selection: $prs.stateFilter) {
                ForEach(PullRequestsModel.StateFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11))
                Text(model.prs.stateFilter.shortLabel)
                    .font(.system(size: 10.5))
            }
            .foregroundStyle(model.prs.stateFilter == .all ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by state")
    }

    private var searchField: some View {
        @Bindable var prs = model.prs
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            TextField("Filter pull requests", text: $prs.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !model.prs.searchText.isEmpty {
                Button {
                    model.prs.searchText = ""
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

    private func summaryRow(_ pr: PullRequestSummary) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Button {
                Task { await model.prs.expand(pr.number) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(model.prs.expanded.contains(pr.number) ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 12))
                .foregroundStyle(DesignStyle.prStateColor(state: pr.state, isDraft: pr.isDraft))
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
        .background(sidebarRowBackground(model.prs.selectedNumber == pr.number && model.prs.selectedItem == nil))
        .onTapGesture {
            model.prs.selectedNumber = pr.number
            model.prs.selectedItem = nil
        }
    }

    @ViewBuilder
    private func expansion(_ detail: PullRequestDetail) -> some View {
        let commitsKey = "pr:\(detail.number):commits"
        sectionHeader("Commits \(detail.commits.count)", key: commitsKey, topPadding: 6)
        if !collapsedPRSections.contains(commitsKey) {
            ForEach(detail.commits) { commit in
                let viewed = model.prs.isCommitViewed(commit.hash, in: detail.number)
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
                    ViewedToggle(viewed: viewed) {
                        model.prs.toggleCommitViewed(commit.hash, in: detail.number)
                    }
                }
                .padding(.leading, 34)
                .padding(.trailing, 16)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .background(sidebarRowBackground(isItemSelected(.commit(hash: commit.hash), in: detail.number)))
                .onTapGesture {
                    model.prs.selectItem(.commit(hash: commit.hash), in: detail.number)
                }
            }
        }

        let filesKey = "pr:\(detail.number):files"
        sectionHeader("Files Changed \(detail.files.count)", key: filesKey, topPadding: 8)
        if !collapsedPRSections.contains(filesKey) {
            ForEach(detail.files) { file in
                let viewed = model.prs.isFileViewed(file.path, in: detail.number)
                HStack(spacing: 7) {
                    HStack(spacing: 7) {
                        StatusBadge(status: file.deletions > 0 && file.additions == 0 ? .deleted : .modified)
                        Text((file.path as NSString).lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                    }
                    .opacity(viewed ? 0.4 : 1)
                    ViewedToggle(viewed: viewed) {
                        model.prs.toggleFileViewed(file.path, in: detail.number)
                    }
                }
                .padding(.leading, 34)
                .padding(.trailing, 16)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .background(sidebarRowBackground(isItemSelected(.file(path: file.path), in: detail.number)))
                .onTapGesture {
                    model.prs.selectItem(.file(path: file.path), in: detail.number)
                }
            }
        }
    }

    private func isItemSelected(_ item: PullRequestsModel.ItemSelection, in number: Int) -> Bool {
        model.prs.selectedNumber == number && model.prs.selectedItem == item
    }

    private func sectionHeader(_ title: String, key: String, topPadding: CGFloat) -> some View {
        DisclosureRow(
            isExpanded: !collapsedPRSections.contains(key),
            chevronSize: 7,
            spacing: 5,
            insets: EdgeInsets(top: topPadding, leading: 34, bottom: 3, trailing: 16)
        ) {
            collapsedPRSections.toggleMembership(key)
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .kerning(0.5)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
        }
    }
}
