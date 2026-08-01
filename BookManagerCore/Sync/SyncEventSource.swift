import CoreServices
import Foundation

/// A source of "the library changed" signals. FSEvents on local volumes;
/// polling on network/cloud roots where events are unreliable.
public protocol SyncEventSource: Sendable {
    func start()
    func stop()
}

/// FSEvents watcher on a library root (CoreServices FSEventStream on a
/// dispatch queue — sandbox-safe while the security scope is active).
public final class FSEventSource: SyncEventSource, @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "bookmanager.fsevents")
    private let onChange: () -> Void

    public init(root: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let source = Unmanaged<FSEventSource>.fromOpaque(info).takeUnretainedValue()
            source.onChange()
        }
        stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )
        )
    }

    public func start() {
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

/// Periodic polling — the correctness mechanism on network/cloud roots where
/// FSEvents is unreliable, and the test double's real counterpart.
public final class PollingSource: SyncEventSource, @unchecked Sendable {
    private let interval: Duration
    private let onChange: () -> Void
    private var task: Task<Void, Never>?

    public init(interval: Duration, onChange: @escaping () -> Void) {
        self.interval = interval
        self.onChange = onChange
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.interval ?? .seconds(60))
                guard !Task.isCancelled, let self else { break }
                self.onChange()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }
}
