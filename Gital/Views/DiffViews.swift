import SwiftUI

private let diffFont = Font.system(size: 12, design: .monospaced)
private let lineNumberColor = Color.secondary.opacity(0.55)

// MARK: - Unified

struct UnifiedDiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 10)
                .foregroundStyle(lineNumberColor)
            Text(line.newNumber.map(String.init) ?? "")
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 10)
                .foregroundStyle(lineNumberColor)
            Text(line.sign)
                .frame(width: 14)
                .foregroundStyle(signColor)
            Text(line.text.isEmpty ? " " : line.text)
                .lineLimit(1)
                .padding(.trailing, 16)
            Spacer(minLength: 0)
        }
        .font(diffFont)
        .frame(height: 19)
        .background(background)
    }

    private var signColor: Color {
        switch line.kind {
        case .addition: DesignStyle.addition
        case .deletion: DesignStyle.deletion
        case .context: .clear
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: DesignStyle.additionBackground
        case .deletion: DesignStyle.deletionBackground
        case .context: .clear
        }
    }
}

struct HunkHeaderView: View {
    let text: String

    var body: some View {
        HStack {
            Text(text)
                .font(diffFont)
                .foregroundStyle(DesignStyle.hunkText)
                .padding(.leading, 12)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(height: 19)
        .background(DesignStyle.hunkBackground)
    }
}

// MARK: - Split

struct SplitDiffRowView: View {
    let row: SplitDiffRow

    var body: some View {
        if row.isHunkHeader {
            HunkHeaderView(text: row.hunkText)
        } else {
            HStack(spacing: 0) {
                sideView(row.left)
                Divider()
                sideView(row.right)
            }
            .frame(height: 19)
        }
    }

    private func sideView(_ side: SplitDiffRow.Side) -> some View {
        HStack(spacing: 0) {
            Text(side.number.map(String.init) ?? "")
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 9)
                .foregroundStyle(lineNumberColor)
            Text(side.text ?? " ")
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(diffFont)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sideBackground(side))
    }

    private func sideBackground(_ side: SplitDiffRow.Side) -> Color {
        switch side.kind {
        case .addition: DesignStyle.additionBackground
        case .deletion: DesignStyle.deletionBackground
        default: .clear
        }
    }
}

// MARK: - Whole-file diff (read-only, used by History / Stash / plain views)

struct FileDiffContentView: View {
    let diff: FileDiff
    let mode: DiffMode

    var body: some View {
        if diff.isBinary {
            Text("Binary file not shown")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(40)
        } else if diff.hunks.isEmpty {
            Text("No textual changes")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(40)
        } else {
            switch mode {
            case .unified:
                LazyVStack(spacing: 0) {
                    ForEach(diff.hunks) { hunk in
                        HunkHeaderView(text: hunk.header)
                        ForEach(hunk.lines) { line in
                            UnifiedDiffLineView(line: line)
                        }
                    }
                }
            case .split:
                LazyVStack(spacing: 0) {
                    ForEach(SplitDiffRow.rows(for: diff.hunks)) { row in
                        SplitDiffRowView(row: row)
                    }
                }
            }
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
