import Foundation
import CryptoKit
import Darwin

/// A local capability stored separately from the socket. Symlinks and permissive
/// files fail closed; a failed token load never disables authentication.
public enum HostCapabilityToken {
    public static func path(socketPath: String) -> String {
        ((socketPath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("capability.token")
    }

    public static func load(path: String, create: Bool = false) throws -> String {
        if create {
            let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 {
                let bytes = Array(random().utf8)
                let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                let success = written == bytes.count && fsync(fd) == 0
                Darwin.close(fd)
                guard success else { unlink(path); throw HostClientError.hostError(code: "authenticationUnavailable") }
            } else if errno != EEXIST {
                throw HostClientError.hostError(code: "authenticationUnavailable")
            }
        }
        let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw HostClientError.hostError(code: "authenticationUnavailable") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1, info.st_size == 64 else {
            throw HostClientError.hostError(code: "authenticationUnavailable")
        }
        var bytes = [UInt8](repeating: 0, count: 65)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count == 64, bytes.prefix(64).allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw HostClientError.hostError(code: "authenticationUnavailable")
        }
        return String(decoding: bytes.prefix(64), as: UTF8.self)
    }

    static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func matches(_ supplied: String?, _ expected: String) -> Bool {
        // Both hashes are fixed length, including for malformed credentials.
        let lhs = Array(SHA256.hash(data: Data((supplied ?? "").utf8)))
        let rhs = Array(SHA256.hash(data: Data(expected.utf8)))
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }
}

public final class HostService: @unchecked Sendable {
    public let router: HostRouter
    private let routedRequests = HostRepoGate()
    private let journal: EventJournal
    public let sessionManager: SessionManager
    public let agentLaunch: AgentLaunchService
    private let hostIdentity: ProcessIdentity?
    private let hostEnvironment: [String: String]
    public let capabilityTokenPath: String
    private let capabilityToken: String?
    private let credential = HostCapabilityToken.random()
    private let stateLock = NSLock()
    private var active: [UUID: Control] = [:]
    private var subscribers = 0
    public var activeSubscriberCount: Int { stateLock.withLock { subscribers } }
    public static let maximumSubscribers = 64
    public static let streamChunkBytes = 65_536
    public static let maximumPendingRequests = 64
    public static let maximumRequestBytes = 700_000
    public static let maximumTimeoutMilliseconds = 30_000

    private final class Control: @unchecked Sendable {
        let requestID: String
        let processControl = GitProcessControl()
        let deadline: DispatchTime
        private let deadlineTimer: DispatchSourceTimer
        private let lock = NSLock()
        private var cancelled = false
        init(requestID: String, milliseconds: Int) {
            self.requestID = requestID
            deadline = .now() + .milliseconds(milliseconds)
            deadlineTimer = DispatchSource.makeTimerSource(queue: .global())
            deadlineTimer.schedule(deadline: deadline)
            deadlineTimer.setEventHandler { [processControl] in processControl.cancel() }
            deadlineTimer.resume()
        }
        deinit { deadlineTimer.cancel() }
        func cancel() { lock.withLock { cancelled = true }; processControl.cancel() }
        var error: String? {
            let result: String? = lock.withLock {
                if cancelled { return "cancelled" }
                return DispatchTime.now() >= deadline ? "deadlineExceeded" : nil
            }
            if result != nil { processControl.cancel() }
            return result
        }
    }
    // Serialize lookup, execution, and append across concurrent socket clients.
    private let lock = NSLock()
    private var stopped = false
    private let scrollbackDirectory: URL?
    private let onShutdown: (@Sendable () -> Void)?
    private var shutdownRequested = false
    private var shutdownDelivered = false

