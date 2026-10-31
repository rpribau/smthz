import Foundation
import SQLite3
import Testing
@testable import SmthzCore

private struct HostFixture {
    let directory = "/tmp/smthz-host-\(UUID().uuidString.prefix(8))"
    var journalPath: String { directory + "/journal.sqlite" }
    var socketPath: String { directory + "/s.sock" }

    func journal() throws -> EventJournal {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return try EventJournal(path: journalPath)
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: directory) }
}

private struct HostBody: Decodable {
    let ok: Bool
    let result: String?
    let error: String?
    let pid: Int32?
    let startSeconds: UInt64?
    let startMicroseconds: UInt64?
}

private func hostRequest(_ method: String, id: String = "r1", version: Int = 1) throws -> Data {
    try JSONEncoder().encode(RPCEnvelope(version: version, requestID: id, method: method, payload: Data()))
}

private func hostBody(_ response: Data) throws -> HostBody {
    let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: response)
    return try JSONDecoder().decode(HostBody.self, from: envelope.payload)
}

@Test func hostPing() throws {
    let fixture = HostFixture()
    defer { fixture.cleanup() }
    let journal = try fixture.journal()
    let service = HostService(journal: journal, hostIdentity: nil)
    let response = service.handleAuthenticatedTestRequest(try hostRequest("ping", id: "ping-id", version: 1))
    let body = try hostBody(response)
    #expect(body.ok)
    #expect(body.result == "pong")
    let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: response)
    #expect(envelope.version == 1)
    #expect(envelope.requestID == "ping-id")
    #expect(envelope.method == "ping")
    #expect(try journal.entry(requestID: "ping-id") == nil)
}

@Test func hostVersion() throws {
    let fixture = HostFixture()
    defer { fixture.cleanup() }
    let service = HostService(journal: try fixture.journal(), hostIdentity: nil)
    let body = try hostBody(service.handleAuthenticatedTestRequest(hostRequest("version")))
    #expect(body.ok)
    #expect(body.result == ApplicationIdentity.version)
}

@Test func hostIdentity() throws {
    let fixture = HostFixture()
    defer { fixture.cleanup() }
    let identity = ProcessIdentity(pid: 42, startSeconds: 123456789, startMicroseconds: 654321)
    let service = HostService(journal: try fixture.journal(), hostIdentity: identity)
    let body = try hostBody(service.handleAuthenticatedTestRequest(hostRequest("host.identity")))
    #expect(body.ok)
    #expect(body.pid == identity.pid)
    #expect(body.startSeconds == identity.startSeconds)
    #expect(body.startMicroseconds == identity.startMicroseconds)
}

@Test func hostMissingIdentity() throws {
    let fixture = HostFixture()
    defer { fixture.cleanup() }
    let service = HostService(journal: try fixture.journal(), hostIdentity: nil)
    let body = try hostBody(service.handleAuthenticatedTestRequest(hostRequest("host.identity")))
    #expect(!body.ok)
    #expect(body.error == "identityUnavailable")
}

@Test func hostUnknownMethod() throws {
    let fixture = HostFixture()
    defer { fixture.cleanup() }
    let service = HostService(journal: try fixture.journal(), hostIdentity: nil)
    let body = try hostBody(service.handleAuthenticatedTestRequest(hostRequest("missing")))
    #expect(!body.ok)
    #expect(body.error == "unknownMethod")
}

@Test func hostBadRequest() throws {
    let fixture = HostFixture()
    defer { fixture.cleanup() }
    let journal = try fixture.journal()
    let service = HostService(journal: journal, hostIdentity: nil)
    for payload in [Data(), Data("not json".utf8), Data("{}".utf8)] {
        let response = service.handleAuthenticatedTestRequest(payload)
        let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: response)
        #expect(envelope.requestID.isEmpty)
        let body = try hostBody(response)
        #expect(!body.ok)
        #expect(body.error == "badRequest")
    }
    #expect(try journal.read(after: 0, limit: 10).isEmpty)
}

