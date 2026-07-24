import Foundation

/// Lane layout for the commit graph, computed once per log load.
struct CommitGraph {
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

    private(set) var rows: [String: Row] = [:]
    private(set) var maxLanes = 1

    init(commits: [Commit]) {
        var lanes: [String?] = []

        for commit in commits {
            let top = lanes

            var dot = top.firstIndex(of: commit.hash) ?? -1
            if dot == -1 {
                dot = Self.firstEmpty(top)
            }

            var after = top
            while after.count <= dot { after.append(nil) }

            var mergeFrom: [Int] = []
            for (i, id) in after.enumerated() where id == commit.hash && i != dot {
                mergeFrom.append(i)
                after[i] = nil
            }

            var branchOut: [Int] = []
            if let firstParent = commit.parents.first {
                after[dot] = firstParent
                for parent in commit.parents.dropFirst() {
                    if let existing = after.firstIndex(of: parent) {
                        // Parent already tracked in another lane; merge into it below.
                        branchOut.append(existing)
                        continue
                    }
                    let idx = Self.firstEmpty(after)
                    while after.count <= idx { after.append(nil) }
                    after[idx] = parent
                    branchOut.append(idx)
                }
            } else {
                after[dot] = nil
            }
            while let last = after.last, last == nil { after.removeLast() }

            var edges: [Edge] = []
            for (i, id) in top.enumerated() {
                guard id != nil, i != dot else { continue }
                if mergeFrom.contains(i) {
                    edges.append(Edge(shape: .mergeIn(fromLane: i), colorIndex: i))
                    continue
                }
                var j = after.firstIndex(of: id) ?? i
                if j == i {
                    edges.append(Edge(shape: .passThrough(lane: i), colorIndex: i))
                } else {
                    j = min(j, max(after.count - 1, 0))
                    edges.append(Edge(shape: .laneShift(fromLane: i, toLane: j), colorIndex: i))
                }
            }
            if dot < top.count, top[dot] == commit.hash {
                edges.append(Edge(shape: .intoDot, colorIndex: dot))
            }
            if dot < after.count, after[dot] != nil {
                edges.append(Edge(shape: .outOfDot, colorIndex: dot))
            }
            for idx in branchOut {
                edges.append(Edge(shape: .branchOut(toLane: idx), colorIndex: idx))
            }

            let laneCount = max(top.count, after.count, dot + 1)
            rows[commit.hash] = Row(dotLane: dot, dotColorIndex: dot, edges: edges, laneCount: laneCount)
            maxLanes = max(maxLanes, laneCount)
            lanes = after
        }
    }

    private static func firstEmpty(_ lanes: [String?]) -> Int {
        for (i, id) in lanes.enumerated() where id == nil { return i }
        return lanes.count
    }
}
