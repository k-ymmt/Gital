//
//  KeyboardShortcuts.swift
//  Gital
//

import AppKit
import Observation
import SwiftUI

// MARK: - KeyCombo

/// One non-modifier key plus modifier flags, recordable from an `NSEvent`
/// and convertible to a SwiftUI `KeyboardShortcut` for menu items.
struct KeyCombo: Codable, Hashable {
    /// A single lowercase character, or a `SpecialKey` raw value
    /// ("return", "escape", …) for keys without a printable character.
    var key: String
    /// Raw value of the `EventModifiers` subset (⌘ ⌥ ⌃ ⇧).
    var modifiersRaw: Int

    init(_ key: String, _ modifiers: EventModifiers) {
        self.key = key
        self.modifiersRaw = modifiers.rawValue
    }

    var modifiers: EventModifiers { EventModifiers(rawValue: modifiersRaw) }

    /// Keys that have no printable character. Stored by name so the encoded
    /// form stays readable and stable across OS versions.
    enum SpecialKey: String, CaseIterable {
        case `return`, escape, delete, deleteForward, tab, space
        case upArrow, downArrow, leftArrow, rightArrow
        case home, end, pageUp, pageDown

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
            }
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
            default: return nil
            }
        }
    }

    /// Builds a combo from a keyDown event, or nil for a press with no
    /// representable non-modifier key.
    init?(event: NSEvent) {
        var modifiers: EventModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        if let special = SpecialKey(keyCode: event.keyCode) {
            self.init(special.rawValue, modifiers)
            return
        }
        // charactersIgnoringModifiers strips ⌥-layer characters, so ⌥⌘D
        // records as "d", not "∂".
        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              characters.count == 1,
              let character = characters.first,
              character.isASCII, !character.isWhitespace, !(character.asciiValue.map { $0 < 0x20 || $0 == 0x7F } ?? true)
        else { return nil }
        self.init(String(character), modifiers)
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
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Override].self, from: data) {
            overrides = decoded
        } else {
            overrides = [:]
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
