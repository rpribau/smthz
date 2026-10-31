import Darwin
import Foundation
import Testing
@testable import SmthzCore

// Legacy method tests authenticate explicitly through this adapter. The tests
// below exercise the unadapted handler and real sockets, including rejection.
extension HostService {
    func handleAuthenticatedTestRequest(_ payload: Data) -> Data {
        guard var request = try? JSONDecoder().decode(RPCEnvelope.self, from: payload),
              request.method != "handshake", request.authorization == nil else { return handle(payload) }
        do {
            request.authorization = try hardeningCredential(service: self)
            return handle(try JSONEncoder().encode(request))
        } catch { return handle(payload) }
    }
}

private struct HardeningBody: Decodable {
    let ok: Bool
    let error: String?
    let credential: String?
    let cancelled: Bool?
}
private func hardeningBody(_ data: Data) throws -> HardeningBody {
    let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: data)
    return try JSONDecoder().decode(HardeningBody.self, from: envelope.payload)
}
private func hardeningRequest(_ method: String = "ping", id: String = UUID().uuidString,
    params: Data = Data("{}".utf8), authorization: String? = nil, version: Int = 1,
    timeout: Int? = nil) throws -> Data {
    try JSONEncoder().encode(RPCEnvelope(version: version, requestID: id, method: method,
        payload: params, authorization: authorization, timeoutMilliseconds: timeout))
}
private func hardeningCredential(service: HostService) throws -> String {
    let token = try HostCapabilityToken.load(path: service.capabilityTokenPath)
    let params = try JSONSerialization.data(withJSONObject: ["token": token])
    return try #require(hardeningBody(service.handle(hardeningRequest("handshake", params: params))).credential)
}
private final class HardeningFixture {
    let directory = "/tmp/smthz-hard-\(UUID().uuidString.prefix(8))"
    let journal: EventJournal
    let service: HostService
    var socket: String { directory + "/s" }
    init() throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        journal = try EventJournal(path: directory + "/j")
        service = HostService(journal: journal, hostIdentity: nil)
    }
    deinit {
        for info in service.sessionManager.list() { try? service.sessionManager.close(id: info.id) }
        try? FileManager.default.removeItem(atPath: directory)
    }
}

private final class HardeningResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    let done = DispatchSemaphore(value: 0)
    func store(_ data: Data) { lock.withLock { value = data }; done.signal() }
    func load() -> Data? { lock.withLock { value } }
}

