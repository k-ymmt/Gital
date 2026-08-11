import Foundation

/// Reverses git's C-style path quoting (`"a\tb.txt"`, `"\346\227\245.txt"`).
/// quotepath=false keeps non-ASCII raw, but tabs, quotes, and control bytes
/// in a path are still escaped. The one implementation shared by
/// `GitRepository` (name-status / file-history output) and `DiffParser`
/// (diff headers) — the two must agree, because diff-side paths feed row IDs
/// and staging pathspecs that are later matched against status output.
enum GitPathQuoting {
    /// Wraps a concrete file path for use as a git pathspec. `:(literal)` is
    /// load-bearing: a bare pathspec globs, so "app/[id]/page.tsx" matches
    /// app/i/page.tsx instead of (or as well as) itself — a stage, diff, or
    /// worst of all `clean`/`rm` would then hit the wrong file. Every place
    /// that passes a known path as a pathspec must go through this; paths
    /// that are NOT pathspecs (blame's positional file, --no-index operands)
    /// must not.
    static func literalPathspec(_ path: String) -> String {
        ":(literal)\(path)"
    }

    /// Unquotes a fully quoted path; returns other strings unchanged.
    static func unquote(_ raw: String) -> String {
        guard raw.hasPrefix("\"") else { return raw }
        var rest = Substring(raw)
        guard let unquoted = scanQuoted(&rest), rest.isEmpty else { return raw }
        return unquoted
    }

    /// Scans a leading C-quoted string, consuming it (and its closing quote)
    /// from `rest`; nil when `rest` doesn't start a terminated quoted string.
    static func scanQuoted(_ rest: inout Substring) -> String? {
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
                case "a": bytes.append(0x07)
                case "b": bytes.append(0x08)
                case "t": bytes.append(0x09)
                case "n": bytes.append(0x0A)
                case "v": bytes.append(0x0B)
                case "f": bytes.append(0x0C)
                case "r": bytes.append(0x0D)
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
                    // \" and \\ fall through here.
                    bytes.append(contentsOf: Array(String(escaped).utf8))
                }
            } else {
                bytes.append(contentsOf: Array(String(char).utf8))
            }
            index = rest.index(after: index)
        }
        return nil
    }
}
