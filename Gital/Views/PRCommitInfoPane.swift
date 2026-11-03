import SwiftUI

/// Lower pane with just the commit's details, History-style: avatar,
/// author line, hash, and the FULL commit message (subject and body) —
/// the one-line toolbar title can't show either. Sourced from local git,
/// since gh's PR detail only carries each commit's headline.
///
/// Collapse state and height are bindings into the owning diff view so
/// they survive this pane leaving the hierarchy between commits; only the
/// transient drag/cursor state lives here.
struct PRCommitInfoPane: View {
    let commit: CommitDetail
    let avatarURL: URL?
    let maxBodyHeight: CGFloat
    @Binding var isCollapsed: Bool
    @Binding var height: CGFloat

    /// Height when the current resize drag started; nil outside a drag.
    @State private var dragBase: CGFloat?
    /// Whether the resize cursor is currently pushed — onHover alone can't
    /// guarantee the pop when the handle leaves the hierarchy mid-hover.
    @State private var resizeCursorPushed = false

    var body: some View {
        VStack(spacing: 0) {
            resizeHandle(cap: maxBodyHeight)
            header
            // Collapsing squeezes the message area to zero height instead of
            // removing it, which is what makes the toggle animatable. The
            // divider lives inside so it disappears along with the area.
            VStack(spacing: 0) {
                Divider()
                ScrollView {
                    Text(commit.message)
                        .font(.system(size: 12.5))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .frame(height: isCollapsed ? 0 : min(height, maxBodyHeight))
            .clipped()
        }
    }

    /// The pane's top divider, doubling as its resize handle — a slim drag
    /// band replacing the VSplitView divider. Inert while collapsed, so the
    /// hidden message area can't be dragged open.
    private func resizeHandle(cap: CGFloat) -> some View {
        ZStack {
            Divider()
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    // Global space: the handle itself moves with every height
                    // change, so a local-space translation would be measured
                    // against a moving origin and lag the cursor.
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            let base = dragBase ?? min(height, cap)
                            dragBase = base
                            height = min(max(base - value.translation.height, 60), cap)
                        }
                        .onEnded { _ in dragBase = nil }
                )
                .onHover { setResizeCursor($0) }
        }
        .frame(height: 7)
        .allowsHitTesting(!isCollapsed)
        // onHover's exit callback isn't delivered when the handle leaves the
        // hierarchy (or stops hit-testing) mid-hover, which would leave the
        // resize cursor pushed over the whole app.
        .onDisappear {
            setResizeCursor(false)
            dragBase = nil
        }
        .onChange(of: isCollapsed) { _, collapsed in
            if collapsed { setResizeCursor(false) }
        }
    }

    /// Push/pop tracked through one flag so the two can never run unpaired.
    private func setResizeCursor(_ pushed: Bool) {
        guard pushed != resizeCursorPushed else { return }
        resizeCursorPushed = pushed
        if pushed {
            NSCursor.resizeUpDown.push()
        } else {
            NSCursor.pop()
        }
    }

    /// The pane's header row — avatar, author line, hash, and the collapse
    /// toggle. This is what remains on screen while the pane is collapsed.
    private var header: some View {
        HStack(spacing: 11) {
            AvatarView(name: commit.author, url: avatarURL)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(commit.author) <\(commit.authorEmail)>")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(commit.authorDate)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(commit.hash)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button {
                withAnimation(.easeInOut(duration: 0.22)) {
                    isCollapsed.toggle()
                }
            } label: {
                // The Xcode/Fork bottom-panel toggle: one fixed glyph whose
                // tint carries the state, not a direction-flipping chevron.
                Image(systemName: "inset.filled.bottomthird.square")
                    .font(.system(size: 13))
                    .foregroundStyle(isCollapsed ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand commit details" : "Collapse commit details")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.25))
    }
}
