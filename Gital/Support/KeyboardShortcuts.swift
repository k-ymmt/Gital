//
//  KeyboardShortcuts.swift
//  Gital
//

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

// MARK: - KeyCombo

/// One non-modifier key plus modifier flags, recordable from an `NSEvent`
/// and convertible to a SwiftUI `KeyboardShortcut` for menu items.
struct KeyCombo: Hashable {
    /// A single lowercase base-layer character, or a `SpecialKey` raw value
    /// ("return", "escape", …) for keys without a printable character.
    var key: String
    /// Raw value of the `SwiftUI.EventModifiers` subset (⌘ ⌥ ⌃ ⇧). In-memory only;
    /// persistence encodes modifier *names* (see `Codable` below).
    var modifiersRaw: Int

    init(_ key: String, _ modifiers: SwiftUI.EventModifiers) {
        self.key = key
        self.modifiersRaw = modifiers.rawValue
    }

    var modifiers: SwiftUI.EventModifiers { SwiftUI.EventModifiers(rawValue: modifiersRaw) }

    /// Keys that have no printable character. Stored by name so the encoded
    /// form stays readable and stable across OS versions.
    enum SpecialKey: String, CaseIterable {
        case `return`, escape, delete, deleteForward, tab, space
        case upArrow, downArrow, leftArrow, rightArrow
        case home, end, pageUp, pageDown
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

        var keyEquivalent: KeyEquivalent {
            switch self {
            case .return: .return
            case .escape: .escape
            case .delete: .delete
            case .deleteForward: .deleteForward
            case .tab: .tab
            case .space: .space
            case .upArrow: .upArrow
            case .downArrow: .downArrow
            case .leftArrow: .leftArrow
            case .rightArrow: .rightArrow
            case .home: .home
            case .end: .end
            case .pageUp: .pageUp
            case .pageDown: .pageDown
            case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
                // NSF1FunctionKey (0xF704) onward; AppKit renders these as
                // "F1"… in menus and matches them at dispatch.
                KeyEquivalent(Character(UnicodeScalar(0xF704 + functionKeyIndex!)!))
            }
        }

        /// 0 for F1 … 11 for F12; nil for non-function keys.
        var functionKeyIndex: Int? {
            guard rawValue.hasPrefix("f"), let n = Int(rawValue.dropFirst()) else { return nil }
            return n - 1
        }

        var symbol: String {
            switch self {
            case .return: "↩"
            case .escape: "⎋"
            case .delete: "⌫"
            case .deleteForward: "⌦"
            case .tab: "⇥"
            case .space: "Space"
            case .upArrow: "↑"
            case .downArrow: "↓"
            case .leftArrow: "←"
            case .rightArrow: "→"
            case .home: "↖"
            case .end: "↘"
            case .pageUp: "⇞"
            case .pageDown: "⇟"
            case .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12:
                rawValue.uppercased()
            }
        }

        init?(keyCode: UInt16) {
            switch keyCode {
            case 36, 76: self = .return
            case 53: self = .escape
            case 51: self = .delete
            case 117: self = .deleteForward
            case 48: self = .tab
            case 49: self = .space
            case 126: self = .upArrow
            case 125: self = .downArrow
            case 123: self = .leftArrow
            case 124: self = .rightArrow
            case 115: self = .home
            case 119: self = .end
            case 116: self = .pageUp
            case 121: self = .pageDown
            case 122: self = .f1
            case 120: self = .f2
            case 99: self = .f3
            case 118: self = .f4
            case 96: self = .f5
            case 97: self = .f6
            case 98: self = .f7
            case 100: self = .f8
            case 101: self = .f9
            case 109: self = .f10
            case 103: self = .f11
            case 111: self = .f12
            default: return nil
            }
        }
    }

    /// Builds a combo from a keyDown event, or nil for a press with no
    /// representable non-modifier key.
    init?(event: NSEvent) {
        var modifiers: SwiftUI.EventModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        if let special = SpecialKey(keyCode: event.keyCode) {
            self.init(special.rawValue, modifiers)
            return
        }
        // Resolve the key by translating the key *code* on the base layer:
        // `charactersIgnoringModifiers` keeps the Shift layer (⇧⌘1 → "!"),
        // which is layout-dependent and doesn't match AppKit's key-equivalent
        // convention; translating with no modifiers yields "1". For non-Latin
        // layouts the ASCII-capable fallback inside the translator yields the
        // Latin key AppKit matches shortcuts against.
        var character = Self.baseLayerCharacter(for: event.keyCode)
        if character == nil, let fallback = event.charactersIgnoringModifiers?.lowercased(),
           fallback.count == 1 {
            character = fallback.first
        }
        guard let character,
              character.isASCII, !character.isWhitespace,
              !(character.asciiValue.map { $0 < 0x20 || $0 == 0x7F } ?? true)
        else { return nil }
        self.init(String(character).lowercased(), modifiers)
    }

