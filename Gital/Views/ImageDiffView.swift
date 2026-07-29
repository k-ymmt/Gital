import AppKit
import SwiftUI

/// Where the two sides of a binary file's bytes can be loaded from. Built by
/// each screen (working copy, commit, stash, file history) because only the
/// screen knows which comparison its diffs came from.
struct ImageDiffContext {
    let repository: GitRepository
    /// nil when the change has no old side at all (an untracked file).
    let oldRevision: BlobRevision?
    let newRevision: BlobRevision
}

/// Content for a binary file in a diff list: image files get side-by-side
/// previews, everything else keeps the "not shown" placeholder. Callers with
/// no way to load blobs (PR diffs against unfetched commits) pass nil.
struct BinaryFileContentView: View {
    let diff: FileDiff
    let imageContext: ImageDiffContext?

    var body: some View {
        if let imageContext, diff.isImage {
            ImageDiffView(diff: diff, context: imageContext)
        } else {
            BinaryPlaceholderText()
        }
    }
}

struct BinaryPlaceholderText: View {
    var body: some View {
        Text("Binary file not shown")
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(40)
    }
}

/// Old/new preview panes for an image change.
struct ImageDiffView: View {
    let diff: FileDiff
    let context: ImageDiffContext

    enum SideState: Equatable {
        case loading
        case empty
        case loaded(NSImage, bytes: Int)
    }

    @State private var oldSide: SideState = .loading
    @State private var newSide: SideState = .loading

    /// Everything that decides what the panes show — `.task(id:)` reloads
    /// when the row is reused for another file or another comparison.
    private struct LoadKey: Hashable {
        let oldPath: String?
        let newPath: String
        let oldRevision: BlobRevision?
        let newRevision: BlobRevision
    }

    private var loadKey: LoadKey {
        LoadKey(
            oldPath: diff.oldPath,
            newPath: diff.path,
            oldRevision: context.oldRevision,
            newRevision: context.newRevision
        )
    }

    var body: some View {
        content
            .task(id: loadKey) {
                oldSide = .loading
                newSide = .loading
                async let old = load(path: diff.oldPath ?? diff.path, revision: context.oldRevision)
                async let new = load(path: diff.path, revision: context.newRevision)
                let (loadedOld, loadedNew) = await (old, new)
                guard !Task.isCancelled else { return }
                oldSide = loadedOld
                newSide = loadedNew
            }
    }

    @ViewBuilder
    private var content: some View {
        if oldSide == .empty, newSide == .empty {
            // Neither side decoded (corrupt data, non-image bytes behind an
            // image extension) — fall back to the plain placeholder.
            BinaryPlaceholderText()
        } else {
            HStack(alignment: .top, spacing: 0) {
                pane(title: "Old", state: oldSide, tint: DesignStyle.deletion)
                Divider()
                pane(title: "New", state: newSide, tint: DesignStyle.addition)
            }
            .padding(.vertical, 14)
        }
    }

    private func pane(title: String, state: SideState, tint: Color) -> some View {
        VStack(spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            switch state {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 110)
            case .empty:
                Text("No image")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110)
            case .loaded(let image, let bytes):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    // Cap at natural size so small assets (icons) don't blur
                    // up to the pane width.
                    .frame(
                        maxWidth: max(image.size.width, 1),
                        maxHeight: min(max(image.size.height, 1), 380)
                    )
                    .background(CheckerboardBackground())
                    .overlay {
                        Rectangle()
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    }
                Text(Self.caption(for: image, bytes: bytes))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private func load(path: String, revision: BlobRevision?) async -> SideState {
        guard let revision else { return .empty }
        guard let data = try? await context.repository.fileContents(path: path, at: revision),
              !data.isEmpty, let image = NSImage(data: data) else { return .empty }
        return .loaded(image, bytes: data.count)
    }

    /// "640 × 480 px — 34 KB"; pixel part omitted when no bitmap rep reports
    /// real pixel dimensions.
    static func caption(for image: NSImage, bytes: Int) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        guard let rep = image.representations.max(by: { $0.pixelsWide < $1.pixelsWide }),
              rep.pixelsWide > 0 else { return size }
        return "\(rep.pixelsWide) × \(rep.pixelsHigh) px — \(size)"
    }
}

/// Alternating squares behind an image so transparent regions read as
/// transparent instead of blending into the pane.
private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let square: CGFloat = 8
            var darkRow = false
            var y: CGFloat = 0
            while y < size.height {
                var dark = darkRow
                var x: CGFloat = 0
                while x < size.width {
                    if dark {
                        context.fill(
                            Path(CGRect(x: x, y: y, width: square, height: square)),
                            with: .color(.primary.opacity(0.09))
                        )
                    }
                    dark.toggle()
                    x += square
                }
                darkRow.toggle()
                y += square
            }
        }
        .background(Color.primary.opacity(0.035))
    }
}
