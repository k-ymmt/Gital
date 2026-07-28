import Foundation

/// Derives github.com avatar URLs, used when the repository's default remote
/// is hosted on github.com. Pure URL construction — no network access here;
/// views load the images with AsyncImage and fall back to colored initials.
enum GitHubAvatars {
    /// Whether a `git remote get-url` value points at github.com. Handles
    /// https/ssh/git schemes and the scp-like `git@github.com:owner/repo`.
    static func isGitHub(remoteURL: String) -> Bool {
        host(of: remoteURL) == "github.com"
    }

    static func host(of remoteURL: String) -> String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://") {
            return URL(string: trimmed)?.host?.lowercased()
        }
        // scp-like syntax: [user@]host:path
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        var host = trimmed[..<colon]
        if let at = host.lastIndex(of: "@") {
            host = host[host.index(after: at)...]
        }
        return host.isEmpty ? nil : host.lowercased()
    }

    /// Avatar for a GitHub login (PR authors and reviewers).
    static func url(login: String, pixelSize: Int) -> URL? {
        guard !login.isEmpty,
              let escaped = login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "https://avatars.githubusercontent.com/\(escaped)?s=\(pixelSize)")
    }

    /// Avatar for a commit author email. `id+login@users.noreply.github.com`
    /// resolves by user id without a lookup; every other email goes through
    /// GitHub's email endpoint, which serves an identicon for addresses that
    /// match no account — the same thing github.com shows for such authors.
    static func url(email: String, pixelSize: Int) -> URL? {
        guard !email.isEmpty else { return nil }
        let noreplySuffix = "@users.noreply.github.com"
        if email.lowercased().hasSuffix(noreplySuffix) {
            let local = String(email.dropLast(noreplySuffix.count))
            if let plus = local.firstIndex(of: "+"), let id = Int(local[..<plus]) {
                return URL(string: "https://avatars.githubusercontent.com/u/\(id)?s=\(pixelSize)")
            }
            return url(login: local, pixelSize: pixelSize)
        }
        var components = URLComponents(string: "https://avatars.githubusercontent.com/u/e")!
        components.queryItems = [
            URLQueryItem(name: "email", value: email),
            URLQueryItem(name: "s", value: String(pixelSize)),
        ]
        // URLComponents leaves "+" literal, which servers decode as a space —
        // "foo+tag@example.com" must not turn into "foo tag@example.com".
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
