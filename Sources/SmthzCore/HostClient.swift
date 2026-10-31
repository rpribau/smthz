import Foundation

public enum HostClientError: Error, Equatable, Sendable, CustomStringConvertible {
    case hostNotRunning
    case hostError(code: String)
    case invalidResponse
    case streamBackpressure

    public var description: String {
        switch self {
        case .hostNotRunning: "smthzd is not running"
        case .hostError(let code): "smthzd: \(code)"
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

/// A synchronous connection. Calls and disconnect must be serialized by its owner.
public final class HostClient {
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

    public func call<Params: Encodable, Result: Decodable>(method: String, params: Params,
        requestID: String = RequestID.generate().rawValue, timeoutMilliseconds: Int = 5_000) throws -> Result {
        let request = RPCEnvelope(version: RPCEnvelope.currentVersion, requestID: requestID,
                                  method: method, payload: try JSONEncoder().encode(params),
                                  authorization: credential, timeoutMilliseconds: timeoutMilliseconds)
        let response = try JSONDecoder().decode(RPCEnvelope.self,
            from: transport.request(JSONEncoder().encode(request), timeout: Double(max(1, min(timeoutMilliseconds, 30_000))) / 1000 + 1))
        guard response.version == request.version, response.requestID == request.requestID,
              response.method == request.method else { throw HostClientError.invalidResponse }
        let status = try JSONDecoder().decode(Status.self, from: response.payload)
        guard status.ok else { throw HostClientError.hostError(code: status.error ?? "unknownError") }
        return try JSONDecoder().decode(Result.self, from: response.payload)
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
