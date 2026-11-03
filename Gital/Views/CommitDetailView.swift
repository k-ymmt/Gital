import SwiftUI

struct CommitDetailView: View {
    @Bindable var model: RepoViewModel
    @State private var collapsedDirectories: Set<String> = []
    @State private var fileRowsCache = BranchTreeRowsCache<CommitFileStat>()

    var body: some View {
        VStack(spacing: 0) {
            if let commit = model.selectedCommit {
                detailHeader(commit)
                Divider()
                if let error = model.commitDetailError {
                    EmptyStateView(error, systemImage: "exclamationmark.triangle")
                } else {
                    switch model.commitDetailTab {
                    case .commit:
                        commitInfoPane(commit)
                    case .files:
                        // Same stale-pairing guard as commitInfoPane: while a
                        // new selection's load is in flight, commitFiles and
                        // the diff still hold the previous commit's data —
                        // rendering them would pair them with this header.
                        if model.commitDiffsHash == commit.hash {
                            ResizableSplit(
                                axis: .horizontal,
                                firstPane: .init(min: 220, ideal: 300, max: 420),
                                secondPane: .init(min: 320)
                            ) {
                                filesList
                            } second: {
                                diffPane
                            }
                        } else {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            } else {
                Text("Select a commit")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func detailHeader(_ commit: Commit) -> some View {
        HStack(alignment: .top, spacing: 11) {
            AvatarView(name: commit.author, url: model.avatarURL(email: commit.authorEmail, size: 30))
            VStack(alignment: .leading, spacing: 3) {
                Text(commit.subject)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(2)
                Text("\(commit.author) <\(commit.authorEmail)> · \(commit.relativeDate)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Detail Tab", selection: $model.commitDetailTab) {
                ForEach(CommitDetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 130)
            Text(commit.shortHash)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.quaternary.opacity(0.25))
    }

    // MARK: Commit info tab

    @ViewBuilder
    private func commitInfoPane(_ commit: Commit) -> some View {
        if let detail = model.commitDetail, detail.hash == commit.hash {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 8) {
                        infoRow("SHA") {
                            Text(detail.hash)
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if !detail.parents.isEmpty {
                            infoRow(detail.parents.count == 1 ? "Parent" : "Parents") {
                                HStack(spacing: 8) {
                                    ForEach(detail.parents, id: \.self) { parent in
                                        Button(parent.gitShortHash) {
                                            model.selectedCommitHash = parent
                                        }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(Color.accentColor)
                                        .help(parent)
                                    }
                                }
                            }
                        }
                        infoRow("Author") {
                            Text("\(detail.author) <\(detail.authorEmail)> · \(detail.authorDate)")
                                .font(.system(size: 12))
                                .textSelection(.enabled)
                        }
                        if detail.hasDistinctCommitter {
                            infoRow("Committer") {
                                Text("\(detail.committer) <\(detail.committerEmail)> · \(detail.committerDate)")
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                            }
                        }
                        if !detail.refs.isEmpty {
                            infoRow("Refs") {
                                // Scrolls so a large ref pileup can't widen the pane.
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(detail.refs) { gitRef in
                                            RefBadge(gitRef: gitRef)
                                        }
                                    }
                                }
                            }
                        }
                        infoRow("Changes") {
                            HStack(spacing: 8) {
                                Text("\(model.commitFiles.count) files")
                                    .font(.system(size: 12))
                                DiffStatsLabel(
                                    additions: model.commitFiles.reduce(0) { $0 + $1.additions },
                                    deletions: model.commitFiles.reduce(0) { $0 + $1.deletions }
                                )
                            }
                        }
                    }

                    Divider()

                    Text(detail.message.isEmpty ? commit.subject : detail.message)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func infoRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content()
        }
    }

    private var filesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("\(model.commitFiles.count) files changed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)

                let rows = fileRowsCache.rows(
                    model.commitFiles.map { ($0.path, $0) },
                    keyPrefix: "commit-files",
                    collapsed: collapsedDirectories,
                    compressChains: true
                )
                ForEach(rows) { row in
                    switch row {
                    case .folder(let path, let name, let depth):
                        directoryRow(name: name, path: path, depth: depth)
                    case .leaf(let file, _, _, let depth):
                        fileRow(file, depth: depth)
                    }
                }
            }
        }
    }

    private func directoryRow(name: String, path: String, depth: Int) -> some View {
        DisclosureRow(
            isExpanded: !collapsedDirectories.contains(path),
            spacing: 5,
            insets: EdgeInsets(top: 4, leading: 14 + CGFloat(depth) * 16, bottom: 4, trailing: 14)
        ) {
            collapsedDirectories.toggleMembership(path)
        } label: {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(name)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func fileRow(_ file: CommitFileStat, depth: Int) -> some View {
        let isSelected = model.selectedCommitFilePath == file.path
        return HStack(spacing: 9) {
            StatusBadge(status: file.status)
            Text(file.fileName)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text("+\(file.additions)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(DesignStyle.addition)
            Text("−\(file.deletions)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(DesignStyle.deletion)
        }
        .padding(.leading, 14 + CGFloat(depth) * 16 + 15)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear)
        .onTapGesture {
            model.selectedCommitFilePath = file.path
        }
        .contextMenu {
            Button("File History") {
                model.showFileHistory(path: file.path, at: model.selectedCommitHash)
            }
            Button("Blame") {
                model.showFileHistory(path: file.path, at: model.selectedCommitHash, tab: .blame)
            }
        }
    }

    private var diffPane: some View {
        VStack(spacing: 0) {
            PaneHeader {
                if let diff = model.selectedCommitDiff {
                    Text(diff.path)
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    DiffStatsLabel(additions: diff.additions, deletions: diff.deletions)
                }
                Spacer()
                DiffModePicker(mode: $model.diffMode)
            }

            if let diff = model.selectedCommitDiff {
                SingleFileDiffContent(diff: diff, mode: model.diffMode, imageContext: commitImageContext)
            } else {
                Color.clear
            }
        }
    }

    /// Keyed off the hash the diffs were loaded for, not the selection —
    /// they diverge while a new selection's diff load is in flight.
    private var commitImageContext: ImageDiffContext? {
        model.commitDiffsHash.map { ImageDiffContext.firstParent(repository: model.repository, hash: $0) }
    }
}