    /// Translates a key code to its unmodified base-layer character, trying
    /// the current keyboard layout first and falling back to the ASCII-capable
    /// layout (what AppKit itself matches key equivalents against).
    static func baseLayerCharacter(for keyCode: UInt16) -> Character? {
        let sources = [
            TISCopyCurrentKeyboardLayoutInputSource(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource(),
        ]
        for unmanaged in sources {
            guard let source = unmanaged?.takeRetainedValue(),
                  let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
            let character: Character? = layoutData.withUnsafeBytes { buffer -> Character? in
                guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
                var deadKeyState: UInt32 = 0
                var length = 0
                var utf16 = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, utf16.count, &length, &utf16
                )
                guard status == noErr, length > 0 else { return nil }
                let string = String(utf16CodeUnits: utf16, count: length)
                return string.count == 1 ? string.first : nil
            }
            if let character, character.isASCII { return character }
        }
        return nil
    }

    var keyEquivalent: KeyEquivalent? {
        if let special = SpecialKey(rawValue: key) { return special.keyEquivalent }
        guard let character = key.first, key.count == 1 else { return nil }
        return KeyEquivalent(character)
    }

    var keyboardShortcut: KeyboardShortcut? {
        keyEquivalent.map { KeyboardShortcut($0, modifiers: modifiers) }
    }

    /// A bare character key would fire while typing in any text field; menu
    /// shortcuts must carry at least one of ⌘ ⌃ ⌥.
    var isValidMenuShortcut: Bool {
        keyEquivalent != nil && !modifiers.isDisjoint(with: [.command, .control, .option])
    }

    /// Key equivalents claimed by fixed menu items the app cannot rebind
    /// (app/File/Edit/Window menus provided by AppKit/SwiftUI). Those menus
    /// precede ours in scan order, so a rebindable action given one of these
    /// would silently never fire.
    static let reservedByFixedMenuItems: Set<KeyCombo> = [
        KeyCombo("q", .command),                       // Quit
        KeyCombo("w", .command),                       // Close
        KeyCombo("w", [.command, .shift]),             // Close All
        KeyCombo("h", .command),                       // Hide
        KeyCombo("h", [.command, .option]),            // Hide Others
        KeyCombo("m", .command),                       // Minimize
        KeyCombo("n", .command),                       // New Window
        KeyCombo(",", .command),                       // Settings…
        KeyCombo("c", .command),                       // Copy
        KeyCombo("v", .command),                       // Paste
        KeyCombo("v", [.command, .option, .shift]),    // Paste and Match Style
        KeyCombo("x", .command),                       // Cut
        KeyCombo("a", .command),                       // Select All
        KeyCombo("z", .command),                       // Undo
        KeyCombo("z", [.command, .shift]),             // Redo
        KeyCombo("f", [.command, .control]),           // Enter Full Screen
    ]

    /// What the recorder (and load-time sanitizing) accepts.
    var isRecordable: Bool {
        isValidMenuShortcut && !Self.reservedByFixedMenuItems.contains(self)
    }

    /// Display form in the canonical macOS modifier order, e.g. "⌃⌥⇧⌘P".
    var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        if let special = SpecialKey(rawValue: key) {
            text += special.symbol
        } else {
            text += key.uppercased()
        }
        return text
    }
}

/// Persistence encodes modifiers by *name* — `SwiftUI.EventModifiers.rawValue` is an
/// undocumented framework numeric that could be renumbered by an SDK update,
/// which would silently move stored shortcuts to different keys.
extension KeyCombo: Codable {
    private enum CodingKeys: String, CodingKey {
        case key, modifiers
    }

    private static let modifierNames: [(name: String, flag: SwiftUI.EventModifiers)] = [
        ("control", .control), ("option", .option), ("shift", .shift), ("command", .command),
    ]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(String.self, forKey: .key)
        let names = try container.decode([String].self, forKey: .modifiers)
        var modifiers: SwiftUI.EventModifiers = []
        for (name, flag) in Self.modifierNames where names.contains(name) {
            modifiers.insert(flag)
        }
        self.init(key, modifiers)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        let names = Self.modifierNames.filter { modifiers.contains($0.flag) }.map(\.name)
        try container.encode(names, forKey: .modifiers)
    }
}

// MARK: - ShortcutAction

/// Every user-customizable app action, with its factory-default combo.
enum ShortcutAction: String, CaseIterable, Codable, Identifiable {
    case openRepository
    case fetch, pull, push, commit
    case newBranch, stashChanges
    case stageAll, unstageAll
    case refresh
    case showWorkingCopy, showHistory, showPullRequests, showStashes
    case toggleDiffLayout

