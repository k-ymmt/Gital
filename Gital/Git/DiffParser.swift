import Foundation

enum DiffParser {
    /// Parses `git diff` / `git show --patch` unified output into per-file diffs.
    static func parse(_ output: String) -> [FileDiff] {
        var files: [FileDiff] = []

        var currentPath: String?
        var currentOldPath: String?
        var currentIsBinary = false
        var currentHunks: [DiffHunk] = []

        var hunkHeader: String?
        var hunkOldStart = 0
        var hunkNewStart = 0
        var hunkLines: [DiffLine] = []
        var oldNumber = 0
        var newNumber = 0
        var nextHunkID = 0
        var nextLineID = 0

        func flushHunk() {
            guard let header = hunkHeader else { return }
            // IDs embed the file path so SwiftUI never confuses rows across files.
            let fileKey = currentPath ?? currentOldPath ?? "?"
            currentHunks.append(DiffHunk(
                id: "\(fileKey)@\(nextHunkID)",
                header: header,
                oldStart: hunkOldStart,
                newStart: hunkNewStart,
                lines: hunkLines.map {
                    DiffLine(
                        id: "\(fileKey)@\($0.id)",
                        kind: $0.kind,
                        text: $0.text,
                        oldNumber: $0.oldNumber,
                        newNumber: $0.newNumber
                    )
                }
            ))
            nextHunkID += 1
            hunkHeader = nil
            hunkLines = []
        }

        func flushFile() {
            flushHunk()
            guard let path = currentPath else { return }
            files.append(FileDiff(
                path: path,
                oldPath: currentOldPath == currentPath ? nil : currentOldPath,
                isBinary: currentIsBinary,
                hunks: currentHunks
            ))
            currentPath = nil
            currentOldPath = nil
            currentIsBinary = false
            currentHunks = []
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                flushFile()
                // Paths are re-read from ---/+++ lines; keep a fallback from the header.
                let remainder = line.dropFirst("diff --git ".count)
                if let bPath = parseHeaderPaths(String(remainder)) {
                    currentPath = bPath.new
                    currentOldPath = bPath.old
                }
                continue
            }

            if currentPath == nil && !line.hasPrefix("@@") { continue }

            if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                currentIsBinary = true
                continue
            }
            if line.hasPrefix("--- ") {
                let path = String(line.dropFirst(4))
                if path != "/dev/null" {
                    currentOldPath = stripPathPrefix(path)
                }
                continue
            }
            if line.hasPrefix("+++ ") {
                let path = String(line.dropFirst(4))
                if path != "/dev/null" {
                    currentPath = stripPathPrefix(path)
                } else if let old = currentOldPath {
                    currentPath = old
                }
                continue
            }
            if line.hasPrefix("@@") {
                flushHunk()
                guard let ranges = parseHunkHeader(String(line)) else { continue }
                hunkHeader = String(line)
                hunkOldStart = ranges.oldStart
                hunkNewStart = ranges.newStart
                oldNumber = ranges.oldStart
                newNumber = ranges.newStart
                continue
            }

            guard hunkHeader != nil, let first = line.first else { continue }
            let text = String(line.dropFirst())
            switch first {
            case "+":
                hunkLines.append(DiffLine(id: String(nextLineID), kind: .addition, text: text, oldNumber: nil, newNumber: newNumber))
                newNumber += 1
            case "-":
                hunkLines.append(DiffLine(id: String(nextLineID), kind: .deletion, text: text, oldNumber: oldNumber, newNumber: nil))
                oldNumber += 1
            case " ":
                hunkLines.append(DiffLine(id: String(nextLineID), kind: .context, text: text, oldNumber: oldNumber, newNumber: newNumber))
                oldNumber += 1
                newNumber += 1
            case "\\":
                continue  // "\ No newline at end of file"
            default:
                continue
            }
            nextLineID += 1
        }
        flushFile()
        return files
    }

    private static func stripPathPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }

    private static func parseHeaderPaths(_ remainder: String) -> (old: String, new: String)? {
        // Common case: "a/path b/path" without quoting. Quoted/space paths are
        // recovered from the ---/+++ lines instead.
        let parts = remainder.split(separator: " ")
        guard parts.count >= 2,
              let aPart = parts.first(where: { $0.hasPrefix("a/") }),
              let bPart = parts.last(where: { $0.hasPrefix("b/") }) else { return nil }
        return (String(aPart.dropFirst(2)), String(bPart.dropFirst(2)))
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        // @@ -12,7 +12,9 @@ optional context
        let scanner = Scanner(string: line)
        guard scanner.scanString("@@") != nil,
              scanner.scanString("-") != nil,
              let oldStart = scanner.scanInt() else { return nil }
        _ = scanner.scanString(",")
        _ = scanner.scanInt()
        guard scanner.scanString("+") != nil,
              let newStart = scanner.scanInt() else { return nil }
        return (oldStart, newStart)
    }
}
