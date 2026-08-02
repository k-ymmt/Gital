import CryptoKit
import Foundation
import Testing
@testable import Gital

@MainActor
struct DiffSyntaxHighlightingTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // GitalTests/
            .deletingLastPathComponent() // repo root
    }

    @Test func mapsExtensionsToShikiLanguageIDs() {
        #expect(DiffSyntaxHighlighting.language(forPath: "Gital/Views/ChangesView.swift") == "swift")
        #expect(DiffSyntaxHighlighting.language(forPath: "src/main.TS") == "typescript", "extension match is case-insensitive")
        #expect(DiffSyntaxHighlighting.language(forPath: "a/b/component.tsx") == "tsx")
        #expect(DiffSyntaxHighlighting.language(forPath: "Sources/legacy.m") == "objective-c")
        #expect(DiffSyntaxHighlighting.language(forPath: "config.yml") == "yaml")
        #expect(DiffSyntaxHighlighting.language(forPath: "App/Info.plist") == "xml")
        #expect(DiffSyntaxHighlighting.language(forPath: "Scripts/run-tests.sh") == "shellscript")
    }

    @Test func mapsSpecialFilenames() {
        #expect(DiffSyntaxHighlighting.language(forPath: "docker/Dockerfile") == "docker")
        #expect(DiffSyntaxHighlighting.language(forPath: "Makefile") == "make")
        #expect(DiffSyntaxHighlighting.language(forPath: "ios/Podfile") == "ruby")
    }

    @Test func unknownFilesGetNoLanguage() {
        #expect(DiffSyntaxHighlighting.language(forPath: "LICENSE") == nil)
        #expect(DiffSyntaxHighlighting.language(forPath: "data.bin") == nil)
        #expect(DiffSyntaxHighlighting.language(forPath: "notes.unknownext") == nil)
        #expect(DiffSyntaxHighlighting.language(forPath: "") == nil)
    }

    // Combined (@@@) hunks interleave deletions from both merge parents —
    // no coherent old file exists to tokenize, so those diffs must render
    // uncolored rather than smear misleading colors during conflicts.
    @Test func combinedDiffsGetNoLanguage() {
        let hunk = DiffHunk(id: "h0", header: "@@@ -1 -1 +1 @@@", oldStart: 1, newStart: 1, lines: [
            DiffLine(id: "l0", kind: .context, text: "let a = 1", oldNumber: 1, newNumber: 1),
        ])
        let combined = FileDiff(path: "A.swift", oldPath: nil, isBinary: false, isCombined: true, hunks: [hunk])
        #expect(DiffSyntaxHighlighting.language(for: combined) == nil)
        for mode in DiffMode.allCases {
            #expect(!DiffHTMLBuilder.page(for: combined, mode: mode).contains("data-lang"), "\(mode.rawValue): combined page carries no language")
        }
        let plain = FileDiff(path: "A.swift", oldPath: nil, isBinary: false, hunks: [hunk])
        #expect(DiffSyntaxHighlighting.language(for: plain) == "swift", "non-combined diff still resolves")
    }

    // build.sh stamps the bundle with sha256(entry.mjs); recomputing it here
    // fails the suite whenever entry.mjs is edited without rebuilding — the
    // committed 2.5MB artifact is what actually ships.
    @Test func bundledArtifactMatchesEntrySource() throws {
        let bundleURL = try #require(Bundle.main.url(forResource: "ShikiDiff", withExtension: "js"), "ShikiDiff.js missing from the app bundle")
        let prefix = try #require(String(data: Data(contentsOf: bundleURL).prefix(100), encoding: .utf8))
        let entry = try Data(contentsOf: Self.repoRoot.appendingPathComponent("Scripts/shiki/entry.mjs"))
        let hash = SHA256.hash(data: entry).map { String(format: "%02x", $0) }.joined()
        #expect(prefix.contains("gital-entry-sha256:\(hash)"), "ShikiDiff.js is stale — run Scripts/shiki/build.sh")
    }

    // Every id the Swift map can emit must have a grammar registered in the
    // LANGS map (Scripts/shiki/entry.mjs) — an unmapped id silently renders
    // the page uncolored. The shipped bundle is checked too: each grammar's
    // JSON keeps a `"name":"<id>"` field through minification.
    @Test func emittedIDsExistInBundledLangsMap() throws {
        let entryURL = Self.repoRoot.appendingPathComponent("Scripts/shiki/entry.mjs")
        let entry = try String(contentsOf: entryURL, encoding: .utf8)
        let bundleURL = try #require(Bundle.main.url(forResource: "ShikiDiff", withExtension: "js"))
        let bundled = try String(contentsOf: bundleURL, encoding: .utf8)
        let paths = [
            "a.swift", "a.kt", "a.java", "a.c", "a.cpp", "a.m", "a.cs", "a.js",
            "a.jsx", "a.ts", "a.tsx", "a.vue", "a.json", "a.html", "a.css",
            "a.scss", "a.py", "a.rb", "a.go", "a.rs", "a.php", "a.dart",
            "a.lua", "a.pl", "a.sh", "a.yml", "a.toml", "a.ini", "a.md",
            "a.sql", "a.graphql", "a.gradle", "a.diff", "a.xml", "Dockerfile",
            "Makefile",
        ]
        for path in paths {
            let id = try #require(DiffSyntaxHighlighting.language(forPath: path), "\(path) should map to a language")
            // Ids appear in LANGS either as a bare shorthand key or quoted.
            #expect(entry.contains("'\(id)'") || entry.contains(" \(id),") || entry.contains("{\n  \(id),") || entry.contains("  \(id),"), "\(id) missing from entry.mjs LANGS")
            #expect(bundled.contains(#""name":"\#(id)""#), "\(id) grammar missing from the built ShikiDiff.js")
        }
    }
}
