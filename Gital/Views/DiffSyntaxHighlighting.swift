import Foundation
import WebKit

/// Shiki-based syntax highlighting for the WebView diff pages.
///
/// The heavy lifting lives in `Resources/ShikiDiff.js` — a committed esbuild
/// bundle of Shiki (rebuild with `Scripts/shiki/build.sh`) that runs inside
/// each diff page as a user script, reads the language id off
/// `<body data-lang>`, and paints token colors into the rows. Injecting it as
/// a `WKUserScript` keeps the multi-megabyte bundle out of every HTML string
/// (chunk pages are cached and hashed by their HTML).
enum DiffSyntaxHighlighting {
    /// nil when the resource is missing (e.g. a build without the bundle) —
    /// diffs then degrade to uncolored text.
    private static let userScript: WKUserScript? = {
        guard let url = Bundle.main.url(forResource: "ShikiDiff", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }()

    static func install(into configuration: WKWebViewConfiguration) {
        if let userScript {
            configuration.userContentController.addUserScript(userScript)
        }
    }

    /// Language for a diff. Combined (`@@@`) diffs never highlight: their
    /// deletion rows interleave both merge parents, so no coherent "old
    /// file" exists to tokenize — the colors would smear misleadingly on
    /// exactly the conflict-resolution screen.
    static func language(for diff: FileDiff) -> String? {
        diff.isCombined ? nil : language(forPath: diff.path)
    }

    /// Shiki language id for a repo-relative path, or nil when the file's
    /// language isn't bundled. Ids must exist in `LANGS` in
    /// `Scripts/shiki/entry.mjs`.
    static func language(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if let id = byFilename[name] { return id }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return byExtension[ext]
    }

    private static let byFilename: [String: String] = [
        "dockerfile": "docker",
        "makefile": "make",
        "gnumakefile": "make",
        "gemfile": "ruby",
        "rakefile": "ruby",
        "podfile": "ruby",
        "fastfile": "ruby",
        "brewfile": "ruby",
    ]

    private static let byExtension: [String: String] = [
        "swift": "swift",
        "kt": "kotlin", "kts": "kotlin",
        "java": "java",
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
        "m": "objective-c", "mm": "objective-c",
        "cs": "csharp",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "jsx": "jsx",
        "ts": "typescript", "mts": "typescript", "cts": "typescript",
        "tsx": "tsx",
        "vue": "vue",
        "json": "json", "jsonc": "json",
        "html": "html", "htm": "html",
        "css": "css",
        "scss": "scss",
        "py": "python",
        "rb": "ruby",
        "go": "go",
        "rs": "rust",
        "php": "php",
        "dart": "dart",
        "lua": "lua",
        "pl": "perl", "pm": "perl",
        "sh": "shellscript", "bash": "shellscript", "zsh": "shellscript",
        "yml": "yaml", "yaml": "yaml",
        "toml": "toml",
        "ini": "ini",
        "md": "markdown", "markdown": "markdown",
        "sql": "sql",
        "graphql": "graphql", "gql": "graphql",
        "gradle": "groovy", "groovy": "groovy",
        "diff": "diff", "patch": "diff",
        "xml": "xml", "plist": "xml", "xib": "xml", "storyboard": "xml",
        "entitlements": "xml", "svg": "xml",
    ]
}
