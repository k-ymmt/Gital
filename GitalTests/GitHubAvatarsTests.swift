import Foundation
import Testing
@testable import Gital

@MainActor
struct GitHubAvatarsTests {
    @Test func remoteDetection() {
        #expect(GitHubAvatars.isGitHub(remoteURL: "https://github.com/k-ymmt/Gital.git"),
                "https github remote detected")
        #expect(GitHubAvatars.isGitHub(remoteURL: "git@github.com:k-ymmt/Gital.git"),
                "scp-like github remote detected")
        #expect(GitHubAvatars.isGitHub(remoteURL: "ssh://git@github.com/k-ymmt/Gital.git"),
                "ssh github remote detected")
        #expect(GitHubAvatars.isGitHub(remoteURL: "  https://GitHub.com/foo/bar.git\n"),
                "host match is case-insensitive and trims whitespace")
        #expect(!GitHubAvatars.isGitHub(remoteURL: "https://gitlab.com/foo/bar.git"),
                "non-github remote rejected")
        #expect(!GitHubAvatars.isGitHub(remoteURL: "git@gist.github.com:abc.git"),
                "github.com subdomain rejected")
        #expect(!GitHubAvatars.isGitHub(remoteURL: "/Users/me/repos/local"),
                "local path remote rejected")
    }

    @Test func avatarURLs() {
        #expect(GitHubAvatars.url(login: "octocat", pixelSize: 64)?.absoluteString
                == "https://avatars.githubusercontent.com/octocat?s=64",
                "login URL")
        #expect(GitHubAvatars.url(login: "", pixelSize: 64) == nil,
                "empty login yields no URL")
        #expect(GitHubAvatars.url(email: "12345+octocat@users.noreply.github.com", pixelSize: 64)?.absoluteString
                == "https://avatars.githubusercontent.com/u/12345?s=64",
                "noreply email resolves by embedded user id")
        #expect(GitHubAvatars.url(email: "octocat@users.noreply.github.com", pixelSize: 64)?.absoluteString
                == "https://avatars.githubusercontent.com/octocat?s=64",
                "legacy noreply email resolves by login")
        #expect(GitHubAvatars.url(email: "u/583231@users.noreply.github.com", pixelSize: 64)?.absoluteString
                == "https://avatars.githubusercontent.com/u/e?email=u/583231@users.noreply.github.com&s=64",
                "crafted noreply local part cannot inject a URL path")
        #expect(GitHubAvatars.url(email: "dev@example.com", pixelSize: 64)?.absoluteString
                == "https://avatars.githubusercontent.com/u/e?email=dev@example.com&s=64",
                "plain email goes through the email endpoint")
        #expect(GitHubAvatars.url(email: "dev+tag@example.com", pixelSize: 64)?.absoluteString
                == "https://avatars.githubusercontent.com/u/e?email=dev%2Btag@example.com&s=64",
                "plus in email is percent-encoded")
        #expect(GitHubAvatars.url(email: "", pixelSize: 64) == nil,
                "empty email yields no URL")
    }
}
