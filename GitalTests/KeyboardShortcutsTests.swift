//
//  KeyboardShortcutsTests.swift
//  GitalTests
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Gital

/// Fabricates a keyDown event the way the recorder receives one.
@MainActor
private func keyDown(
    code: UInt16, modifiers: NSEvent.ModifierFlags,
    characters: String, ignoringModifiers: String? = nil
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: characters,
        charactersIgnoringModifiers: ignoringModifiers ?? characters,
        isARepeat: false, keyCode: code
    )!
}

@MainActor
@Suite struct KeyComboTests {
    @Test func displayStringUsesCanonicalModifierOrder() {
        let combo = KeyCombo("p", [.command, .shift, .option, .control])
        #expect(combo.displayString == "⌃⌥⇧⌘P")
    }

    @Test func displayStringForSpecialKeys() {
        #expect(KeyCombo(KeyCombo.SpecialKey.return.rawValue, .command).displayString == "⌘↩")
        #expect(KeyCombo(KeyCombo.SpecialKey.leftArrow.rawValue, [.command, .option]).displayString == "⌥⌘←")
        #expect(KeyCombo(KeyCombo.SpecialKey.f5.rawValue, .command).displayString == "⌘F5")
    }

    @Test func codableRoundTrip() throws {
        let combo = KeyCombo("k", [.command, .shift])
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: JSONEncoder().encode(combo))
        #expect(decoded == combo)
    }

    @Test func modifiersPersistByNameNotRawValue() throws {
        let data = try JSONEncoder().encode(KeyCombo("k", [.command, .shift]))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"command\""))
        #expect(json.contains("\"shift\""))
        #expect(!json.contains("modifiersRaw"))

        // The stored form is readable JSON with named flags; unknown names
        // from a future version are ignored instead of failing the decode.
        let explicit = Data("{\"key\":\"p\",\"modifiers\":[\"command\",\"shift\",\"function\"]}".utf8)
        let decoded = try JSONDecoder().decode(KeyCombo.self, from: explicit)
        #expect(decoded == KeyCombo("p", [.command, .shift]))
    }

    @Test func keyEquivalentMapsCharactersAndSpecialKeys() {
        #expect(KeyCombo("a", .command).keyEquivalent == KeyEquivalent("a"))
        #expect(KeyCombo(KeyCombo.SpecialKey.escape.rawValue, .command).keyEquivalent == KeyEquivalent.escape)
        #expect(KeyCombo(KeyCombo.SpecialKey.f1.rawValue, .command).keyEquivalent == KeyEquivalent(Character(UnicodeScalar(0xF704)!)))
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

    @Test func fixedMenuItemShortcutsAreNotRecordable() {
        #expect(!KeyCombo("q", .command).isRecordable)      // Quit
        #expect(!KeyCombo("w", .command).isRecordable)      // Close
        // The fixed alternates macOS shows while holding ⌥ — recording one
        // would close/minimize every window instead of firing the action.
        #expect(!KeyCombo("w", [.command, .option]).isRecordable)  // Close All
        #expect(!KeyCombo("m", [.command, .option]).isRecordable)  // Minimize All
        #expect(!KeyCombo("c", .command).isRecordable)      // Copy
        #expect(!KeyCombo(",", .command).isRecordable)      // Settings…
        #expect(!KeyCombo("f", [.command, .control]).isRecordable)  // Full Screen
        #expect(KeyCombo("j", [.command, .control]).isRecordable)
        #expect(KeyCombo("q", [.command, .shift]).isRecordable)  // only exact combos are reserved
    }

    @Test func specialKeyCodesMap() {
        #expect(KeyCombo.SpecialKey(keyCode: 36) == .return)
        #expect(KeyCombo.SpecialKey(keyCode: 76) == .return)  // keypad enter
        #expect(KeyCombo.SpecialKey(keyCode: 126) == .upArrow)
        #expect(KeyCombo.SpecialKey(keyCode: 96) == .f5)
        #expect(KeyCombo.SpecialKey(keyCode: 0) == nil)  // "a"
    }

    @Test func defaultCombosAreUniqueAndRecordable() {
        var seen: Set<KeyCombo> = []
        for action in ShortcutAction.allCases {
            let combo = action.defaultCombo
            #expect(combo.isRecordable, "default for \(action) must be recordable")
            #expect(seen.insert(combo).inserted, "default for \(action) collides with another action")
        }
    }
}

