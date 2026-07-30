import Foundation
import Testing
@testable import Gital

@MainActor
struct MarkdownPreviewTests {
    private func plain(_ text: AttributedString) -> String {
        String(text.characters)
    }

    @Test func headingAndParagraph() throws {
        let blocks = MarkdownBlockParser.parse("# Title\n\nHello **world**")
        #expect(blocks.count == 2, "one heading + one paragraph")
        guard case .heading(let level, let text) = blocks[0].kind else {
            Issue.record("expected heading, got \(blocks[0].kind)")
            return
        }
        #expect(level == 1 && plain(text) == "Title")
        guard case .paragraph(let body) = blocks[1].kind else {
            Issue.record("expected paragraph, got \(blocks[1].kind)")
            return
        }
        #expect(plain(body) == "Hello world", "inline markup is folded into the text")
    }

    @Test func unorderedListWithNesting() throws {
        let blocks = MarkdownBlockParser.parse("- outer\n  - inner\n- second")
        #expect(blocks.count == 3)
        guard case .listItem(let depth0, let marker0, let text0) = blocks[0].kind,
              case .listItem(let depth1, _, let text1) = blocks[1].kind else {
            Issue.record("expected list items")
            return
        }
        #expect(depth0 == 0 && marker0 == .bullet && plain(text0) == "outer")
        #expect(depth1 == 1 && plain(text1) == "inner", "nested item is one level deeper")
    }

    @Test func orderedListOrdinals() throws {
        let blocks = MarkdownBlockParser.parse("1. first\n2. second")
        guard case .listItem(_, .ordered(let first), _) = blocks[0].kind,
              case .listItem(_, .ordered(let second), _) = blocks[1].kind else {
            Issue.record("expected ordered list items")
            return
        }
        #expect(first == 1 && second == 2)
    }

    @Test func taskListCheckboxes() throws {
        let blocks = MarkdownBlockParser.parse("- [x] done\n- [ ] todo")
        guard case .listItem(_, .task(let done), let doneText) = blocks[0].kind,
              case .listItem(_, .task(let open), let openText) = blocks[1].kind else {
            Issue.record("expected task list items, got \(blocks.map(\.kind))")
            return
        }
        #expect(done == true && plain(doneText) == "done", "literal [x] becomes a checked marker")
        #expect(open == false && plain(openText) == "todo")
    }

    @Test func fencedCodeBlock() throws {
        let blocks = MarkdownBlockParser.parse("```swift\nlet a = 1\nlet b = 2\n```")
        #expect(blocks.count == 1)
        guard case .codeBlock(let code) = blocks[0].kind else {
            Issue.record("expected code block, got \(blocks[0].kind)")
            return
        }
        #expect(code == "let a = 1\nlet b = 2", "code keeps interior newlines, drops the trailing one")
    }

    @Test func blockQuoteDepth() throws {
        let blocks = MarkdownBlockParser.parse("> quoted\n\n>> deeper")
        #expect(blocks.count == 2)
        #expect(blocks[0].quoteDepth == 1)
        #expect(blocks[1].quoteDepth == 2)
    }

    @Test func table() throws {
        let blocks = MarkdownBlockParser.parse("| Name | Value |\n| --- | --- |\n| a | 1 |\n| b | 2 |")
        #expect(blocks.count == 1)
        guard case .table(let header, let rows) = blocks[0].kind else {
            Issue.record("expected table, got \(blocks[0].kind)")
            return
        }
        #expect(header.map(plain) == ["Name", "Value"])
        #expect(rows.map { $0.map(plain) } == [["a", "1"], ["b", "2"]])
    }

    @Test func thematicBreak() throws {
        let blocks = MarkdownBlockParser.parse("above\n\n---\n\nbelow")
        #expect(blocks.count == 3)
        guard case .thematicBreak = blocks[1].kind else {
            Issue.record("expected thematic break, got \(blocks[1].kind)")
            return
        }
    }

    // GitHub renders a lone newline inside a paragraph as a line break;
    // the parser injects hard breaks so the preview matches.
    @Test func singleNewlineBecomesHardBreak() throws {
        let blocks = MarkdownBlockParser.parse("line one\nline two")
        #expect(blocks.count == 1, "still a single paragraph")
        guard case .paragraph(let text) = blocks[0].kind else {
            Issue.record("expected paragraph")
            return
        }
        #expect(plain(text).contains("\n"), "the paragraph keeps the line break")
    }

    @Test func hardBreaksSkipFencedCode() {
        let input = "para\nnext\n```\ncode line\nmore code\n```"
        let output = MarkdownBlockParser.insertingHardBreaks(input)
        #expect(output.contains("para  \n"), "paragraph lines get the break suffix")
        #expect(!output.contains("code line  "), "fenced code lines stay untouched")
    }

    @Test func windowsNewlinesAndEmptyInput() {
        #expect(MarkdownBlockParser.parse("").isEmpty)
        #expect(MarkdownBlockParser.parse("  \n").isEmpty)
        let blocks = MarkdownBlockParser.parse("# A\r\n\r\nB")
        #expect(blocks.count == 2, "CRLF input parses the same as LF")
    }

    @Test func multiParagraphListItemMarksContinuation() throws {
        let blocks = MarkdownBlockParser.parse("- first paragraph\n\n  second paragraph\n- next item")
        let markers: [MarkdownBlock.ListMarker] = blocks.compactMap {
            if case .listItem(_, let marker, _) = $0.kind { return marker } else { return nil }
        }
        #expect(markers == [.bullet, .continuation, .bullet], "only the item's first paragraph gets a bullet")
    }
}
