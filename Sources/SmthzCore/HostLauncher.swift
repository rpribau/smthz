import Darwin
import Dispatch
import Foundation

public struct HostEndpoint: Sendable, Equatable {
    public let stateDirectory: URL
    public let logPath: String
    public var socketPath: String { stateDirectory.appendingPathComponent("smthzd.sock").path }

    public init(stateDirectory: URL, logPath: String? = nil) {
        self.stateDirectory = stateDirectory
        self.logPath = logPath ?? stateDirectory.appendingPathComponent("smthzd.log").path
    }

    public static func standard(home: URL) -> HostEndpoint {
        HostEndpoint(stateDirectory: ApplicationIdentity.applicationSupportDirectory(home: home),
                     logPath: home.appendingPathComponent("Library/Logs/smthz/smthzd.log").path)
    }
}

public enum HostLaunchState: Equatable, Sendable {
    case running(identity: ProcessIdentity, version: String, compatible: Bool)
    case startedByUs(identity: ProcessIdentity)
    case unreachable(reason: String)
    case throttled(retryAfter: Duration)
    case failed(exitStatus: Int32?, logTail: String)
}

public enum HostLauncherError: Error, Equatable, Sendable {
    case identityMismatch
    case timeout
    case system(Int32)
    case invalidResponse
}

