import Foundation

enum NavTab: String, CaseIterable, Identifiable {
    case changes, branches, pullRequests, stashes

    var id: String { rawValue }

    /// SF Symbol name, or a `GitGlyph.Kind` raw value (asset-catalog image)
    /// for the tabs with custom SVG icons.
    var symbol: String {
        switch self {
        case .changes: "doc.text"
        case .branches: "TabBranches"
        case .pullRequests: "TabPullRequests"
        case .stashes: "archivebox"
        }
    }

    var help: String {
        switch self {
        case .changes: "Working Copy"
        case .branches: "Branches"
        case .pullRequests: "Pull Requests"
        case .stashes: "Stashes"
        }
    }
}

/// Tabs in the history detail pane: full commit metadata vs. changed files.
enum CommitDetailTab: String, CaseIterable, Identifiable {
    case commit = "Commit"
    case files = "Files"

    var id: String { rawValue }
}

enum DiffMode: String, CaseIterable, Identifiable {
    case unified = "Unified"
    case split = "Split"

    var id: String { rawValue }
}
