import Foundation
import Testing
@testable import BookManagerCore

@Suite
struct LibraryMonitorTests {
    private actor Counter {
        private(set) var changes = 0
        private(set) var periodics = 0
        func bumpChanges() { changes += 1 }
        func bumpPeriodics() { periodics += 1 }
    }

    @Test
    func debouncesBurstsIntoOneChange() async throws {
        let counter = Counter()
        let source = FakeEventSource()
        let monitor = LibraryMonitor(
            eventSource: source,
            periodic: .seconds(60),
            debounce: .milliseconds(50),
            onChange: { await counter.bumpChanges() },
            onPeriodic: { await counter.bumpPeriodics() }
        )
        // The event source's closure hops to the monitor's actor.
        source.onChange = { Task { await monitor.onEvent() } }
        await monitor.start()
        source.fire()
        source.fire()
        source.fire()
        try await Task.sleep(for: .milliseconds(200))
        await monitor.stop()
        let state = await counter.changes
        #expect(state == 1)
    }

    @Test
    func periodicBackstopFires() async throws {
        let counter = Counter()
        let monitor = LibraryMonitor(
            eventSource: FakeEventSource(),
            periodic: .milliseconds(80),
            debounce: .milliseconds(10),
            onChange: { await counter.bumpChanges() },
            onPeriodic: { await counter.bumpPeriodics() }
        )
        await monitor.start()
        try await Task.sleep(for: .milliseconds(250))
        await monitor.stop()
        let periodics = await counter.periodics
        #expect(periodics >= 2)
    }

    @Test
    func stopPreventsFurtherCallbacks() async throws {
        let counter = Counter()
        let source = FakeEventSource()
        let monitor = LibraryMonitor(
            eventSource: source,
            periodic: .milliseconds(20),
            debounce: .milliseconds(5),
            onChange: { await counter.bumpChanges() },
            onPeriodic: { await counter.bumpPeriodics() }
        )
        source.onChange = { Task { await monitor.onEvent() } }
        await monitor.start()
        source.fire()
        await monitor.stop()
        let before = await counter.changes
        source.fire()
        try await Task.sleep(for: .milliseconds(100))
        let after = await counter.changes
        #expect(after == before)
    }
}

private final class FakeEventSource: SyncEventSource, @unchecked Sendable {
    var onChange: () -> Void = {}
    func start() {}
    func stop() {}
    func fire() { onChange() }
}
