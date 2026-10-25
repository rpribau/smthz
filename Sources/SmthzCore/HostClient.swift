import Foundation

public enum HostClientError: Error, Equatable, Sendable, CustomStringConvertible {
    case hostNotRunning
    case hostError(code: String)
    case invalidResponse

    public var description: String {
        switch self {
        case .hostNotRunning: "smthzd is not running"
        case .hostError(let code): "smthzd: \(code)"
        case .invalidResponse: "invalid response from smthzd"
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
    private var credential: String?

    public init(socketPath: String, capabilityTokenPath: String? = nil) throws {
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
