//
//  SettingsView.swift
//  Gital
//

import AppKit
import SwiftUI

/// App settings window: one row per rebindable action, grouped by menu.
struct SettingsView: View {
    let shortcuts: ShortcutStore

    var body: some View {
        Form {
            ForEach(ShortcutAction.Category.allCases, id: \.self) { category in
                Section(category.rawValue) {
                    ForEach(ShortcutAction.allCases.filter { $0.category == category }) { action in
                        ShortcutRow(action: action, shortcuts: shortcuts)
                    }
                }
            }

            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text("Click a shortcut to record a new one. While recording, press Delete to remove the shortcut or Esc to cancel. Assigning a shortcut that is already in use unbinds it from the other action.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset All") { shortcuts.resetAll() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    let shortcuts: ShortcutStore

    var body: some View {
        HStack {
            Text(action.title)
            Spacer()
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
            ShortcutRecorderButton(action: action, shortcuts: shortcuts)
        }
    }
}

/// Click-to-record control: while recording, a local event monitor swallows
/// the next key press and stores it as the action's combo.
private struct ShortcutRecorderButton: View {
    let action: ShortcutAction
    let shortcuts: ShortcutStore

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(label)
                .font(.callout.monospaced())
                .foregroundStyle(labelStyle)
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .help(isRecording ? "Press the new shortcut (Esc to cancel, Delete to remove)" : "Click to record a new shortcut")
        .onDisappear { stopRecording() }
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

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil  // swallow the press while recording
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        let modifierless = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        if event.keyCode == 53, modifierless {  // Esc cancels recording
            stopRecording()
            return
        }
        if event.keyCode == 51, modifierless {  // Delete unbinds
            shortcuts.setCombo(nil, for: action)
            stopRecording()
            return
        }
        guard let combo = KeyCombo(event: event), combo.isValidMenuShortcut else {
            NSSound.beep()  // e.g. a bare letter — would fire while typing
            return
        }
        shortcuts.setCombo(combo, for: action)
        stopRecording()
    }
}
