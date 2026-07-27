import Foundation

/// A flattened row of the branch tree: slash-separated ref names
/// (`feature/foo`) grouped into collapsible folders.
enum BranchTreeRow<Leaf: Hashable>: Identifiable, Hashable {
    case folder(path: String, name: String, depth: Int)
    case leaf(Leaf, name: String, path: String, depth: Int)

    var id: String {
        switch self {
        case .folder(let path, _, _): "folder:\(path)"
        case .leaf(_, _, let path, _): "leaf:\(path)"
        }
    }
}

private final class BranchTreeNode<Leaf> {
    var subfolders: [String: BranchTreeNode] = [:]
    var leaves: [(name: String, leaf: Leaf)] = []
}

enum BranchTree {
    /// Builds visible rows for the given (fullName, leaf) pairs, skipping the
    /// contents of folders whose path is in `collapsed`. `keyPrefix` namespaces
    /// folder paths so sections (local vs. each remote) never collide.
    static func rows<Leaf: Hashable>(
        _ items: [(String, Leaf)],
        keyPrefix: String,
        collapsed: Set<String>
    ) -> [BranchTreeRow<Leaf>] {
        let root = BranchTreeNode<Leaf>()
        for (fullName, leaf) in items {
            let components = fullName.split(separator: "/").map(String.init)
            var node = root
            for folder in components.dropLast() {
                if let child = node.subfolders[folder] {
                    node = child
                } else {
                    let child = BranchTreeNode<Leaf>()
                    node.subfolders[folder] = child
                    node = child
                }
            }
            node.leaves.append((components.last ?? fullName, leaf))
        }

        var rows: [BranchTreeRow<Leaf>] = []
        flatten(root, path: keyPrefix, depth: 0, collapsed: collapsed, into: &rows)
        return rows
    }

    private static func flatten<Leaf: Hashable>(
        _ node: BranchTreeNode<Leaf>,
        path: String,
        depth: Int,
        collapsed: Set<String>,
        into rows: inout [BranchTreeRow<Leaf>]
    ) {
        for (name, child) in node.subfolders.sorted(by: {
            $0.key.localizedStandardCompare($1.key) == .orderedAscending
        }) {
            let folderPath = path + "/" + name
            rows.append(.folder(path: folderPath, name: name, depth: depth))
            if !collapsed.contains(folderPath) {
                flatten(child, path: folderPath, depth: depth + 1, collapsed: collapsed, into: &rows)
            }
        }
        for (name, leaf) in node.leaves.sorted(by: {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }) {
            rows.append(.leaf(leaf, name: name, path: path + "/" + name, depth: depth))
        }
    }
}
