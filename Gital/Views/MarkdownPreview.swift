import SwiftUI

/// One rendered block of a Markdown document. `MarkdownBlockParser` flattens
/// nesting into per-block context (quote depth, list depth) so the view layer
/// stays a simple switch instead of a recursive tree walk.
struct MarkdownBlock: Identifiable {
    enum ListMarker: Equatable {
        case bullet
        case ordered(Int)
        case task(done: Bool)
        /// Follow-up paragraph inside an already-marked list item.
        case continuation
    }

    enum Kind {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        case codeBlock(String)
        case listItem(depth: Int, marker: ListMarker, text: AttributedString)
        case table(header: [AttributedString], rows: [[AttributedString]])
        case thematicBreak
    }

    let id: Int
    /// How many block quotes enclose this block (0 = top level).
    let quoteDepth: Int
    /// Extra list-content indentation for non-`listItem` blocks (headings,
    /// code blocks, tables) that live inside a list item.
    var listIndent: Int = 0
    let kind: Kind
}

enum MarkdownBlockParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let normalized = insertingHardBreaks(markdown.replacingOccurrences(of: "\r\n", with: "\n"))
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let source = try? AttributedString(markdown: normalized, options: options) else {
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [MarkdownBlock(id: 0, quoteDepth: 0, kind: .paragraph(AttributedString(trimmed)))]
        }

        var blocks: [MarkdownBlock] = []
        var table: TableBuilder?
        var seenListItems: Set<Int> = []

        func flushTable() {
            if let finished = table {
                blocks.append(MarkdownBlock(
                    id: blocks.count,
                    quoteDepth: finished.quoteDepth,
                    listIndent: finished.listIndent,
                    kind: finished.build()
                ))
                table = nil
            }
        }

        // A non-paragraph block occupying a list item still consumes the
        // item's marker slot, so its follow-up paragraphs render as
        // continuations instead of sprouting a second marker.
        func consumeListItem(_ context: BlockContext) -> Int {
            guard let item = context.listItem else { return 0 }
            seenListItems.insert(item.identity)
            return item.depth + 1
        }

        for group in leafGroups(of: source) {
            let context = BlockContext(intent: group.intent)

            if let cell = context.tableCell {
                if table?.identity != cell.tableIdentity {
                    flushTable()
                    table = TableBuilder(
                        identity: cell.tableIdentity,
                        columns: cell.columns,
                        quoteDepth: context.quoteDepth,
                        listIndent: consumeListItem(context)
                    )
                }
                table?.add(cell: styledInline(group.text), column: cell.column, row: cell.row)
                continue
            }
            flushTable()

            let kind: MarkdownBlock.Kind
            var listIndent = 0
            if context.isThematicBreak {
                kind = .thematicBreak
            } else if context.isCodeBlock {
                var code = String(group.text.characters)
                while code.hasSuffix("\n") { code.removeLast() }
                kind = .codeBlock(code)
                listIndent = consumeListItem(context)
            } else if let level = context.headerLevel {
                kind = .heading(level: min(max(level, 1), 6), text: styledInline(group.text))
                listIndent = consumeListItem(context)
            } else if let item = context.listItem {
                var marker: MarkdownBlock.ListMarker = item.ordered ? .ordered(item.ordinal) : .bullet
                var text = styledInline(group.text)
                if seenListItems.contains(item.identity) {
                    marker = .continuation
                } else {
                    seenListItems.insert(item.identity)
                    if !item.ordered, let task = extractTaskMarker(from: &text) {
                        marker = task
                    }
                }
                kind = .listItem(depth: item.depth, marker: marker, text: text)
            } else {
                let text = styledInline(group.text)
                if text.characters.isEmpty { continue }
                kind = .paragraph(text)
            }
            blocks.append(MarkdownBlock(id: blocks.count, quoteDepth: context.quoteDepth, listIndent: listIndent, kind: kind))
        }
        flushTable()
        return blocks
    }

    /// GitHub renders a single newline inside a comment paragraph as a hard
    /// line break, while CommonMark treats it as a space. Append the two-space
    /// hard-break suffix to interior lines so the preview matches github.com,
    /// leaving fenced/indented code untouched. Fence tracking follows
    /// CommonMark: block-quote markers are stripped first (so `> ```` ``` ````
    /// opens a fence too), a fence only closes on the same character with at
    /// least the opening run's length, and a backtick fence whose info string
    /// contains a backtick is not a fence at all.
    static func insertingHardBreaks(_ markdown: String) -> String {
        var openFence: (char: Character, length: Int)?
        let lines = markdown.components(separatedBy: "\n")
        let processed = lines.enumerated().map { index, line -> String in
            let content = strippingQuoteMarkers(line)
            if let fence = openFence {
                if closesFence(content, opening: fence) { openFence = nil }
                return line
            }
            let isIndentedCode = content.hasPrefix("    ") || content.hasPrefix("\t")
            if !isIndentedCode, let fence = openingFence(content) {
                openFence = fence
                return line
            }
            guard !isIndentedCode,
                  !content.trimmingCharacters(in: .whitespaces).isEmpty,
                  !line.hasSuffix("  "), !line.hasSuffix("\\"),
                  index + 1 < lines.count,
                  !strippingQuoteMarkers(lines[index + 1]).trimmingCharacters(in: .whitespaces).isEmpty
            else { return line }
            return line + "  "
        }
        return processed.joined(separator: "\n")
    }

    private static func strippingQuoteMarkers(_ line: String) -> String {
        var rest = Substring(line)
        while true {
            let afterSpaces = rest.drop(while: { $0 == " " })
            guard afterSpaces.first == ">" else { break }
            rest = afterSpaces.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
        }
        return String(rest)
    }

    private static func openingFence(_ content: String) -> (char: Character, length: Int)? {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix(while: { $0 == first })
        guard run.count >= 3 else { return nil }
        if first == "`", trimmed.dropFirst(run.count).contains("`") { return nil }
        return (first, run.count)
    }

    private static func closesFence(_ content: String, opening: (char: Character, length: Int)) -> Bool {
        guard !content.hasPrefix("    "), !content.hasPrefix("\t") else { return false }
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        let run = trimmed.prefix(while: { $0 == opening.char })
        return run.count >= opening.length && trimmed.dropFirst(run.count).isEmpty
    }

    // MARK: - Intent flattening

    private struct BlockContext {
        var quoteDepth = 0
        var headerLevel: Int?
        var isCodeBlock = false
        var isThematicBreak = false
        var listItem: (identity: Int, ordinal: Int, ordered: Bool, depth: Int)?
        var tableCell: (tableIdentity: Int, columns: Int, column: Int, row: TableBuilder.Row)?

        init(intent: PresentationIntent?) {
            guard let intent else { return }
            var innermostItem: (identity: Int, ordinal: Int)?
            var awaitingListKind = false
            var innermostOrdered = false
            var listDepth = 0
            var cellColumn: Int?
            var cellRow: TableBuilder.Row?

            // Components run innermost → outermost, so the first listItem is
            // the one whose marker this block carries, and the next list
            // container decides bullet vs number.
            for component in intent.components {
                switch component.kind {
                case .blockQuote:
                    quoteDepth += 1
                case .header(let level):
                    headerLevel = level
                case .codeBlock:
                    isCodeBlock = true
                case .thematicBreak:
                    isThematicBreak = true
                case .listItem(let ordinal):
                    if innermostItem == nil {
                        innermostItem = (component.identity, ordinal)
                        awaitingListKind = true
                    }
                    listDepth += 1
                case .orderedList:
                    if awaitingListKind { innermostOrdered = true; awaitingListKind = false }
                case .unorderedList:
                    if awaitingListKind { awaitingListKind = false }
                case .tableCell(let column):
                    cellColumn = column
                case .tableHeaderRow:
                    cellRow = .header
                case .tableRow(let rowIndex):
                    cellRow = .body(rowIndex)
                case .table(let columns):
                    if let column = cellColumn, let row = cellRow {
                        tableCell = (component.identity, columns.count, column, row)
                    }
                default:
                    break
                }
            }
            if let item = innermostItem {
                listItem = (item.identity, item.ordinal, innermostOrdered, max(listDepth - 1, 0))
            }
        }
    }

    private struct TableBuilder {
        enum Row {
            case header
            case body(Int)
        }

        let identity: Int
        let columns: Int
        let quoteDepth: Int
        let listIndent: Int
        private var header: [Int: AttributedString] = [:]
        private var rows: [Int: [Int: AttributedString]] = [:]

        init(identity: Int, columns: Int, quoteDepth: Int, listIndent: Int) {
            self.identity = identity
            self.columns = columns
            self.quoteDepth = quoteDepth
            self.listIndent = listIndent
        }

        mutating func add(cell: AttributedString, column: Int, row: Row) {
            switch row {
            case .header: header[column] = cell
            case .body(let index): rows[index, default: [:]][column] = cell
            }
        }

        func build() -> MarkdownBlock.Kind {
            func padded(_ cells: [Int: AttributedString]) -> [AttributedString] {
                (0..<columns).map { cells[$0] ?? AttributedString() }
            }
            return .table(
                header: padded(header),
                rows: rows.keys.sorted().map { padded(rows[$0]!) }
            )
        }
    }

    // MARK: - Leaf grouping

    /// Splits the parsed document into runs of consecutive characters sharing
    /// one presentation intent — i.e. the leaf blocks of the Markdown tree.
    private static func leafGroups(of source: AttributedString) -> [(intent: PresentationIntent?, text: AttributedString)] {
        var groups: [(intent: PresentationIntent?, text: AttributedString)] = []
        var currentIntent: PresentationIntent?
        var currentRange: Range<AttributedString.Index>?

        for run in source.runs {
            if let range = currentRange, run.presentationIntent == currentIntent {
                currentRange = range.lowerBound..<run.range.upperBound
            } else {
                if let range = currentRange {
                    groups.append((currentIntent, AttributedString(source[range])))
                }
                currentIntent = run.presentationIntent
                currentRange = run.range
            }
        }
        if let range = currentRange {
            groups.append((currentIntent, AttributedString(source[range])))
        }
        return groups
    }

    // MARK: - Inline styling

    /// `Text` already honors bold/italic/strikethrough intents; inline code and
    /// links need explicit attributes to look like GitHub.
    private static func styledInline(_ text: AttributedString) -> AttributedString {
        var result = text
        while result.characters.last == "\n" { result.characters.removeLast() }
        for run in result.runs {
            if let inline = run.inlinePresentationIntent, inline.contains(.code) {
                result[run.range].font = .system(size: 12, design: .monospaced)
                result[run.range].backgroundColor = Color.primary.opacity(0.08)
            }
            if run.link != nil {
                result[run.range].foregroundColor = DesignStyle.linkBlue
            }
            if let imageURL = run.imageURL {
                // Text can't inline the bitmap; degrade the alt text to a
                // link instead of showing a bare word with no affordance.
                result[run.range].link = imageURL
                result[run.range].foregroundColor = DesignStyle.linkBlue
            }
        }
        return result
    }

    /// Turns a leading GitHub task-list literal (`[ ] `, `[x] `) into a
    /// checkbox marker; Foundation's parser doesn't know the extension.
    private static func extractTaskMarker(from text: inout AttributedString) -> MarkdownBlock.ListMarker? {
        let plain = String(text.characters)
        let done: Bool
        if plain == "[ ]" || plain.hasPrefix("[ ] ") {
            done = false
        } else if ["[x]", "[X]"].contains(plain) || plain.hasPrefix("[x] ") || plain.hasPrefix("[X] ") {
            done = true
        } else {
            return nil
        }
        text.characters.removeFirst(min(4, plain.count))
        return .task(done: done)
    }
}

