import Foundation
import Testing
@testable import SmthzCore

private final class HostMonitorFixture {
    let directory = "/tmp/smthz-mon-\(UUID().uuidString.prefix(8))"
    let service: HostService
    let server: UnixSocketServer
    var socket: String { directory + "/s" }

    init(identity: ProcessIdentity? = ProcessIdentity.current()) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let journal = try EventJournal(path: directory + "/j")
        let host = HostService(journal: journal, hostIdentity: identity)
        service = host
        server = try UnixSocketServer(path: directory + "/s") { host.handle($0) }
    }

    func responseCount() throws -> Int {
        // A separate SQLite connection avoids sharing the service's connection.
        try EventJournal(path: directory + "/j").read(after: 0, limit: 100_000)
            .filter { $0.kind.hasPrefix("response:") }.count
    }

    deinit {
        for session in service.sessionManager.list() { try? service.sessionManager.close(id: session.id) }
        server.stop()
        try? FileManager.default.removeItem(atPath: directory)
    }
}

private enum MonitorTestError: Error { case timeout }

/// Bound stream waits so a broken polling loop or finish cannot hang the suite.
private func monitorSnapshot(
    from stream: AsyncStream<HostSnapshot>,
    matching predicate: @escaping @Sendable (HostSnapshot) -> Bool = { _ in true }
) async throws -> HostSnapshot? {
    try await withThrowingTaskGroup(of: HostSnapshot?.self) { group in
        group.addTask {
            for await snapshot in stream where predicate(snapshot) { return snapshot }
            return nil
        }
        group.addTask {
            try await Task.sleep(for: .seconds(3))
            throw MonitorTestError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

@Suite(.serialized)
struct HostMonitorTests {
    @Test func missingHostProducesNotRunning() async throws {
        let fixture = try HostMonitorFixture()
        fixture.server.stop()
        let monitor = HostMonitor(socketPath: fixture.socket, interval: .milliseconds(20))
        await monitor.start()
        let snapshot = try await monitorSnapshot(from: monitor.snapshots)
        await monitor.stop()
        #expect(snapshot == HostSnapshot(state: .notRunning, sessions: []))
    }

    @Test func pollingReportsIdentityVersionAndNewSessions() async throws {
        let fixture = try HostMonitorFixture()
        let identity = try #require(ProcessIdentity.current())
        let monitor = HostMonitor(socketPath: fixture.socket, interval: .milliseconds(20))
        await monitor.start()
        let initial = try await monitorSnapshot(from: monitor.snapshots)
        #expect(initial == HostSnapshot(state: .running(identity: identity,
                                                       version: ApplicationIdentity.version), sessions: []))
        let client = try HostClient(socketPath: fixture.socket)
        let session: SessionInfo
        do {
            defer { client.disconnect() }
            session = try client.createSession(executable: "/bin/cat")
        }
        let snapshot = try await monitorSnapshot(from: monitor.snapshots) {
            $0.sessions.contains { $0.id == session.id }
        }
        await monitor.stop()
        #expect(snapshot?.sessions == [session])
        #expect(snapshot?.state == .running(identity: identity, version: ApplicationIdentity.version))
    }

    @Test func pollingDetectsHostStopAndClearsSessions() async throws {
        let fixture = try HostMonitorFixture()
        let client = try HostClient(socketPath: fixture.socket)
        do {
            defer { client.disconnect() }
            _ = try client.createSession(executable: "/bin/cat")
        }
        let monitor = HostMonitor(socketPath: fixture.socket, interval: .milliseconds(20))
        await monitor.start()
        let running = try await monitorSnapshot(from: monitor.snapshots)
        #expect(running?.sessions.count == 1)
        fixture.server.stop()
        let stopped = try await monitorSnapshot(from: monitor.snapshots) { $0.state == .notRunning }
        await monitor.stop()
        #expect(stopped == HostSnapshot(state: .notRunning, sessions: []))
    }

    @Test func refreshWorksBeforeStartAndReportsServiceErrors() async throws {
        let fixture = try HostMonitorFixture(identity: nil)
        let monitor = HostMonitor(socketPath: fixture.socket, interval: .seconds(60))
        await monitor.refresh()
        let snapshot = try await monitorSnapshot(from: monitor.snapshots)
        await monitor.stop()
        #expect(snapshot == HostSnapshot(state: .error(message: "smthzd: identityUnavailable"), sessions: []))
    }

    @Test func stopEndsStreamAndPreventsFurtherRequests() async throws {
        let fixture = try HostMonitorFixture()
        let monitor = HostMonitor(socketPath: fixture.socket, interval: .milliseconds(10))
        await monitor.start()
        await monitor.start() // Idempotent even when invoked before the first poll.
        _ = try await monitorSnapshot(from: monitor.snapshots)
        await monitor.stop()
        let count = try fixture.responseCount()
        #expect(count >= 3)
        await monitor.stop()
        await monitor.start()
        await monitor.refresh()
        // Finish preserves at most one previously buffered snapshot.
        #expect(try await monitorSnapshot(from: monitor.snapshots, matching: { _ in false }) == nil)
        try await Task.sleep(for: .milliseconds(80))
        #expect(try fixture.responseCount() == count)
    }

    @Test func stopBeforeStartFinishesStream() async throws {
        let monitor = HostMonitor(socketPath: "/tmp/smthz-no-monitor-host")
        await monitor.stop()
        await monitor.start()
        await monitor.refresh()
        #expect(try await monitorSnapshot(from: monitor.snapshots) == nil)
    }

    @Test func droppingMonitorCancelsPollingAndFinishesStream() async throws {
        let fixture = try HostMonitorFixture()
        var monitor: HostMonitor? = HostMonitor(socketPath: fixture.socket, interval: .seconds(60))
        weak var weakMonitor = monitor
        let stream = try #require(monitor).snapshots
        await monitor?.start()
        _ = try await monitorSnapshot(from: stream)
        monitor = nil
        // The polling loop must not hold the actor throughout its sleep.
        let deadline = ContinuousClock.now + .seconds(3)
        while weakMonitor != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(weakMonitor == nil)
        #expect(try await monitorSnapshot(from: stream) == nil)
    }
}
