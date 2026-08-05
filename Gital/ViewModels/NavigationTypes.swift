import Foundation

enum NavTab: String, CaseIterable, Identifiable {
    case changes, branches, pullRequests, stashes

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .changes: "doc.text"
        case .branches: "TabBranches"
        case .pullRequests: "TabPullRequests"
        case .stashes: "archivebox"
        }
    }

    /// True when `symbol` names an asset-catalog image (custom SVG) instead
    /// of an SF Symbol.
    var usesCustomSymbol: Bool {
        switch self {
        case .branches, .pullRequests: true
        case .changes, .stashes: false
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
