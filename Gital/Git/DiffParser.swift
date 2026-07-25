import Foundation

enum DiffParser {
    /// Parses `git diff` / `git show --patch` unified output into per-file diffs.
    static func parse(_ output: String, scope: DiffScope = .snapshot) -> [FileDiff] {
        var files: [FileDiff] = []

        var inFile = false
        var currentPath: String?
        var currentOldPath: String?
        var currentIsBinary = false
        var currentHunks: [DiffHunk] = []

        var hunkHeader: String?
        var hunkParents = 1  // >1 inside a combined (@@@) hunk
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
                        newNumber: $0.newNumber,
                        noNewline: $0.noNewline
                    )
                }
            ))
            nextHunkID += 1
            hunkHeader = nil
            hunkLines = []
        }

        func flushFile() {
            flushHunk()
            defer {
                inFile = false
                currentPath = nil
                currentOldPath = nil
                currentIsBinary = false
                currentHunks = []
            }
            guard let path = currentPath ?? currentOldPath else { return }
            files.append(FileDiff(
                path: path,
                oldPath: currentOldPath == path ? nil : currentOldPath,
                isBinary: currentIsBinary,
                hunks: currentHunks,
                scope: scope
            ))
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                flushFile()
                inFile = true
                // Paths are re-read from ---/+++ lines; keep a fallback from the header.
                let remainder = line.dropFirst("diff --git ".count)
                if let paths = parseHeaderPaths(String(remainder)) {
                    currentPath = paths.new
                    currentOldPath = paths.old
                }
                continue
            }

            // Combined diffs for conflicted paths ("git diff" during a merge).
            if line.hasPrefix("diff --cc ") || line.hasPrefix("diff --combined ") {
                flushFile()
                inFile = true
                let prefix = line.hasPrefix("diff --cc ") ? "diff --cc " : "diff --combined "
                let path = unquotePath(String(line.dropFirst(prefix.count)))
                currentPath = path
                currentOldPath = path
                continue
            }

            if !inFile && !line.hasPrefix("@@") { continue }

            // File header lines only appear before the first hunk; inside a hunk
            // "--- "/"+++ " are ordinary deletion/addition content ("-- x" / "++ x").
            if hunkHeader == nil {
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    currentIsBinary = true
                    continue
                }
                if line.hasPrefix("--- ") {
                    let path = unquotePath(String(line.dropFirst(4)))
                    if path != "/dev/null" {
                        currentOldPath = stripPathPrefix(path)
                    }
                    continue
                }
                if line.hasPrefix("+++ ") {
                    let path = unquotePath(String(line.dropFirst(4)))
                    if path != "/dev/null" {
                        currentPath = stripPathPrefix(path)
                    } else if let old = currentOldPath {
                        currentPath = old
                    }
                    continue
                }
            }
            if line.hasPrefix("@@") {
                flushHunk()
                guard let ranges = parseHunkHeader(String(line)) else { continue }
                hunkHeader = String(line)
                hunkParents = ranges.parents
                hunkOldStart = ranges.oldStart
                hunkNewStart = ranges.newStart
                oldNumber = ranges.oldStart
                newNumber = ranges.newStart
                continue
            }

            guard hunkHeader != nil, let first = line.first else { continue }
            if first == "\\" {  // "\ No newline at end of file"
                if !hunkLines.isEmpty {
                    hunkLines[hunkLines.count - 1].noNewline = true
                }
                continue
            }

            if hunkParents > 1 {
                // Combined hunk: one prefix column per parent. Old numbers
                // track the first parent; a line is in the result unless some
                // column removes it.
                guard line.count >= hunkParents else { continue }
                let prefix = line.prefix(hunkParents)
                guard prefix.allSatisfy({ $0 == " " || $0 == "+" || $0 == "-" }) else { continue }
                let text = String(line.dropFirst(hunkParents))
                let inFirstParent = prefix.first != "+"
                if prefix.contains("-") {
                    hunkLines.append(DiffLine(id: String(nextLineID), kind: .deletion, text: text, oldNumber: inFirstParent ? oldNumber : nil, newNumber: nil))
                } else if prefix.contains("+") {
                    hunkLines.append(DiffLine(id: String(nextLineID), kind: .addition, text: text, oldNumber: nil, newNumber: newNumber))
                    newNumber += 1
                } else {
                    hunkLines.append(DiffLine(id: String(nextLineID), kind: .context, text: text, oldNumber: oldNumber, newNumber: newNumber))
                    newNumber += 1
                }
                if inFirstParent { oldNumber += 1 }
                nextLineID += 1
                continue
            }

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
        // Quoted paths ("a/\346..." with C escapes) appear when core.quotepath
        // applies or the name contains quotes/control characters.
        if remainder.hasPrefix("\"") {
            var rest = Substring(remainder)
            guard let old = scanQuoted(&rest) else { return nil }
            let newPart = rest.drop(while: { $0 == " " })
            let new = newPart.hasPrefix("\"")
                ? { var r = newPart; return scanQuoted(&r) }()
                : (newPart.isEmpty ? nil : String(newPart))
            guard let new else { return nil }
            return (stripPathPrefix(old), stripPathPrefix(new))
        }
        if let quoteRange = remainder.range(of: " \"") {
            // Unquoted old path, quoted new path.
            let old = String(remainder[..<quoteRange.lowerBound])
            var rest = remainder[quoteRange.lowerBound...].drop(while: { $0 == " " })
            guard let new = scanQuoted(&rest) else { return nil }
            return (stripPathPrefix(old), stripPathPrefix(new))
        }
        // Common case: "a/path b/path" without quoting. Paths with spaces are
        // ambiguous here and get corrected from the ---/+++ lines.
        let parts = remainder.split(separator: " ")
        guard parts.count >= 2,
              let aPart = parts.first(where: { $0.hasPrefix("a/") }),
              let bPart = parts.last(where: { $0.hasPrefix("b/") }) else { return nil }
        return (String(aPart.dropFirst(2)), String(bPart.dropFirst(2)))
    }

    /// Unquotes a git C-style quoted path (`"\346\227\245..."`); returns other
    /// strings unchanged.
    private static func unquotePath(_ path: String) -> String {
        guard path.hasPrefix("\"") else { return path }
        var rest = Substring(path)
        return scanQuoted(&rest) ?? path
    }

    /// Scans a leading C-quoted string, consuming it from `rest`.
    private static func scanQuoted(_ rest: inout Substring) -> String? {
        guard rest.first == "\"" else { return nil }
        var bytes: [UInt8] = []
        var index = rest.index(after: rest.startIndex)
        while index < rest.endIndex {
            let char = rest[index]
            if char == "\"" {
                rest = rest[rest.index(after: index)...]
                return String(decoding: bytes, as: UTF8.self)
            }
            if char == "\\" {
                index = rest.index(after: index)
                guard index < rest.endIndex else { return nil }
                let escaped = rest[index]
                switch escaped {
                case "n": bytes.append(0x0A)
                case "t": bytes.append(0x09)
                case "r": bytes.append(0x0D)
                case "\\", "\"": bytes.append(escaped.asciiValue!)
                case "0"..."7":
                    var value = 0
                    var digits = 0
                    var digitIndex = index
                    while digitIndex < rest.endIndex, digits < 3,
                          let ascii = rest[digitIndex].asciiValue, (0x30...0x37).contains(ascii) {
                        value = value * 8 + Int(ascii - 0x30)
                        digits += 1
                        digitIndex = rest.index(after: digitIndex)
                    }
                    bytes.append(UInt8(truncatingIfNeeded: value))
                    index = rest.index(digitIndex, offsetBy: -1)
                default:
                    bytes.append(contentsOf: Array(String(escaped).utf8))
                }
            } else {
                bytes.append(contentsOf: Array(String(char).utf8))
            }
            index = rest.index(after: index)
        }
        return nil
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int, parents: Int)? {
        // @@ -12,7 +12,9 @@ optional context — counts are omitted when 1 (@@ -1 +1 @@).
        // Combined hunks have one extra @ and one extra old range per parent
        // (@@@ -1,3 -1,4 +1,8 @@@).
        let atCount = line.prefix(while: { $0 == "@" }).count
        guard atCount >= 2 else { return nil }
        let parents = atCount - 1
        let scanner = Scanner(string: line)
        _ = scanner.scanString(String(repeating: "@", count: atCount))
        var oldStart: Int?
        for _ in 0..<parents {
            guard scanner.scanString("-") != nil,
                  let start = scanner.scanInt() else { return nil }
            if oldStart == nil { oldStart = start }
            if scanner.scanString(",") != nil {
                _ = scanner.scanInt()
            }
        }
        guard let oldStart,
              scanner.scanString("+") != nil,
              let newStart = scanner.scanInt() else { return nil }
        return (oldStart, newStart, parents)
    }
}