@Test func hostIdempotency() throws {
    let fixture = HostFixture()
    defer { fixture.cleanup() }
    let journal = try fixture.journal()
    let service = HostService(journal: journal, hostIdentity: nil)
    let request = try hostRequest("session.resize")
    let first = service.handleAuthenticatedTestRequest(request)
    #expect(service.handleAuthenticatedTestRequest(request) == first)
    #expect(try journal.read(after: 0, limit: 10).count == 1)
    let entry = try #require(try journal.entry(requestID: "r1"))
    #expect(entry.kind == "response:session.resize")
    #expect(entry.payload == first)
    // A reused ID must match both method and canonical parameters.
    #expect(try hostBody(service.handleAuthenticatedTestRequest(hostRequest("session.close"))).error == "idempotencyConflict")
    #expect(try hostBody(service.handleAuthenticatedTestRequest(hostRequest("session.resize", version: 2))).error == "protocolVersionMismatch")
    let reopened = HostService(journal: try EventJournal(path: fixture.journalPath), hostIdentity: nil)
    #expect(reopened.handleAuthenticatedTestRequest(request) == first)
}

@Test func hostDifferentRequestIDs() throws {
    let fixture = HostFixture()
    defer { fixture.cleanup() }
    let journal = try fixture.journal()
    let service = HostService(journal: journal, hostIdentity: nil)
    _ = service.handleAuthenticatedTestRequest(try hostRequest("session.resize", id: "first"))
    _ = service.handleAuthenticatedTestRequest(try hostRequest("session.resize", id: "second"))
    #expect(try journal.read(after: 0, limit: 10).map(\.requestID) == ["first", "second"])
}

@Test func hostConcurrentIdempotency() async throws {
    let fixture = HostFixture()
    defer { fixture.cleanup() }
    let journal = try fixture.journal()
    let service = HostService(journal: journal, hostIdentity: nil)
    let request = try hostRequest("session.resize")
    let results = await withTaskGroup(of: Data.self, returning: [Data].self) { group in
        for _ in 0..<20 { group.addTask { service.handleAuthenticatedTestRequest(request) } }
        var results: [Data] = []
        for await result in group { results.append(result) }
        return results
    }
    #expect(results.count == 20)
    #expect(results.allSatisfy { $0 == results.first })
    #expect(try journal.read(after: 0, limit: 100).count == 1)
}

@Test func hostJournalFailures() throws {
    let fixture = HostFixture()
    defer { fixture.cleanup() }
    let journal = try fixture.journal()
    let service = HostService(journal: journal, hostIdentity: nil)
    var db: OpaquePointer?
    #expect(sqlite3_open(fixture.journalPath, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    // Make append fail while lookup still succeeds.
    #expect(sqlite3_exec(db, "CREATE TRIGGER reject_insert BEFORE INSERT ON events BEGIN SELECT RAISE(FAIL, 'rejected'); END;", nil, nil, nil) == SQLITE_OK)
    let appendFailure = try hostBody(service.handleAuthenticatedTestRequest(hostRequest("session.resize")))
    #expect(!appendFailure.ok)
    #expect(appendFailure.error == "journalFailure")
    #expect(try journal.entry(requestID: "r1") == nil)
    // Make lookup fail as well.
    #expect(sqlite3_exec(db, "DROP TABLE events;", nil, nil, nil) == SQLITE_OK)
    let lookupFailure = try hostBody(service.handleAuthenticatedTestRequest(hostRequest("session.resize")))
    #expect(!lookupFailure.ok)
    #expect(lookupFailure.error == "journalFailure")
}

@Test func hostSocketRoundTrip() throws {
    let fixture = HostFixture()
    defer { fixture.cleanup() }
    let journal = try fixture.journal()
    let service = HostService(journal: journal, hostIdentity: ProcessIdentity.current())
    let server = try UnixSocketServer(path: fixture.socketPath) { service.handleAuthenticatedTestRequest($0) }
    defer { server.stop() }
    let client = try UnixSocketClient(path: fixture.socketPath)
    defer { client.close() }
    let request = try hostRequest("ping")
    let response = try client.request(request)
    let body = try hostBody(response)
    #expect(body.ok)
    #expect(body.result == "pong")
    #expect(try client.request(request) == response)
    #expect(try journal.read(after: 0, limit: 10).isEmpty)
    server.stop()
    #expect(!FileManager.default.fileExists(atPath: fixture.socketPath))
}
