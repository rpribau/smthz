import Darwin
import Foundation
import SQLite3
import Testing
@testable import SmthzCore

private final class SessionRPCFixture {
    let directory = "/tmp/smthz-rpc-\(UUID().uuidString.prefix(8))"
    let journal: EventJournal
    let service: HostService
    var socket: String { directory + "/s" }
    init() throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        journal = try EventJournal(path: directory + "/j")
        service = HostService(journal: journal, hostIdentity: nil)
    }
    deinit { try? FileManager.default.removeItem(atPath: directory) }
}

private func rpcSessionRequest(_ method: String, _ params: [String: Any], id: String = UUID().uuidString) throws -> Data {
    try JSONEncoder().encode(RPCEnvelope(version: 1, requestID: id, method: method,
                                         payload: JSONSerialization.data(withJSONObject: params)))
}
private func rpcSessionBody(_ response: Data) throws -> [String: Any] {
    let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: response)
    return try #require(JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any])
}
private func createParams(_ executable: String = "/bin/cat", arguments: [String] = []) -> [String: Any] {
    ["executable": executable, "arguments": arguments, "rows": 24, "cols": 80]
}
private func rpcSessionEventually(timeout: TimeInterval = 5, _ predicate: () throws -> Bool) rethrows -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    repeat {
        if try predicate() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    } while Date() < deadline
    return try predicate()
}

@Suite(.serialized)
struct HostSessionRPCTests {
    @Test func concurrentCreateReplaysOneSession() async throws {
        let fixture = try SessionRPCFixture()
        let request = try rpcSessionRequest("session.create", createParams(), id: "create-once")
        let service = fixture.service
        let responses = await withTaskGroup(of: Data.self, returning: [Data].self) { group in
            for _ in 0..<20 { group.addTask { service.handleAuthenticatedTestRequest(request) } }
            var results: [Data] = []
            for await response in group { results.append(response) }
            return results
        }
        let first = try #require(responses.first)
        #expect(responses.allSatisfy { $0 == first })
        let body = try rpcSessionBody(first)
        #expect(body["ok"] as? Bool == true)
        let id = try #require(body["id"] as? String)
        defer { try? service.sessionManager.close(id: id) }
        #expect(service.sessionManager.list().count == 1)
        let listed = try rpcSessionBody(service.handleAuthenticatedTestRequest(rpcSessionRequest("session.list", [:])))
        #expect((listed["sessions"] as? [[String: Any]])?.count == 1)
        #expect(try fixture.journal.read(after: 0, limit: 100).filter { $0.kind == "session.create" }.count == 1)
        let reopened = HostService(journal: try EventJournal(path: fixture.directory + "/j"), hostIdentity: nil)
        #expect(reopened.handleAuthenticatedTestRequest(request) == first)
        #expect(reopened.sessionManager.list().isEmpty)
    }

    @Test func invalidParamsAndUnknownSessions() throws {
        let fixture = try SessionRPCFixture()
        let service = fixture.service
        let file = fixture.directory + "/plain"
        try Data("not executable".utf8).write(to: URL(fileURLWithPath: file))
        #expect(chmod(file, 0o600) == 0)
        for executable in ["bin/cat", file, "/tmp"] {
            let body = try rpcSessionBody(service.handleAuthenticatedTestRequest(rpcSessionRequest("session.create", createParams(executable))))
            #expect(body["error"] as? String == "badRequest")
        }
        let invalid: [(String, [String: Any])] = [
            ("session.create", [:]), ("session.list", ["unexpected": true]), ("session.create", ["executable": "/bin/cat", "arguments": [], "rows": "24", "cols": 80]),
            ("session.write", ["id": "none", "data_base64": "%%%"]),
            ("session.read", ["id": "none", "from": -1]),
            ("session.read", ["id": "none", "from": 0, "maxBytes": 0]),
            ("session.resize", ["id": "none", "rows": 2.5, "cols": 80]),
            ("session.write", ["id": "none", "data_base64": Data(repeating: 1, count: 1_048_577).base64EncodedString()])
        ]
        for (method, params) in invalid {
            #expect(try rpcSessionBody(service.handleAuthenticatedTestRequest(rpcSessionRequest(method, params)))["error"] as? String == "badRequest")
        }
        for (method, params) in [
            ("session.write", ["id": "none", "data_base64": ""] as [String: Any]),
            ("session.read", ["id": "none", "from": 0]),
            ("session.resize", ["id": "none", "rows": 24, "cols": 80]),
            ("session.close", ["id": "none"])
        ] {
            #expect(try rpcSessionBody(service.handleAuthenticatedTestRequest(rpcSessionRequest(method, params)))["error"] as? String == "unknownSession")
        }
        let invalidList = try JSONEncoder().encode(RPCEnvelope(version: 1, requestID: UUID().uuidString,
            method: "session.list", payload: Data("[]".utf8)))
        #expect(try rpcSessionBody(service.handleAuthenticatedTestRequest(invalidList))["error"] as? String == "badRequest")
        var params = createParams("/bin/echo")
        params["cwd"] = "/nonexistent-smthz"
        #expect(try rpcSessionBody(service.handleAuthenticatedTestRequest(rpcSessionRequest("session.create", params)))["error"] as? String == "spawnFailed")
    }

