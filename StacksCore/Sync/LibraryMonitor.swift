import Foundation

/// Always-on watcher: debounces change bursts into one `onChange`, and runs a
/// periodic `onPeriodic` (the full-rescan backstop for missed events). The
/// app pauses it while the library is unavailable and stops it on close.
public actor LibraryMonitor {
    private let eventSource: any SyncEventSource
    private let periodic: Duration
    private let debounce: Duration
    private let onChange: @Sendable () async -> Void
    private let onPeriodic: @Sendable () async -> Void
    private var debounceTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
    private var running = false

    public init(
        eventSource: any SyncEventSource,
        periodic: Duration = .seconds(60),
        debounce: Duration = .seconds(1),
        onChange: @escaping @Sendable () async -> Void,
        onPeriodic: @escaping @Sendable () async -> Void
    ) {
        self.eventSource = eventSource
        self.periodic = periodic
        self.debounce = debounce
        self.onChange = onChange
        self.onPeriodic = onPeriodic
    }

    public func start() {
        guard !running else { return }
        running = true
        eventSource.start()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.periodic ?? .seconds(60))
                guard !Task.isCancelled, let self else { break }
                await self.runPeriodic()
            }
        }
    }

    public func stop() {
        guard running else { return }
        running = false
        eventSource.stop()
        debounceTask?.cancel()
        debounceTask = nil
        periodicTask?.cancel()
        periodicTask = nil
    }

    /// Called from the event source's queue on any change; coalesces bursts.
    public func onEvent() {
        guard running else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: self?.debounce ?? .seconds(1))
            guard !Task.isCancelled, let self else { return }
            await self.onChange()
        }
    }

    private func runPeriodic() async {
        guard running else { return }
        await onPeriodic()
    }
}
