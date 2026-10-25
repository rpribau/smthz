import Foundation
import Network
import Testing
@testable import SmthzCore

private final class WSTestResult<Value: Sendable>: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: Value?
    func set(_ value: Value) { lock.withLock { self.value = value }; semaphore.signal() }
    func wait() throws -> Value {
        try #require(semaphore.wait(timeout: .now() + 5) == .success)
        return try #require(lock.withLock { value })
    }
}

private func wsRawConnection(_ port: UInt16) throws -> NWConnection {
    let parameters = NWParameters.tcp
    let options = NWProtocolWebSocket.Options()
    options.maximumMessageSize = 2 * RPCFrameCodec.maxFrameSize
    parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
    let connection = NWConnection(to: .url(URL(string: "ws://127.0.0.1:\(port)/")!), using: parameters)
    let ready = WSTestResult<Bool>()
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready: ready.set(true)
        case .failed, .cancelled: ready.set(false)
        default: break
        }
    }
    connection.start(queue: DispatchQueue(label: "smthz.ws.test.raw"))
    do { try #require(try ready.wait()) }
    catch { connection.cancel(); throw error }
    connection.stateUpdateHandler = nil
    return connection
}

@Suite(.serialized) struct WebSocketTransportTests {
    @Test func envelopeAndSequentialRequests() throws {
        let server = try WebSocketServer { $0 }
        defer { server.stop() }
        let client = try WebSocketClient(port: server.port)
        defer { client.close() }
        let envelope = RPCEnvelope(version: 1, requestID: UUID().uuidString, method: "ping", payload: Data([1, 2]))
        let payload = try JSONEncoder().encode(envelope)
        let response = try client.request(payload)
        #expect(try JSONDecoder().decode(RPCEnvelope.self, from: response) == envelope)
        #expect(try client.request(Data([42])) == Data([42]))
    }

    @Test func exactOneMiBLimitAndLocalValidation() throws {
        let server = try WebSocketServer { $0 }
        defer { server.stop() }
        let client = try WebSocketClient(port: server.port)
        defer { client.close() }
        let largest = Data(repeating: 0xAD, count: RPCFrameCodec.maxFrameSize)
        #expect(try client.request(largest) == largest)
        #expect(throws: WebSocketTransportError.self) { try client.request(Data()) }
        #expect(throws: WebSocketTransportError.self) { try client.request(Data(repeating: 1, count: largest.count + 1)) }
        #expect(try client.request(Data([7])) == Data([7]))
    }