// MARK: - View

/// Renders Markdown (PR descriptions, comments) GitHub-style.
struct MarkdownPreview: View {
    private let blocks: [MarkdownBlock]

    // SwiftUI re-evaluates the parent body on unrelated state changes (avatar
    // loads, Viewed toggles), and parsing a huge bot-generated body costs
    // visible milliseconds — memoize per source string.
    private static var cache: [String: [MarkdownBlock]] = [:]
    private static var cacheOrder: [String] = []

    init(markdown: String) {
        if let hit = Self.cache[markdown] {
            blocks = hit
        } else {
            blocks = MarkdownBlockParser.parse(markdown)
            Self.cache[markdown] = blocks
            Self.cacheOrder.append(markdown)
            if Self.cacheOrder.count > 16 {
                Self.cache.removeValue(forKey: Self.cacheOrder.removeFirst())
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                MarkdownBlockView(block: block)
            }
        }
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        if block.quoteDepth > 0 {
            indentedContent
                .foregroundStyle(.secondary)
                .padding(.leading, CGFloat(block.quoteDepth) * 13)
                .overlay(alignment: .leading) { quoteBars }
        } else {
            indentedContent
        }
    }

    private var indentedContent: some View {
        content.padding(.leading, CGFloat(block.listIndent) * 18)
    }

