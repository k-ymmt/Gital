import AppKit
import SwiftUI

struct HistoryView: View {
    @Bindable var model: RepoViewModel

    @State private var branchAnchor: Commit?
    @State private var tagAnchor: Commit?

    var body: some View {
        VSplitView {
            commitList
                .frame(minHeight: 220)
            CommitDetailView(model: model)
                .frame(minHeight: 240, idealHeight: 360)
        }
        .sheet(item: $branchAnchor) { commit in
            RefCreationSheet(
                title: "New Branch at \(commit.shortHash)",
                placeholder: "Branch name",
                showCheckoutToggle: true
            ) { name, checkout in
                model.createBranch(name: name, at: commit, checkout: checkout)
            }
        }
        .sheet(item: $tagAnchor) { commit in
            RefCreationSheet(
                title: "New Tag at \(commit.shortHash)",
                placeholder: "Tag name",
                showCheckoutToggle: false
            ) { name, _ in
                model.createTag(name: name, at: commit)
            }
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
                                isSelected: model.selectedCommitHash == commit.hash
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectedCommitHash = commit.hash
                            }
                            .contextMenu { commitMenu(commit) }
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
                // Tab switches rebuild this list at the top; jump straight
                // back to the selection instead of losing the position.
                .onAppear {
                    if let hash = model.selectedCommitHash {
                        proxy.scrollTo(hash, anchor: .center)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func commitMenu(_ commit: Commit) -> some View {
        Button("Copy SHA") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(commit.hash, forType: .string)
        }
        Divider()
        Button("Create Branch Here…") { branchAnchor = commit }
        Button("Create Tag Here…") { tagAnchor = commit }
        Divider()
        // Disabled while a merge/rebase/… is stopped on conflicts, matching
        // the branch menu's merge/rebase items — git would refuse anyway.
        Button("Checkout \(commit.shortHash) (Detached HEAD)…") {
            model.requestCheckoutDetached(hash: commit.hash, subject: commit.subject)
        }
        .disabled(model.pendingOperation != nil)
        Button("Cherry-pick \(commit.shortHash)") { model.cherryPick(commit) }
            .disabled(model.pendingOperation != nil)
        Button("Revert \(commit.shortHash)") { model.revertCommit(commit) }
            .disabled(model.pendingOperation != nil)
        Button("Interactive Rebase from \(commit.shortHash)…") { model.requestInteractiveRebase(from: commit) }
            .disabled(model.pendingOperation != nil)
        // Gated like its reflog-sheet twin: mixed/hard would silently blow
        // away an in-progress merge/rebase state.
        Menu("Reset “\(model.status.branch ?? "HEAD")” to Here") {
            Button("Soft — keep changes staged") { model.requestReset(toHash: commit.hash, mode: .soft) }
            Button("Mixed — keep changes unstaged") { model.requestReset(toHash: commit.hash, mode: .mixed) }
            Button("Hard — discard all changes…", role: .destructive) { model.requestReset(toHash: commit.hash, mode: .hard) }
        }
        .disabled(model.pendingOperation != nil)
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

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Description")
                .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Branch / tag creation sheet

struct RefCreationSheet: View {
    let title: String
    let placeholder: String
    let showCheckoutToggle: Bool
    let onCreate: (_ name: String, _ checkout: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var checkout = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            TextField(placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(create)
            if showCheckoutToggle {
                Toggle("Check out after creating", isOn: $checkout)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onCreate(trimmed, checkout)
        dismiss()
    }
}

// MARK: - Commit row

struct CommitRowView: View {
    let commit: Commit
    let row: CommitGraph.Row?
    let isSelected: Bool

    private static let maxVisibleRefs = 3
    private static let laneSpacing: CGFloat = 15

    // Sized per row, not to the widest row in the history: the message starts
    // a fixed gap after this row's rightmost lane, like `git log --graph`.
    // Lane spacing never compresses on lane-heavy histories — the graph keeps
    // its natural look and the commit message truncates instead.
    private var rowGraphWidth: CGFloat {
        let lanes = CGFloat(max(row?.laneCount ?? 1, 1))
        return 10 + (lanes - 1) * Self.laneSpacing + 14
    }

    var body: some View {
        HStack(spacing: 0) {
            GraphRowCanvas(row: row, laneSpacing: Self.laneSpacing)
                .frame(width: rowGraphWidth, height: 32)

            HStack(spacing: 6) {
                // Badge padding is incompressible, so an unbounded run of refs
                // (e.g. dozens of tags on HEAD) would force the row — and the
                // whole split view — wider than the window. Cap and summarize.
                ForEach(commit.refs.prefix(Self.maxVisibleRefs)) { gitRef in
                    RefBadge(gitRef: gitRef)
                }
                if commit.refs.count > Self.maxVisibleRefs {
                    RefOverflowBadge(count: commit.refs.count - Self.maxVisibleRefs)
                        .help(commit.refs.dropFirst(Self.maxVisibleRefs).map(\.name).joined(separator: ", "))
                }
                Text(commit.subject)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    // Lowest priority in the row: when the graph or ref badges
                    // need room, the message is what gets truncated.
                    .layoutPriority(-1)
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
    var laneSpacing: CGFloat = 15

    var body: some View {
        Canvas { context, size in
            guard let row else { return }
            let laneX: (Int) -> CGFloat = { 10 + CGFloat($0) * laneSpacing }
            let height = size.height
            let centerY = height / 2
            let lineWidth = min(1.8, laneSpacing * 0.3)
            let dotRadius = min(4.5, laneSpacing * 0.45)
            let dotOutlineWidth = min(1.5, laneSpacing * 0.25)

            func stroke(_ path: Path, _ colorIndex: Int) {
                context.stroke(
                    path,
                    with: .color(DesignStyle.laneColor(colorIndex)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
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

            let dotRect = CGRect(
                x: dotX - dotRadius, y: centerY - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            )
            context.fill(Path(ellipseIn: dotRect), with: .color(DesignStyle.laneColor(row.dotColorIndex)))
            context.stroke(
                Path(ellipseIn: dotRect),
                with: .color(Color(nsColor: .windowBackgroundColor)),
                lineWidth: dotOutlineWidth
            )
        }
        .clipped()
    }
}

// MARK: - Commit detail

struct CommitDetailView: View {
    @Bindable var model: RepoViewModel
    @State private var collapsedDirectories: Set<String> = []
    @State private var fileRowsCache = BranchTreeRowsCache<CommitFileStat>()

    var body: some View {
        VStack(spacing: 0) {
            if let commit = model.selectedCommit {
                detailHeader(commit)
                Divider()
                switch model.commitDetailTab {
                case .commit:
                    commitInfoPane(commit)
                case .files:
                    HSplitView {
                        filesList
                            .frame(minWidth: 220, idealWidth: 300, maxWidth: 420)
                        diffPane
                            .frame(minWidth: 320, maxWidth: .infinity)
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
                                        Button(String(parent.prefix(7))) {
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

            ScrollView([.vertical, .horizontal]) {
                if let diff = model.selectedCommitDiff {
                    FileDiffContentView(diff: diff, mode: model.diffMode)
                        .frame(minWidth: 600, alignment: .leading)
                }
            }
        }
    }
}
