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

    // MARK: - Working-copy revision pairing

    @Test func workingRevisionPairing() {
        let unstaged = ImageDiffContext.workingRevisions(for: .unstaged)
        #expect(unstaged?.old == .index && unstaged?.new == .worktree,
                "`git diff` compares index to worktree")
        let staged = ImageDiffContext.workingRevisions(for: .staged)
        #expect(staged?.old == .commit("HEAD") && staged?.new == .index,
                "`git diff --cached` compares HEAD to index")
        let untracked = ImageDiffContext.workingRevisions(for: .untracked)
        #expect(untracked?.old == nil && untracked?.new == .worktree)
        #expect(ImageDiffContext.workingRevisions(for: .snapshot) == nil,
                "the working-copy loaders never produce snapshot diffs")
    }

    // MARK: - Content fingerprint (index line)

    @Test func binaryDiffCarriesBlobHashes() {
        let output = """
        diff --git a/pic.png b/pic.png
        index f584f40..6bf43ff 100644
        Binary files a/pic.png and b/pic.png differ
        """
        let diffs = DiffParser.parse(output, scope: .unstaged)
        #expect(diffs.count == 1)
        #expect(diffs[0].oldBlobHash == "f584f40")
        #expect(diffs[0].newBlobHash == "6bf43ff")

        // Same path, different bytes ⇒ unequal FileDiffs, so image previews
        // keyed on the diff reload when a mutable revision's content changes.
        let changed = DiffParser.parse(
            output.replacingOccurrences(of: "6bf43ff", with: "1234567"),
            scope: .unstaged
        )
        #expect(diffs[0] != changed[0], "blob OIDs are the content fingerprint")
    }

    @Test func combinedAndModelessIndexLinesParse() {
        let combined = """
        diff --cc conflicted.png
        index 111aaaa,222bbbb..333cccc
        Binary files differ
        """
        let diffs = DiffParser.parse(combined)
        #expect(diffs[0].oldBlobHash == "111aaaa,222bbbb", "combined parents kept verbatim")
        #expect(diffs[0].newBlobHash == "333cccc", "no-mode index line still parses")
    }

    // MARK: - LFS pointer detection

    @Test func lfsPointerDetection() {
        let pointer = Data("version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 12\n".utf8)
        #expect(ImageDiffView.isLFSPointer(pointer))
        #expect(!ImageDiffView.isLFSPointer(Data([0x89, 0x50, 0x4e, 0x47])))
        #expect(!ImageDiffView.isLFSPointer(Data()))
    }

    // MARK: - fileContents / fileSize against a real repository

    private func withTempRepo(_ body: (GitRepository) async throws -> Void) async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("gital-imagediff-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let executor = GitExecutor(workingDirectory: tempRoot)
        _ = try await executor.run(["init"])
        _ = try await executor.run(["config", "user.email", "test@example.com"])
        _ = try await executor.run(["config", "user.name", "Test"])
        _ = try await executor.run(["config", "commit.gpgsign", "false"])
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

            let worktree = Data([0x89, 0x50, 0x4e, 0x47, 0x03, 0x04])
            try worktree.write(to: repo.root.appendingPathComponent("pic.png"))

            #expect(try await repo.fileContents(path: "pic.png", at: .commit("HEAD")) == committed)
            #expect(try await repo.fileContents(path: "pic.png", at: .index) == staged)
            #expect(try await repo.fileContents(path: "pic.png", at: .worktree) == worktree)

            #expect(try await repo.fileSize(path: "pic.png", at: .commit("HEAD")) == committed.count)
            #expect(try await repo.fileSize(path: "pic.png", at: .index) == staged.count)
            #expect(try await repo.fileSize(path: "pic.png", at: .worktree) == worktree.count)
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
            await #expect(throws: (any Error).self) {
                try await repo.fileSize(path: "missing.png", at: .index)
            }
        }
    }

    // Untracked files stashed with `--include-untracked` live in the stash's
    // third parent — the StashDetailView fallback revision must find them
    // there, and the stash commit itself must NOT resolve them.
    @Test func stashedUntrackedBlobLivesInThirdParent() async throws {
        try await withTempRepo { repo in
            try Data([0x01]).write(to: repo.root.appendingPathComponent("tracked.txt"))
            try await repo.stage(["tracked.txt"])
            try await repo.commit(message: "base", amend: false)

            let untracked = Data([0x89, 0x50, 0x4e, 0x47, 0x00, 0x05])
            try untracked.write(to: repo.root.appendingPathComponent("new.png"))
            let executor = GitExecutor(workingDirectory: repo.root)
            _ = try await executor.run(["stash", "push", "--include-untracked"])

            let stash = try #require(try await repo.stashes().first)
            await #expect(throws: (any Error).self) {
                try await repo.fileContents(path: "new.png", at: .commit(stash.commitHash))
            }
            let fromThirdParent = try await repo.fileContents(
                path: "new.png", at: .commit("\(stash.commitHash)^3")
            )
            #expect(fromThirdParent == untracked)
        }
    }
}
