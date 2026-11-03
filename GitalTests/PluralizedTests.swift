import Foundation
import Testing
@testable import Gital

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PluralizedTests {
    @Test func singularOnlyForExactlyOne() {
        #expect(pluralized(1, "file") == "1 file")
        #expect(pluralized(0, "file") == "0 files")
        #expect(pluralized(3, "conflicted file") == "3 conflicted files")
        #expect(pluralized(2, "Line") == "2 Lines")
    }
}
