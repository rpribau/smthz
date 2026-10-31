import Foundation

public enum HostClientError: Error, Equatable, Sendable, CustomStringConvertible {
    case hostNotRunning
    case hostError(code: String)
    case detailedHostError(code: String, detail: String?)
    case invalidResponse
    case streamBackpressure

    public var description: String {
        switch self {
        case .hostNotRunning: "smthzd is not running"
        case .hostError(let code): "smthzd: \(code)"
        case .detailedHostError(let code, let detail): "smthzd: \(code)" + (detail.map { ": " + $0 } ?? "")
        case .invalidResponse: "invalid response from smthzd"
        case .streamBackpressure: "terminal subscriber fell behind; resume from the last consumed cursor"
        }
    }
}

public struct HostAcknowledgement: Decodable, Sendable {
    public let ok: Bool
}

public struct HostCancellationAcknowledgement: Decodable, Sendable {
    public let ok: Bool
    /// True if at least one active request observed the cancellation signal.
    public let cancelled: Bool
}

public struct HostSessionExit: Decodable, Equatable, Sendable {
    public let code: Int32?
    public let signal: Int32?
}

public struct HostReadResult: Decodable, Sendable {
    public let data: Data
    public let next: UInt64
    public let truncated: Bool
    public let exit: HostSessionExit?

    private enum CodingKeys: String, CodingKey { case data = "data_base64", next, truncated, exit }
}

public struct HostReplayResult: Decodable, Sendable {
    public let data: Data
    public let next: UInt64
    public let eof: Bool

    private enum CodingKeys: String, CodingKey { case data = "data_base64", next, eof }
}

/// The process-group leader currently owning a session's terminal.
public struct HostSessionForeground: Decodable, Equatable, Sendable {
    public let pgid: Int32
    public let pid: Int32
    public let executable: String?
    public let isShell: Bool
}

public struct HostSessionList: Decodable, Sendable {
    public let sessions: [SessionInfo]
}

/// Stable status wire representation; state and blocked kind have separate names.
public struct HostAgentStatusRow: Codable, Equatable, Sendable {
    public let sessionID: String
    public let state: String
    public let kind: AgentBlockKind?
    public let source: AgentStatusSource
    public let updatedAt: Double
    public let agent: AgentHookSource?
    public let app: String?
    public let lastEventName: String?
    public let toolName: String?
    public let toolInputPreview: String?
    public let prompt: String?
    public let providerSessionID: String?
    public let transcriptPath: String?
    public let title: String?
    public let message: String?
    public let progress: Int?

    init(_ row: AgentStatusRow) {
        sessionID = row.sessionID; state = row.state.name; kind = row.state.blockKind
        source = row.source; updatedAt = row.updatedAt.timeIntervalSince1970
        agent = row.agent; app = row.app; lastEventName = row.lastEventName
        toolName = row.toolName; toolInputPreview = row.toolInputPreview; prompt = row.prompt
        providerSessionID = row.providerSessionID; transcriptPath = row.transcriptPath
        title = row.title; message = row.message; progress = row.progress
    }
}

/// A synchronous connection. Calls and disconnect must be serialized by its owner.
public final class HostClient {
    private struct DetailedStatus: Decodable { let ok: Bool; let error: String?; let detail: String? }
    private struct Status: Decodable { let ok: Bool; let error: String? }
    private let transport: UnixSocketClient
    private let socketPath: String
    private let capabilityTokenPath: String?
    private var credential: String?

    public init(socketPath: String, capabilityTokenPath: String? = nil) throws {
        self.socketPath = socketPath
        self.capabilityTokenPath = capabilityTokenPath
        do { transport = try UnixSocketClient(path: socketPath) }
        catch UnixSocketError.connectFailed { throw HostClientError.hostNotRunning }
        do {
            let token = try HostCapabilityToken.load(path: capabilityTokenPath ?? HostCapabilityToken.path(socketPath: socketPath))
            struct Params: Encodable { let token: String }
            struct Handshake: Decodable { let credential: String }
            let result: Handshake = try call(method: "handshake", params: Params(token: token))
            credential = result.credential
        } catch {
            transport.close()
            throw error
        }
    }

    public func disconnect() { transport.close() }

    public static let maximumBufferedStreamFrames = 8

