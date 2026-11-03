import SwiftUI

struct CommitRowView: View {
    let commit: Commit
    let row: CommitGraph.Row?
    let isSelected: Bool
    var avatarURL: URL? = nil

    static let avatarSize: CGFloat = 18
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
            }
            // The graph canvas and ref badges are incompressible, so on a
            // lane-heavy history (20+ parallel branches) the widest rows need
            // more width than the list offers. Left to its own devices the
            // row then overflows and SwiftUI centers it, shifting those rows
            // — and only those rows — left by half the overflow: the lanes no
            // longer line up with the rows above and below and the lines look
            // disconnected. Pin this column's minimum width at zero and anchor
            // it leading so overflow spills to the right under the clip; the
            // lane x positions stay identical in every row, and the trailing
            // columns keep their place.
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()

            HStack(spacing: 6) {
                AvatarView(name: commit.author, size: Self.avatarSize, url: avatarURL)
                Text(commit.author)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
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
