import Foundation

/// Lane layout for the commit graph, computed once per log load.
///
/// Lanes are compacted row by row: when a lane ends (its branch merges into
/// the commit on this row, or the commit has no parent), every lane to its
/// right shifts left at the bottom of that same row, so a merged branch never
/// leaves a gap between the remaining lines. Colors belong to the branch line,
/// not to the lane position, so a line keeps its color while it shifts.
nonisolated struct CommitGraph {
    struct Edge: Hashable {
        enum Shape: Hashable {
            /// Straight line through the whole row in one lane.
            case passThrough(lane: Int)
            /// Curve from `fromLane` at the row top to `toLane` at the row bottom.
            case laneShift(fromLane: Int, toLane: Int)
            /// Curve from `fromLane` at the row top into the dot at the row center.
            case mergeIn(fromLane: Int)
            /// Curve from the dot at the row center out to `toLane` at the row bottom.
            case branchOut(toLane: Int)
            /// Line from the row top into the dot.
            case intoDot
            /// Line from the dot to the row bottom.
            case outOfDot
        }

        let shape: Shape
        let colorIndex: Int
    }

    struct Row {
        let dotLane: Int
        let dotColorIndex: Int
        let edges: [Edge]
        let laneCount: Int
    }

    /// A branch line occupying a lane: the hash it is waiting to reach and the
    /// color it was born with.
    private struct Lane: Equatable {
        let hash: String
        let color: Int
    }

    private(set) var rows: [String: Row] = [:]
    private(set) var maxLanes = 1

    init(commits: [Commit]) {
        // Compacted at the end of every row, so `lanes` never holds a hole
        // when the next row starts.
        var lanes: [Lane] = []
        var nextColor = 0

        for commit in commits {
            let top = lanes

            // The leftmost lane waiting for this commit is where its dot goes;
            // an unseen commit (branch tip, or a parent outside the window of
            // the rows above) opens a new lane at the right edge.
            let dot: Int
            let dotColor: Int
            if let existing = top.firstIndex(where: { $0.hash == commit.hash }) {
                dot = existing
                dotColor = top[existing].color
            } else {
                dot = top.count
                dotColor = nextColor
                nextColor += 1
            }

            var after: [Lane?] = top
            while after.count <= dot { after.append(nil) }

            // Other lanes waiting for the same commit merge into the dot and end.
            var mergeFrom: [Int] = []
            for (i, lane) in after.enumerated() where lane?.hash == commit.hash && i != dot {
                mergeFrom.append(i)
                after[i] = nil
            }

            if let firstParent = commit.parents.first {
                after[dot] = Lane(hash: firstParent, color: dotColor)
            } else {
                after[dot] = nil
            }

            // Compact: every surviving lane moves left past the holes on its
            // left, in this same row. `newIndex[i]` is where top lane i ends up.
            var newIndex: [Int?] = Array(repeating: nil, count: after.count)
            var compacted: [Lane] = []
            for (i, lane) in after.enumerated() {
                guard let lane else { continue }
                newIndex[i] = compacted.count
                compacted.append(lane)
            }

            // Extra parents branch out after compaction: into the lane already
            // waiting for that parent, or a fresh lane at the right edge.
            var branchOut: [(lane: Int, color: Int)] = []
            for parent in commit.parents.dropFirst() {
                if let existing = compacted.firstIndex(where: { $0.hash == parent }) {
                    branchOut.append((existing, compacted[existing].color))
                    continue
                }
                let color = nextColor
                nextColor += 1
                compacted.append(Lane(hash: parent, color: color))
                branchOut.append((compacted.count - 1, color))
            }

            var edges: [Edge] = []
            for (i, lane) in top.enumerated() where i != dot {
                if mergeFrom.contains(i) {
                    edges.append(Edge(shape: .mergeIn(fromLane: i), colorIndex: lane.color))
                    continue
                }
                let j = newIndex[i] ?? i
                if j == i {
                    edges.append(Edge(shape: .passThrough(lane: i), colorIndex: lane.color))
                } else {
                    edges.append(Edge(shape: .laneShift(fromLane: i, toLane: j), colorIndex: lane.color))
                }
            }
            if dot < top.count {
                edges.append(Edge(shape: .intoDot, colorIndex: dotColor))
            }
            if let j = newIndex[dot] {
                // The dot lane only shifts when a hole opened to its left; the
                // dot stays put at the center, so leave it like a branch-out.
                edges.append(Edge(shape: j == dot ? .outOfDot : .branchOut(toLane: j), colorIndex: dotColor))
            }
            for target in branchOut {
                edges.append(Edge(shape: .branchOut(toLane: target.lane), colorIndex: target.color))
            }

            let laneCount = max(top.count, compacted.count, dot + 1)
            rows[commit.hash] = Row(dotLane: dot, dotColorIndex: dotColor, edges: edges, laneCount: laneCount)
            maxLanes = max(maxLanes, laneCount)
            lanes = compacted
        }
    }
}
