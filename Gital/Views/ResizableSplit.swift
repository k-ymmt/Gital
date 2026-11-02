import SwiftUI

/// Two panes separated by a draggable divider, laid out in plain SwiftUI.
///
/// Not `HSplitView`/`VSplitView`: those are NSSplitView-backed, and inside
/// the NavigationSplitView detail column the bridge extends the split view
/// under the full-height sidebar and re-applies the sidebar's safe-area
/// inset inside each pane's hosting view — in the pane's min/max
/// constraints too. An HSplitView whose first pane has a minimum width then
/// reports "minimum + sidebar width" as its own minimum, outgrows the
/// column, and with a wide sidebar either squeezes the sidebar narrower or
/// pushes the whole split view past the window edge (issue #4). Keeping
/// the geometry in SwiftUI makes the column's proposal final.
///
/// The first pane keeps the length the user dragged it to; the second pane
/// absorbs window resizes (NSSplitView's default holding behaviour), giving
/// way only when the first pane would otherwise drop below its minimum.
struct ResizableSplit<First: View, Second: View>: View {
    typealias Pane = ResizableSplitLayout.Pane

    let axis: Axis
    let firstPane: Pane
    let secondPane: Pane
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second

    /// First-pane length from the last divider drag; nil until the user
    /// drags, so the panes open at their ideal sizes.
    @State private var requestedFirst: CGFloat?
    @State private var dragStartFirst: CGFloat?

    private static var dividerThickness: CGFloat { 1 }
    private static var dividerHitThickness: CGFloat { 9 }

    var body: some View {
        GeometryReader { geometry in
            let total = axis == .horizontal ? geometry.size.width : geometry.size.height
            let layout = ResizableSplitLayout(
                total: total,
                divider: Self.dividerThickness,
                first: firstPane,
                second: secondPane
            )
            let firstLength = layout.firstLength(requested: requestedFirst)
            let secondLength = layout.secondLength(firstLength: firstLength)

            stack {
                pane(first(), length: firstLength)
                divider(layout: layout, firstLength: firstLength)
                pane(second(), length: secondLength)
            }
        }
    }

    @ViewBuilder
    private func stack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        switch axis {
        case .horizontal: HStack(spacing: 0, content: content)
        case .vertical: VStack(spacing: 0, content: content)
        }
    }

    private func pane(_ content: some View, length: CGFloat) -> some View {
        content
            .frame(
                width: axis == .horizontal ? length : nil,
                height: axis == .vertical ? length : nil
            )
            .clipped()
    }

    private func divider(layout: ResizableSplitLayout, firstLength: CGFloat) -> some View {
        // Global coordinates: the divider itself moves with every change,
        // so a translation measured in its own space would shrink by the
        // distance already travelled and the drag would track at half speed.
        let drag = DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartFirst ?? firstLength
                dragStartFirst = start
                let delta = axis == .horizontal ? value.translation.width : value.translation.height
                requestedFirst = layout.clampedFirst(start + delta)
            }
            .onEnded { _ in
                dragStartFirst = nil
            }

        return Rectangle()
            .fill(.separator)
            .frame(
                width: axis == .horizontal ? Self.dividerThickness : nil,
                height: axis == .vertical ? Self.dividerThickness : nil
            )
            // The grab area is wider than the drawn line and overlaps the
            // panes on both sides; zIndex keeps it above their content.
            .overlay {
                Color.clear
                    .frame(
                        width: axis == .horizontal ? Self.dividerHitThickness : nil,
                        height: axis == .vertical ? Self.dividerHitThickness : nil
                    )
                    .contentShape(Rectangle())
                    .pointerStyle(axis == .horizontal ? .columnResize(directions: .all) : .rowResize(directions: .all))
                    .gesture(drag)
            }
            .zIndex(1)
    }
}

/// Pure sizing rules behind `ResizableSplit`, kept separate so they can be
/// unit-tested without a view hierarchy.
struct ResizableSplitLayout: Equatable {
    struct Pane: Equatable {
        var min: CGFloat = 0
        var ideal: CGFloat? = nil
        var max: CGFloat? = nil
    }

    let total: CGFloat
    let divider: CGFloat
    let first: Pane
    let second: Pane

    /// Length left for the two panes once the divider has its share.
    var available: CGFloat { Swift.max(total - divider, 0) }

    /// First-pane length for this layout: the drag target when there is one,
    /// otherwise the opening size, both clamped to the panes' limits.
    func firstLength(requested: CGFloat?) -> CGFloat {
        clampedFirst(requested ?? initialFirst)
    }

    func secondLength(firstLength: CGFloat) -> CGFloat {
        Swift.max(available - firstLength, 0)
    }

    /// Opening size: the first pane's ideal, else whatever leaves the second
    /// pane its ideal, else an even split.
    private var initialFirst: CGFloat {
        if let ideal = first.ideal { return ideal }
        if let ideal = second.ideal { return available - ideal }
        return available / 2
    }

    /// Clamps a first-pane length to its own min/max and to what leaves the
    /// second pane its minimum. When both minimums cannot fit, the first
    /// pane keeps its minimum and the second pane takes what is left.
    func clampedFirst(_ desired: CGFloat) -> CGFloat {
        var length = desired
        if let max = first.max { length = Swift.min(length, max) }
        if available - length < second.min { length = available - second.min }
        return Swift.max(length, first.min)
    }
}