    @Test func createDefaultsInitialSizeWhenFieldsAreOmitted() throws {
        let fixture = try SessionRPCFixture()
        let service = fixture.service
        let response = service.handleAuthenticatedTestRequest(try rpcSessionRequest("session.create", [
            "executable": "/bin/sh", "arguments": ["-c", "stty size; read answer"]
        ]))
        let body = try rpcSessionBody(response)
        #expect(body["ok"] as? Bool == true)
        let id = try #require(body["id"] as? String)
        defer { try? service.sessionManager.close(id: id) }
        #expect(try rpcSessionEventually { try service.sessionManager.read(id: id, from: 0).data.contains(Data("24 80".utf8)) })
        try service.sessionManager.write(id: id, data: Data("done\n".utf8))
        #expect(try rpcSessionEventually { try service.sessionManager.read(id: id, from: 0).exit == .exited(0) })

        let custom = try rpcSessionBody(service.handleAuthenticatedTestRequest(try rpcSessionRequest("session.create", [
            "executable": "/bin/sh", "arguments": ["-c", "stty size; read answer"], "rows": 41, "cols": 123
        ])))
        #expect(custom["ok"] as? Bool == true)
        let customID = try #require(custom["id"] as? String)
        defer { try? service.sessionManager.close(id: customID) }
        #expect(try rpcSessionEventually { try service.sessionManager.read(id: customID, from: 0).data.contains(Data("41 123".utf8)) })
        try service.sessionManager.write(id: customID, data: Data("done\n".utf8))
        #expect(try rpcSessionEventually { try service.sessionManager.read(id: customID, from: 0).exit == .exited(0) })
    }

