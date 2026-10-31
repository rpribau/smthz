import Foundation
import Testing
@testable import SmthzCore

private final class StreamFixture {
    let directory = URL(fileURLWithPath: "/tmp/sz-st-\(UUID().uuidString.prefix(8))")
    let service: HostService
    let server: UnixSocketServer
    let client: HostClient

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = try EventJournal(path: directory.appendingPathComponent("journal").path)
        let manager = SessionManager(journal: journal, outputLimit: 65_536,
            scrollbackDirectory: directory.appendingPathComponent("scrollback"), scrollbackLimit: 64 * 1_048_576)
        let service = HostService(journal: journal, hostIdentity: ProcessIdentity.current(), sessionManager: manager)
        self.service = service
        server = try UnixSocketServer(path: directory.appendingPathComponent("s").path,
            handler: { service.handle($0) }, streamHandler: { service.stream($0, send: $1, cancelled: $2) })
        client = try HostClient(socketPath: directory.appendingPathComponent("s").path)
    }

    deinit {
        client.disconnect()
        server.stop()
        service.sessionManager.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func streamEventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    try #require(predicate())
}

private struct StreamCapture: Sendable {
    var data = Data()
    var cursor: UInt64 = 0
    var exit: HostSessionExit?
    var frames = 0
}