    public init(journal: EventJournal, hostIdentity: ProcessIdentity?, sessionManager: SessionManager? = nil, capabilityTokenPath: String? = nil,
                hostEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                scrollbackDirectory: URL? = nil, router: HostRouter = HostRouter(), agentSocketPath: String? = nil,
                agentStateDirectory: URL? = nil,
                onShutdown: (@Sendable () -> Void)? = nil) {
        self.router = router
        self.scrollbackDirectory = scrollbackDirectory
        self.onShutdown = onShutdown
        self.hostEnvironment = hostEnvironment
        let tokenPath = capabilityTokenPath ?? ((journal.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("capability.token")
        self.capabilityTokenPath = tokenPath
        self.capabilityToken = try? HostCapabilityToken.load(path: tokenPath, create: true)
        self.journal = journal
        let sessions = sessionManager ?? SessionManager(journal: journal)
        self.sessionManager = sessions
        let stateDirectory = agentStateDirectory ?? URL(fileURLWithPath: journal.path).deletingLastPathComponent()
        let launcher = AgentLaunchService(sessions: sessions, stateDirectory: stateDirectory,
            socketPath: agentSocketPath ?? stateDirectory.appendingPathComponent("smthzd.sock").path,
            environment: hostEnvironment)
        self.agentLaunch = launcher
        self.hostIdentity = hostIdentity
        router.register("agent.list", methodClass: .read) { _, context in
            let detected = try launcher.list(checkCancellation: { try context.checkCancellation() })
            return ["agents": .array(detected.map { agent in
                .object(["id": .string(agent.id.rawValue), "executable": .string(agent.executable),
                         "version": agent.version.map(HostJSON.string) ?? .null])
            })]
        }
        router.register("agent.launch", methodClass: .mutation, repository: { _ in nil }) { params, context in
            let request = try JSONDecoder().decode(AgentLaunchRequest.self, from: JSONEncoder().encode(params))
            let session = try launcher.launch(request, checkCancellation: { try context.checkCancellation() })
            return try JSONDecoder().decode([String: HostJSON].self, from: JSONEncoder().encode(session))
        }
        router.register("agent.hook", methodClass: .mutation, repository: { _ in nil }) { params, _ in
            guard let id = params["sessionID"]?.string,
                  let source = params["source"]?.string.flatMap(AgentHookSource.init(rawValue:)),
                  let json = params["payload"] else { throw HostRPCError("badRequest") }
            let payload: AgentHookPayload
            do { payload = try AgentHookPayload(source: source, json: JSONEncoder().encode(json)) }
            catch { throw HostRPCError("badRequest") }
            sessions.applyAgentHook(payload, sessionID: id)
            return [:]
        }
        for method in ["agent.status.list", "agent.status.subscribe"] {
            router.register(method, methodClass: .read, repository: { _ in nil }) { params, _ in
                guard params.isEmpty else { throw HostRPCError("badRequest") }
                return try Self.agentStatusFields(sessions)
            }
        }
    }

    private static func agentStatusFields(_ sessions: SessionManager) throws -> [String: HostJSON] {
        let rows = sessions.agentStatusRows().map(HostAgentStatusRow.init)
        return ["statuses": try JSONDecoder().decode(HostJSON.self, from: JSONEncoder().encode(rows))]
    }

    /// Consumes a dedicated connection. Socket writes provide back-pressure;
    /// subscriber state is only a cursor, never an unbounded queue of PTY bytes.
    public func stream(_ payload: Data, send: (Data) throws -> Void, cancelled: () -> Bool) -> Bool {
        guard let request = try? JSONDecoder().decode(RPCEnvelope.self, from: payload),
              ["session.subscribe", "agent.status.subscribe"].contains(request.method) else { return false }
        let admitted = stateLock.withLock {
            guard subscribers < Self.maximumSubscribers else { return false }
            subscribers += 1
            return true
        }
        guard admitted else {
            try? send(response(to: request, body: Body(ok: false, error: "limitExceeded")))
            return true
        }
        defer { stateLock.withLock { subscribers -= 1 } }
        do {
            let acknowledgement = handle(payload)
            try send(acknowledgement)
            let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: acknowledgement)
            struct Status: Decodable { let ok: Bool }
            guard try JSONDecoder().decode(Status.self, from: envelope.payload).ok else { return true }
            if request.method == "agent.status.subscribe" {
                struct Snapshot: Decodable { let statuses: [HostAgentStatusRow] }
                var previous = try JSONDecoder().decode(Snapshot.self, from: envelope.payload).statuses
                // Initial state is already in the acknowledgement. Poll bounded shared
                // state, never enqueue an unbounded history for a slow subscriber.
                while !cancelled() && !stateLock.withLock({ stopped }) {
                    Thread.sleep(forTimeInterval: 0.025)
                    let rows = sessionManager.agentStatusRows().map(HostAgentStatusRow.init)
                    if rows != previous {
                        var fields = try Self.agentStatusFields(sessionManager)
                        fields["ok"] = .bool(true)
                        try send(JSONEncoder().encode(RPCEnvelope(version: RPCEnvelope.currentVersion,
                            requestID: request.requestID, method: request.method,
                            payload: JSONEncoder().encode(fields))))
                        previous = rows
                    }
                }
                return true
            }
            let params = try JSONDecoder().decode(SubscribeParams.self, from: request.payload)
            var cursor = params.fromCursor
            while !cancelled() {
                guard try sessionManager.waitForOutput(id: params.id, from: cursor, cancelled: cancelled) else { break }
                let result = try sessionManager.read(id: params.id, from: cursor, maxBytes: Self.streamChunkBytes)
                // An exit is delivered separately after every final output byte.
                var exit: ExitBody?
                if result.data.isEmpty {
                    switch result.exit {
                    case .exited(let code): exit = ExitBody(code: code)
                    case .signaled(let signal): exit = ExitBody(signal: signal)
                    case nil: break
                    }
                }
                try send(response(to: request, body: Body(ok: true,
                    data_base64: result.data.base64EncodedString(), next: result.nextOffset,
                    truncated: result.truncated, exit: exit)))
                cursor = result.nextOffset
                if exit != nil { break }
            }
        } catch let error as SessionError {
            try? send(response(to: request, body: Body(ok: false, error: error.rawValue)))
        } catch { /* Disconnect or deadline: a new subscriber resumes from its own cursor. */ }
        return true
    }

    public func handle(_ payload: Data) -> Data {
        guard let request = try? JSONDecoder().decode(RPCEnvelope.self, from: payload) else {
            return response(to: RPCEnvelope(version: 1, requestID: "", method: "", payload: Data()),
                            body: Body(ok: false, error: "badRequest"))
        }
        guard request.version == RPCEnvelope.currentVersion else {
            return response(to: request, body: Body(ok: false, error: "protocolVersionMismatch"))
        }
        guard !request.requestID.isEmpty, request.requestID.utf8.count <= 128,
              request.method.utf8.count <= 128, request.payload.count <= Self.maximumRequestBytes,
              payload.count <= RPCFrameCodec.maxFrameSize else {
            return response(to: request, body: Body(ok: false, error: "badRequest"))
        }
        guard let capabilityToken else {
            return response(to: request, body: Body(ok: false, error: "authenticationUnavailable"))
        }
        if request.method == "handshake" {
            struct Handshake: Decodable { let token: String }
            guard let params = try? JSONDecoder().decode(Handshake.self, from: request.payload),
                  HostCapabilityToken.matches(params.token, capabilityToken) else {
                return response(to: request, body: Body(ok: false, error: "unauthorized"))
            }
            return response(to: request, body: Body(ok: true, credential: credential))
        }
        if request.method == "agent.hook" {
            // Hook credentials are scoped to this live launch and this method only.
            guard let params = try? JSONDecoder().decode([String: HostJSON].self, from: request.payload),
                  let id = params["sessionID"]?.string, let token = request.authorization,
                  let scope = agentLaunch.scope(sessionID: id, hookToken: token),
                  params["agent"]?.string == scope.agent.rawValue,
                  HostCapabilityToken.matches(params["launchToken"]?.string, scope.launchToken),
                  let source = params["source"]?.string,
                  source == (scope.agent == .codex ? "codex" : "claude") else {
                return response(to: request, body: Body(ok: false, error: "unauthorized"))
            }
        } else if !HostCapabilityToken.matches(request.authorization, credential) {
            return response(to: request, body: Body(ok: false, error: "unauthorized"))
        }
        let timeout = request.timeoutMilliseconds ?? 5_000
        guard (1...Self.maximumTimeoutMilliseconds).contains(timeout) else {
            return response(to: request, body: Body(ok: false, error: "limitExceeded"))
        }
        if request.method == "session.subscribe" {
            do {
                let params = try JSONDecoder().decode(SubscribeParams.self, from: request.payload)
                _ = try sessionManager.read(id: params.id, from: params.fromCursor, maxBytes: 1)
                return response(to: request, body: Body(ok: true))
            } catch {
                return response(to: request, body: Body(ok: false, error: (error as? SessionError)?.rawValue ?? "badRequest"))
            }
        }
        if request.method == "request.cancel" {
            struct Cancel: Decodable { let requestID: String }
            guard let params = try? JSONDecoder().decode(Cancel.self, from: request.payload) else {
                return response(to: request, body: Body(ok: false, error: "badRequest"))
            }
            let found = stateLock.withLock {
                let targets = active.values.filter { $0.requestID == params.requestID }
                targets.forEach { $0.cancel() }
                return !targets.isEmpty
            }
            return response(to: request, body: Body(ok: true, cancelled: found))
        }
        let control = Control(requestID: request.requestID, milliseconds: timeout)
        let ticket = UUID()
        let admitted = stateLock.withLock {
            guard active.count < Self.maximumPendingRequests else { return false }
            active[ticket] = control
            return true
        }
        guard admitted else { return response(to: request, body: Body(ok: false, error: "limitExceeded")) }
        defer { _ = stateLock.withLock { active.removeValue(forKey: ticket) } }
        let route = router.route(request.method)
        let isRead = route?.methodClass == .read || ["ping", "version", "host.identity", "session.list", "session.read", "session.replay", "session.foreground"].contains(request.method)
        if isRead { return handleAdmitted(request, control: control) }
        do {
            return try routedRequests.withGate(request.requestID, cancellation: { control.error }) {
                handleAdmitted(request, control: control)
            }
        } catch { return routedError(request, error: error) }
    }

    private func handleAdmitted(_ request: RPCEnvelope, control: Control) -> Data {
        if let error = control.error { return response(to: request, body: Body(ok: false, error: error)) }
        guard !stateLock.withLock({ stopped }) else { return response(to: request, body: Body(ok: false, error: "hostStopping")) }
        if let route = router.route(request.method) {
            return routedResponse(request, route: route, control: control)
        }
        // Live reads never queue behind the host's mutation or journal locks.
        if ["ping", "version", "host.identity", "session.list", "session.read", "session.replay", "session.foreground"].contains(request.method) {
            switch request.method {
            case "ping": return response(to: request, body: Body(ok: true, result: "pong"))
            case "version": return response(to: request, body: Body(ok: true, result: ApplicationIdentity.version))
            case "host.identity":
                guard let identity = hostIdentity else { return response(to: request, body: Body(ok: false, error: "identityUnavailable")) }
                return response(to: request, body: Body(ok: true, pid: identity.pid, startSeconds: identity.startSeconds, startMicroseconds: identity.startMicroseconds))
            default: return response(to: request, body: sessionResponse(request, control: control))
            }
        }
        guard ["session.create", "session.write", "session.resize", "session.close", "host.shutdown"].contains(request.method) else {
            return response(to: request, body: Body(ok: false, error: "unknownMethod"))
        }
        // Cancellable lock acquisition bounds queue wait without dispatching detached work.
        while !lock.try() {
            if let error = control.error { return response(to: request, body: Body(ok: false, error: error)) }
            Thread.sleep(forTimeInterval: 0.001)
        }
        defer { lock.unlock() }
        guard !stateLock.withLock({ stopped }) else { return response(to: request, body: Body(ok: false, error: "hostStopping")) }
        while !sessionManager.journalLock.try() {
            if let error = control.error { return response(to: request, body: Body(ok: false, error: error)) }
            Thread.sleep(forTimeInterval: 0.001)
        }
        defer { sessionManager.journalLock.unlock() }
        if let error = control.error { return response(to: request, body: Body(ok: false, error: error)) }
        let paramsHash = Self.paramsHash(request.payload)
        var createdID: String?
        do {
            if let entry = try journal.entry(requestID: request.requestID) {
                guard try journal.matchesRequest(requestID: request.requestID, method: request.method, paramsHash: paramsHash) else {
                    return response(to: request, body: Body(ok: false, error: "idempotencyConflict"))
                }
                return entry.payload
            }
            let body: Body
            switch request.method {
            case let method where method.hasPrefix("session."):
                body = sessionResponse(request, control: control)
                if request.method == "session.create", body.ok { createdID = body.id }
            case "host.shutdown":
                if let params = try JSONSerialization.jsonObject(with: request.payload) as? [String: Any], params.isEmpty {
                    body = Body(ok: true)
                } else {
                    body = Body(ok: false, error: "badRequest")
                }
            case "ping":
                body = Body(ok: true, result: "pong")
            case "version":
                body = Body(ok: true, result: ApplicationIdentity.version)
            case "host.identity":
                if let identity = hostIdentity {
                    body = Body(ok: true, pid: identity.pid, startSeconds: identity.startSeconds,
                                startMicroseconds: identity.startMicroseconds)
                } else {
                    body = Body(ok: false, error: "identityUnavailable")
                }
            default:
                body = Body(ok: false, error: "unknownMethod")
            }
            let encoded = response(to: request, body: body)
            guard encoded.count <= RPCFrameCodec.maxFrameSize else {
                if let createdID { sessionManager.discard(id: createdID) }
                return response(to: request, body: Body(ok: false, error: "limitExceeded"))
            }
            try journal.appendResponse(requestID: request.requestID, method: request.method,
                                       paramsHash: paramsHash, payload: encoded)
            if request.method == "host.shutdown", body.ok { shutdownRequested = true }
            return encoded
        } catch {
            if let createdID { sessionManager.discard(id: createdID) }
            return response(to: request, body: Body(ok: false, error: "journalFailure"))
        }
    }

    private func routedResponse(_ request: RPCEnvelope, route: HostRouter.Route, control: Control) -> Data {
        let context = HostRequestContext(requestID: request.requestID, processControl: control.processControl,
            cancellationError: { [self] in stateLock.withLock({ stopped }) ? "hostStopping" : control.error })
        func invoke() throws -> Data {
            try context.checkCancellation()
            let params = try JSONDecoder().decode([String: HostJSON].self, from: request.payload)
            let fields = try router.repoGate.withGate(route.methodClass == .mutation ? route.repository(params) : nil,
                                                     cancellation: { control.error }) {
                try route.handler(params, context)
            }
            var body = fields; body["ok"] = .bool(true)
            let envelope = RPCEnvelope(version: RPCEnvelope.currentVersion, requestID: request.requestID,
                                       method: request.method, payload: try JSONEncoder().encode(body))
            let result = try JSONEncoder().encode(envelope)
            guard result.count <= RPCFrameCodec.maxFrameSize else { throw HostRPCError("limitExceeded") }
            return result
        }
        do {
            if route.methodClass == .read { return try invoke() }
            do {
                let hash = Self.paramsHash(request.payload)
                while !sessionManager.journalLock.try() {
                    try context.checkCancellation(); Thread.sleep(forTimeInterval: 0.001)
                }
                do {
                    if let entry = try journal.entry(requestID: request.requestID) {
                        guard try journal.matchesRequest(requestID: request.requestID, method: request.method, paramsHash: hash) else {
                            throw HostRPCError("idempotencyConflict")
                        }
                        sessionManager.journalLock.unlock()
                        return entry.payload
                    }
                    sessionManager.journalLock.unlock()
                } catch { sessionManager.journalLock.unlock(); throw error }
                let result: Data
                do { result = try invoke() }
                catch where control.error != nil { throw HostRPCError(control.error ?? "cancelled") }
                catch let error as HostRPCError where ["cancelled", "deadlineExceeded", "hostStopping"].contains(error.code) { throw error }
                catch { result = routedError(request, error: error) }
                // Once a mutation has committed, store its result even if cancellation
                // arrives during the append; retry must not repeat the side effect.
                sessionManager.journalLock.lock()
                defer { sessionManager.journalLock.unlock() }
                try journal.appendResponse(requestID: request.requestID, method: request.method, paramsHash: hash, payload: result)
                return result
            }
        } catch { return routedError(request, error: error) }
    }

    private func routedError(_ request: RPCEnvelope, error: any Error) -> Data {
        let rpc: HostRPCError
        if let e = error as? HostRPCError { rpc = e }
        else if let e = error as? GitError {
            switch e {
            case .authenticationRequired(let detail): rpc = HostRPCError("authenticationRequired", detail: detail)
            case .cancelled: rpc = HostRPCError("cancelled")
            case .timedOut: rpc = HostRPCError("deadlineExceeded")
            case .commandFailed(_, let detail): rpc = HostRPCError("gitFailed", detail: detail)
            default: rpc = HostRPCError("gitFailed", detail: String(describing: e))
            }
        }
        else if error is JournalError { rpc = HostRPCError("journalFailure") }
        else if error is DecodingError { rpc = HostRPCError("badRequest") }
        else { rpc = HostRPCError("gitFailed", detail: String(describing: error)) }
        return response(to: request, body: Body(ok: false, error: rpc.code, detail: rpc.detail))
    }

    /// Called by the transport only after a complete reply frame has been written.
    /// Scheduling is injected by the daemon so teardown runs on its main queue.
    public func responseFlushed(_ payload: Data) {
        guard let envelope = try? JSONDecoder().decode(RPCEnvelope.self, from: payload),
              envelope.method == "host.shutdown",
              let object = try? JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any],
              object["ok"] as? Bool == true else { return }
        let callback: (@Sendable () -> Void)? = lock.withLock {
            guard shutdownRequested, !shutdownDelivered, !stopped else { return nil }
            shutdownDelivered = true
            return onShutdown
        }
        callback?()
    }