/// Lifecycle operations are serialized on a dedicated queue; blocking socket I/O
/// and process waits never occupy the main actor or a cooperative executor thread.
public actor HostLauncher {
    private let queue = DispatchQueue(label: "dev.smthz.host-launcher")
    private let worker: HostLaunchWorker

    public init(endpoint: HostEndpoint, executable: URL,
                appVersion: String = ApplicationIdentity.version,
                throttle: (attempts: Int, window: Duration) = (3, .seconds(60))) {
        worker = HostLaunchWorker(endpoint: endpoint, executable: executable,
                                  appVersion: appVersion, throttle: throttle)
    }

    public func ensureRunning(timeout: Duration = .seconds(5)) async -> HostLaunchState {
        let worker = worker
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: worker.ensureRunning(timeout: timeout)) }
        }
    }

    public func stop(expected: ProcessIdentity, timeout: Duration = .seconds(5)) async throws {
        let worker = worker
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do { try worker.stop(expected: expected, timeout: timeout); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

// Mutable fields are accessed exclusively by HostLauncher's serial queue.
private final class HostLaunchWorker: @unchecked Sendable {
    let endpoint: HostEndpoint
    let executable: URL
    let appVersion: String
    let throttle: (attempts: Int, window: Duration)
    var attempts: [ContinuousClock.Instant] = []
    // A readiness deadline does not end the child's lifetime. Retain ownership
    // across retries, including the interval before smthzd acquires its lock.
    var launchedChild: LaunchChild?
    let clock = ContinuousClock()

    init(endpoint: HostEndpoint, executable: URL, appVersion: String,
         throttle: (attempts: Int, window: Duration)) {
        self.endpoint = endpoint
        self.executable = executable
        self.appVersion = appVersion
        self.throttle = throttle
    }

    private enum Probe {
        case absent
        case running(ProcessIdentity, String)
        case unreachable(String)
    }

    private struct Reply: Decodable {
        let ok: Bool
        let error: String?
        let credential: String?
        let result: String?
        let pid: Int32?
        let startSeconds: UInt64?
        let startMicroseconds: UInt64?
    }

    /// Uses the same authenticated RPC as HostClient, with a shared operation
    /// deadline (HostClient's initializer has a fixed handshake timeout).
    private func call(_ method: String, payload: Data = Data("{}".utf8),
                      credential: String? = nil, client: UnixSocketClient,
                      deadline: ContinuousClock.Instant) throws -> Reply {
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else { throw HostLauncherError.timeout }
        let parts = remaining.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        let request = RPCEnvelope(version: RPCEnvelope.currentVersion, requestID: RequestID.generate().rawValue,
                                  method: method, payload: payload, authorization: credential)
        let response = try JSONDecoder().decode(RPCEnvelope.self,
            from: client.request(JSONEncoder().encode(request), timeout: seconds))
        guard response.version == request.version, response.requestID == request.requestID,
              response.method == request.method else { throw HostLauncherError.invalidResponse }
        let reply = try JSONDecoder().decode(Reply.self, from: response.payload)
        guard reply.ok else { throw HostClientError.hostError(code: reply.error ?? "unknownError") }
        return reply
    }

    private func authenticate(_ client: UnixSocketClient, deadline: ContinuousClock.Instant) throws -> String {
        let token = try HostCapabilityToken.load(path: HostCapabilityToken.path(socketPath: endpoint.socketPath))
        let payload = try JSONEncoder().encode(["token": token])
        return try call("handshake", payload: payload, client: client, deadline: deadline).credential
            ?? { throw HostLauncherError.invalidResponse }()
    }

    private func identity(_ client: UnixSocketClient, credential: String,
                          deadline: ContinuousClock.Instant) throws -> ProcessIdentity {
        let reply = try call("host.identity", credential: credential, client: client, deadline: deadline)
        guard let pid = reply.pid, pid > 0, let seconds = reply.startSeconds,
              let micros = reply.startMicroseconds else { throw HostLauncherError.invalidResponse }
        return ProcessIdentity(pid: pid, startSeconds: seconds, startMicroseconds: micros)
    }

    private func probe(deadline: ContinuousClock.Instant) -> Probe {
        let client: UnixSocketClient
        do { client = try UnixSocketClient(path: endpoint.socketPath) }
        catch UnixSocketError.connectFailed(let code) where code == ENOENT || code == ECONNREFUSED { return .absent }
        catch { return .unreachable(String(describing: error)) }
        defer { client.close() }
        do {
            let credential = try authenticate(client, deadline: deadline)
            guard try call("ping", credential: credential, client: client, deadline: deadline).result == "pong" else {
                throw HostLauncherError.invalidResponse
            }
            let id = try identity(client, credential: credential, deadline: deadline)
            guard id.isStillRunning(), let version = try call("version", credential: credential,
                client: client, deadline: deadline).result else { throw HostLauncherError.invalidResponse }
            return .running(id, version)
        } catch { return .unreachable(String(describing: error)) }
    }

    func ensureRunning(timeout: Duration) -> HostLaunchState {
        let deadline = clock.now.advanced(by: max(.zero, timeout))
        switch probe(deadline: deadline) {
        case .running(let id, let version):
            return .running(identity: id, version: version, compatible: version == appVersion)
        case .unreachable(let reason): return .unreachable(reason: reason)
        case .absent: break
        }
        guard clock.now < deadline else { return .unreachable(reason: "Host probe deadline expired") }
        let child: LaunchChild
        if let pending = launchedChild, pending.exitStatus == nil,
           pending.identity?.isStillRunning() ?? true {
            // Socket absence alone cannot prove our previous launch is dead.
            // Reuse the same initializer instead of creating another process.
            child = pending
        } else {
            attempts.removeAll { $0.duration(to: clock.now) >= throttle.window }
            guard attempts.count < max(0, throttle.attempts) else {
                return .throttled(retryAfter: attempts.first.map { max(.zero, $0.advanced(by: throttle.window) - clock.now) }
                                  ?? max(.zero, throttle.window))
            }
            attempts.append(clock.now)
            do {
                child = try spawn()
                launchedChild = child
            } catch { return .failed(exitStatus: nil, logTail: logTail() + "\n" + String(describing: error)) }
        }
        repeat {
            // A competing launcher can win the lock; probe its healthy endpoint
            // even if our child exited with the single-instance status.
            if case .running(let id, let version) = probe(deadline: deadline) {
                if id.pid == child.pid { return .startedByUs(identity: id) }
                return .running(identity: id, version: version, compatible: version == appVersion)
            }
            if let status = child.exitStatus { return .failed(exitStatus: status, logTail: logTail()) }
            Thread.sleep(forTimeInterval: 0.025)
        } while clock.now < deadline
        // Do not signal or unlink an endpoint whose readiness is unknown.
        return .failed(exitStatus: child.exitStatus, logTail: logTail())
    }

    func stop(expected: ProcessIdentity, timeout: Duration) throws {
        guard expected.isStillRunning() else { throw HostLauncherError.identityMismatch }
        let deadline = clock.now.advanced(by: max(.zero, timeout))
        var acknowledged = false
        do {
            let client = try UnixSocketClient(path: endpoint.socketPath)
            defer { client.close() }
            let credential = try authenticate(client, deadline: deadline)
            guard try identity(client, credential: credential, deadline: deadline) == expected,
                  expected.isStillRunning() else { throw HostLauncherError.identityMismatch }
            _ = try call("host.shutdown", credential: credential, client: client, deadline: deadline)
            acknowledged = true
        } catch HostLauncherError.identityMismatch { throw HostLauncherError.identityMismatch }
        catch { /* Only the verified identity below may receive the fallback. */ }
        if !acknowledged {
            if !expected.isStillRunning() { return }
            guard Darwin.kill(expected.pid, SIGTERM) == 0 else {
                if errno == ESRCH { return }
                throw HostLauncherError.system(errno)
            }
        }
        while expected.isStillRunning(), clock.now < deadline { Thread.sleep(forTimeInterval: 0.025) }
        guard !expected.isStillRunning() else { throw HostLauncherError.timeout }
    }

    private func logTail() -> String {
        guard let handle = FileHandle(forReadingAtPath: endpoint.logPath) else { return "" }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end > 8192 ? end - 8192 : 0)
            return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        } catch { return "" }
    }

    private func spawn() throws -> LaunchChild {
        try FileManager.default.createDirectory(at: endpoint.stateDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(atPath: (endpoint.logPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let log = Darwin.open(endpoint.logPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard log >= 0 else { throw HostLauncherError.system(errno) }
        defer { Darwin.close(log) }
        guard fchmod(log, 0o600) == 0 else { throw HostLauncherError.system(errno) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func check(_ result: Int32) throws { if result != 0 { throw HostLauncherError.system(result) } }
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, log, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, log, STDERR_FILENO))
        let arguments = [executable.path, "--state-dir", endpoint.stateDirectory.path].map { strdup($0)! }
        var environment = ProcessInfo.processInfo.environment
        environment["SMTHZ_LAUNCHED_BY"] = "app"
        let variables = environment.map { strdup("\($0.key)=\($0.value)")! }
        defer { for item in arguments + variables { free(item) } }
        var argv: [UnsafeMutablePointer<CChar>?] = arguments + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = variables + [nil]
        var pid: pid_t = 0
        try check(posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp))
        return LaunchChild(pid: pid)
    }
}

/// A dedicated waiter reaps every spawned child, including hosts that outlive
/// their launcher. No deinit hook terminates the independently owned host.
private final class LaunchChild: @unchecked Sendable {
    let pid: pid_t
    // waitpid can reap the child before its waiter publishes status. The full
    // identity lets a retry recognize that gap without trusting a recycled pid.
    let identity: ProcessIdentity?
    private let lock = NSLock()
    private var status: Int32?
    var exitStatus: Int32? { lock.withLock { status } }

    init(pid: pid_t) {
        self.pid = pid
        identity = ProcessIdentity.lookup(pid: pid)
        Thread.detachNewThread { [self] in
            var raw: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &raw, 0) } while result < 0 && errno == EINTR
            let code: Int32 = result < 0 ? -1 : ((raw & 0x7f) == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f))
            lock.withLock { status = code }
        }
    }
}
