import SwiftUI

// MARK: - Binary / empty diff placeholder (read-only panes)

/// Every text diff renders on the WKWebView path; this view covers the two
/// cases that path can't serve — a binary file (image preview or "Binary
/// file not shown") and a diff with no textual hunks. It once carried a
/// SwiftUI `Text`-per-line renderer too, but no reachable call site fed it
/// a text diff, and a second renderer only drifts from the real one.
struct FileDiffContentView: View {
    let diff: FileDiff
    /// Blob sources for image previews of binary files; nil keeps the plain
    /// "Binary file not shown" placeholder.
    var imageContext: ImageDiffContext? = nil

    var body: some View {
        if diff.isBinary {
            BinaryFileContentView(diff: diff, imageContext: imageContext)
        } else {
            Text("No textual changes")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(40)
        }
    }
}

/// The renderer split shared by the read-only single-file diff panes
/// (History, File History): binary and empty diffs render on the SwiftUI
/// path (image preview, "no changes" note) inside a two-axis ScrollView;
/// text diffs go to the self-scrolling WKWebView renderer (proper
/// multi-line selection, clean copies, native scrolling). One home for the
/// predicate, so a change to it can't miss a pane.
struct SingleFileDiffContent: View {
    let diff: FileDiff
    let mode: DiffMode
    var imageContext: ImageDiffContext? = nil

    var body: some View {
        if diff.isBinary || diff.hunks.isEmpty {
            ScrollView([.vertical, .horizontal]) {
                FileDiffContentView(diff: diff, imageContext: imageContext)
                    .frame(minWidth: 600, alignment: .leading)
            }
        } else {
            WebDiffView(diff: diff, mode: mode)
        }
    }
}

struct DiffModePicker: View {
    @Binding var mode: DiffMode

    var body: some View {
        Picker("Diff Mode", selection: $mode) {
            ForEach(DiffMode.allCases) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: 130)
    }
}

struct DiffStatsLabel: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("+\(additions)")
                .foregroundStyle(DesignStyle.addition)
            Text("−\(deletions)")
                .foregroundStyle(DesignStyle.deletion)
        }
        .font(.system(size: 11))
    }
}

/// Pinned section header for one file in a diff list: name, directory, and
/// stats, with optional actions between them.
struct FileSectionHeader<Trailing: View>: View {
    let diff: FileDiff
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(diff.fileName)
                .font(.system(size: 12, design: .monospaced))
            Text(diff.directory)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            trailing
            DiffStatsLabel(additions: diff.additions, deletions: diff.deletions)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension FileSectionHeader where Trailing == EmptyView {
    init(diff: FileDiff) {
        self.init(diff: diff) { EmptyView() }
    }
}
