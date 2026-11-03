import Foundation
import Testing
@testable import Gital

/// `FileDiff` line lookups shared by the working-copy and PR diff panes:
/// ID → line resolution and the framed-range "changed lines" set the
/// stage/discard capsules act on.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FileDiffLineLookupTests {
    // One hunk: context, deletion, two additions, context.
    private static let diff = DiffParser.parse("""
diff --git a/f.txt b/f.txt
index 1111111..2222222 100644
--- a/f.txt
+++ b/f.txt
@@ -1,3 +1,4 @@
 keep1
-old
+new1
+new2
 keep2
""")[0]

    private var lines: [DiffLine] { Self.diff.hunks.flatMap(\.lines) }

    @Test func changedLinesSkipContext() {
        #expect(Self.diff.changedLines.map(\.text) == ["old", "new1", "new2"])
    }

    @Test func lineLookupByID() {
        let target = lines[2]
        #expect(Self.diff.line(withID: target.id) == target)
        #expect(Self.diff.line(withID: "other.txt@0") == nil)
    }

    @Test func changedLineIDsSpanIncludesBoundsAndSkipsContext() {
        let ids = Self.diff.changedLineIDs(from: lines[0].id, to: lines[4].id)
        #expect(ids == Set(lines[1...3].map(\.id)))
    }

    @Test func changedLineIDsIsOrderIndependent() {
        let forward = Self.diff.changedLineIDs(from: lines[1].id, to: lines[2].id)
        let backward = Self.diff.changedLineIDs(from: lines[2].id, to: lines[1].id)
        #expect(forward == backward)
        #expect(forward == [lines[1].id, lines[2].id])
    }

    @Test func changedLineIDsWithUnknownBoundIsEmpty() {
        #expect(Self.diff.changedLineIDs(from: lines[1].id, to: "f.txt@999").isEmpty)
    }

    @Test func shortHashIsSevenCharacters() {
        #expect("0123456789abcdef".gitShortHash == "0123456")
        #expect("abc".gitShortHash == "abc")
    }
}
