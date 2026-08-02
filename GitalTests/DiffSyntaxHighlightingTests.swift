import Foundation
import Testing
@testable import Gital

@MainActor
struct DiffSyntaxHighlightingTests {
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

    // Every id the Swift map can emit must have a grammar registered in the
    // bundle's LANGS map (Scripts/shiki/entry.mjs) — an unmapped id silently
    // renders the page uncolored.
    @Test func emittedIDsExistInBundledLangsMap() throws {
        let entryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // GitalTests/
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Scripts/shiki/entry.mjs")
        let entry = try String(contentsOf: entryURL, encoding: .utf8)
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
        }
    }
}
