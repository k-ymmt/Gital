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
    /// Tried when `newRevision` has no such path. Stashes made with
    /// `--include-untracked` keep untracked files in the stash's *third*
    /// parent, never in the stash commit itself.
    var newFallbackRevision: BlobRevision? = nil

    /// Revision pair matching the comparison each working-copy scope's diff
    /// came from. A staged rename's old side reads `HEAD:<oldPath>`; a
    /// conflicted path has no index stage 0, so its old side renders empty.
    /// nil for `.snapshot`, which the working-copy loaders never produce.
    static func workingRevisions(for scope: DiffScope) -> (old: BlobRevision?, new: BlobRevision)? {
        switch scope {
        case .unstaged: (old: .index, new: .worktree)
        case .staged: (old: .commit("HEAD"), new: .index)
        case .untracked: (old: nil, new: .worktree)
        case .snapshot: nil
        }
    }

    static func working(repository: GitRepository, scope: DiffScope) -> ImageDiffContext? {
        workingRevisions(for: scope).map {
            ImageDiffContext(repository: repository, oldRevision: $0.old, newRevision: $0.new)
        }
    }
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

    /// Refuse to buffer more than this per side; also the post-read cap for
    /// LFS smudges whose pointer passed the pre-read gate.
    static let maxPreviewBytes = 32 << 20

    enum SideState: Equatable {
        case loading
        /// No blob there at all — the added/deleted side of the change.
        case absent
        /// Bytes exist but can't be previewed truthfully (unresolved LFS
        /// pointer, too large, undecodable). Distinct from `absent` because
        /// showing "No image" for these would assert a file was added or
        /// deleted when it wasn't.
        case unavailable
        case loaded(NSImage, bytes: Int)
    }

    @State private var oldSide: SideState = .loading
    @State private var newSide: SideState = .loading

    /// Everything that decides what the panes show — `.task(id:)` reloads
    /// when the row is reused for another file or another comparison. The
    /// blob OIDs are the content fingerprint: revisions like `.index` or
    /// `.worktree` are mutable, so path + revision alone would keep showing
    /// stale bytes after the file changes again.
    private struct LoadKey: Hashable {
        let oldPath: String?
        let newPath: String
        let oldRevision: BlobRevision?
        let newRevision: BlobRevision
        let oldBlob: String?
        let newBlob: String?
    }

    private var loadKey: LoadKey {
        LoadKey(
            oldPath: diff.oldPath,
            newPath: diff.path,
            oldRevision: context.oldRevision,
            newRevision: context.newRevision,
            oldBlob: diff.oldBlobHash,
            newBlob: diff.newBlobHash
        )
    }

    var body: some View {
        content
            .task(id: loadKey) {
                oldSide = .loading
                newSide = .loading
                async let old = load(
                    path: diff.oldPath ?? diff.path,
                    revisions: context.oldRevision.map { [$0] } ?? []
                )
                async let new = load(
                    path: diff.path,
                    revisions: [context.newRevision] + (context.newFallbackRevision.map { [$0] } ?? [])
                )
                let (loadedOld, loadedNew) = await (old, new)
                guard !Task.isCancelled else { return }
                oldSide = loadedOld
                newSide = loadedNew
            }
    }

    @ViewBuilder
    private var content: some View {
        if oldSide == .unavailable || newSide == .unavailable
            || (oldSide == .absent && newSide == .absent) {
            // An unavailable side would make the pane pair lie ("No image"
            // next to a real image reads as an addition) — the whole file
            // falls back to the plain placeholder instead.
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
            case .loading, .unavailable:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 110)
            case .absent:
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

    /// Tries each revision in order; the first whose blob exists decides the
    /// side's state. A blob that exists but can't be shown truthfully is
    /// `.unavailable`, never skipped — falling through to a later revision
    /// would preview different bytes than the diff describes.
    private func load(path: String, revisions: [BlobRevision]) async -> SideState {
        for revision in revisions {
            guard let size = try? await context.repository.fileSize(path: path, at: revision) else {
                continue  // no blob at this revision — try the next source
            }
            guard size <= Self.maxPreviewBytes else { return .unavailable }
            guard let data = try? await context.repository.fileContents(path: path, at: revision),
                  !data.isEmpty else { return .absent }
            guard data.count <= Self.maxPreviewBytes, !Self.isLFSPointer(data),
                  let image = NSImage(data: data) else { return .unavailable }
            return .loaded(image, bytes: data.count)
        }
        return .absent
    }

    /// Git LFS pointer files start with this line; the real bytes live under
    /// `.git/lfs` or on the server. `cat-file --filters` smudges pointers
    /// when the object is local, so reaching one here means it isn't.
    static func isLFSPointer(_ data: Data) -> Bool {
        data.starts(with: Data("version https://git-lfs".utf8))
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
