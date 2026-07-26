import CoreServices
import Foundation

/// Watches the repository tree via FSEvents and reports coalesced change
/// notifications, so the UI can refresh when files change outside the app
/// (editors, terminals, agents).
final class RepoWatcher {
    private final class Handler: @unchecked Sendable {
        let onChange: @Sendable () -> Void
        init(onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }

    private var stream: FSEventStreamRef?
    private let handler: Handler
    private let queue = DispatchQueue(label: "app.kymmt.Gital.RepoWatcher")

    init(root: URL, latency: TimeInterval = 0.5, onChange: @escaping @Sendable () -> Void) {
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
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
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

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
