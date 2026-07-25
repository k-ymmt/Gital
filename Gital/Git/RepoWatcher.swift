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

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: nil,
            release: nil,
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
        ) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