/// The NSEvent capture path — where layout and shift-layer bugs live.
/// Key codes 0-50 land on the same characters on every ANSI/ISO/JIS Latin
/// layout, so these are stable on any development machine.
@MainActor
@Suite struct KeyComboCaptureTests {
    @Test func shiftedNumberRecordsBaseCharacter() {
        // ⇧⌘1: charactersIgnoringModifiers keeps the Shift layer ("!" on US);
        // the combo must normalize to the base-layer "1" or the resulting
        // menu item displays wrong and never matches at dispatch.
        let event = keyDown(code: 18, modifiers: [.command, .shift], characters: "!", ignoringModifiers: "!")
        let combo = KeyCombo(event: event)
        #expect(combo == KeyCombo("1", [.command, .shift]))
        #expect(combo?.displayString == "⇧⌘1")
    }

    @Test func optionLayerCharacterRecordsBaseCharacter() {
        // ⌥⌘D: the character with ⌥ applied is "∂" on US layouts.
        let event = keyDown(code: 2, modifiers: [.command, .option], characters: "∂", ignoringModifiers: "d")
        #expect(KeyCombo(event: event) == KeyCombo("d", [.command, .option]))
    }

    @Test func shiftedLetterRecordsLowercase() {
        let event = keyDown(code: 38, modifiers: [.command, .shift], characters: "J", ignoringModifiers: "J")
        #expect(KeyCombo(event: event) == KeyCombo("j", [.command, .shift]))
    }

    @Test func specialAndFunctionKeysRecordByKeyCode() {
        let escape = keyDown(code: 53, modifiers: [.command], characters: "\u{1B}")
        #expect(KeyCombo(event: escape) == KeyCombo(KeyCombo.SpecialKey.escape.rawValue, .command))
        let f5 = keyDown(code: 96, modifiers: [.command], characters: "\u{F708}")
        #expect(KeyCombo(event: f5) == KeyCombo(KeyCombo.SpecialKey.f5.rawValue, .command))
    }

    @Test func baseLayerTranslationYieldsASCII() {
        // Even under a non-Latin or IME input source the translator must
        // yield the ASCII key AppKit matches shortcuts against (via the
        // ASCII-capable-layout fallback), so recording is never impossible.
        #expect(KeyCombo.baseLayerCharacter(for: 18) == "1")
        #expect(KeyCombo.baseLayerCharacter(for: 2) == "d")
    }
}