    /// Completes session teardown before the daemon removes its socket.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        let controls = stateLock.withLock { stopped = true; return Array(active.values) }
        controls.forEach { $0.cancel() }
        router.jobs.stop()
        sessionManager.stop()
    }

    deinit { stop() }

    private struct Body: Encodable {
        let ok: Bool
        var credential: String? = nil
        var cancelled: Bool? = nil
        var result: String? = nil
        var error: String? = nil
        var detail: String? = nil
        var pid: Int32? = nil
        var startSeconds: UInt64? = nil
        var startMicroseconds: UInt64? = nil
        var id: String? = nil
        var running: Bool? = nil
        var executable: String? = nil
        var arguments: [String]? = nil
        var cwd: String? = nil
        var createdAt: Double? = nil
        var pgid: Int32? = nil
        var isShell: Bool? = nil
        var sessions: [SessionInfo]? = nil
        var data_base64: String? = nil
        var next: UInt64? = nil
        var eof: Bool? = nil
        var truncated: Bool? = nil
        var exit: ExitBody? = nil
    }

    private struct ExitBody: Encodable {
        var code: Int32? = nil
        var signal: Int32? = nil
    }

    private struct CreateParams: Decodable {
        let executable: String
        let arguments: [String]
        var environment: [String: String]?
        var cwd: String?
        var rows: Int?
        var cols: Int?
    }
    private struct SubscribeParams: Decodable { let id: String; let fromCursor: UInt64 }
    private struct IDParams: Decodable { let id: String }
    private struct WriteParams: Decodable { let id: String; let data_base64: String }
    private struct ResizeParams: Decodable { let id: String; let rows: Int; let cols: Int }
    private struct ReadParams: Decodable { let id: String; let from: UInt64; var maxBytes: Int? }

