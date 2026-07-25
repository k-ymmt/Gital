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