@MainActor
@Suite struct ShortcutStoreTests {
    /// Fresh, isolated defaults per test, wiped from disk afterwards —
    /// hosted tests run unsandboxed, so a leaked suite is a real plist in
    /// ~/Library/Preferences.
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "ShortcutStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    @Test func returnsDefaultsWhenUncustomized() {
        withDefaults { defaults in
            let store = ShortcutStore(defaults: defaults)
            for action in ShortcutAction.allCases {
                #expect(store.combo(for: action) == action.defaultCombo)
                #expect(!store.isCustomized(action))
            }
        }
    }

    @Test func customComboPersistsAcrossInstances() {
        withDefaults { defaults in
            let combo = KeyCombo("j", [.command, .control])
            ShortcutStore(defaults: defaults).setCombo(combo, for: .fetch)

            let reloaded = ShortcutStore(defaults: defaults)
            #expect(reloaded.combo(for: .fetch) == combo)
            #expect(reloaded.isCustomized(.fetch))
        }
    }

    @Test func unbindingPersists() {
        withDefaults { defaults in
            ShortcutStore(defaults: defaults).setCombo(nil, for: .push)

            let reloaded = ShortcutStore(defaults: defaults)
            #expect(reloaded.combo(for: .push) == nil)
            #expect(reloaded.isCustomized(.push))
        }
    }

    @Test func assigningTakenComboUnbindsOtherAction() {
        withDefaults { defaults in
            let store = ShortcutStore(defaults: defaults)
            store.setCombo(ShortcutAction.pull.defaultCombo, for: .fetch)
            #expect(store.combo(for: .fetch) == ShortcutAction.pull.defaultCombo)
            #expect(store.combo(for: .pull) == nil)
        }
    }

    // An app update can introduce a default equal to a combo the user
    // recorded earlier for another action. Both would render as live menu
    // items with one key equivalent, and AppKit fires only the first — the
    // load path must demote the colliding default to unbound instead.
    @Test func newDefaultCollidingWithStoredOverrideIsDemoted() {
        withDefaults { defaults in
            // Simulate the pre-update state: the user recorded showReflog's
            // default combo for fetch before showReflog existed.
            let stolen = ShortcutAction.showReflog.defaultCombo
            ShortcutStore(defaults: defaults).setCombo(stolen, for: .fetch)

            let reloaded = ShortcutStore(defaults: defaults)
            #expect(reloaded.combo(for: .fetch) == stolen, "the user's override wins")
            #expect(reloaded.combo(for: .showReflog) == nil, "the colliding default is unbound")
            // Recording the combo for its own action explicitly reclaims it.
            reloaded.setCombo(stolen, for: .showReflog)
            #expect(reloaded.combo(for: .showReflog) == stolen, "explicit rebind reclaims the combo")
            #expect(reloaded.combo(for: .fetch) == nil, "the previous holder is unbound")
        }
    }

    // The demotion above strips a default the user never touched, without a
    // word — the store must report it so Settings can explain why the action
    // shows "None". Written as raw JSON: only an override persisted by an
    // older app version (with no entry for the colliding action) takes the
    // load-time demotion path — `setCombo` unbinds the other action itself.
    @Test func conflictDemotionIsSurfacedAndClearedByExplicitRebind() {
        withDefaults { defaults in
            // fetch holds showReflog's default (⇧⌘G).
            let json = """
            {"fetch":{"combo":{"key":"g","modifiers":["shift","command"]}}}
            """
            defaults.set(Data(json.utf8), forKey: ShortcutStore.defaultsKey)

            let store = ShortcutStore(defaults: defaults)
            #expect(store.combo(for: .showReflog) == nil, "the colliding default is unbound")
            #expect(store.isConflictDemoted(.showReflog))
            #expect(!store.isConflictDemoted(.fetch), "the override holder is not demoted")
            store.setCombo(KeyCombo("j", [.command, .control]), for: .showReflog)
            #expect(!store.isConflictDemoted(.showReflog), "an explicit rebind clears the flag")
        }
    }

    @Test func settingDefaultComboClearsCustomization() {
        withDefaults { defaults in
            let store = ShortcutStore(defaults: defaults)
            store.setCombo(KeyCombo("z", [.command, .option]), for: .refresh)
            #expect(store.isCustomized(.refresh))
            store.setCombo(ShortcutAction.refresh.defaultCombo, for: .refresh)
            #expect(!store.isCustomized(.refresh))
        }
    }

    @Test func resetRestoresDefaultAndReclaimsCombo() {
        withDefaults { defaults in
            let store = ShortcutStore(defaults: defaults)
            // .fetch steals pull's default, then pull is reset: pull must get
            // its default back and fetch must be unbound (one combo, one
            // action).
            store.setCombo(ShortcutAction.pull.defaultCombo, for: .fetch)
            store.reset(.pull)
            #expect(store.combo(for: .pull) == ShortcutAction.pull.defaultCombo)
            #expect(!store.isCustomized(.pull))
            #expect(store.combo(for: .fetch) == nil)
        }
    }

    @Test func resetAllClearsEverythingAndDefaultsKey() {
        withDefaults { defaults in
            let store = ShortcutStore(defaults: defaults)
            store.setCombo(KeyCombo("z", [.command, .option]), for: .refresh)
            store.setCombo(nil, for: .push)
            store.resetAll()
            for action in ShortcutAction.allCases {
                #expect(store.combo(for: action) == action.defaultCombo)
            }
            #expect(defaults.data(forKey: ShortcutStore.defaultsKey) == nil)
        }
    }

    @Test func corruptStoredDataFallsBackToDefaults() {
        withDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: ShortcutStore.defaultsKey)
            let store = ShortcutStore(defaults: defaults)
            #expect(store.combo(for: .fetch) == ShortcutAction.fetch.defaultCombo)
        }
    }

    @Test func invalidStoredComboIsDemotedToUnbound() {
        withDefaults { defaults in
            // Hand-edited defaults: a bare "f" would become a modifier-less
            // menu key equivalent that fires while typing; a reserved ⌘Q
            // would be a dead binding. Both must load as unbound, not as-is,
            // and not fall back to the default (which another action might
            // legitimately hold by then).
            let json = """
            {"fetch":{"combo":{"key":"f","modifiers":[]}},"pull":{"combo":{"key":"q","modifiers":["command"]}}}
            """
            defaults.set(Data(json.utf8), forKey: ShortcutStore.defaultsKey)
            let store = ShortcutStore(defaults: defaults)
            #expect(store.combo(for: .fetch) == nil)
            #expect(store.combo(for: .pull) == nil)
        }
    }

    @Test func mutationsMergeWithChangesFromAnotherInstance() {
        withDefaults { defaults in
            // Two live stores over one domain (two running app copies).
            // A's earlier rebind must survive B's later, unrelated rebind.
            let a = ShortcutStore(defaults: defaults)
            let b = ShortcutStore(defaults: defaults)
            a.setCombo(KeyCombo("j", [.command, .control]), for: .pull)
            b.setCombo(KeyCombo("k", [.command, .control]), for: .fetch)

            let reloaded = ShortcutStore(defaults: defaults)
            #expect(reloaded.combo(for: .pull) == KeyCombo("j", [.command, .control]))
            #expect(reloaded.combo(for: .fetch) == KeyCombo("k", [.command, .control]))
        }
    }
}
