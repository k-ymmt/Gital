//
//  SettingsView.swift
//  Gital
//

import AppKit
import Observation
import SwiftUI

/// App settings window: one row per rebindable action, grouped by menu.
struct SettingsView: View {
    let shortcuts: ShortcutStore
    @State private var recording = ShortcutRecordingSession()

    var body: some View {
        Form {
            ForEach(ShortcutAction.Category.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(ShortcutAction.allCases.filter { $0.category == category }) { action in
                        ShortcutRow(action: action, shortcuts: shortcuts, recording: recording)
                    }
                }
            }

            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text("Click a shortcut to record a new one. While recording, press Delete to remove the shortcut or Esc to cancel. Assigning a shortcut that is already in use unbinds it from the other action; shortcuts owned by fixed menu items (⌘Q, ⌘W, copy/paste, …) cannot be recorded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset All") { shortcuts.resetAll() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .onDisappear { recording.end() }
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    let shortcuts: ShortcutStore
    let recording: ShortcutRecordingSession

    var body: some View {
        HStack {
            Text(action.title)
            Spacer()
            // A default silently unbound at launch because another action's
            // recorded shortcut owns the combo — without this, the shortcut
            // just vanishes with no explanation anywhere.
            if shortcuts.isConflictDemoted(action) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help("The default shortcut (\(action.defaultCombo.displayString)) is assigned to another action, so this one is unbound. Click to record a new shortcut.")
            }
            if shortcuts.isCustomized(action) {
                Button {
                    shortcuts.reset(action)
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reset to default (\(action.defaultCombo.displayString))")
            }
            ShortcutRecorderButton(action: action, shortcuts: shortcuts, recording: recording)
        }
    }
}

/// Click-to-record control. All monitor state lives in the shared
/// `ShortcutRecordingSession`, so at most one row records at a time.
private struct ShortcutRecorderButton: View {
    let action: ShortcutAction
    let shortcuts: ShortcutStore
    let recording: ShortcutRecordingSession

    private var isRecording: Bool { recording.activeAction == action }

    var body: some View {
        Button {
            if isRecording {
                recording.end()
            } else {
                recording.begin(action, store: shortcuts)
            }
        } label: {
            Text(label)
                .font(.callout.monospaced())
                .foregroundStyle(labelStyle)
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .help(isRecording ? "Press the new shortcut (Esc to cancel, Delete to remove)" : "Click to record a new shortcut")
    }

    private var label: String {
        if isRecording { return "Type Shortcut…" }
        return shortcuts.combo(for: action)?.displayString ?? "None"
    }

    private var labelStyle: some ShapeStyle {
        if isRecording { return AnyShapeStyle(.tint) }
        if shortcuts.combo(for: action) == nil { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.primary)
    }
}

/// The one active recording: installs a single app-wide keyDown monitor and
/// tears it down on capture, cancel, a different row starting, the Settings
/// window losing key status, or the view disappearing. Without the resign-key
/// hook the monitor would keep swallowing (and worse, *assigning*) keystrokes
/// typed into other windows.
@MainActor
@Observable
final class ShortcutRecordingSession {
    private(set) var activeAction: ShortcutAction?
    @ObservationIgnored private var store: ShortcutStore?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    func begin(_ action: ShortcutAction, store: ShortcutStore) {
        end()
        activeAction = action
        self.store = store
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event)
            return nil  // swallow the press while recording
        }
        // Recording can only start while the Settings window is key; any
        // window resigning key therefore means focus moved away from it.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        activeAction = nil
        store = nil
    }

    private func handle(_ event: NSEvent) {
        guard let activeAction, let store else { return }
        let modifierless = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if event.keyCode == 53, modifierless {  // Esc cancels recording
            end()
            return
        }
        if event.keyCode == 51, modifierless {  // Delete unbinds
            store.setCombo(nil, for: activeAction)
            end()
            return
        }
        guard let combo = KeyCombo(event: event), combo.isRecordable else {
            NSSound.beep()  // bare letter, or a fixed menu item's shortcut
            return
        }
        store.setCombo(combo, for: activeAction)
        end()
    }
}
