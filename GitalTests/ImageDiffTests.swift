import Foundation
import Testing
@testable import Gital

@MainActor
struct ImageDiffTests {
    // MARK: - Image path detection

    @Test func imagePathDetection() {
        #expect(FileDiff.isImagePath("Assets/logo.png"))
        #expect(FileDiff.isImagePath("photo.JPEG"), "extension match is case-insensitive")
        #expect(FileDiff.isImagePath("icon.webp"))
        #expect(!FileDiff.isImagePath("diagram.svg"), "SVG is text and diffs normally")
        #expect(!FileDiff.isImagePath("archive.zip"))
        #expect(!FileDiff.isImagePath("png"), "a bare name is not an extension")
        #expect(!FileDiff.isImagePath("Makefile"))
    }

    @Test func eitherSideOfARenameCounts() {
        let renamedImage = FileDiff(path: "art/new.png", oldPath: "art/old.png", isBinary: true, hunks: [])
        #expect(renamedImage.isImage)
        let renamedAway = FileDiff(path: "data.bin", oldPath: "icon.png", isBinary: true, hunks: [])
        #expect(renamedAway.isImage, "rename away from an image still previews the old side")
        let plainBinary = FileDiff(path: "data.bin", oldPath: nil, isBinary: true, hunks: [])
        #expect(!plainBinary.isImage)
    }

    // MARK: - Blob specs

    @Test func blobSpecs() {
        #expect(GitRepository.blobSpec(path: "a/b.png", revision: .worktree) == nil,
                "worktree bytes are read from disk, not through git")
        #expect(GitRepository.blobSpec(path: "a/b.png", revision: .index) == ":0:a/b.png")
        #expect(GitRepository.blobSpec(path: "a/b.png", revision: .commit("abc123^")) == "abc123^:a/b.png")
        #expect(GitRepository.blobSpec(path: "a/b.png", revision: .commit("HEAD")) == "HEAD:a/b.png")
    }

    // MARK: - fileContents against a real repository

    private func withTempRepo(_ body: (GitRepository) async throws -> Void) async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-imagediff-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let executor = GitExecutor(workingDirectory: tempRoot)
        _ = try await executor.run(["init"])
        _ = try await executor.run(["config", "user.email", "test@example.com"])
        _ = try await executor.run(["config", "user.name", "Test"])
        try await body(GitRepository(root: tempRoot))
    }

    @Test func fileContentsReadsWorktreeIndexAndCommit() async throws {
        try await withTempRepo { repo in
            let committed = Data([0x89, 0x50, 0x4e, 0x47, 0x01])
            try committed.write(to: repo.root.appendingPathComponent("pic.png"))
            try await repo.stage(["pic.png"])
            try await repo.commit(message: "add pic", amend: false)

            let staged = Data([0x89, 0x50, 0x4e, 0x47, 0x02])
            try staged.write(to: repo.root.appendingPathComponent("pic.png"))
            try await repo.stage(["pic.png"])

            let worktree = Data([0x89, 0x50, 0x4e, 0x47, 0x03])
            try worktree.write(to: repo.root.appendingPathComponent("pic.png"))

            #expect(try await repo.fileContents(path: "pic.png", at: .commit("HEAD")) == committed)
            #expect(try await repo.fileContents(path: "pic.png", at: .index) == staged)
            #expect(try await repo.fileContents(path: "pic.png", at: .worktree) == worktree)
        }
    }

    @Test func missingBlobThrows() async throws {
        try await withTempRepo { repo in
            try Data([0x01]).write(to: repo.root.appendingPathComponent("a.png"))
            try await repo.stage(["a.png"])
            try await repo.commit(message: "root", amend: false)

            // The root commit has no parent — an "old side" load must throw,
            // never silently return something.
            await #expect(throws: (any Error).self) {
                try await repo.fileContents(path: "a.png", at: .commit("HEAD^"))
            }
            // A path absent from the index throws too.
            await #expect(throws: (any Error).self) {
                try await repo.fileContents(path: "missing.png", at: .index)
            }
            await #expect(throws: (any Error).self) {
                try await repo.fileContents(path: "missing.png", at: .worktree)
            }
        }
    }
}