    /// Owns a separate authenticated socket, leaving writes/resizes responsive.
    /// Output is bounded to eight 64 KiB frames. On overflow the stream fails;
    /// resubscribe with the last *consumed* cursor to replay bytes without loss.
    public func subscribe(id: String, fromCursor: UInt64 = 0) -> AsyncThrowingStream<HostReadResult, any Error> {
        let socket = socketPath
        let token = capabilityTokenPath
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(Self.maximumBufferedStreamFrames)) { continuation in
            let worker = SubscriptionWorker(socket: socket, token: token, id: id,
                cursor: fromCursor, continuation: continuation)
            continuation.onTermination = { [weak worker] _ in worker?.cancel() }
            Thread.detachNewThread { worker.run() }
        }
    }

    private final class SubscriptionWorker: @unchecked Sendable {
        let socket: String
        let token: String?
        let id: String
        let cursor: UInt64
        let continuation: AsyncThrowingStream<HostReadResult, any Error>.Continuation
        let lock = NSLock()
        var cancelled = false
        var client: HostClient?

        init(socket: String, token: String?, id: String, cursor: UInt64,
             continuation: AsyncThrowingStream<HostReadResult, any Error>.Continuation) {
            self.socket = socket; self.token = token; self.id = id; self.cursor = cursor
            self.continuation = continuation
        }

        func cancel() {
            lock.withLock { cancelled = true; client?.transport.interrupt() }
        }

        func run() {
            do {
                let connection = try HostClient(socketPath: socket, capabilityTokenPath: token)
                defer {
                    lock.withLock { client = nil }
                    connection.disconnect()
                }
                let stopped = lock.withLock {
                    client = connection
                    return cancelled
                }
                guard !stopped else { continuation.finish(); return }
                struct Params: Encodable { let id: String; let fromCursor: UInt64 }
                let requestID = RequestID.generate().rawValue
                let _: HostAcknowledgement = try connection.call(method: "session.subscribe",
                    params: Params(id: id, fromCursor: cursor), requestID: requestID)
                while !lock.withLock({ cancelled }) {
                    let response = try JSONDecoder().decode(RPCEnvelope.self, from: connection.transport.receive())
                    guard response.version == RPCEnvelope.currentVersion, response.requestID == requestID,
                          response.method == "session.subscribe" else { throw HostClientError.invalidResponse }
                    let status = try JSONDecoder().decode(Status.self, from: response.payload)
                    guard status.ok else { throw HostClientError.hostError(code: status.error ?? "unknownError") }
                    let event = try JSONDecoder().decode(HostReadResult.self, from: response.payload)
                    switch continuation.yield(event) {
                    case .enqueued: break
                    case .dropped: throw HostClientError.streamBackpressure
                    case .terminated: return
                    @unknown default: return
                    }
                    if event.exit != nil { break }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }

    public func agentStatuses() throws -> [HostAgentStatusRow] {
        struct Empty: Encodable {}
        struct Result: Decodable { let statuses: [HostAgentStatusRow] }
        let result: Result = try call(method: "agent.status.list", params: Empty())
        return result.statuses
    }

    /// Scoped, handshake-free hook submission. The token cannot authorize another method.
    public static func sendAgentHook(socketPath: String, sessionID: String, agent: String,
                                     launchToken: String, hookToken: String, source: AgentHookSource,
                                     payload: Data) throws {
        let socket = try UnixSocketClient(path: socketPath)
        defer { socket.close() }
        // Drop unrelated raw fields and send the same bounded previews the host
        // stores. A valid 1 MiB tool payload must fit the framed RPC as well.
        guard let hook = try? AgentHookPayload(source: source, json: payload) else {
            throw HostClientError.hostError(code: "badRequest")
        }
        var fields: [String: HostJSON] = ["hook_event_name": .string(hook.eventName),
                                         "is_interrupt": .bool(hook.isInterrupt)]
        let strings: [String: String?] = ["session_id": hook.providerSessionID,
            "transcript_path": hook.transcriptPath, "cwd": hook.cwd, "tool_name": hook.toolName,
            "tool_input": hook.toolInputPreview, "tool_use_id": hook.toolUseID, "prompt": hook.prompt,
            "source": hook.sessionSource, "agent_id": hook.childAgentID, "model": hook.model,
            "trigger": hook.trigger]
        for (key, value) in strings { if let value { fields[key] = .string(value) } }
        let json = HostJSON.object(fields)
        let params: [String: HostJSON] = ["sessionID": .string(sessionID), "agent": .string(agent),
            "launchToken": .string(launchToken), "source": .string(source.rawValue), "payload": json]
        let request = RPCEnvelope(version: RPCEnvelope.currentVersion,
            requestID: RequestID.generate().rawValue, method: "agent.hook",
            payload: try JSONEncoder().encode(params), authorization: hookToken, timeoutMilliseconds: 1000)
        let envelope = try JSONDecoder().decode(RPCEnvelope.self,
            from: socket.request(JSONEncoder().encode(request), timeout: 1))
        guard envelope.requestID == request.requestID, envelope.method == request.method,
              envelope.version == request.version else { throw HostClientError.invalidResponse }
        let status = try JSONDecoder().decode(Status.self, from: envelope.payload)
        guard status.ok else { throw HostClientError.hostError(code: status.error ?? "unknownError") }
    }

    /// A dedicated bounded status stream. Dropped snapshots are replaced by the newest snapshot.
    public func subscribeAgentStatuses() -> AsyncThrowingStream<[HostAgentStatusRow], any Error> {
        let socket = socketPath, token = capabilityTokenPath
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let worker = AgentStatusSubscription(socket: socket, token: token, continuation: continuation)
            continuation.onTermination = { [weak worker] _ in worker?.cancel() }
            Thread.detachNewThread { worker.run() }
        }
    }

    private final class AgentStatusSubscription: @unchecked Sendable {
        let socket: String
        let token: String?
        let continuation: AsyncThrowingStream<[HostAgentStatusRow], any Error>.Continuation
        let lock = NSLock()
        var cancelled = false
        var client: HostClient?
        init(socket: String, token: String?,
             continuation: AsyncThrowingStream<[HostAgentStatusRow], any Error>.Continuation) {
            self.socket = socket; self.token = token; self.continuation = continuation
        }
        func cancel() { lock.withLock { cancelled = true; client?.transport.interrupt() } }
        func run() {
            do {
                let connection = try HostClient(socketPath: socket, capabilityTokenPath: token)
                defer { lock.withLock { client = nil }; connection.disconnect() }
                guard !lock.withLock({ client = connection; return cancelled }) else { continuation.finish(); return }
                struct Empty: Encodable {}
                struct Snapshot: Decodable { let statuses: [HostAgentStatusRow] }
                let id = RequestID.generate().rawValue
                let initial: Snapshot = try connection.call(method: "agent.status.subscribe", params: Empty(), requestID: id)
                continuation.yield(initial.statuses)
                while !lock.withLock({ cancelled }) {
                    let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: connection.transport.receive())
                    guard envelope.version == RPCEnvelope.currentVersion, envelope.requestID == id,
                          envelope.method == "agent.status.subscribe" else { throw HostClientError.invalidResponse }
                    let status = try JSONDecoder().decode(Status.self, from: envelope.payload)
                    guard status.ok else { throw HostClientError.hostError(code: status.error ?? "unknownError") }
                    let snapshot = try JSONDecoder().decode(Snapshot.self, from: envelope.payload)
                    if case .terminated = continuation.yield(snapshot.statuses) { return }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }

    public func listAgents() throws -> [DetectedAgent] {
        struct Empty: Encodable {}
        struct Entry: Decodable { let id: AgentID; let executable: String; let version: String? }
        struct Result: Decodable { let agents: [Entry] }
        let result: Result = try callWithDetail(method: "agent.list", params: Empty(), timeoutMilliseconds: 30_000)
        return result.agents.map { DetectedAgent(id: $0.id, executable: $0.executable, version: $0.version) }
    }

    public func launchAgent(_ request: AgentLaunchRequest,
                            requestID: String = RequestID.generate().rawValue) throws -> SessionInfo {
        try callWithDetail(method: "agent.launch", params: request, requestID: requestID, timeoutMilliseconds: 30_000)
    }

    public func call<Params: Encodable, Result: Decodable>(method: String, params: Params,
        requestID: String = RequestID.generate().rawValue, timeoutMilliseconds: Int = 5_000) throws -> Result {
        let payload = try rawCall(method: method, params: JSONEncoder().encode(params), requestID: requestID,
                                  timeoutMilliseconds: timeoutMilliseconds)
        let status = try JSONDecoder().decode(Status.self, from: payload)
        guard status.ok else { throw HostClientError.hostError(code: status.error ?? "unknownError") }
        return try JSONDecoder().decode(Result.self, from: payload)
    }

    /// Returns the complete payload, including failure code and human detail.
    public func rawCall(method: String, params: Data = Data("{}".utf8),
                        requestID: String = RequestID.generate().rawValue,
                        timeoutMilliseconds: Int = 5_000) throws -> Data {
        let request = RPCEnvelope(version: RPCEnvelope.currentVersion, requestID: requestID,
                                  method: method, payload: params, authorization: credential,
                                  timeoutMilliseconds: timeoutMilliseconds)
        let response = try JSONDecoder().decode(RPCEnvelope.self,
            from: transport.request(JSONEncoder().encode(request), timeout: Double(max(1, min(timeoutMilliseconds, 30_000))) / 1000 + 1))
        guard response.version == request.version, response.requestID == request.requestID,
              response.method == request.method else { throw HostClientError.invalidResponse }
        return response.payload
    }

    public func callWithDetail<Params: Encodable, Result: Decodable>(method: String, params: Params,
        requestID: String = RequestID.generate().rawValue, timeoutMilliseconds: Int = 5_000) throws -> Result {
        let payload = try rawCall(method: method, params: JSONEncoder().encode(params), requestID: requestID,
                                  timeoutMilliseconds: timeoutMilliseconds)
        let status = try JSONDecoder().decode(DetailedStatus.self, from: payload)
        guard status.ok else { throw HostClientError.detailedHostError(code: status.error ?? "unknownError", detail: status.detail) }
        return try JSONDecoder().decode(Result.self, from: payload)
    }

    /// Use a separate connection to cancel an in-flight synchronous call.
    @discardableResult public func cancel(requestID: String) throws -> HostCancellationAcknowledgement {
        struct Params: Encodable { let requestID: String }
        return try call(method: "request.cancel", params: Params(requestID: requestID))
    }

    public func createSession(requestID: String? = nil, executable: String, arguments: [String] = [],
                              environment: [String: String]? = nil, cwd: String? = nil,
                              rows: Int = 24, cols: Int = 80) throws -> SessionInfo {
        struct Params: Encodable {
            let executable: String; let arguments: [String]; let environment: [String: String]?
            let cwd: String?; let rows: Int; let cols: Int
        }
        return try call(method: "session.create", params: Params(executable: executable,
            arguments: arguments, environment: environment, cwd: cwd, rows: rows, cols: cols),
            requestID: requestID ?? RequestID.generate().rawValue)
    }

    @discardableResult public func write(id: String, data: Data) throws -> HostAcknowledgement {
        struct Params: Encodable { let id: String; let data_base64: String }
        return try call(method: "session.write", params: Params(id: id, data_base64: data.base64EncodedString()))
    }

    @discardableResult public func resize(id: String, rows: Int, cols: Int) throws -> HostAcknowledgement {
        struct Params: Encodable { let id: String; let rows: Int; let cols: Int }
        return try call(method: "session.resize", params: Params(id: id, rows: rows, cols: cols))
    }

    public func read(id: String, from: UInt64 = 0, maxBytes: Int? = nil) throws -> HostReadResult {
        struct Params: Encodable { let id: String; let from: UInt64; let maxBytes: Int? }
        return try call(method: "session.read", params: Params(id: id, from: from, maxBytes: maxBytes))
    }

    @discardableResult public func close(id: String) throws -> HostAcknowledgement {
        struct Params: Encodable { let id: String }
        return try call(method: "session.close", params: Params(id: id))
    }

    @discardableResult public func shutdown() throws -> HostAcknowledgement {
        struct Params: Encodable {}
        return try call(method: "host.shutdown", params: Params())
    }

    public func replay(id: String, from: UInt64 = 0, maxBytes: Int? = nil) throws -> HostReplayResult {
        struct Params: Encodable { let id: String; let from: UInt64; let maxBytes: Int? }
        return try call(method: "session.replay", params: Params(id: id, from: from, maxBytes: maxBytes))
    }

    public func foreground(id: String) throws -> HostSessionForeground {
        struct Params: Encodable { let id: String }
        return try call(method: "session.foreground", params: Params(id: id))
    }

    public func list() throws -> HostSessionList {
        struct Params: Encodable {}
        return try call(method: "session.list", params: Params())
    }
}
