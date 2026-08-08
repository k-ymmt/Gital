import Foundation
import Testing
@testable import Gital

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GitPathQuotingTests {

    @Test func unquotedPathIsUntouched() {
        #expect(GitPathQuoting.unquote("plain/path.swift") == "plain/path.swift")
    }

    @Test func simpleEscapes() {
        #expect(GitPathQuoting.unquote("\"a\\tb\"") == "a\tb")
        #expect(GitPathQuoting.unquote("\"a\\\\b\\\"c\"") == "a\\b\"c")
    }

    /// The full control-character escape map — this is where the two
    /// pre-unification implementations disagreed (`\a` parsed as a bell in
    /// file history but as a literal "a" in diff headers).
    @Test func controlCharacterEscapes() {
        #expect(GitPathQuoting.unquote("\"x\\ay\"") == "x\u{07}y")
        #expect(GitPathQuoting.unquote("\"x\\by\"") == "x\u{08}y")
        #expect(GitPathQuoting.unquote("\"x\\vy\"") == "x\u{0B}y")
        #expect(GitPathQuoting.unquote("\"x\\fy\"") == "x\u{0C}y")
        #expect(GitPathQuoting.unquote("\"x\\ny\"") == "x\ny")
        #expect(GitPathQuoting.unquote("\"x\\ry\"") == "x\ry")
    }

    @Test func octalEscapesDecodeAsUTF8() {
        #expect(GitPathQuoting.unquote("\"\\346\\227\\245.txt\"") == "日.txt")
    }

    @Test func unterminatedQuoteIsReturnedAsIs() {
        #expect(GitPathQuoting.unquote("\"abc") == "\"abc")
        #expect(GitPathQuoting.unquote("\"abc\\\"") == "\"abc\\\"")
    }

    @Test func trailingGarbageAfterCloseIsReturnedAsIs() {
        #expect(GitPathQuoting.unquote("\"abc\"def") == "\"abc\"def")
    }

    @Test func scanQuotedConsumesOnlyTheQuotedPrefix() {
        var rest = Substring("\"a b\" and rest")
        #expect(GitPathQuoting.scanQuoted(&rest) == "a b")
        #expect(rest == " and rest")
    }

    @Test func scanQuotedRejectsUnquotedInput() {
        var rest = Substring("plain")
        #expect(GitPathQuoting.scanQuoted(&rest) == nil)
        #expect(rest == "plain")
    }

    /// The repository-side wrapper must stay in lockstep with the shared
    /// implementation — diff paths feed row IDs and staging pathspecs that
    /// are matched against status output.
    @Test func repositoryWrapperDelegates() {
        #expect(GitRepository.unquotePath("\"x\\ay\"") == GitPathQuoting.unquote("\"x\\ay\""))
        #expect(GitRepository.unquotePath("\"\\346\\227\\245.txt\"") == "日.txt")
    }
}
