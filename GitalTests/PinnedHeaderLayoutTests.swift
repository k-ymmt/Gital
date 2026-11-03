import Foundation
import Testing
@testable import Gital

/// `PinnedHeaderLayout` — which file header the working-copy diff pane pins
/// to its top edge, and how far the next header pushes it out.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PinnedHeaderLayoutTests {
    private func current(_ tops: [CGFloat?], y: CGFloat) -> Int? {
        PinnedHeaderLayout.currentIndex(count: tops.count, scrollY: y) { tops[$0] }
    }

    private func pushOut(_ tops: [CGFloat?], after index: Int, y: CGFloat, height: CGFloat = 30) -> CGFloat {
        PinnedHeaderLayout.pushOut(after: index, count: tops.count, scrollY: y, headerHeight: height) { tops[$0] }
    }

    @Test func pinsTheLastHeaderAtOrAboveTheScrollPosition() {
        let tops: [CGFloat?] = [0, 200, 500]
        #expect(current(tops, y: 10) == 0)
        #expect(current(tops, y: 200) == 1)
        #expect(current(tops, y: 499) == 1)
        #expect(current(tops, y: 900) == 2)
    }

    @Test func nothingPinnedAboveTheFirstHeader() {
        #expect(current([50, 200], y: 10) == nil)
        #expect(current([], y: 10) == nil)
    }

    @Test func unmeasuredHeadersAreSkipped() {
        #expect(current([0, nil, 500], y: 300) == 0)
        #expect(current([nil, 100], y: 300) == 1)
    }

    @Test func nextHeaderPushesThePinnedOneOut() {
        let tops: [CGFloat?] = [0, 200]
        #expect(pushOut(tops, after: 0, y: 100) == 0, "next header still below the pinned one")
        #expect(pushOut(tops, after: 0, y: 180) == -10)
    }

    @Test func pushOutUsesTheNextMeasuredHeader() {
        #expect(pushOut([0, nil, 200], after: 0, y: 180) == -10)
    }

    @Test func lastHeaderIsNeverPushed() {
        #expect(pushOut([0, 200], after: 1, y: 5000) == 0)
        #expect(pushOut([0, nil], after: 0, y: 5000) == 0)
    }
}
