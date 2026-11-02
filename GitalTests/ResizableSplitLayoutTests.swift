import Foundation
import Testing
@testable import Gital

/// `ResizableSplitLayout` — the sizing rules behind the pure-SwiftUI split
/// that replaced HSplitView/VSplitView in the History pane.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ResizableSplitLayoutTests {
    private func layout(
        total: CGFloat,
        first: ResizableSplitLayout.Pane,
        second: ResizableSplitLayout.Pane
    ) -> ResizableSplitLayout {
        ResizableSplitLayout(total: total, divider: 1, first: first, second: second)
    }

    @Test func dividerIsTakenOutOfTheAvailableLength() {
        let layout = layout(total: 721, first: .init(min: 220, ideal: 300), second: .init(min: 320))
        #expect(layout.available == 720)
        #expect(layout.firstLength(requested: nil) == 300)
        #expect(layout.secondLength(firstLength: 300) == 420)
    }

    @Test func opensAtTheFirstPanesIdeal() {
        let layout = layout(total: 721, first: .init(min: 220, ideal: 300, max: 420), second: .init(min: 320))
        #expect(layout.firstLength(requested: nil) == 300)
    }

    @Test func opensLeavingTheSecondPaneItsIdeal() {
        // History's list/detail split: only the detail declares an ideal.
        let layout = layout(total: 749, first: .init(min: 220), second: .init(min: 240, ideal: 360))
        #expect(layout.firstLength(requested: nil) == 388)
        #expect(layout.secondLength(firstLength: 388) == 360)
    }

    @Test func opensEvenlyWithoutIdeals() {
        let layout = layout(total: 601, first: .init(min: 100), second: .init(min: 100))
        #expect(layout.firstLength(requested: nil) == 300)
    }

    @Test func dragIsClampedToTheFirstPanesMaximum() {
        let layout = layout(total: 1001, first: .init(min: 220, ideal: 300, max: 420), second: .init(min: 320))
        #expect(layout.firstLength(requested: 900) == 420)
    }

    @Test func dragIsClampedToTheFirstPanesMinimum() {
        let layout = layout(total: 1001, first: .init(min: 220, ideal: 300, max: 420), second: .init(min: 320))
        #expect(layout.firstLength(requested: 10) == 220)
    }

    @Test func secondPaneKeepsItsMinimumWhenTheWindowShrinks() {
        // The user dragged the first pane to 400; the window then shrinks so
        // only 600 is available — the second pane holds 320 and the first
        // pane gives way.
        let layout = layout(total: 601, first: .init(min: 220, ideal: 300, max: 420), second: .init(min: 320))
        #expect(layout.firstLength(requested: 400) == 280)
        #expect(layout.secondLength(firstLength: 280) == 320)
    }

    @Test func dragTargetIsRestoredWhenTheWindowGrowsBack() {
        let first = ResizableSplitLayout.Pane(min: 220, ideal: 300, max: 420)
        let second = ResizableSplitLayout.Pane(min: 320)
        #expect(layout(total: 601, first: first, second: second).firstLength(requested: 400) == 280)
        #expect(layout(total: 1001, first: first, second: second).firstLength(requested: 400) == 400)
    }

    @Test func firstPaneKeepsItsMinimumWhenBothCannotFit() {
        let layout = layout(total: 401, first: .init(min: 220), second: .init(min: 320))
        #expect(layout.firstLength(requested: nil) == 220)
        #expect(layout.secondLength(firstLength: 220) == 180)
    }

    @Test func zeroTotalProducesZeroPanes() {
        // GeometryReader's first pass hands out a zero size.
        let layout = layout(total: 0, first: .init(min: 220, ideal: 300), second: .init(min: 320))
        #expect(layout.available == 0)
        #expect(layout.firstLength(requested: nil) == 220)
        #expect(layout.secondLength(firstLength: 220) == 0)
    }
}
