import AppKit
import SwiftUI

/// The HEAD-reflog sheet: every place HEAD has been, newest first, with the
/// recovery actions (detached checkout, reset) on each row's context menu.
/// Actions target the entry's hash — the positional HEAD@{N} selector is
/// display-only and goes stale the moment HEAD moves again.
struct ReflogSheet: View {
    let model: RepoViewModel
    let snapshot: RepoViewModel.ReflogSnapshot

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("HEAD Reflog")
                    .font(.headline)
                Text("Where HEAD has been, newest first — commits lost to a reset or rebase can be recovered from here. Right-click an entry to check it out or reset to it.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Divider()

            if snapshot.entries.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    Text("The reflog is empty.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(snapshot.entries) { entry in
                            ReflogRow(entry: entry)
                                .contentShape(Rectangle())
                                .contextMenu { entryMenu(entry) }
                        }
                        // Without this, a commit sitting just past the cutoff
                        // reads as unrecoverable.
                        if snapshot.isTruncated {
                            Text("Only the newest \(snapshot.entries.count) entries are shown — older ones exist but are not listed.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 360, idealHeight: 480)
    }

    @ViewBuilder
    private func entryMenu(_ entry: ReflogEntry) -> some View {
        Button("Copy SHA") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.hash, forType: .string)
        }
        Divider()
        // Same gating as the history context menu: while a merge/rebase/…
        // is stopped on conflicts, git would refuse anyway.
        Button("Checkout \(entry.shortHash) (Detached HEAD)…") { model.reflogCheckout(entry) }
            .disabled(model.pendingOperation != nil)
        Menu("Reset “\(model.status.branch ?? "HEAD")” to Here") {
            Button("Soft — keep changes staged") { model.reflogReset(entry, mode: .soft) }
            Button("Mixed — keep changes unstaged") { model.reflogReset(entry, mode: .mixed) }
            Button("Hard — discard all changes…", role: .destructive) { model.reflogReset(entry, mode: .hard) }
        }
        .disabled(model.pendingOperation != nil)
    }
}

private struct ReflogRow: View {
    let entry: ReflogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.selector)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(entry.shortHash)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(entry.subject)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.recordedDate)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .layoutPriority(1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 16)
    }
}