    var id: String { rawValue }

    enum Category: String, CaseIterable {
        case file = "File"
        case repository = "Repository"
        case view = "View"
    }

    var category: Category {
        switch self {
        case .openRepository:
            .file
        case .fetch, .pull, .push, .commit, .newBranch, .stashChanges, .stageAll, .unstageAll, .refresh:
            .repository
        case .showWorkingCopy, .showHistory, .showPullRequests, .showStashes, .toggleDiffLayout:
            .view
        }
    }

    var title: String {
        switch self {
        case .openRepository: "Open Repository…"
        case .fetch: "Fetch"
        case .pull: "Pull"
        case .push: "Push"
        case .commit: "Commit"
        case .newBranch: "New Branch…"
        case .stashChanges: "Stash Changes…"
        case .stageAll: "Stage All"
        case .unstageAll: "Unstage All"
        case .refresh: "Refresh"
        case .showWorkingCopy: "Show Working Copy"
        case .showHistory: "Show History"
        case .showPullRequests: "Show Pull Requests"
        case .showStashes: "Show Stashes"
        case .toggleDiffLayout: "Toggle Unified/Split Diff"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .openRepository: KeyCombo("o", .command)
        case .fetch: KeyCombo("f", [.command, .shift])
        case .pull: KeyCombo("l", [.command, .shift])
        case .push: KeyCombo("p", [.command, .shift])
        case .commit: KeyCombo(KeyCombo.SpecialKey.return.rawValue, .command)
        case .newBranch: KeyCombo("b", [.command, .shift])
        case .stashChanges: KeyCombo("s", [.command, .shift])
        case .stageAll: KeyCombo("s", [.command, .option])
        case .unstageAll: KeyCombo("u", [.command, .option])
        case .refresh: KeyCombo("r", .command)
        case .showWorkingCopy: KeyCombo("1", .command)
        case .showHistory: KeyCombo("2", .command)
        case .showPullRequests: KeyCombo("3", .command)
        case .showStashes: KeyCombo("4", .command)
        case .toggleDiffLayout: KeyCombo("d", [.command, .shift])
        }
    }
}

// MARK: - ShortcutStore

/// Persisted user overrides on top of `ShortcutAction` defaults. An override
/// with a nil combo means "explicitly unbound".
@MainActor
@Observable
final class ShortcutStore {
    struct Override: Codable, Equatable {
        var combo: KeyCombo?
    }

    static let defaultsKey = "customKeyboardShortcuts"

    private var overrides: [String: Override]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        overrides = Self.load(from: defaults)
    }

    /// Decodes and sanitizes stored overrides: an entry whose combo would be
    /// invalid as a menu shortcut (hand-edited defaults, sync damage — e.g. a
    /// bare "f" that would hijack typing app-wide) is kept but demoted to
    /// unbound rather than dropped, so it can't resurrect a default that now
    /// belongs to another action.
    private static func load(from defaults: UserDefaults) -> [String: Override] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Override].self, from: data)
        else { return [:] }
        return decoded
            .filter { ShortcutAction(rawValue: $0.key) != nil }
            .mapValues { override in
                if let combo = override.combo, !combo.isRecordable {
                    return Override(combo: nil)
                }
                return override
            }
    }

    /// The effective combo: the user's override if present, else the default.
    func combo(for action: ShortcutAction) -> KeyCombo? {
        if let override = overrides[action.rawValue] { return override.combo }
        return action.defaultCombo
    }

    func isCustomized(_ action: ShortcutAction) -> Bool {
        overrides[action.rawValue] != nil
    }

    /// Assigns a combo (or nil to unbind). A combo triggers exactly one
    /// action, so any other action currently holding it is unbound.
    func setCombo(_ combo: KeyCombo?, for action: ShortcutAction) {
        // Re-read before mutating so a rebind in one running instance doesn't
        // clobber what another instance saved since this one launched.
        overrides = Self.load(from: defaults)
        if let combo {
            for other in ShortcutAction.allCases
            where other != action && self.combo(for: other) == combo {
                overrides[other.rawValue] = Override(combo: nil)
            }
        }
        if combo == action.defaultCombo {
            overrides[action.rawValue] = nil
        } else {
            overrides[action.rawValue] = Override(combo: combo)
        }
        persist()
    }

    /// Restores the factory default, unbinding any action that has taken
    /// the default combo over in the meantime.
    func reset(_ action: ShortcutAction) {
        setCombo(action.defaultCombo, for: action)
    }

    func resetAll() {
        overrides = [:]
        persist()
    }

    private func persist() {
        if overrides.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(try? JSONEncoder().encode(overrides), forKey: Self.defaultsKey)
        }
    }
}
