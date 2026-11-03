import CoreServices
import Foundation

/// Watches the repository tree via FSEvents and reports coalesced change
/// notifications — with the changed paths, so the refresh can be scoped —
/// letting the UI refresh when files change outside the app (editors,
/// terminals, agents).
final class RepoWatcher {
    private final class Handler: @unchecked Sendable {
        let onChange: @Sendable ([String]) -> Void
        init(onChange: @escaping @Sendable ([String]) -> Void) { self.onChange = onChange }
    }

    private var stream: FSEventStreamRef?
    private let handler: Handler
    private let queue = DispatchQueue(label: "app.kymmt.Gital.RepoWatcher")

    /// `extraPaths`: directories outside `root` to watch as well (a linked
    /// worktree's git dirs).
    init(root: URL, extraPaths: [String] = [], latency: TimeInterval = 0.5, onChange: @escaping @Sendable ([String]) -> Void) {
        handler = Handler(onChange: onChange)

        // The stream retains the handler and releases it after invalidation,
        // so a callback mid-flight on `queue` can never race our deinit into
        // a use-after-free (the unretained variant could).
        let retainedHandler = Unmanaged.passRetained(handler)
        var context = FSEventStreamContext(
            version: 0,
            info: retainedHandler.toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<Handler>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            // UseCFTypes below makes eventPaths a CFArray of CFString.
            let paths = Unmanaged<NSArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            _ = count
            Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue().onChange(paths)
        }
        // FileEvents: per-file paths instead of per-directory, so a change at
        // the repository root can be told apart from a change inside .git —
        // the refresh scoping depends on that distinction.
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            ([root.path] + extraPaths) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            )
        ) else {
            retainedHandler.release()
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    /// False when FSEvents stream creation failed — callers should surface
    /// that external changes won't be picked up instead of failing silently.
    var isWatching: Bool { stream != nil }

    /// `path` with symlinks resolved the way FSEvents reports it (/tmp →
    /// /private/tmp); unchanged when it doesn't exist.
    nonisolated static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether a burst of changed paths can have moved refs, their
    /// decoration, or log traversal. An empty list means "unknown".
    /// `gitDirs` are the repository's resolved git dirs: a path under one is
    /// classified by its position inside it. Other paths fall back to a
    /// substring match on "/.git/", not a root-prefix compare: FSEvents
    /// reports symlink-resolved paths (/private/tmp vs /tmp), which would
    /// defeat a prefix built from the repo root. A nested repo's .git also
    /// matches — refreshing more than needed is safe.
    /// Inside a git dir, only what can change refs, their decoration, or
    /// log traversal counts: refs/, packed-refs, HEAD (+ HEAD.lock),
    /// reflogs, reftable/ (the reftable backend stores refs AND reflogs
    /// there, with HEAD a static placeholder), shallow (a deepened clone
    /// exposes new history without moving refs), and config (remote
    /// add/remove reclassifies log decorations).
    nonisolated static func touchesGitMetadata(_ paths: [String], gitDirs: [String] = []) -> Bool {
        func affectsRefs(_ inner: Substring) -> Bool {
            inner.hasPrefix("refs/") || inner.hasPrefix("packed-refs")
                || inner.hasPrefix("HEAD") || inner.hasPrefix("logs/")
                || inner.hasPrefix("reftable/") || inner.hasPrefix("shallow")
                || inner.hasPrefix("config")
        }
        // Longest first: a linked worktree's git dir sits inside the common dir.
        let dirs = gitDirs.sorted { $0.count > $1.count }
        return paths.isEmpty || paths.contains { path in
            if let dir = dirs.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                return path == dir || affectsRefs(path.dropFirst(dir.count + 1))
            }
            guard let gitDir = path.range(of: "/.git/") else {
                return path.hasSuffix("/.git")
            }
            return affectsRefs(path[gitDir.upperBound...])
        }
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
