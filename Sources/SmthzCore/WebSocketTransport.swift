import Foundation
import Network

public enum WebSocketTransportError: Error, Equatable {
    case invalidHost
    case invalidPort
    case invalidTimeout
    case timedOut
    case closed
    case network(String)
    case frame(String)
}

// Blocking API, like UnixSocketTransport. Never invoke it on a Network callback
// queue. Each wait has a deadline; a timed-out exchange closes its connection so
// a late response cannot be mistaken for a subsequent request's response.
private final class WebSocketResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var result: Result<Value, WebSocketTransportError>?

    func finish(_ value: Result<Value, WebSocketTransportError>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        lock.unlock()
        signal.signal()
    }

    func wait(_ timeout: TimeInterval) throws -> Value {
        guard timeout.isFinite, timeout > 0, timeout <= 86_400 else {
            throw WebSocketTransportError.invalidTimeout
        }
        guard signal.wait(timeout: .now() + timeout) == .success else {
            throw WebSocketTransportError.timedOut
        }
        return try lock.withLock { try result!.get() }
    }
}

private func webSocketParameters(_ factory: (@Sendable () -> NWParameters)?) -> NWParameters {
    // Hook for a future TLS policy and WebSocket handshake authorization. The
    // factory must return fresh parameters per endpoint; it may supply TLS and
    // a configured WebSocket options object (headers / handshake admission).
    // Default is deliberately unauthenticated TCP, bound to loopback by server.
    let parameters = factory?() ?? NWParameters.tcp
    if let options = parameters.defaultProtocolStack.applicationProtocols.first(
        where: { $0 is NWProtocolWebSocket.Options }) as? NWProtocolWebSocket.Options {
        options.maximumMessageSize = RPCFrameCodec.maxFrameSize + 4
        options.autoReplyPing = true
    } else {
        let options = NWProtocolWebSocket.Options()
        options.maximumMessageSize = RPCFrameCodec.maxFrameSize + 4
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
    }
    return parameters
}

private func webSocketContext() -> NWConnection.ContentContext {
    NWConnection.ContentContext(identifier: "smthz.rpc", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
}

private func webSocketPayload(_ data: Data?, _ context: NWConnection.ContentContext?, _ complete: Bool) throws -> Data {
    guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
            as? NWProtocolWebSocket.Metadata,
          metadata.opcode == .binary, complete, let data,
          data.count <= RPCFrameCodec.maxFrameSize + 4 else {
        throw WebSocketTransportError.frame("expected one complete binary RPC frame")
    }
    var decoder = RPCFrameDecoder()
    decoder.append(data)
    do {
        guard let payload = try decoder.nextFrame(), data.count == payload.count + 4 else {
            throw WebSocketTransportError.frame("expected exactly one RPC frame")
        }
        return payload
    } catch let error as WebSocketTransportError { throw error }
    catch { throw WebSocketTransportError.frame(String(describing: error)) }
}

public final class WebSocketServer: @unchecked Sendable {
    // All mutable State fields are isolated to this private queue.
    private final class State: @unchecked Sendable {
        let queue = DispatchQueue(label: "dev.smthz.websocket.server")
        let listener: NWListener
        let handler: @Sendable (Data) -> Data
        var peers: [UUID: NWConnection] = [:]
        var stopped = false

        init(listener: NWListener, handler: @escaping @Sendable (Data) -> Data) {
            self.listener = listener
            self.handler = handler
        }

        func accept(_ connection: NWConnection) {
            guard !stopped else { connection.cancel(); return }
            let id = UUID()
            peers[id] = connection
            connection.stateUpdateHandler = { [weak self] status in
                guard let self else { return }
                switch status {
                case .ready: self.receive(id)
                case .failed, .cancelled: self.remove(id)
                default: break
                }
            }
            connection.start(queue: queue)
        }

        func remove(_ id: UUID) {
            guard let connection = peers.removeValue(forKey: id) else { return }
            connection.stateUpdateHandler = nil
            connection.cancel()
        }

        func receive(_ id: UUID) {
            guard let connection = peers[id], !stopped else { return }
            connection.receiveMessage { [weak self] data, context, complete, error in
                guard let self, !self.stopped, self.peers[id] != nil else { return }
                do {
                    if let error { throw error }
                    // Ping/pong are transport control messages, not RPC input.
                    let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                    if metadata?.opcode == .ping || metadata?.opcode == .pong {
                        self.receive(id)
                        return
                    }
                    let payload = try webSocketPayload(data, context, complete)
                    let handler = self.handler
                    let queue = self.queue
                    // Application work must not block transport cancellation or
                    // other peers. Only one handler per peer is in flight.
                    DispatchQueue.global().async { [weak self] in
                        let response = try? RPCFrameCodec.encode(handler(payload))
                        queue.async { [weak self] in
                            guard let self, !self.stopped, let connection = self.peers[id] else { return }
                            guard let response else { self.remove(id); return }
                            connection.send(content: response, contentContext: webSocketContext(), isComplete: true,
                                            completion: .contentProcessed { [weak self] error in
                                guard let self else { return }
                                if error != nil { self.remove(id) } else { self.receive(id) }
                            })
                        }
                    }
                } catch { self.remove(id) }
            }
        }

        func stop() {
            queue.sync {
                guard !stopped else { return }
                stopped = true
                listener.newConnectionHandler = nil
                listener.stateUpdateHandler = nil
                listener.cancel()
                for id in Array(peers.keys) { remove(id) }
            }
        }
    }

    private let state: State
    public let port: UInt16

    /// Uses an ephemeral loopback port when port is zero. The parameter factory
    /// is the integration point for future TLS and handshake authentication.
    public init(host: String = "127.0.0.1", port: UInt16 = 0, timeout: TimeInterval = 5,
                parameters: (@Sendable () -> NWParameters)? = nil,
                handler: @escaping @Sendable (Data) -> Data) throws {
        let configuration = webSocketParameters(parameters)
        configuration.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: configuration)
        let state = State(listener: listener, handler: handler)
        self.state = state
        let ready = WebSocketResult<UInt16>()
        listener.stateUpdateHandler = { [weak listener] status in
            switch status {
            case .ready:
                if let port = listener?.port { ready.finish(.success(port.rawValue)) }
                else { ready.finish(.failure(.closed)) }
            case .failed(let error): ready.finish(.failure(.network(String(describing: error))))
            case .cancelled: ready.finish(.failure(.closed))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak state] connection in
            guard let state else { connection.cancel(); return }
            state.accept(connection)
        }
        listener.start(queue: state.queue)
        do { self.port = try ready.wait(timeout) }
        catch { state.stop(); throw error }
    }

    public func stop() { state.stop() }
    deinit { state.stop() }
}

