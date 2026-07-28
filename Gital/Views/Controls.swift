import SwiftUI

extension Set where Element == String {
    /// Inserts the key when absent, removes it when present — the collapse
    /// bookkeeping every disclosure row shares.
    mutating func toggleMembership(_ key: String) {
        if contains(key) {
            remove(key)
        } else {
            insert(key)
        }
    }
}

/// Chevron disclosure row: rotating chevron + caller-provided label, with a
/// full-width hit area. All collapsible headers/folders in the sidebar and
/// history file tree go through this so chevron behavior stays consistent.
struct DisclosureRow<Label: View>: View {
    let isExpanded: Bool
    var chevronSize: CGFloat = 8
    var spacing: CGFloat = 9
    var insets = EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16)
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: spacing) {
                Image(systemName: "chevron.right")
                    .font(.system(size: chevronSize, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                label()
                Spacer(minLength: 0)
            }
            .padding(insets)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Checkmark button toggling a row's "Viewed" flag. Kept outside the
/// grayed-out portion of its row so it stays legible on viewed rows.
struct ViewedToggle: View {
    let viewed: Bool
    var size: CGFloat = 11
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: viewed ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: size))
                .foregroundStyle(viewed ? DesignStyle.addition : Color.secondary.opacity(0.55))
        }
        .buttonStyle(.plain)
        .help(viewed ? "Mark as not viewed" : "Mark as viewed")
    }
}

/// Header bar above a diff pane (working copy, stash, PR item, history):
/// caller content on the shared quaternary strip, with the divider below.
struct PaneHeader<Content: View>: View {
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 6
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                content()
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(.quaternary.opacity(0.25))
            Divider()
        }
    }
}

extension View {
    /// Rounded card chrome shared by the PR detail cards and agent threads.
    func cardStyle(cornerRadius: CGFloat = 9) -> some View {
        self
            .background(.background.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator, lineWidth: 1))
    }
}

/// Multi-line text input with the app's rounded-border chrome and a
/// placeholder overlay; shared by the commit and agent composers.
struct PlaceholderTextEditor: View {
    @Binding var text: String
    let placeholder: String
    var height: CGFloat = 58

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12.5))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: height)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(.separator, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 10)
                        .allowsHitTesting(false)
                }
            }
    }
}
