import Foundation

/// Sidebar Branches-tab filter: narrows local branches, remote branches, and
/// tags to those whose name contains the query (case- and
/// diacritic-insensitive, via `localizedStandardContains`). Pure functions so
/// the test harness can reach them without a view model.
nonisolated enum BranchFilter {
    /// The query as matched: surrounding whitespace is ignored, and a
    /// whitespace-only query means "no filter".
    static func normalizedQuery(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isActive(_ text: String) -> Bool {
        !normalizedQuery(text).isEmpty
    }

    /// Substring match on the full ref name (`feature/foo`, `origin/main`,
    /// `v1.2.0`). An empty query matches everything.
    static func matches(_ name: String, query: String) -> Bool {
        let query = normalizedQuery(query)
        return query.isEmpty || name.localizedStandardContains(query)
    }

    static func branches(_ branches: [Branch], query: String) -> [Branch] {
        guard isActive(query) else { return branches }
        return branches.filter { matches($0.name, query: query) }
    }

    /// Remote branches are matched on the joined `remote/branch` name, so
    /// "origin" alone keeps every branch of that remote and "origin/main"
    /// narrows to one. Remotes left with no matching branch are dropped.
    static func remotes(_ remotes: [RemoteInfo], query: String) -> [RemoteInfo] {
        guard isActive(query) else { return remotes }
        return remotes.compactMap { remote in
            let kept = remote.branches.filter { matches("\(remote.name)/\($0.name)", query: query) }
            return kept.isEmpty ? nil : RemoteInfo(name: remote.name, branches: kept)
        }
    }

    static func tags(_ tags: [Tag], query: String) -> [Tag] {
        guard isActive(query) else { return tags }
        return tags.filter { matches($0.name, query: query) }
    }
}