    private func sessionResponse(_ request: RPCEnvelope, control: Control) -> Body {
        let decoder = JSONDecoder()
        do {
            switch request.method {
            case "session.create":
                let p = try decoder.decode(CreateParams.self, from: request.payload)
                let info = try sessionManager.create(executable: p.executable, arguments: p.arguments,
                    environment: SessionEnvironment.build(base: hostEnvironment,
                                                          override: p.environment),
                    workingDirectory: p.cwd, rows: p.rows ?? 24, cols: p.cols ?? 80)
                return Body(ok: true, pid: info.pid, startSeconds: info.startSeconds,
                            startMicroseconds: info.startMicroseconds, id: info.id, running: info.running,
                            executable: info.executable, arguments: info.arguments, cwd: info.cwd,
                            createdAt: info.createdAt)
            case "session.foreground":
                let p = try decoder.decode(IDParams.self, from: request.payload)
                let foreground = try sessionManager.foreground(id: p.id)
                return Body(ok: true, pid: foreground.pid, executable: foreground.executable,
                            pgid: foreground.pgid, isShell: foreground.isShell)
            case "session.write":
                let p = try decoder.decode(WriteParams.self, from: request.payload)
                guard p.data_base64.utf8.count <= ((SessionManager.maximumTransferBytes + 2) / 3) * 4,
                      let data = Data(base64Encoded: p.data_base64),
                      data.count <= SessionManager.maximumTransferBytes else { throw SessionError.badRequest }
                try sessionManager.write(id: p.id, data: data, shouldCancel: { control.error != nil })
                return Body(ok: true)
            case "session.resize":
                let p = try decoder.decode(ResizeParams.self, from: request.payload)
                try sessionManager.resize(id: p.id, rows: p.rows, cols: p.cols)
                return Body(ok: true)
            case "session.read":
                let p = try decoder.decode(ReadParams.self, from: request.payload)
                let limit = p.maxBytes ?? SessionManager.maximumTransferBytes
                guard limit > 0 else { throw SessionError.badRequest }
                // JSON Data in the envelope adds a second layer of base64. Leave
                // room for both layers and metadata within the 1 MiB frame.
                let result = try sessionManager.read(id: p.id, from: p.from, maxBytes: min(limit, 512 * 1024))
                var exit: ExitBody?
                switch result.exit {
                case .exited(let code): exit = ExitBody(code: code)
                case .signaled(let signal): exit = ExitBody(signal: signal)
                case nil: break
                }
                return Body(ok: true, data_base64: result.data.base64EncodedString(), next: result.nextOffset,
                            truncated: result.truncated, exit: exit)
            case "session.replay":
                let p = try decoder.decode(ReadParams.self, from: request.payload)
                guard UUID(uuidString: p.id)?.uuidString.lowercased() == p.id,
                      (p.maxBytes ?? SessionManager.maximumTransferBytes) > 0 else { throw SessionError.badRequest }
                let limit = min(p.maxBytes ?? SessionManager.maximumTransferBytes, 512 * 1024)
                // A live writer must be read under the manager's record lock.
                if sessionManager.list().contains(where: { $0.id == p.id }) {
                    let result = try sessionManager.read(id: p.id, from: p.from, maxBytes: limit)
                    let tail = try sessionManager.read(id: p.id, from: result.nextOffset, maxBytes: 1)
                    return Body(ok: true, data_base64: result.data.base64EncodedString(),
                                next: result.nextOffset, eof: tail.data.isEmpty)
                }
                guard let directory = scrollbackDirectory else { throw SessionError.unknownSession }
                var metadata = stat()
                let path = directory.appendingPathComponent(p.id + ".scrollback").path
                if lstat(path, &metadata) != 0 {
                    throw errno == ENOENT ? SessionError.unknownSession : SessionError.scrollbackFailure
                }
                let result = try SessionManager.readScrollback(id: p.id, directory: directory, from: p.from, maxBytes: limit)
                let tail = try SessionManager.readScrollback(id: p.id, directory: directory, from: result.nextOffset, maxBytes: 1)
                return Body(ok: true, data_base64: result.data.base64EncodedString(),
                            next: result.nextOffset, eof: tail.data.isEmpty)
            case "session.close":
                let p = try decoder.decode(IDParams.self, from: request.payload)
                try sessionManager.close(id: p.id)
                return Body(ok: true)
            case "session.list":
                guard let params = try JSONSerialization.jsonObject(with: request.payload) as? [String: Any],
                      params.isEmpty else { throw SessionError.badRequest }
                return Body(ok: true, sessions: sessionManager.list())
            default:
                return Body(ok: false, error: "unknownMethod")
            }
        } catch let error as SessionError {
            return Body(ok: false, error: control.error ?? error.rawValue)
        } catch {
            return Body(ok: false, error: "badRequest")
        }
    }

    private static func paramsHash(_ payload: Data) -> String {
        // Normalize JSON object key order so equivalent retries share a binding.
        let canonical: Data
        if let object = try? JSONSerialization.jsonObject(with: payload, options: [.fragmentsAllowed]),
           let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) {
            canonical = normalized
        } else { canonical = payload }
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    private func response(to request: RPCEnvelope, body: Body) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // These synthesized Encodable types contain only finite integers, strings,
        // booleans, and Data, so encoding cannot encounter an invalid JSON value.
        do {
            let envelope = RPCEnvelope(version: RPCEnvelope.currentVersion, requestID: request.requestID,
                                       method: request.method, payload: try encoder.encode(body))
            return try encoder.encode(envelope)
        } catch {
            return Data(#"{"version":1,"requestID":"","method":"","payload":"eyJvayI6ZmFsc2UsImVycm9yIjoiam91cm5hbEZhaWx1cmUifQ=="}"#.utf8)
        }
    }
}
