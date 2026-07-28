import Foundation
import Testing
@testable import Gital

@MainActor
struct CommitGraphTests {
    private func makeCommit(_ hash: String, _ parents: [String]) -> Commit {
        Commit(hash: hash, parents: parents, author: "A", authorEmail: "a@a", relativeDate: "now", subject: hash, body: "", refs: [])
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
        #expect(try #require(graph.rows["C"]).edges.contains { if case .branchOut = $0.shape { return true }; return false },
                "merge commit branches out")
        #expect(try #require(graph.rows["E"]).dotLane == 1, "second parent occupies lane 1")
        #expect(graph.maxLanes >= 2, "graph tracks max lanes")
        let mergeBack = try #require(graph.rows["F"]).edges.contains { if case .mergeIn = $0.shape { return true }; return false }
        #expect(mergeBack, "lanes merge back into common parent")
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
        let c3Edges = try #require(branchGraph.rows["C3"]).edges
        #expect(c3Edges.contains { $0.shape == .passThrough(lane: 1) }, "duplicate parent lane passes straight through")
        #expect(!c3Edges.contains { if case .laneShift = $0.shape { return true }; return false },
                "no spurious lane shift at a branch point")
        let pEdges = try #require(branchGraph.rows["P"]).edges
        #expect(pEdges.contains { $0.shape == .passThrough(lane: 2) }, "unrelated lane passes through the branch parent row")
        #expect(pEdges.contains { $0.shape == .mergeIn(fromLane: 1) }, "duplicate lane merges into the parent dot")
    }

    // Parents outside the loaded window (log pagination cuts at the limit)
    // must not crash the layout.
    @Test func parentsOutsideWindow() {
        let windowedGraph = CommitGraph(commits: [makeCommit("A", ["MISSING"]), makeCommit("B", ["MISSING"])])
        #expect(windowedGraph.rows.count == 2, "graph handles parents outside the loaded window")
    }
}
