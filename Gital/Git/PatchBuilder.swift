import Foundation

/// Rebuilds minimal unified-diff patches from parsed hunks so a single hunk
/// can be staged (`git apply --cached`) or unstaged (`--reverse`).
enum PatchBuilder {
    /// Returns a patch containing only `hunk`, or nil when a partial patch
    /// cannot represent the change (binary file, rename, combined conflict
    /// hunk) and the caller should fall back to whole-file staging.
    static func hunkPatch(for hunk: DiffHunk, in diff: FileDiff) -> String? {
        guard !diff.isBinary, !diff.containsInvalidUTF8, diff.oldPath == nil,
              !hunk.header.hasPrefix("@@@") else { return nil }
        var patch = headerLines(for: diff, hunks: [hunk])
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
    /// nil when no applicable line is selected, the diff can't be partially
    /// applied (binary, rename, combined conflict hunk), or the selection
    /// would change newline-at-EOF semantics of an unselected line — such a
    /// patch cannot be represented and git would silently corrupt the target.
    static func linesPatch(for diff: FileDiff, selecting selectedIDs: Set<String>, direction: Direction) -> String? {
        guard !diff.isBinary, !diff.containsInvalidUTF8, diff.oldPath == nil else { return nil }
        var keptHunks: [(hunk: DiffHunk, kept: [(sign: String, text: String, noNewline: Bool)])] = []
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
            guard markersAreRepresentable(kept) else { return nil }
            keptHunks.append((hunk, kept))
        }
        guard !keptHunks.isEmpty else { return nil }

        var body = ""
        for (hunk, kept) in keptHunks {
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
        let sides = patchSides(for: diff, hunks: keptHunks)
        return "--- \(sides.old)\n+++ \(sides.new)\n" + body
    }

    /// A "\ No newline at end of file" marker is only valid on the final line
    /// of the side(s) its carrier belongs to. Neutralizing lines can move a
    /// marker onto a line that is no longer last on one of its sides (e.g. a
    /// no-newline deletion turned into context followed by an addition) —
    /// `git apply` accepts some of those patches and concatenates lines.
    private static func markersAreRepresentable(_ kept: [(sign: String, text: String, noNewline: Bool)]) -> Bool {
        for (index, line) in kept.enumerated() where line.noNewline {
            let rest = kept[(index + 1)...]
            switch line.sign {
            case "-":
                if rest.contains(where: { $0.sign != "+" }) { return false }
            case "+":
                if rest.contains(where: { $0.sign != "-" }) { return false }
            default:  // context: carries the marker for both sides
                if !rest.isEmpty { return false }
            }
        }
        return true
    }

    /// File creations need `--- /dev/null` and full deletions `+++ /dev/null`;
    /// emitting `a/path`/`b/path` instead makes `git apply --cached` stage an
    /// empty file rather than a deletion.
    private static func patchSides(
        for diff: FileDiff,
        hunks: [(hunk: DiffHunk, kept: [(sign: String, text: String, noNewline: Bool)])]
    ) -> (old: String, new: String) {
        let oldEmpty = hunks.allSatisfy { $0.hunk.oldStart == 0 && $0.kept.allSatisfy { $0.sign == "+" } }
        let newEmpty = hunks.allSatisfy { $0.hunk.newStart == 0 && $0.kept.allSatisfy { $0.sign == "-" } }
        return (
            oldEmpty ? "/dev/null" : headerPath("a", diff.path),
            newEmpty ? "/dev/null" : headerPath("b", diff.path)
        )
    }

    private static func headerLines(for diff: FileDiff, hunks: [DiffHunk]) -> String {
        let mapped = hunks.map { hunk in
            (hunk: hunk, kept: hunk.lines.map { (sign: $0.sign, text: $0.text, noNewline: $0.noNewline) })
        }
        let sides = patchSides(for: diff, hunks: mapped)
        return "--- \(sides.old)\n+++ \(sides.new)\n"
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
