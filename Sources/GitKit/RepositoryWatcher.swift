import CoreServices
import Foundation

/// Watches a working tree (including `.git`) with FSEvents and calls `onChange`
/// after changes settle. Noisy internals such as object writes and lock files are ignored.
public final class RepositoryWatcher: @unchecked Sendable {
    private let url: URL
    private let debounceInterval: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "Gity.RepositoryWatcher", qos: .utility)

    // Only touched on `queue`.
    private var stream: FSEventStreamRef?
    private var pendingNotification: DispatchWorkItem?

    public init(url: URL, debounceInterval: TimeInterval = 0.4, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.debounceInterval = debounceInterval
        self.onChange = onChange
    }

    deinit {
        // The stream holds an unretained pointer to us, so it must not outlive this object.
        stop()
    }

    public func start() {
        queue.sync {
            guard stream == nil else { return }

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                watcher.handle(paths)
            }
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )
            guard let stream = FSEventStreamCreate(
                nil, callback, &context, [url.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags
            ) else { return }

            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
            self.stream = stream
        }
    }

    public func stop() {
        queue.sync {
            pendingNotification?.cancel()
            pendingNotification = nil
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private func handle(_ paths: [String]) {
        guard paths.contains(where: Self.isRelevant) else { return }
        pendingNotification?.cancel()
        let onChange = onChange
        let work = DispatchWorkItem { onChange() }
        pendingNotification = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    static func isRelevant(_ path: String) -> Bool {
        if path.hasSuffix(".lock") { return false }
        if let range = path.range(of: "/.git/") {
            let inside = path[range.upperBound...]
            // Object and reflog writes always accompany a ref or index change we do care about.
            if inside.hasPrefix("objects/") || inside.hasPrefix("logs/") { return false }
        }
        return true
    }
}