@Suite(.serialized)
struct RPCHardeningTests {
    @Test func versionAndAuthenticationFailBeforeJournal() throws {
        let fixture = try HardeningFixture()
        #expect(try hardeningBody(fixture.service.handle(hardeningRequest(version: 99))).error == "protocolVersionMismatch")
        #expect(try hardeningBody(fixture.service.handle(hardeningRequest())).error == "unauthorized")
        #expect(try hardeningBody(fixture.service.handle(hardeningRequest(authorization: "wrong"))).error == "unauthorized")
        let badToken = Data(#"{"token":"wrong"}"#.utf8)
        #expect(try hardeningBody(fixture.service.handle(hardeningRequest("handshake", params: badToken))).error == "unauthorized")
        let token = try HostCapabilityToken.load(path: fixture.service.capabilityTokenPath)
        // Possession of the file token still requires handshake to obtain a credential.
        #expect(try hardeningBody(fixture.service.handle(hardeningRequest(authorization: token))).error == "unauthorized")
        let credential = try hardeningCredential(service: fixture.service)
        #expect(try hardeningBody(fixture.service.handle(hardeningRequest(authorization: credential))).ok)
        let entries = try fixture.journal.read(after: 0, limit: 10)
        #expect(entries.isEmpty)
        _ = fixture.service.handle(try hardeningRequest("session.resize", authorization: credential))
        let mutation = try #require(fixture.journal.read(after: 0, limit: 10).first)
        #expect(!String(decoding: mutation.payload, as: UTF8.self).contains(credential))
        #expect(!String(decoding: mutation.payload, as: UTF8.self).contains(token))
    }

    @Test func capabilityFilePermissionsAndUnsafeFiles() throws {
        let fixture = try HardeningFixture()
        let path = fixture.service.capabilityTokenPath
        var info = stat()
        #expect(lstat(path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        let token = try HostCapabilityToken.load(path: path)
        #expect(try HostCapabilityToken.load(path: path, create: true) == token)
        #expect(chmod(path, 0o644) == 0)
        #expect(throws: HostClientError.hostError(code: "authenticationUnavailable")) { try HostCapabilityToken.load(path: path) }
        let refused = HostService(journal: fixture.journal, hostIdentity: nil)
        #expect(try hardeningBody(refused.handle(hardeningRequest())).error == "authenticationUnavailable")
        #expect(chmod(path, 0o600) == 0)
        let link = fixture.directory + "/link"
        #expect(symlink(path, link) == 0)
        #expect(throws: HostClientError.hostError(code: "authenticationUnavailable")) { try HostCapabilityToken.load(path: link, create: true) }
        let hardlink = fixture.directory + "/hardlink"
        #expect(Darwin.link(path, hardlink) == 0)
        #expect(throws: HostClientError.hostError(code: "authenticationUnavailable")) { try HostCapabilityToken.load(path: path) }
    }

    @Test func idempotencyBindsCanonicalParamsAndMethodAcrossRestart() throws {
        let fixture = try HardeningFixture()
        let credential = try hardeningCredential(service: fixture.service)
        let original = try hardeningRequest("session.resize", id: "retry", params: Data(#"{"a":1,"b":2}"#.utf8), authorization: credential)
        let first = fixture.service.handle(original)
        let reordered = try hardeningRequest("session.resize", id: "retry", params: Data(#"{ "b": 2, "a": 1 }"#.utf8), authorization: credential)
        #expect(fixture.service.handle(reordered) == first)
        #expect(try hardeningBody(fixture.service.handle(hardeningRequest("session.close", id: "retry", authorization: credential))).error == "idempotencyConflict")
        #expect(try hardeningBody(fixture.service.handle(hardeningRequest("session.resize", id: "retry", params: Data(#"{"a":2,"b":2}"#.utf8), authorization: credential))).error == "idempotencyConflict")
        let reopened = HostService(journal: try EventJournal(path: fixture.journal.path), hostIdentity: nil)
        #expect(try hardeningBody(reopened.handle(original)).error == "unauthorized")
        let newCredential = try hardeningCredential(service: reopened)
        #expect(reopened.handle(try hardeningRequest("session.resize", id: "retry", params: Data(#"{"b":2,"a":1}"#.utf8), authorization: newCredential)) == first)
        #expect(try fixture.journal.read(after: 0, limit: 10).count == 1)
    }

    @Test func realSocketRequiresHandshakeAndTypedClientAuthenticates() throws {
        let fixture = try HardeningFixture()
        let service = fixture.service
        let server = try UnixSocketServer(path: fixture.socket) { service.handle($0) }
        defer { server.stop() }
        let raw = try UnixSocketClient(path: fixture.socket)
        defer { raw.close() }
        #expect(try hardeningBody(raw.request(hardeningRequest())).error == "unauthorized")
        let token = try HostCapabilityToken.load(path: service.capabilityTokenPath)
        let params = try JSONSerialization.data(withJSONObject: ["token": token])
        let credential = try #require(hardeningBody(raw.request(hardeningRequest("handshake", params: params))).credential)
        #expect(try hardeningBody(raw.request(hardeningRequest(authorization: credential))).ok)
        let client = try HostClient(socketPath: fixture.socket)
        defer { client.disconnect() }
        struct Empty: Encodable {}
        let result: HostAcknowledgement = try client.call(method: "ping", params: Empty())
        #expect(result.ok)
        let child = try client.createSession(executable: "/bin/cat")
        #expect(child.running)
        #expect(try client.close(id: child.id).ok)
    }

    @Test func queuedRequestCancellationAndDeadlineUseIndependentSocket() throws {
        let fixture = try HardeningFixture()
        let service = fixture.service
        let server = try UnixSocketServer(path: fixture.socket) { service.handle($0) }
        defer { server.stop() }
        let credential = try hardeningCredential(service: service)
        let request = try hardeningRequest("session.resize", id: "queued-cancel", authorization: credential)
        let result = HardeningResult()
        service.sessionManager.journalLock.lock()
        Thread.detachNewThread { result.store(service.handle(request)) }
        let cancellingClient = try UnixSocketClient(path: fixture.socket)
        defer { cancellingClient.close() }
        let params = Data(#"{"requestID":"queued-cancel"}"#.utf8)
        var cancelled = false
        let deadline = Date(timeIntervalSinceNow: 10)
        repeat {
            cancelled = try hardeningBody(cancellingClient.request(hardeningRequest("request.cancel", params: params, authorization: credential))).cancelled == true
            if !cancelled { Thread.sleep(forTimeInterval: 0.001) }
        } while !cancelled && Date() < deadline
        let completed = result.done.wait(timeout: .now() + 10)
        service.sessionManager.journalLock.unlock()
        #expect(cancelled)
        #expect(completed == .success)
        #expect(try hardeningBody(#require(result.load())).error == "cancelled")
        #expect(try fixture.journal.entry(requestID: "queued-cancel") == nil)

        let expiring = HardeningResult()
        let shortRequest = try hardeningRequest("session.resize", id: "queued-deadline", authorization: credential, timeout: 20)
        service.sessionManager.journalLock.lock()
        Thread.detachNewThread { expiring.store(service.handle(shortRequest)) }
        let expired = expiring.done.wait(timeout: .now() + 10)
        service.sessionManager.journalLock.unlock()
        #expect(expired == .success)
        #expect(try hardeningBody(#require(expiring.load())).error == "deadlineExceeded")
        #expect(try fixture.journal.entry(requestID: "queued-deadline") == nil)
        #expect(try hardeningBody(cancellingClient.request(hardeningRequest("request.cancel", params: params, authorization: credential))).cancelled == false)
        #expect(try hardeningBody(service.handle(hardeningRequest(id: "next", authorization: credential))).ok)
    }

    @Test func requestLimitsRejectBeforeExecution() throws {
        let fixture = try HardeningFixture()
        let credential = try hardeningCredential(service: fixture.service)
        for timeout in [0, -1, 30_001, Int.max] {
            #expect(try hardeningBody(fixture.service.handle(hardeningRequest(authorization: credential, timeout: timeout))).error == "limitExceeded")
        }
        #expect(try hardeningBody(fixture.service.handle(hardeningRequest(id: String(repeating: "x", count: 129), authorization: credential))).error == "badRequest")
        #expect(try hardeningBody(fixture.service.handle(hardeningRequest(params: Data(repeating: 0, count: HostService.maximumRequestBytes + 1), authorization: credential))).error == "badRequest")
        #expect(try fixture.journal.read(after: 0, limit: 10).isEmpty)
    }
}
