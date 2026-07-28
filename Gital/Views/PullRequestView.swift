import SwiftUI

struct PullRequestView: View {
    @Bindable var model: RepoViewModel

    var body: some View {
        if let item = model.prs.selectedItem {
            PullRequestItemDiffView(model: model, item: item)
        } else if let detail = model.prs.detail {
            PullRequestDetailView(model: model, detail: detail)
        } else if model.prs.selectedNumber != nil {
            ProgressView("Loading pull request…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(model.prs.loadError ?? "Select a pull request")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Diff pane for a commit or changed file selected in a PR's sidebar rows.
struct PullRequestItemDiffView: View {
    @Bindable var model: RepoViewModel
    let item: PullRequestsModel.ItemSelection

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    model.prs.selectedItem = nil
                } label: {
                    Label("Overview", systemImage: "chevron.left")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Back to pull request overview")

                Divider().frame(height: 16)

                itemTitle
                Spacer()
                if case .commit(let hash) = item, let number = model.prs.selectedNumber {
                    Toggle("Viewed", isOn: Binding(
                        get: { model.prs.isCommitViewed(hash, in: number) },
                        set: { _ in model.prs.toggleCommitViewed(hash, in: number) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .help("Mark the whole commit as viewed")
                }
                DiffModePicker(mode: $model.diffMode)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.25))
            Divider()

            if let error = model.prs.itemLoadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 460)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.prs.itemDiffs.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(model.prs.itemDiffs) { diff in
                            Section {
                                FileDiffContentView(diff: diff, mode: model.diffMode)
                            } header: {
                                FileSectionHeader(diff: diff) {
                                    fileViewedToggle(for: diff)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var itemTitle: some View {
        switch item {
        case .commit(let hash):
            Image(systemName: "circle")
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text(commitMessage(for: hash) ?? "Commit")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text(hash)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
        case .file(let path):
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Per-file "Viewed" checkbox in a diff section header. Inside a commit it
    /// toggles the commit-scoped flag (promoting the commit when its last file
    /// is viewed); on a Files Changed selection it toggles the PR-wide flag.
    @ViewBuilder
    private func fileViewedToggle(for diff: FileDiff) -> some View {
        if let number = model.prs.selectedNumber {
            switch item {
            case .commit(let hash):
                Toggle("Viewed", isOn: Binding(
                    get: { model.prs.isCommitFileViewed(commit: hash, path: diff.path, in: number) },
                    set: { _ in
                        model.prs.toggleCommitFileViewed(
                            commit: hash,
                            path: diff.path,
                            allPaths: model.prs.itemDiffs.map(\.path),
                            in: number
                        )
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
            case .file(let path):
                Toggle("Viewed", isOn: Binding(
                    get: { model.prs.isFileViewed(path, in: number) },
                    set: { _ in model.prs.toggleFileViewed(path, in: number) }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
            }
        }
    }

    private func commitMessage(for hash: String) -> String? {
        guard let number = model.prs.selectedNumber else { return nil }
        return model.prs.detailsCache[number]?.commits.first { $0.hash == hash }?.message
    }
}

struct PullRequestDetailView: View {
    @Bindable var model: RepoViewModel
    let detail: PullRequestDetail

    private var isMerging: Bool { model.prs.mergingNumber == detail.number }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                statusChip

                Text("\(Text(detail.title).fontWeight(.semibold))  \(Text("#\(detail.number)").foregroundStyle(.secondary))")
                    .font(.system(size: 22))
                    .padding(.top, 13)

                mergeSummaryLine
                    .padding(.top, 9)

                metaRow
                    .padding(.top, 16)
                    .padding(.bottom, 18)
                Divider()

                if !detail.labels.isEmpty {
                    labelChips
                        .padding(.top, 16)
                }

                descriptionCard
                    .padding(.top, 16)

                sectionTitle("Reviewers")
                reviewersCard

                sectionTitle("Commits", count: detail.commits.count)
                commitsCard

                mergeBox
                    .padding(.top, 26)
            }
            .frame(maxWidth: 840, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Pieces

    private var statusColor: Color {
        switch detail.state {
        case "MERGED": Color(hex: 0x8957e5)
        case "CLOSED": DesignStyle.deletion
        default: detail.isDraft ? Color.secondary : DesignStyle.addition
        }
    }

    private var statusChip: some View {
        Label(detail.statusLabel, systemImage: "arrow.triangle.pull")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(statusColor, in: Capsule())
    }

    private var mergeSummaryLine: some View {
        Text("\(detail.author) wants to merge \(Text("\(detail.commits.count) commits").foregroundStyle(.primary)) into \(refText(detail.base)) from \(refText(detail.head))")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
    }

    private func refText(_ name: String) -> Text {
        Text(name)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color(hex: 0x6ea8fe))
    }

    private var metaRow: some View {
        HStack(spacing: 12) {
            AvatarView(name: detail.author, size: 26, url: model.avatarURL(login: detail.authorLogin, size: 26))
            Text("\(detail.author) opened \(detail.createdAt)")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Spacer()
            Text("+\(detail.additions)")
                .font(.system(size: 12))
                .foregroundStyle(DesignStyle.addition)
            Text("−\(detail.deletions)")
                .font(.system(size: 12))
                .foregroundStyle(DesignStyle.deletion)
            Text("\(detail.changedFiles) files")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var labelChips: some View {
        HStack(spacing: 7) {
            ForEach(detail.labels) { label in
                let color = Color(hex: UInt32(label.color, radix: 16) ?? 0x2f6fed)
                Text(label.name)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(color.opacity(0.18), in: Capsule())
                    .foregroundStyle(color)
            }
        }
    }

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                AvatarView(name: detail.author, size: 20, url: model.avatarURL(login: detail.authorLogin, size: 20))
                Text("\(detail.author) commented · \(detail.createdAt)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.3))
            Divider()
            Text(detail.body.isEmpty ? "No description provided." : detail.body)
                .font(.system(size: 13))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator, lineWidth: 1))
    }

    private func sectionTitle(_ title: String, count: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
            if let count {
                Text("\(count)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 26)
        .padding(.bottom, 10)
    }

    private var reviewersCard: some View {
        VStack(spacing: 0) {
            if detail.reviewers.isEmpty {
                Text("No reviewers")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            ForEach(detail.reviewers) { reviewer in
                HStack(spacing: 10) {
                    AvatarView(name: reviewer.name, size: 24, url: model.avatarURL(login: reviewer.login, size: 24))
                    Text(reviewer.name)
                        .font(.system(size: 12.5))
                    Spacer()
                    reviewerState(reviewer.state)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                if reviewer.id != detail.reviewers.last?.id {
                    Divider()
                }
            }
        }
        .background(.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator, lineWidth: 1))
    }

    private func reviewerState(_ state: String) -> some View {
        let (label, color): (String, Color) = switch state {
        case "APPROVED": ("Approved", DesignStyle.addition)
        case "CHANGES_REQUESTED": ("Changes requested", DesignStyle.deletion)
        case "COMMENTED": ("Commented", .secondary)
        default: ("Pending", DesignStyle.tagAmber)
        }
        return Text(label)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var commitsCard: some View {
        VStack(spacing: 0) {
            ForEach(detail.commits) { commit in
                let viewed = model.prs.isCommitViewed(commit.hash, in: detail.number)
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "circle")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                        Text(commit.message)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                        Spacer()
                        Text(commit.author)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Text(commit.hash)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .opacity(viewed ? 0.4 : 1)
                    Button {
                        model.prs.toggleCommitViewed(commit.hash, in: detail.number)
                    } label: {
                        Image(systemName: viewed ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(viewed ? DesignStyle.addition : Color.secondary.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .help(viewed ? "Mark as not viewed" : "Mark as viewed")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.prs.selectItem(.commit(hash: commit.hash), in: detail.number)
                }
                .help("Click to show this commit's diff")
                if commit.id != detail.commits.last?.id {
                    Divider()
                }
            }
        }
        .background(.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator, lineWidth: 1))
    }

    private var canMerge: Bool {
        detail.state == "OPEN" && !detail.isDraft && detail.mergeable == "MERGEABLE"
    }

    private var mergeBox: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 17))
                .foregroundStyle(canMerge ? DesignStyle.addition : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(mergeTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(mergeNote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.prs.merge(detail.number)
            } label: {
                if isMerging {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Merge pull request")
                }
            }
            .buttonStyle(.glassProminent)
            .tint(DesignStyle.addition)
            .disabled(!canMerge || isMerging)
        }
        .padding(16)
        .glassEffect(in: .rect(cornerRadius: 12))
    }

    private var mergeTitle: String {
        switch detail.state {
        case "MERGED": return "Pull request merged"
        case "CLOSED": return "Pull request closed"
        default:
            if detail.isDraft { return "Draft pull request" }
            return detail.mergeable == "MERGEABLE"
                ? "No conflicts with the base branch"
                : "Merge state: \(detail.mergeable.lowercased())"
        }
    }

    private var mergeNote: String {
        switch detail.state {
        case "MERGED": return "The changes are already part of \(detail.base)."
        case "CLOSED": return "This pull request was closed without merging."
        default:
            if detail.isDraft { return "Mark as ready for review before merging." }
            return "Merging will create a merge commit on \(detail.base)."
        }
    }
}
