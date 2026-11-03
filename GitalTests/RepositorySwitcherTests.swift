import Foundation
import Testing
@testable import Gital

/// The repository menu's path abbreviation: menu items ignore Text
/// truncation modifiers, so the string itself is middle-ellipsized.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RepositorySwitcherTests {
    @Test func middleEllipsizedKeepsBothEnds() {
        #expect(RepositorySwitcher.middleEllipsized("short", maxLength: 10) == "short")
        #expect(RepositorySwitcher.middleEllipsized("abcdefghijkl", maxLength: 7) == "abc…jkl")
        #expect(RepositorySwitcher.middleEllipsized("abcdefghijkl", maxLength: 8) == "abc…ijkl")
    }
}
