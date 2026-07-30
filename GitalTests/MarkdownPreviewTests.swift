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

    // A fence inside a block quote must be tracked too, or the hard-break
    // suffix leaks into the quoted code's content.
    @Test func quotedFencedCodeKeepsContentClean() throws {
        let blocks = MarkdownBlockParser.parse("> ```\n> let a = 1\n> let b = 2\n> ```")
        #expect(blocks.count == 1)
        #expect(blocks[0].quoteDepth == 1)
        guard case .codeBlock(let code) = blocks[0].kind else {
            Issue.record("expected code block, got \(blocks[0].kind)")
            return
        }
        #expect(code == "let a = 1\nlet b = 2", "no trailing spaces injected into quoted code")
    }

    // CommonMark: a tilde fence closes only with tildes, so backtick lines
    // inside it are content and must stay untouched.
    @Test func tildeFenceMayContainBackticks() throws {
        let blocks = MarkdownBlockParser.parse("~~~\n```\ninner code\n```\n~~~")
        guard case .codeBlock(let code) = blocks[0].kind else {
            Issue.record("expected code block, got \(blocks[0].kind)")
            return
        }
        #expect(code == "```\ninner code\n```")
    }

    // A backtick fence whose info string contains a backtick is not a fence;
    // it must not flip the tracker and swallow hard breaks for the rest of
    // the document.
    @Test func falseFenceDoesNotSwallowHardBreaks() {
        let output = MarkdownBlockParser.insertingHardBreaks("``` `` x\nplain one\nplain two")
        #expect(output.contains("plain one  \n"), "paragraph lines after the false fence keep their breaks")
    }

    // A ``` marker indented four spaces is indented-code content, not a fence.
    @Test func indentedFenceMarkerDoesNotToggle() {
        let output = MarkdownBlockParser.insertingHardBreaks("    ```\nplain one\nplain two")
        #expect(output.contains("plain one  \n"))
        #expect(!output.contains("```  "), "the indented marker itself stays untouched")
    }

    @Test func closingFenceMustMatchCharAndLength() throws {
        let mixed = MarkdownBlockParser.parse("```\ncode\n~~~\nmore\n```")
        guard case .codeBlock(let mixedCode) = mixed[0].kind else {
            Issue.record("expected code block")
            return
        }
        #expect(mixedCode == "code\n~~~\nmore", "tildes don't close a backtick fence")

        let longer = MarkdownBlockParser.parse("````\n```\ncode\n````")
        guard case .codeBlock(let longerCode) = longer[0].kind else {
            Issue.record("expected code block")
            return
        }
        #expect(longerCode == "```\ncode", "a shorter run doesn't close a longer fence")
    }

    // A heading as a list item's first block consumes the item's marker slot:
    // the follow-up paragraph is a continuation, not a second marker.
    @Test func headingFirstListItemDoesNotDuplicateMarkers() throws {
        let blocks = MarkdownBlockParser.parse("- ## Head\n\n  para under\n- second")
        #expect(blocks.count == 3)
        guard case .heading(_, let head) = blocks[0].kind else {
            Issue.record("expected heading, got \(blocks[0].kind)")
            return
        }
        #expect(plain(head) == "Head")
        #expect(blocks[0].listIndent == 1, "the heading indents as list content")
        guard case .listItem(_, .continuation, _) = blocks[1].kind else {
            Issue.record("expected continuation, got \(blocks[1].kind)")
            return
        }
        guard case .listItem(_, .bullet, _) = blocks[2].kind else {
            Issue.record("expected bullet, got \(blocks[2].kind)")
            return
        }
    }

    @Test func codeBlockInsideListItemIndents() throws {
        let blocks = MarkdownBlockParser.parse("1. item\n\n   ```\n   code\n   ```\n\n2. two")
        let codeBlock = try #require(blocks.first {
            if case .codeBlock = $0.kind { return true } else { return false }
        })
        #expect(codeBlock.listIndent == 1, "code inside a list item is indented as list content")
    }

    // Text can't show the bitmap, so the alt text becomes a link to the image.
    @Test func imageBecomesLinkToItsURL() throws {
        let blocks = MarkdownBlockParser.parse("![screenshot](https://example.com/a.png)")
        guard case .paragraph(let text) = blocks[0].kind else {
            Issue.record("expected paragraph, got \(blocks[0].kind)")
            return
        }
        #expect(plain(text) == "screenshot")
        let linked = text.runs.compactMap(\.link)
        #expect(linked == [URL(string: "https://example.com/a.png")!], "alt text links to the image URL")
    }

    @Test func multiParagraphListItemMarksContinuation() throws {
        let blocks = MarkdownBlockParser.parse("- first paragraph\n\n  second paragraph\n- next item")
        let markers: [MarkdownBlock.ListMarker] = blocks.compactMap {
            if case .listItem(_, let marker, _) = $0.kind { return marker } else { return nil }
        }
        #expect(markers == [.bullet, .continuation, .bullet], "only the item's first paragraph gets a bullet")
    }
}