// Every receive has a deadline so regressions fail instead of hanging the suite.
private func collectStream(_ stream: AsyncThrowingStream<HostReadResult, any Error>,
                           from cursor: UInt64 = 0, stopAfterBytes: Int? = nil) async throws -> StreamCapture {
    try await withThrowingTaskGroup(of: StreamCapture.self) { group in
        group.addTask {
            var capture = StreamCapture(cursor: cursor)
            for try await event in stream {
                #expect(!event.truncated)
                #expect(event.next == capture.cursor + UInt64(event.data.count))
                #expect(event.data.count <= HostService.streamChunkBytes)
                capture.cursor = event.next
                capture.data.append(event.data)
                capture.exit = event.exit
                capture.frames += 1
                if let limit = stopAfterBytes, capture.data.count >= limit { break }
            }
            return capture
        }
        group.addTask {
            try await Task.sleep(for: .seconds(30))
            throw HostClientError.invalidResponse
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

@Suite(.serialized)
struct SessionStreamTests {
    @Test func orderedBinaryOutputAndExitWithReadCompatibility() async throws {
        let fixture = try StreamFixture()
        defer { withExtendedLifetime(fixture) {} }
        let session = try fixture.client.createSession(executable: "/bin/sh",
            arguments: ["-c", "stty -opost; sleep .1; printf 'first\\000second\\n'; exit 7"])
        let result = try await collectStream(fixture.client.subscribe(id: session.id))
        #expect(result.data == Data("first\0second\n".utf8))
        #expect(result.exit?.code == 7)
        let read = try fixture.client.read(id: session.id)
        #expect(read.data == result.data)
        #expect(read.next == result.cursor)
        try await streamEventually { fixture.service.activeSubscriberCount == 0 }
    }

    @Test func disconnectAndReconnectResumeFromConsumedCursor() async throws {
        let fixture = try StreamFixture()
        defer { withExtendedLifetime(fixture) {} }
        let session = try fixture.client.createSession(executable: "/bin/sh",
            arguments: ["-c", "stty -opost; printf first; sleep .3; printf second; sleep .3; printf third"])
        let first = try await collectStream(fixture.client.subscribe(id: session.id), stopAfterBytes: 5)
        #expect(first.data == Data("first".utf8))
        try await streamEventually { fixture.service.activeSubscriberCount == 0 }
        // Replace the listener while the host-owned process/log survive.
        fixture.server.stop()
        let service = fixture.service
        let replacement = try UnixSocketServer(path: fixture.directory.appendingPathComponent("s").path,
            handler: { service.handle($0) }, streamHandler: { service.stream($0, send: $1, cancelled: $2) })
        defer { replacement.stop() }
        let rest = try await collectStream(fixture.client.subscribe(id: session.id, fromCursor: first.cursor), from: first.cursor)
        #expect(first.data + rest.data == Data("firstsecondthird".utf8))
        #expect(rest.cursor == 16)
        #expect(rest.exit?.code == 0)
    }

    @Test func idleConsumerCancellationReleasesServerSubscription() async throws {
        let fixture = try StreamFixture()
        defer { withExtendedLifetime(fixture) {} }
        let session = try fixture.client.createSession(executable: "/bin/cat")
        let stream = fixture.client.subscribe(id: session.id)
        let consumer = Task { for try await _ in stream {} }
        try await streamEventually { fixture.service.activeSubscriberCount == 1 }
        consumer.cancel()
        _ = await consumer.result
        try await streamEventually { fixture.service.activeSubscriberCount == 0 }
        #expect(try fixture.client.list().sessions.first?.running == true)
    }

    @Test func unknownSessionFailsRatherThanFinishingSilently() async throws {
        let fixture = try StreamFixture()
        defer { withExtendedLifetime(fixture) {} }
        do {
            _ = try await collectStream(fixture.client.subscribe(id: UUID().uuidString.lowercased()))
            Issue.record("Expected unknownSession")
        } catch HostClientError.hostError(let code) { #expect(code == "unknownSession") }
    }

    @Test func subscriptionRequiresAuthentication() throws {
        let fixture = try StreamFixture()
        defer { withExtendedLifetime(fixture) {} }
        let socket = try UnixSocketClient(path: fixture.directory.appendingPathComponent("s").path)
        defer { socket.close() }
        let request = RPCEnvelope(version: RPCEnvelope.currentVersion, requestID: RequestID.generate().rawValue,
            method: "session.subscribe", payload: Data("{\"id\":\"unknown\",\"fromCursor\":0}".utf8))
        let envelope = try JSONDecoder().decode(RPCEnvelope.self,
            from: socket.request(JSONEncoder().encode(request)))
        struct Status: Decodable { let ok: Bool; let error: String }
        let response = try JSONDecoder().decode(Status.self, from: envelope.payload)
        #expect(!response.ok)
        #expect(response.error == "unauthorized")
    }

    @Test func stalledSocketWriterTimesOutWithoutBlockingOtherClients() async throws {
        let fixture = try StreamFixture()
        defer { withExtendedLifetime(fixture) {} }
        let session = try fixture.client.createSession(executable: "/bin/sh",
            arguments: ["-c", "stty -opost; sleep .1; head -c 4000000 /dev/zero"])
        let socket = try UnixSocketClient(path: fixture.directory.appendingPathComponent("s").path)
        defer { socket.close() }
        func request(_ method: String, _ params: [String: Any], authorization: String? = nil) throws -> Data {
            let envelope = RPCEnvelope(version: RPCEnvelope.currentVersion, requestID: RequestID.generate().rawValue,
                method: method, payload: try JSONSerialization.data(withJSONObject: params), authorization: authorization)
            return try JSONDecoder().decode(RPCEnvelope.self,
                from: socket.request(JSONEncoder().encode(envelope))).payload
        }
        let token = try HostCapabilityToken.load(path: fixture.service.capabilityTokenPath)
        struct Credential: Decodable { let credential: String }
        let credential = try JSONDecoder().decode(Credential.self, from: request("handshake", ["token": token])).credential
        _ = try request("session.subscribe", ["id": session.id, "fromCursor": 0], authorization: credential)
        try await streamEventually { fixture.service.activeSubscriberCount == 1 }
        // Keep the socket open but never read an output frame. The writer must
        // disconnect it, while other RPC clients and the PTY keep progressing.
        #expect(try fixture.client.list().sessions.count == 1)
        try await streamEventually { fixture.service.activeSubscriberCount == 0 }
        try await streamEventually { fixture.service.sessionManager.list().first?.running == false }
        let tail = try fixture.client.read(id: session.id, from: 3_999_999)
        #expect(tail.data == Data([0]))
        #expect(tail.next == 4_000_000)
    }

    @Test func slowConsumerFloodIsBoundedAndReplayHasNoGaps() async throws {
        let fixture = try StreamFixture()
        defer { withExtendedLifetime(fixture) {} }
        let session = try fixture.client.createSession(executable: "/bin/sh",
            arguments: ["-c", "stty -opost -echo; read go; yes | head -c 50000000"])
        let slow = fixture.client.subscribe(id: session.id)
        // Leave the subscriber unread until it fills and disconnects. The flood
        // waits for the go line: a late subscriber could otherwise fill and
        // disconnect between two polls, so `== 1` would never be observed.
        try await streamEventually { fixture.service.activeSubscriberCount == 1 }
        try fixture.client.write(id: session.id, data: Data("\n".utf8))
        try await streamEventually { fixture.service.activeSubscriberCount == 0 }
        var cursor: UInt64 = 0
        var bufferedBytes = 0
        var overflow = false
        do {
            for try await event in slow {
                #expect(event.next == cursor + UInt64(event.data.count))
                cursor = event.next
                bufferedBytes += event.data.count
            }
        } catch HostClientError.streamBackpressure { overflow = true }
        #expect(overflow)
        #expect(bufferedBytes <= HostClient.maximumBufferedStreamFrames * HostService.streamChunkBytes)
        try await streamEventually { fixture.service.sessionManager.list().first?.running == false }
        // A fast reader may still overflow under arbitrary scheduler load. Each
        // retry continues at the last consumed cursor, checking every byte.
        var ended = false
        var finalExit: HostSessionExit?
        var attempts = 0
        while !ended, attempts < 200 {
            attempts += 1
            do {
                for try await event in fixture.client.subscribe(id: session.id, fromCursor: cursor) {
                    #expect(!event.truncated)
                    #expect(event.next == cursor + UInt64(event.data.count))
                    #expect(event.data.count <= HostService.streamChunkBytes)
                    for (index, byte) in event.data.enumerated() {
                        if byte != ((cursor + UInt64(index)) % 2 == 0 ? 121 : 10) {
                            Issue.record("Flood content gap at \(cursor + UInt64(index))"); break
                        }
                    }
                    cursor = event.next
                    if let exit = event.exit { ended = true; finalExit = exit }
                }
            } catch HostClientError.streamBackpressure { continue }
            catch UnixSocketError.closed { continue } // Socket back-pressure deadline; replay the consumed cursor.
        }
        #expect(ended)
        #expect(cursor == 50_000_000, "exit: \(String(describing: finalExit))")
        try await streamEventually { fixture.service.activeSubscriberCount == 0 }
    }

    @Test func framesSentBeforePeerCloseAreStillReceived() throws {
        let path = "/tmp/sz-st-\(UUID().uuidString.prefix(8))/s"
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let server = try UnixSocketServer(path: path, handler: { $0 }, streamHandler: { _, send, _ in
            try? send(Data("ack".utf8)); try? send(Data("exit".utf8)); return true
        })
        defer { server.stop() }
        let client = try UnixSocketClient(path: path)
        defer { client.close() }
        #expect(try client.request(Data("subscribe".utf8)) == Data("ack".utf8))
        // Let the server close first: Darwin then rejects setsockopt with EINVAL,
        // which used to drop the already-sent final frame as `.closed`.
        Thread.sleep(forTimeInterval: 0.2)
        #expect(try client.receive() == Data("exit".utf8))
    }

    @Test func streamFramesRespectOneMiBCap() async throws {
        let fixture = try StreamFixture()
        defer { withExtendedLifetime(fixture) {} }
        let session = try fixture.client.createSession(executable: "/bin/sh",
            arguments: ["-c", "stty -opost; head -c 200000 /dev/zero"])
        let captured = try await collectStream(fixture.client.subscribe(id: session.id))
        #expect(captured.data == Data(repeating: 0, count: 200_000))
        // The same nested JSON/base64 envelope shape used by HostService.
        struct Body: Encodable { let ok = true; let data_base64: String; let next: UInt64; let truncated = false }
        let payload = try JSONEncoder().encode(Body(data_base64: Data(repeating: 255,
            count: HostService.streamChunkBytes).base64EncodedString(), next: UInt64.max))
        let envelope = RPCEnvelope(version: RPCEnvelope.currentVersion, requestID: RequestID.generate().rawValue,
            method: "session.subscribe", payload: payload)
        let encoded = try JSONEncoder().encode(envelope)
        #expect(encoded.count < RPCFrameCodec.maxFrameSize)
        _ = try RPCFrameCodec.encode(encoded)
    }
}
