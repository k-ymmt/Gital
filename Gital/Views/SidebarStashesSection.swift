import SwiftUI

/// Sidebar content for the Stashes tab.
struct SidebarStashesSection: View {
    var model: RepoViewModel
    @Binding var expandedSections: Set<String>

    var body: some View {
        SidebarCollapsibleHeader(title: "Stashes", key: "stashes", expandedSections: $expandedSections)
        if expandedSections.contains("stashes") {
            if model.stashes.isEmpty {
                Text("No stashes")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
            ForEach(model.stashes) { stash in
                HStack(spacing: 9) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(stash.message)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background(sidebarRowBackground(model.selectedStashRef == stash.id))
                .onTapGesture {
                    model.selectedStashRef = stash.id
                }
                .contextMenu {
                    Button("Apply") { model.stashApply(stash, pop: false) }
                    Button("Pop") { model.stashApply(stash, pop: true) }
                    Divider()
                    // Dropping destroys the stash permanently — confirm like
                    // every other destructive action.
                    Button("Drop…", role: .destructive) { model.pendingStashDrop = stash }
                }
            }
        }
    }
}
