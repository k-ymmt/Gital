import Foundation
import Testing
@testable import Gital

@MainActor
struct CommitGraphTests {
    private func makeCommit(_ hash: String, _ parents: [String]) -> Commit {
        Commit(hash: hash, parents: parents, author: "A", authorEmail: "a@a", relativeDate: "now", subject: hash, body: "", refs: [])
    }

    private func shapes(_ graph: CommitGraph, _ hash: String) throws -> [CommitGraph.Edge.Shape] {
        try #require(graph.rows[hash]).edges.map(\.shape)
    }

    // A -> B -> C(merge of D,E) ; D -> F ; E -> F ; F
    @Test func laneLayout() throws {
        let graphCommits = [
            makeCommit("A", ["B"]),
            makeCommit("B", ["C"]),
            makeCommit("C", ["D", "E"]),
            makeCommit("D", ["F"]),
            makeCommit("E", ["F"]),
            makeCommit("F", []),
        ]
        let graph = CommitGraph(commits: graphCommits)
        #expect(graph.rows.count == 6, "graph has a row per commit")
        #expect(try #require(graph.rows["A"]).dotLane == 0, "first commit in lane 0")
        #expect(try shapes(graph, "C").contains(.branchOut(toLane: 1)), "merge commit branches out")
        #expect(try #require(graph.rows["E"]).dotLane == 1, "second parent occupies lane 1")
        #expect(graph.maxLanes >= 2, "graph tracks max lanes")
        #expect(try shapes(graph, "F").contains(.mergeIn(fromLane: 1)), "lanes merge back into common parent")
    }