    private var quoteBars: some View {
        HStack(spacing: 10) {
            ForEach(0..<block.quoteDepth, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.primary.opacity(0.18))
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch block.kind {
        case .heading(let level, let text):
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(headingFont(level))
                    .textSelection(.enabled)
                if level <= 2 {
                    Divider()
                }
            }
            .padding(.top, 4)

        case .paragraph(let text):
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(4)
                .textSelection(.enabled)

        case .codeBlock(let code):
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))

        case .listItem(let depth, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                markerView(marker)
                Text(text)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(depth) * 18)

        case .table(let header, let rows):
            tableView(header: header, rows: rows)

        case .thematicBreak:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .system(size: 20, weight: .bold)
        case 2: .system(size: 17, weight: .bold)
        case 3: .system(size: 15, weight: .semibold)
        case 4: .system(size: 13.5, weight: .semibold)
        default: .system(size: 12.5, weight: .semibold)
        }
    }

    @ViewBuilder
    private func markerView(_ marker: MarkdownBlock.ListMarker) -> some View {
        switch marker {
        case .bullet:
            Text("•")
                .font(.system(size: 13))
                .frame(minWidth: 14, alignment: .trailing)
        case .ordered(let ordinal):
            Text("\(ordinal).")
                .font(.system(size: 13))
                .monospacedDigit()
                .frame(minWidth: 14, alignment: .trailing)
        case .task(let done):
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundStyle(done ? DesignStyle.brandBlue : Color.secondary)
                .frame(minWidth: 14, alignment: .trailing)
        case .continuation:
            Color.clear
                .frame(width: 14, height: 1)
        }
    }

    private func tableView(header: [AttributedString], rows: [[AttributedString]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    tableCell(cell, isHeader: true)
                }
            }
            .background(.quaternary.opacity(0.4))
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                Divider().gridCellColumns(max(header.count, 1))
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        tableCell(cell, isHeader: false)
                    }
                }
                .background(rowIndex.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func tableCell(_ text: AttributedString, isHeader: Bool) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: isHeader ? .semibold : .regular))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }
}
