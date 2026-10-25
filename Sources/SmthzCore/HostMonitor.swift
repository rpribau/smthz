import Foundation

/// A value captured by one complete host refresh. Unavailable hosts have no sessions.
public struct HostSnapshot: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case notRunning
        case running(identity: ProcessIdentity, version: String)
        case error(message: String)
    }

    public let state: State
    public let sessions: [SessionInfo]

    public init(state: State, sessions: [SessionInfo]) {
        self.state = state
        self.sessions = sessions
    }
}

/// Serializes synchronous HostClient calls away from UI isolation.
///
/// Consume `snapshots` from a single task. Only the latest unread snapshot is
/// buffered. start() is idempotent and polls immediately; refresh() also works
/// before start(). stop() permanently finishes this monitor and waits for its
/// polling task to exit. A refresh already in progress completes before stop
/// can run, subject to HostClient's existing transport timeouts.
public actor HostMonitor {
    public nonisolated let snapshots: AsyncStream<HostSnapshot>
    private let continuation: AsyncStream<HostSnapshot>.Continuation
    private let socketPath: String
    private let interval: Duration
    private var pollingTask: Task<Void, Never>?
    private var stopped = false

    public init(socketPath: String, interval: Duration = .seconds(1)) {
        precondition(interval > .zero, "Polling interval must be positive")
        self.socketPath = socketPath
        self.interval = interval
        let stream = AsyncStream<HostSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        snapshots = stream.stream
        continuation = stream.continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }
    }

    public func start() {
        guard !stopped, pollingTask == nil else { return }
        let interval = interval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: interval) }
                catch { return }
            }
        }
    }

    public func stop() async {
        stopped = true
        let task = pollingTask
        task?.cancel()
        continuation.finish()
        // Keep the handle until the wait completes so concurrent stop callers
        // all wait for the same task, even across this actor suspension.
        await task?.value
        pollingTask = nil
    }

    public func refresh() {
        guard !stopped else { return }
        let snapshot: HostSnapshot
        do {
            let client = try HostClient(socketPath: socketPath)
            defer { client.disconnect() }
            let identity: ProcessIdentity = try client.call(method: "host.identity", params: Empty())
            let version: Version = try client.call(method: "version", params: Empty())
            let sessions = try client.list().sessions
            snapshot = HostSnapshot(state: .running(identity: identity, version: version.result),
                                    sessions: sessions)
        } catch HostClientError.hostNotRunning {
            snapshot = HostSnapshot(state: .notRunning, sessions: [])
        } catch UnixSocketError.closed {
            snapshot = HostSnapshot(state: .notRunning, sessions: [])
        } catch {
            snapshot = HostSnapshot(state: .error(message: String(describing: error)), sessions: [])
        }
        continuation.yield(snapshot)
    }

    private struct Empty: Encodable {}
    private struct Version: Decodable { let result: String }

    deinit {
        pollingTask?.cancel()
        continuation.finish()
    }
}