    @Test func concurrentClients() async throws {
        let server = try WebSocketServer { $0 }
        defer { server.stop() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in UInt8(1)...8 {
                group.addTask {
                    let client = try WebSocketClient(port: server.port)
                    defer { client.close() }
                    let payload = Data(repeating: value, count: 100_000)
                    for _ in 0..<3 { #expect(try client.request(payload) == payload) }
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func rejectsMalformedPeersAndRemainsAvailable() throws {
        let server = try WebSocketServer { $0 }
        defer { server.stop() }
        let valid = try RPCFrameCodec.encode(Data([3]))
        let badFrames: [(Data, NWProtocolWebSocket.Opcode)] = [
            (Data([0, 0, 0, 0]), .binary),
            (Data([0, 0x10, 0, 1]), .binary),
            (Data([0, 0, 0, 2, 1]), .binary),
            (valid + valid, .binary),
            (valid, .text),
            (Data(repeating: 1, count: RPCFrameCodec.maxFrameSize + 5), .binary)
        ]
        for (frame, opcode) in badFrames {
            let connection = try wsRawConnection(server.port)
            defer { connection.cancel() }
            let ended = WSTestResult<Bool>()
            connection.receiveMessage { data, context, _, error in
                let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
                ended.set(error != nil || data == nil || metadata?.opcode == .close)
            }
            let context = NWConnection.ContentContext(identifier: "invalid", metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)])
            connection.send(content: frame, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
            #expect(try ended.wait())
        }
        let client = try WebSocketClient(port: server.port)
        defer { client.close() }
        #expect(try client.request(Data([9])) == Data([9]))
    }

    @Test func rejectsOversizeResponse() throws {
        let server = try WebSocketServer { _ in Data(repeating: 1, count: RPCFrameCodec.maxFrameSize + 1) }
        defer { server.stop() }
        let client = try WebSocketClient(port: server.port)
        defer { client.close() }
        #expect(throws: WebSocketTransportError.self) { try client.request(Data([1])) }
    }

    @Test func timeoutClosesConnection() throws {
        let server = try WebSocketServer { data in
            Thread.sleep(forTimeInterval: 0.15)
            return data
        }
        defer { server.stop() }
        let client = try WebSocketClient(port: server.port)
        #expect(throws: WebSocketTransportError.timedOut) { try client.request(Data([1]), timeout: 0.01) }
        #expect(throws: WebSocketTransportError.closed) { try client.request(Data([2])) }
    }

    @Test func closeInterruptsPendingRequest() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let server = try WebSocketServer { data in
            entered.signal()
            _ = release.wait(timeout: .now() + 3)
            return data
        }
        defer { release.signal(); server.stop() }
        let client = try WebSocketClient(port: server.port)
        let ended = WSTestResult<Bool>()
        DispatchQueue.global().async {
            do { _ = try client.request(Data([1])); ended.set(false) }
            catch { ended.set(true) }
        }
        try #require(entered.wait(timeout: .now() + 2) == .success)
        client.close()
        #expect(try ended.wait())
        client.close()
    }

    @Test func stopDisconnectsPeersAndReleasesPort() throws {
        let server = try WebSocketServer { $0 }
        let port = server.port
        let client = try WebSocketClient(port: port)
        defer { client.close() }
        #expect(try client.request(Data([1])) == Data([1]))
        server.stop()
        server.stop()
        #expect(throws: WebSocketTransportError.self) { try client.request(Data([2])) }
        // Network cancellation is asynchronous: retry binding for up to 2s.
        var replacement: WebSocketServer?
        for _ in 0..<40 {
            replacement = try? WebSocketServer(port: port, timeout: 0.1) { $0 }
            if replacement != nil { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        defer { replacement?.stop() }
        #expect(replacement != nil)
    }

    @Test func repeatedLifecycleDoesNotRetainEndpoints() throws {
        for _ in 0..<20 {
            weak var weakServer: WebSocketServer?
            weak var weakClient: WebSocketClient?
            do {
                let server = try WebSocketServer { $0 }
                weakServer = server
                let client = try WebSocketClient(port: server.port)
                weakClient = client
                #expect(try client.request(Data([5])) == Data([5]))
            }
            #expect(weakClient == nil)
            #expect(weakServer == nil)
        }
    }

    @Test func ipv6LoopbackAndHostname() throws {
        let server = try WebSocketServer(host: "::1") { $0 }
        defer { server.stop() }
        let client = try WebSocketClient(host: "::1", port: server.port)
        defer { client.close() }
        #expect(try client.request(Data([6])) == Data([6]))
        let ipv4Server = try WebSocketServer { $0 }
        defer { ipv4Server.stop() }
        let hostnameClient = try WebSocketClient(host: "localhost", port: ipv4Server.port)
        defer { hostnameClient.close() }
        #expect(try hostnameClient.request(Data([4])) == Data([4]))
    }

    @Test func customHandshakePolicyHook() throws {
        let server = try WebSocketServer(parameters: {
            let parameters = NWParameters.tcp
            let options = NWProtocolWebSocket.Options()
            options.setClientRequestHandler(DispatchQueue.global()) { _, _ in
                .init(status: .reject, subprotocol: nil)
            }
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            return parameters
        }, handler: { $0 })
        defer { server.stop() }
        #expect(throws: WebSocketTransportError.self) {
            try WebSocketClient(port: server.port, timeout: 1)
        }
    }

    @Test func invalidConfigurationAndTimeout() throws {
        #expect(throws: WebSocketTransportError.invalidPort) { try WebSocketClient(port: 0) }
        #expect(throws: WebSocketTransportError.invalidHost) { try WebSocketClient(host: "", port: 1234) }
        #expect(throws: WebSocketTransportError.invalidTimeout) { try WebSocketServer(timeout: .nan) { $0 } }
        let server = try WebSocketServer { $0 }
        defer { server.stop() }
        let client = try WebSocketClient(port: server.port)
        defer { client.close() }
        for timeout in [0.0, -1, Double.infinity, Double.nan] {
            #expect(throws: WebSocketTransportError.invalidTimeout) { try client.request(Data([1]), timeout: timeout) }
        }
        #expect(try client.request(Data([1])) == Data([1]))
    }
}
