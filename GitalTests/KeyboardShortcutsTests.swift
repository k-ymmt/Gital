//
//  KeyboardShortcutsTests.swift
//  GitalTests
//

import Foundation
import SwiftUI
import Testing
@testable import Gital

@MainActor
@Suite struct KeyComboTests {
    @Test func displayStringUsesCanonicalModifierOrder() {
        let combo = KeyCombo("p", [.command, .shift, .option, .control])
        #expect(combo.displayString == "⌃⌥⇧⌘P")
    }

    @Test func displayStringForSpecialKeys() {
        #expect(KeyCombo(KeyCombo.SpecialKey.return.rawValue, .command).displayString == "⌘↩")
        #expect(KeyCombo(KeyCombo.SpecialKey.leftArrow.rawValue, [.command, .option]).displayString == "⌥⌘←")
    }

    @Test func codableRoundTrip() throws {
        let combo = KeyCombo("k", [.command, .shift])
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(combo))
        #expect(decoded == combo)
    }

    @Test func keyEquivalentMapsCharactersAndSpecialKeys() {
        #expect(KeyCombo("a", .command).keyEquivalent == KeyEquivalent("a"))
        #expect(KeyCombo(KeyCombo.SpecialKey.escape.rawValue, .command).keyEquivalent == KeyEquivalent.escape)
        // A corrupt stored value (multi-character, not a special key) must
        // not crash — it just yields no shortcut.
        #expect(KeyCombo("abc", .command).keyEquivalent == nil)
        #expect(KeyCombo("abc", .command).keyboardShortcut == nil)
    }

    @Test func menuValidityRequiresPrimaryModifier() {
        #expect(KeyCombo("f", .command).isValidMenuShortcut)
        #expect(KeyCombo("f", .control).isValidMenuShortcut)
        #expect(KeyCombo("f", .option).isValidMenuShortcut)
        #expect(!KeyCombo("f", .shift).isValidMenuShortcut)
        #expect(!KeyCombo("f", []).isValidMenuShortcut)
    }

    @Test func specialKeyCodesMap() {
        #expect(KeyCombo.SpecialKey(keyCode: 36) == .return)
        #expect(KeyCombo.SpecialKey(keyCode: 76) == .return)  // keypad enter
        #expect(KeyCombo.SpecialKey(keyCode: 126) == .upArrow)
        #expect(KeyCombo.SpecialKey(keyCode: 0) == nil)  // "a"
    }

    @Test func defaultCombosAreUniqueAndMenuValid() {
        var seen: Set<KeyCombo> = []
        for action in ShortcutAction.allCases {
            let combo = action.defaultCombo
            #expect(combo.isValidMenuShortcut, "default for \(action) must carry ⌘/⌃/⌥")
            #expect(seen.insert(combo).inserted, "default for \(action) collides with another action")
        }
    }
}

@MainActor
@Suite struct ShortcutStoreTests {
    /// Fresh, isolated defaults per test so parallel tests can't interfere.
    private func makeDefaults() -> UserDefaults {
        let suite = "ShortcutStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func returnsDefaultsWhenUncustomized() {
        let store = ShortcutStore(defaults: makeDefaults())
        for action in ShortcutAction.allCases {
            #expect(store.combo(for: action) == action.defaultCombo)
            #expect(!store.isCustomized(action))
        }
    }

    @Test func customComboPersistsAcrossInstances() {
        let defaults = makeDefaults()
        let combo = KeyCombo("j", [.command, .control])
        ShortcutStore(defaults: defaults).setCombo(combo, for: .fetch)

        let reloaded = ShortcutStore(defaults: defaults)
        #expect(reloaded.combo(for: .fetch) == combo)
        #expect(reloaded.isCustomized(.fetch))
    }

    @Test func unbindingPersists() {
        let defaults = makeDefaults()
        ShortcutStore(defaults: defaults).setCombo(nil, for: .push)

        let reloaded = ShortcutStore(defaults: defaults)
        #expect(reloaded.combo(for: .push) == nil)
        #expect(reloaded.isCustomized(.push))
    }

    @Test func assigningTakenComboUnbindsOtherAction() {
        let store = ShortcutStore(defaults: makeDefaults())
        store.setCombo(ShortcutAction.pull.defaultCombo, for: .fetch)
        #expect(store.combo(for: .fetch) == ShortcutAction.pull.defaultCombo)
        #expect(store.combo(for: .pull) == nil)
    }

    @Test func settingDefaultComboClearsCustomization() {
        let store = ShortcutStore(defaults: makeDefaults())
        store.setCombo(KeyCombo("z", .command), for: .refresh)
        #expect(store.isCustomized(.refresh))
        store.setCombo(ShortcutAction.refresh.defaultCombo, for: .refresh)
        #expect(!store.isCustomized(.refresh))
    }

    @Test func resetRestoresDefaultAndReclaimsCombo() {
        let store = ShortcutStore(defaults: makeDefaults())
        // .fetch steals pull's default, then pull is reset: pull must get its
        // default back and fetch must be unbound (one combo, one action).
        store.setCombo(ShortcutAction.pull.defaultCombo, for: .fetch)
        store.reset(.pull)
        #expect(store.combo(for: .pull) == ShortcutAction.pull.defaultCombo)
        #expect(!store.isCustomized(.pull))
        #expect(store.combo(for: .fetch) == nil)
    }

    @Test func resetAllClearsEverythingAndDefaultsKey() {
        let defaults = makeDefaults()
        let store = ShortcutStore(defaults: defaults)
        store.setCombo(KeyCombo("z", .command), for: .refresh)
        store.setCombo(nil, for: .push)
        store.resetAll()
        for action in ShortcutAction.allCases {
            #expect(store.combo(for: action) == action.defaultCombo)
        }
        #expect(defaults.data(forKey: ShortcutStore.defaultsKey) == nil)
    }

    @Test func corruptStoredDataFallsBackToDefaults() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: ShortcutStore.defaultsKey)
        let store = ShortcutStore(defaults: defaults)
        #expect(store.combo(for: .fetch) == ShortcutAction.fetch.defaultCombo)
    }
}