    // Regression: two commits sharing a first parent put the same hash in two
    // lanes; each lane must continue straight down instead of zigzagging into
    // the other copy.
    @Test func continuityAtBranchPoints() throws {
        let branchCommits = [
            makeCommit("C1", ["P"]),
            makeCommit("C2", ["P"]),
            makeCommit("C3", ["Q"]),
            makeCommit("P", ["Q"]),
            makeCommit("Q", []),
        ]
        let branchGraph = CommitGraph(commits: branchCommits)
        let c3Shapes = try shapes(branchGraph, "C3")
        #expect(c3Shapes.contains(.passThrough(lane: 1)), "duplicate parent lane passes straight through")
        #expect(!c3Shapes.contains { if case .laneShift = $0 { return true }; return false },
                "no spurious lane shift at a branch point")
        let pShapes = try shapes(branchGraph, "P")
        #expect(pShapes.contains(.mergeIn(fromLane: 1)), "duplicate lane merges into the parent dot")
        #expect(pShapes.contains(.laneShift(fromLane: 2, toLane: 1)),
                "the lane right of the merged one closes the gap in the merge row")
        let qRow = try #require(branchGraph.rows["Q"])
        #expect(qRow.dotLane == 0, "Q's dot sits on the leftmost lane waiting for it")
        #expect(qRow.edges.map(\.shape).contains(.mergeIn(fromLane: 1)), "the shifted line merges in from the compacted lane")
    }

    // Parents outside the loaded window (log pagination cuts at the limit)
    // must not crash the layout.
    @Test func parentsOutsideWindow() {
        let windowedGraph = CommitGraph(commits: [makeCommit("A", ["MISSING"]), makeCommit("B", ["MISSING"])])
        #expect(windowedGraph.rows.count == 2, "graph handles parents outside the loaded window")
    }

    // Three lanes; the middle one merges first. The right lane must close
    // the gap in the merge row and the rows below use only two lanes.
    @Test func mergedMiddleLaneCompacts() throws {
        // T1 is a tip on the far right lane; the merge M joins A (lane 0) and
        // B (lane 1). Both A's and B's lines reach R, where lane 1 merges in.
        let commits = [
            makeCommit("M", ["A", "B"]),
            makeCommit("T1", ["X"]),
            makeCommit("B", ["R"]),
            makeCommit("A", ["A2"]),
            makeCommit("A2", ["R"]),
            makeCommit("R", ["X"]),
            makeCommit("X", []),
        ]
        let graph = CommitGraph(commits: commits)
        // Rows above A2: lanes [A2-line, R(from B), X(from T1)].
        let a2Row = try #require(graph.rows["A2"])
        #expect(a2Row.dotLane == 0)
        #expect(a2Row.laneCount == 3, "three lanes before compaction")
        // R: lane 0 (A2's parent) and lane 1 (B's parent) both wait for R; lane 1
        // merges in and lane 2 (X) shifts into lane 1 in the same row.
        let rShapes = try shapes(graph, "R")
        #expect(rShapes.contains(.mergeIn(fromLane: 1)))
        #expect(rShapes.contains(.laneShift(fromLane: 2, toLane: 1)), "right lane shifts left in the merge row")
        #expect(!rShapes.contains(.passThrough(lane: 2)), "no line stays in the vacated right lane")
        // X: both remaining lanes wait for X, now in lanes 0 and 1.
        let xRow = try #require(graph.rows["X"])
        #expect(xRow.laneCount == 2, "rows below the merge use the compacted lane count")
        #expect(xRow.edges.map(\.shape).contains(.mergeIn(fromLane: 1)))
    }

    // A gap left by a root commit (no parents) is closed the same way.
    @Test func rootCommitGapCompacts() throws {
        let commits = [
            makeCommit("A", ["A2"]),
            makeCommit("P", ["O"]),   // opens lane 1, waiting for O
            makeCommit("T", ["A2"]),  // lane 2, waits for A2
            makeCommit("O", []),      // root: lane 1 ends here
            makeCommit("A2", []),
        ]
        let graph = CommitGraph(commits: commits)
        let oShapes = try shapes(graph, "O")
        #expect(oShapes.contains(.laneShift(fromLane: 2, toLane: 1)), "lane right of the root commit shifts left")
        #expect(!oShapes.contains(.outOfDot), "root commit has no outgoing line")
        let a2Row = try #require(graph.rows["A2"])
        #expect(a2Row.edges.map(\.shape).contains(.mergeIn(fromLane: 1)), "the shifted line merges from the compacted lane")
    }

    // Colors belong to the branch line: a shifted line keeps its color, and
    // the dot takes the color of the line running through it.
    @Test func colorsFollowLines() throws {
        let commits = [
            makeCommit("A", ["A2"]),
            makeCommit("P", ["O"]),
            makeCommit("T", ["T2"]),
            makeCommit("O", []),
            makeCommit("A2", ["R"]),
            makeCommit("T2", ["R"]),
            makeCommit("R", []),
        ]
        let graph = CommitGraph(commits: commits)
        let tColor = try #require(graph.rows["T"]).dotColorIndex
        #expect(tColor == 2, "third branch tip takes the third palette color")
        let shift = try #require(graph.rows["O"]).edges.first { $0.shape == .laneShift(fromLane: 2, toLane: 1) }
        #expect(shift?.colorIndex == tColor, "shifted line keeps its branch color")
        let t2Row = try #require(graph.rows["T2"])
        #expect(t2Row.dotLane == 1)
        #expect(t2Row.dotColorIndex == tColor, "dot in the compacted lane keeps the branch color, not the lane color")
        let rMerge = try #require(graph.rows["R"]).edges.first { $0.shape == .mergeIn(fromLane: 1) }
        #expect(rMerge?.colorIndex == tColor, "merge curve keeps the merging branch's color")
    }

    // In the merge row, a freed lane is closed first and an extra parent that
    // needs a lane goes to the right edge with a fresh color.
    @Test func extraParentAllocatedAfterCompaction() throws {
        let commits = [
            makeCommit("A", ["M"]),
            makeCommit("B", ["M"]),
            makeCommit("T", ["X"]),
            makeCommit("M", ["X", "N"]),
            makeCommit("N", ["X"]),
            makeCommit("X", []),
        ]
        let graph = CommitGraph(commits: commits)
        // Row M: lanes [M, M, X]; lane 1 merges in, lane 2 (X) shifts to 1,
        // parent N opens lane 2.
        let mRow = try #require(graph.rows["M"])
        let mShapes = mRow.edges.map(\.shape)
        #expect(mShapes.contains(.mergeIn(fromLane: 1)))
        #expect(mShapes.contains(.laneShift(fromLane: 2, toLane: 1)))
        #expect(mShapes.contains(.branchOut(toLane: 2)), "extra parent goes to the right edge after compaction")
        let branch = try #require(mRow.edges.first { $0.shape == .branchOut(toLane: 2) })
        #expect(branch.colorIndex == 3, "the new branch gets the next palette color")
        #expect(try #require(graph.rows["N"]).dotLane == 2)
        #expect(try #require(graph.rows["N"]).dotColorIndex == 3)
    }
}