public final class WebSocketClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.smthz.websocket.client")
    private let requestLock = NSLock()
    private let stateLock = NSLock()
    private var closed = false

    public init(host: String = "127.0.0.1", port: UInt16, timeout: TimeInterval = 5,
                parameters: (@Sendable () -> NWParameters)? = nil) throws {
        guard port != 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw WebSocketTransportError.invalidPort
        }
        let configuration = webSocketParameters(parameters)
        // Explicit ephemeral binding avoids EADDRINUSE after rapid loopback
        // churn with Network's implicit source-port selection. The IPv6 wildcard
        // supports both IP families. Preserve a caller's chosen local endpoint.
        if configuration.requiredLocalEndpoint == nil {
            configuration.requiredLocalEndpoint = .hostPort(host: .ipv6(.any), port: .any)
        }
        var address = URLComponents()
        address.scheme = configuration.defaultProtocolStack.applicationProtocols.contains {
            $0 is NWProtocolTLS.Options
        } ? "wss" : "ws"
        address.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        address.port = Int(endpointPort.rawValue)
        address.path = "/"
        guard !host.isEmpty, let url = address.url else { throw WebSocketTransportError.invalidHost }
        // A URL endpoint is required for Network's WebSocket HTTP upgrade; a
        // host/port endpoint alone aborts the server-side handshake.
        connection = NWConnection(to: .url(url), using: configuration)
        let ready = WebSocketResult<Bool>()
        connection.stateUpdateHandler = { status in
            switch status {
            case .ready: ready.finish(.success(true))
            case .failed(let error): ready.finish(.failure(.network(String(describing: error))))
            case .cancelled: ready.finish(.failure(.closed))
            default: break
            }
        }
        connection.start(queue: queue)
        do { _ = try ready.wait(timeout) }
        catch { connection.cancel(); throw error }
    }

    public func request(_ payload: Data, timeout: TimeInterval = 5) throws -> Data {
        try requestLock.withLock {
            guard !stateLock.withLock({ closed }) else { throw WebSocketTransportError.closed }
            guard timeout.isFinite, timeout > 0, timeout <= 86_400 else {
                throw WebSocketTransportError.invalidTimeout
            }
            let frame: Data
            do { frame = try RPCFrameCodec.encode(payload) }
            catch { throw WebSocketTransportError.frame(String(describing: error)) }
            let result = WebSocketResult<Data>()
            connection.send(content: frame, contentContext: webSocketContext(), isComplete: true,
                            completion: .contentProcessed { error in
                if let error { result.finish(.failure(.network(String(describing: error)))) }
            })
            Self.receive(connection, result)
            do { return try result.wait(timeout) }
            catch { close(); throw error }
        }
    }

    private static func receive(_ connection: NWConnection, _ result: WebSocketResult<Data>) {
        connection.receiveMessage { data, context, complete, error in
            if let error { result.finish(.failure(.network(String(describing: error)))); return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .ping || metadata?.opcode == .pong {
                receive(connection, result)
                return
            }
            do { result.finish(.success(try webSocketPayload(data, context, complete))) }
            catch let error as WebSocketTransportError { result.finish(.failure(error)) }
            catch { result.finish(.failure(.frame(String(describing: error)))) }
        }
    }

    public func close() {
        stateLock.withLock {
            guard !closed else { return }
            closed = true
            connection.cancel()
        }
    }

    deinit { close() }
}
