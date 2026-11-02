import AppKit
import Testing
@testable import Gital

/// `InheritedScrollMomentumFilter` policy: a flick's momentum must not
/// scroll the page that was loaded mid-flick, while the next gesture the
/// user starts (or a legacy wheel) scrolls normally.
///
/// `#expect` captures its operands in a closure, where a `var` filter is
/// immutable, so each test feeds an event script through a helper and
/// compares the verdicts as a whole.
struct InheritedScrollMomentumTests {
    private enum Step {
        /// A wheel event; `phase` / `momentum` are the two NSEvent phases.
        case event(phase: NSEvent.Phase = [], momentum: NSEvent.Phase = [])
        /// A new page is about to load.
        case load
    }

    /// Runs the script; returns one Bool per `.event` step, in order.
    private func verdicts(_ steps: [Step]) -> [Bool] {
        var filter = InheritedScrollMomentumFilter()
        var out: [Bool] = []
        for step in steps {
            switch step {
            case .event(let phase, let momentum):
                out.append(filter.allows(phase: phase, momentumPhase: momentum))
            case .load:
                filter.pageWillLoad()
            }
        }
        return out
    }

    @Test func passesEverythingThroughBeforeAnyLoad() {
        let result = verdicts([
            .event(phase: .began), .event(phase: .changed), .event(phase: .ended),
            .event(momentum: .began), .event(momentum: .changed), .event(momentum: .ended),
        ])
        #expect(result == [true, true, true, true, true, true])
    }

    @Test func dropsMomentumInheritedFromThePreviousPage() {
        let result = verdicts([
            // Flick on the old page: gesture, then momentum starts…
            .event(phase: .began), .event(phase: .changed), .event(phase: .ended),
            .event(momentum: .began), .event(momentum: .changed),
            // …the user picks another file mid-momentum.
            .load,
            .event(momentum: .changed), .event(momentum: .changed), .event(momentum: .ended),
        ])
        #expect(result == [true, true, true, true, true, false, false, false])
    }

    @Test func dropsAnUnfinishedFingerGestureInheritedFromThePreviousPage() {
        let result = verdicts([
            .event(phase: .began),
            .load,
            .event(phase: .changed), .event(phase: .ended),
            .event(momentum: .began), .event(momentum: .changed), .event(momentum: .ended),
        ])
        #expect(result == [true, false, false, false, false, false])
    }

    @Test func aNewGestureOnTheNewPageScrollsNormally() {
        let result = verdicts([
            .load,
            .event(momentum: .changed),
            // mayBegin precedes began on a trackpad; either disarms the filter.
            .event(phase: .mayBegin), .event(phase: .began), .event(phase: .changed), .event(phase: .ended),
            .event(momentum: .began), .event(momentum: .changed), .event(momentum: .ended),
        ])
        #expect(result == [false, true, true, true, true, true, true, true])
    }

    @Test func legacyMouseWheelIsNeverDropped() {
        let result = verdicts([
            .load,
            .event(),
            // A legacy wheel also disarms it: stray momentum after it is not
            // plausible, and the user clearly wants to scroll this page.
            .event(momentum: .changed),
        ])
        #expect(result == [true, true])
    }

    @Test func eachLoadReArmsTheFilter() {
        let result = verdicts([
            .load,
            .event(phase: .began), .event(momentum: .began),
            .load,
            .event(momentum: .changed),
        ])
        #expect(result == [true, true, false])
    }
}
