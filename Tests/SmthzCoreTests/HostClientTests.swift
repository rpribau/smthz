import Darwin
import Foundation
import Testing
@testable import SmthzCore

private final class HostClientFixture {
    let directory = "/tmp/smthz-client-\(UUID().uuidString.prefix(8))"
    let service: HostService
    let server: UnixSocketServer
    var socket: String { directory + "/s" }

    init() throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let journal = try EventJournal(path: directory + "/j")
        let host = HostService(journal: journal, hostIdentity: nil)
        service = host
        server = try UnixSocketServer(path: directory + "/s") { host.handle($0) }
    }
    func client() throws -> HostClient { try HostClient(socketPath: socket) }
    deinit {
        for session in service.sessionManager.list() { try? service.sessionManager.close(id: session.id) }
        server.stop()
        try? FileManager.default.removeItem(atPath: directory)
    }
}

private func clientEventually(_ predicate: () throws -> Bool) rethrows -> Bool {
    let deadline = Date(timeIntervalSinceNow: 5)
    repeat {
        if try predicate() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return try predicate()
}

@Suite(.serialized)
struct HostClientTests {
    @Test func createAndListUseFreshRequestIDs() throws {
        let fixture = try HostClientFixture()
        let client = try fixture.client()
        defer { client.disconnect() }
        let first = try client.createSession(executable: "/bin/cat")
        let second = try client.createSession(executable: "/bin/cat")
        #expect(first.id != second.id)
        #expect(first.pid != second.pid)
        #expect(first.running)
        #expect(try client.list().sessions.map(\.id).sorted() == [first.id, second.id].sorted())
    }

    @Test func writeAndReadReturnBytesAndOffsets() throws {
        let fixture = try HostClientFixture()
        let client = try fixture.client()
        defer { client.disconnect() }
        let session = try client.createSession(executable: "/bin/cat")
        #expect(try client.write(id: session.id, data: Data("typed-client\n".utf8)).ok)
        #expect(try clientEventually {
            String(decoding: try client.read(id: session.id).data, as: UTF8.self).contains("typed-client")
        })
        let first = try client.read(id: session.id, maxBytes: 3)
        #expect(first.data.count == 3)
        #expect(first.next == 3)
        #expect(!first.truncated)
        #expect(first.exit == nil)
        let next = try client.read(id: session.id, from: first.next)
        #expect(next.next == first.next + UInt64(next.data.count))
    }

    @Test func resizeChangesChildWindowSize() throws {
        let fixture = try HostClientFixture()
        let client = try fixture.client()
        defer { client.disconnect() }
        let session = try client.createSession(executable: "/bin/sh", arguments: ["-c", "read line; /bin/stty size"])
        #expect(try client.resize(id: session.id, rows: 37, cols: 111).ok)
        try client.write(id: session.id, data: Data("go\n".utf8))
        #expect(try clientEventually {
            String(decoding: try client.read(id: session.id).data, as: UTF8.self).contains("37 111")
        })
    }

    @Test func createPassesCwdEnvironmentAndArguments() throws {
        let fixture = try HostClientFixture()
        let client = try fixture.client()
        defer { client.disconnect() }
        let session = try client.createSession(executable: "/bin/sh",
            arguments: ["-c", "printf '%s:%s' \"$CLIENT_TEST\" \"$PWD\""],
            environment: ["CLIENT_TEST": "custom-value"], cwd: "/")
        #expect(try clientEventually {
            String(decoding: try client.read(id: session.id).data, as: UTF8.self).contains("custom-value:/")
        })
    }

    @Test func closeReturnsExitAndNotRunningError() throws {
        let fixture = try HostClientFixture()
        let client = try fixture.client()
        defer { client.disconnect() }
        let session = try client.createSession(executable: "/bin/cat")
        #expect(try client.close(id: session.id).ok)
        #expect(try client.read(id: session.id).exit != nil)
        #expect(try client.list().sessions.first?.running == false)
        #expect(throws: HostClientError.hostError(code: "notRunning")) {
            try client.write(id: session.id, data: Data("late".utf8))
        }
    }

    @Test func naturalExitCodeIsDecoded() throws {
        let fixture = try HostClientFixture()
        let client = try fixture.client()
        defer { client.disconnect() }
        let session = try client.createSession(executable: "/bin/sh", arguments: ["-c", "exit 7"])
        #expect(try clientEventually { try client.read(id: session.id).exit?.code == 7 })
    }

    @Test func missingHostMapsConnectionFailure() {
        #expect(throws: HostClientError.hostNotRunning) {
            try HostClient(socketPath: "/tmp/smthz-missing-\(UUID().uuidString.prefix(8))/s")
        }
    }

    @Test func hostErrorsPreserveCodes() throws {
        let fixture = try HostClientFixture()
        let client = try fixture.client()
        defer { client.disconnect() }
        #expect(throws: HostClientError.hostError(code: "unknownSession")) { try client.read(id: "missing") }
        #expect(throws: HostClientError.hostError(code: "badRequest")) { try client.createSession(executable: "cat") }
        #expect(throws: HostClientError.hostError(code: "spawnFailed")) {
            try client.createSession(executable: "/bin/cat", cwd: fixture.directory + "/missing")
        }
        struct Empty: Encodable {}
        #expect(throws: HostClientError.hostError(code: "unknownMethod")) {
            let _: HostAcknowledgement = try client.call(method: "missing", params: Empty())
        }
    }

    @Test func sessionOutlivesClientConnection() throws {
        let fixture = try HostClientFixture()
        let first = try fixture.client()
        let session = try first.createSession(executable: "/bin/cat")
        try first.write(id: session.id, data: Data("before-disconnect\n".utf8))
        first.disconnect()
        let second = try fixture.client()
        defer { second.disconnect() }
        #expect(try second.list().sessions.contains { $0.id == session.id && $0.running })
        #expect(try clientEventually {
            String(decoding: try second.read(id: session.id).data, as: UTF8.self).contains("before-disconnect")
        })
        let offset = try second.read(id: session.id).next
        try second.write(id: session.id, data: Data("after-reconnect\n".utf8))
        #expect(try clientEventually {
            String(decoding: try second.read(id: session.id, from: offset).data, as: UTF8.self).contains("after-reconnect")
        })
        #expect(try second.close(id: session.id).ok)
    }
}
