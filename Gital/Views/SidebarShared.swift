import SwiftUI

/// Uppercased sidebar section header with an optional trailing accessory.
struct SidebarSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 5)
    }
}

/// Collapsible top-level sidebar header ("Branches", "Remotes", …) driven by
/// the shared expanded-keys set.
struct SidebarCollapsibleHeader: View {
    let title: String
    let key: String
    @Binding var expandedSections: Set<String>

    var body: some View {
        DisclosureRow(
            isExpanded: expandedSections.contains(key),
            spacing: 6,
            insets: EdgeInsets(top: 12, leading: 16, bottom: 5, trailing: 16)
        ) {
            expandedSections.toggleMembership(key)
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
        }
    }
}

/// Folder row in a BranchTree listing (branch folders, changed-file folders).
struct SidebarFolderRow: View {
    let path: String
    let name: String
    let depth: Int
    var baseIndent: CGFloat = 16
    @Binding var collapsed: Set<String>

    var body: some View {
        DisclosureRow(
            isExpanded: !collapsed.contains(path),
            insets: EdgeInsets(top: 5, leading: baseIndent + CGFloat(depth) * 14, bottom: 5, trailing: 16)
        ) {
            collapsed.toggleMembership(path)
        } label: {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(name)
                .font(.system(size: 12.5))
                .lineLimit(1)
        }
    }
}

/// Selection highlight behind a sidebar row.
func sidebarRowBackground(_ selected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 6)
        .fill(selected ? Color.accentColor.opacity(0.25) : .clear)
        .padding(.horizontal, 8)
}

/// Inline search field at the top of a sidebar tab (Pull Requests, Branches):
/// magnifier, plain text field, and a clear button once there is text.
struct SidebarFilterField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }
}