    @Test func socketRoundTripSurvivesDisconnect() throws {
        let fixture = try SessionRPCFixture()
        let service = fixture.service
        let server = try UnixSocketServer(path: fixture.socket) { service.handleAuthenticatedTestRequest($0) }
        defer { server.stop() }
        let firstClient = try UnixSocketClient(path: fixture.socket)
        let created = try rpcSessionBody(firstClient.request(rpcSessionRequest("session.create", createParams())))
        let id = try #require(created["id"] as? String)
        defer { try? service.sessionManager.close(id: id) }
        firstClient.close()
        let client = try UnixSocketClient(path: fixture.socket)
        defer { client.close() }
        let written = try rpcSessionBody(client.request(rpcSessionRequest("session.write", ["id": id, "data_base64": Data("socket-ping\n".utf8).base64EncodedString()])))
        #expect(written["ok"] as? Bool == true)
        #expect(try rpcSessionEventually {
            let body = try rpcSessionBody(client.request(rpcSessionRequest("session.read", ["id": id, "from": 0])))
            let data = Data(base64Encoded: body["data_base64"] as? String ?? "") ?? Data()
            return String(decoding: data, as: UTF8.self).contains("socket-ping")
        })
        #expect(try rpcSessionBody(client.request(rpcSessionRequest("session.resize", ["id": id, "rows": 40, "cols": 120])))["ok"] as? Bool == true)
        #expect(try rpcSessionBody(client.request(rpcSessionRequest("session.close", ["id": id])))["ok"] as? Bool == true)
        let late = try rpcSessionBody(client.request(rpcSessionRequest("session.read", ["id": id, "from": 0])))
        #expect(late["exit"] is [String: Any])
        #expect(try rpcSessionBody(client.request(rpcSessionRequest("session.write", ["id": id, "data_base64": ""])))["error"] as? String == "notRunning")
    }

    @Test func journalFailuresReapUnreportedChildren() throws {
        let fixture = try SessionRPCFixture()
        var db: OpaquePointer?
        #expect(sqlite3_open(fixture.directory + "/j", &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        // Fail only the RPC response, after a child and its lifecycle event exist.
        #expect(sqlite3_exec(db, "CREATE TRIGGER reject_response BEFORE INSERT ON events WHEN NEW.kind = 'response:session.create' BEGIN SELECT RAISE(FAIL, 'rejected'); END;", nil, nil, nil) == SQLITE_OK)
        let request = try rpcSessionRequest("session.create", createParams(), id: "failed-create")
        #expect(try rpcSessionBody(fixture.service.handleAuthenticatedTestRequest(request))["error"] as? String == "journalFailure")
        #expect(fixture.service.sessionManager.list().isEmpty)
        #expect(try fixture.journal.entry(requestID: "failed-create") == nil)
        let created = try #require(fixture.journal.read(after: 0, limit: 10).first { $0.kind == "session.create" })
        let payload = try #require(JSONSerialization.jsonObject(with: created.payload) as? [String: Any])
        let pid = try #require(payload["pid"] as? Int32)
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
        #expect(sqlite3_exec(db, "DROP TRIGGER reject_response; CREATE TRIGGER reject_create BEFORE INSERT ON events WHEN NEW.kind = 'session.create' BEGIN SELECT RAISE(FAIL, 'rejected'); END;", nil, nil, nil) == SQLITE_OK)
        #expect(try rpcSessionBody(fixture.service.handleAuthenticatedTestRequest(rpcSessionRequest("session.create", createParams())))["error"] as? String == "journalFailure")
        #expect(fixture.service.sessionManager.list().isEmpty)
    }

    @Test func largeReadFitsSocketFrame() throws {
        let fixture = try SessionRPCFixture()
        let service = fixture.service
        let server = try UnixSocketServer(path: fixture.socket) { service.handleAuthenticatedTestRequest($0) }
        defer { server.stop() }
        let client = try UnixSocketClient(path: fixture.socket)
        defer { client.close() }
        let params = createParams("/bin/sh", arguments: ["-c", "/bin/stty -opost; /usr/bin/head -c 600000 /dev/zero | LC_ALL=C /usr/bin/tr '\\000' '\\377'"])
        let created = try rpcSessionBody(client.request(rpcSessionRequest("session.create", params)))
        let id = try #require(created["id"] as? String)
        defer { try? service.sessionManager.close(id: id) }
        #expect(try rpcSessionEventually(timeout: 20) { try service.sessionManager.read(id: id, from: 0).exit != nil })
        #expect(try rpcSessionEventually { try service.sessionManager.read(id: id, from: 524_288).nextOffset == 600_000 })
        var cursor: UInt64 = 0
        var total = 0
        while cursor < 600_000 {
            let body = try rpcSessionBody(client.request(rpcSessionRequest("session.read", ["id": id, "from": cursor, "maxBytes": Int.max])))
            let encoded = try #require(body["data_base64"] as? String)
            let data = try #require(Data(base64Encoded: encoded))
            #expect(!data.isEmpty)
            guard !data.isEmpty else { break }
            #expect(data.allSatisfy { $0 == 255 })
            total += data.count
            cursor = try #require((body["next"] as? NSNumber)?.uint64Value)
        }
        #expect(total == 600_000)
    }
}
