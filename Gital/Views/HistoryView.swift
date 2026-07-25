import SwiftUI

struct HistoryView: View {
    @Bindable var model: RepoViewModel

    var body: some View {
        VSplitView {
            commitList
                .frame(minHeight: 220)
            CommitDetailView(model: model)
                .frame(minHeight: 240, idealHeight: 360)
        }
    }

    // MARK: - Commit list

    private var commitList: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.filteredCommits) { commit in
                            CommitRowView(
                                commit: commit,
                                row: model.graph.rows[commit.hash],
                                graphWidth: graphWidth,
                                isSelected: model.selectedCommitHash == commit.hash
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectedCommitHash = commit.hash
                            }
                            .id(commit.hash)
                        }
                        if model.searchText.isEmpty, model.hasMoreCommits {
                            loadMoreRow
                        }
                    }
                }
                .onChange(of: model.selectedCommitHash) { _, hash in
                    guard let hash else { return }
                    withAnimation {
                        proxy.scrollTo(hash)
                    }
                }
            }
        }
    }

    private var loadMoreRow: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Spacer()
        }
        .frame(height: 32)
        // Keyed on the commit count so the trigger re-fires after each page
        // lands while the row is still on screen (e.g. a page of duplicates).
        .task(id: model.commits.count) {
            await model.loadMoreCommits()
        }
    }

    private var graphWidth: CGFloat {
        let lanes = min(model.graph.maxLanes, 8)
        return 15 + CGFloat(lanes) * 15 + 8
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Description")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, CGFloat(14) + graphWidth)
            Text("Author")
                .frame(width: 150, alignment: .leading)
            Text("Date")
                .frame(width: 130, alignment: .leading)
            Text("Commit")
                .frame(width: 84, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 7)
        .padding(.horizontal, 14)
        .background(.quaternary.opacity(0.4))
    }
}

// MARK: - Commit row

struct CommitRowView: View {
    let commit: Commit
    let row: CommitGraph.Row?
    let graphWidth: CGFloat
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 0) {
            GraphRowCanvas(row: row)
                .frame(width: graphWidth, height: 32)

            HStack(spacing: 6) {
                ForEach(commit.refs) { gitRef in
                    RefBadge(gitRef: gitRef)
                }
                Text(commit.subject)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(commit.author)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
            Text(commit.relativeDate)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)
            Text(commit.shortHash)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 84, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear)
    }
}

/// Draws one row of the commit graph: lanes, curves, and the commit dot.
struct GraphRowCanvas: View {
    let row: CommitGraph.Row?

    var body: some View {
        Canvas { context, size in
            guard let row else { return }
            let laneX: (Int) -> CGFloat = { 10 + CGFloat($0) * 15 }
            let height = size.height
            let centerY = height / 2

            func stroke(_ path: Path, _ colorIndex: Int) {
                context.stroke(
                    path,
                    with: .color(DesignStyle.laneColor(colorIndex)),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
            }

            func curve(from x1: CGFloat, _ y1: CGFloat, to x2: CGFloat, _ y2: CGFloat) -> Path {
                var path = Path()
                let midY = (y1 + y2) / 2
                path.move(to: CGPoint(x: x1, y: y1))
                path.addCurve(
                    to: CGPoint(x: x2, y: y2),
                    control1: CGPoint(x: x1, y: midY),
                    control2: CGPoint(x: x2, y: midY)
                )
                return path
            }

            func line(from x1: CGFloat, _ y1: CGFloat, to x2: CGFloat, _ y2: CGFloat) -> Path {
                var path = Path()
                path.move(to: CGPoint(x: x1, y: y1))
                path.addLine(to: CGPoint(x: x2, y: y2))
                return path
            }

            let dotX = laneX(row.dotLane)

            for edge in row.edges {
                switch edge.shape {
                case .passThrough(let lane):
                    stroke(line(from: laneX(lane), 0, to: laneX(lane), height), edge.colorIndex)
                case .laneShift(let fromLane, let toLane):
                    stroke(curve(from: laneX(fromLane), 0, to: laneX(toLane), height), edge.colorIndex)
                case .mergeIn(let fromLane):
                    stroke(curve(from: laneX(fromLane), 0, to: dotX, centerY), edge.colorIndex)
                case .branchOut(let toLane):
                    stroke(curve(from: dotX, centerY, to: laneX(toLane), height), edge.colorIndex)
                case .intoDot:
                    stroke(line(from: dotX, 0, to: dotX, centerY), edge.colorIndex)
                case .outOfDot:
                    stroke(line(from: dotX, centerY, to: dotX, height), edge.colorIndex)
                }
            }

            let dotRect = CGRect(x: dotX - 4.5, y: centerY - 4.5, width: 9, height: 9)
            context.fill(Path(ellipseIn: dotRect), with: .color(DesignStyle.laneColor(row.dotColorIndex)))
            context.stroke(
                Path(ellipseIn: dotRect),
                with: .color(Color(nsColor: .windowBackgroundColor)),
                lineWidth: 1.5
            )
        }
        .clipped()
    }
}

// MARK: - Commit detail

struct CommitDetailView: View {
    @Bindable var model: RepoViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let commit = model.selectedCommit {
                detailHeader(commit)
                Divider()
                HSplitView {
                    filesList
                        .frame(minWidth: 220, idealWidth: 300, maxWidth: 420)
                    diffPane
                        .frame(minWidth: 320, maxWidth: .infinity)
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
            AvatarView(name: commit.author)
            VStack(alignment: .leading, spacing: 3) {
                Text(commit.subject)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(2)
                Text("\(commit.author) <\(commit.authorEmail)> · \(commit.relativeDate)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
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

    private var filesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("\(model.commitFiles.count) files changed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)

                ForEach(model.commitFiles) { file in
                    let isSelected = model.selectedCommitFilePath == file.path
                    HStack(spacing: 9) {
                        StatusBadge(status: file.status)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(file.fileName)
                                .font(.system(size: 12.5))
                                .lineLimit(1)
                            let directory = (file.path as NSString).deletingLastPathComponent
                            if !directory.isEmpty {
                                Text(directory)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer(minLength: 4)
                        Text("+\(file.additions)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(DesignStyle.addition)
                        Text("−\(file.deletions)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(DesignStyle.deletion)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .background(isSelected ? Color.accentColor.opacity(0.22) : .clear)
                    .onTapGesture {
                        model.selectedCommitFilePath = file.path
                    }
                }
            }
        }
    }

    private var diffPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
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
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.25))
            Divider()

            ScrollView([.vertical, .horizontal]) {
                if let diff = model.selectedCommitDiff {
                    FileDiffContentView(diff: diff, mode: model.diffMode)
                        .frame(minWidth: 600, alignment: .leading)
                }
            }
        }
    }
}
