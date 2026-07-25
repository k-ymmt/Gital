import Foundation

/// Rebuilds minimal unified-diff patches from parsed hunks so a single hunk
/// can be staged (`git apply --cached`) or unstaged (`--reverse`).
enum PatchBuilder {
    /// Returns a patch containing only `hunk`, or nil when a partial patch
    /// cannot represent the change (binary file, rename, combined conflict
    /// hunk) and the caller should fall back to whole-file staging.
    static func hunkPatch(for hunk: DiffHunk, in diff: FileDiff) -> String? {
        guard !diff.isBinary, diff.oldPath == nil, !hunk.header.hasPrefix("@@@") else { return nil }
        var patch = "--- \(headerPath("a", diff.path))\n+++ \(headerPath("b", diff.path))\n"
        patch += hunk.header + "\n"
        for line in hunk.lines {
            patch += line.sign + line.text + "\n"
            if line.noNewline {
                patch += "\\ No newline at end of file\n"
            }
        }
        return patch
    }

    enum Direction {
        case stage    // forward `git apply --cached` on an unstaged diff
        case unstage  // reverse `git apply --cached` on a staged diff
    }

    /// Builds a patch containing only the selected lines of `diff`. Unselected
    /// changes in the same hunk are neutralized so the patch leaves them
    /// untouched: when staging, unpicked additions are omitted (not in the
    /// index yet) and unpicked deletions become context (still in the index);
    /// when unstaging the roles flip, because the patch is applied in reverse
    /// against the index. Hunks without any selected line are dropped. Returns
    /// nil when no applicable line is selected or the diff can't be partially
    /// applied (binary, rename, combined conflict hunk).
    static func linesPatch(for diff: FileDiff, selecting selectedIDs: Set<String>, direction: Direction) -> String? {
        guard !diff.isBinary, diff.oldPath == nil else { return nil }
        var body = ""
        for hunk in diff.hunks {
            guard !hunk.header.hasPrefix("@@@"),
                  hunk.lines.contains(where: { $0.kind != .context && selectedIDs.contains($0.id) })
            else { continue }

            var kept: [(sign: String, text: String, noNewline: Bool)] = []
            for line in hunk.lines {
                let selected = selectedIDs.contains(line.id)
                switch line.kind {
                case .context:
                    kept.append((" ", line.text, line.noNewline))
                case .addition where selected:
                    kept.append(("+", line.text, line.noNewline))
                case .addition where direction == .unstage:
                    kept.append((" ", line.text, line.noNewline))
                case .deletion where selected:
                    kept.append(("-", line.text, line.noNewline))
                case .deletion where direction == .stage:
                    kept.append((" ", line.text, line.noNewline))
                default:
                    break  // neutralized by omission
                }
            }

            // Starts can be reused: line inclusion changes only the counts. A
            // zero-count side keeps its original "line before" start because
            // context lines always survive; a side can only end up empty when
            // the hunk was pure additions/deletions to begin with.
            let oldCount = kept.count { $0.sign != "+" }
            let newCount = kept.count { $0.sign != "-" }
            body += "@@ -\(hunk.oldStart),\(oldCount) +\(hunk.newStart),\(newCount) @@\n"
            for line in kept {
                body += line.sign + line.text + "\n"
                if line.noNewline {
                    body += "\\ No newline at end of file\n"
                }
            }
        }
        guard !body.isEmpty else { return nil }
        return "--- \(headerPath("a", diff.path))\n+++ \(headerPath("b", diff.path))\n" + body
    }

    /// Quotes a header path the way git does when it contains characters that
    /// would break the patch format. Plain UTF-8 (including spaces) stays raw,
    /// matching the `core.quotepath=false` output we parse.
    private static func headerPath(_ prefix: String, _ path: String) -> String {
        let needsQuoting = path.unicodeScalars.contains { $0 == "\"" || $0 == "\\" || $0.value < 0x20 }
        guard needsQuoting else { return "\(prefix)/\(path)" }
        var escaped = ""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case let s where s.value < 0x20: escaped += String(format: "\\%03o", s.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(prefix)/\(escaped)\""
    }
}
