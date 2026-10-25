import Darwin
import Foundation
import Testing
@testable import SmthzCore

private final class ShellRPCFixture {
    let directory = "/tmp/smthz-h1-\(UUID().uuidString.prefix(8))"
    let journal: EventJournal
    let service: HostService
    let server: UnixSocketServer
    let client: HostClient

    init() throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        journal = try EventJournal(path: directory + "/j")
        let host = HostService(journal: journal, hostIdentity: nil)
        service = host
        server = try UnixSocketServer(path: directory + "/s") { host.handle($0) }
        client = try HostClient(socketPath: directory + "/s")
    }

    func shell() throws -> SessionInfo {
        let info = try client.createSession(executable: "/bin/zsh", arguments: ["-f"], cwd: "/")
        // A marker prevents observing the shell before interactive job control
        // has been initialized, including on loaded full-suite runs.
        try client.write(id: info.id, data: Data("printf 'H1_READY\\n'\n".utf8))
        #expect(try shellRPCEventually {
            String(decoding: try client.read(id: info.id).data, as: UTF8.self).contains("H1_READY\r\n")
        })
        return info
    }

    deinit {
        client.disconnect()
        service.stop()
        server.stop()
        try? FileManager.default.removeItem(atPath: directory)
    }
}

private func shellRPCEventually(_ predicate: () throws -> Bool) rethrows -> Bool {
    let deadline = Date(timeIntervalSinceNow: 5)
    repeat {
        if try predicate() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return try predicate()
}

@Suite(.serialized)
struct HostShellRPCTests {
    @Test func repeatedCreateRequestOwnsOneRealChild() throws {
        let fixture = try ShellRPCFixture()
        let requestID = RequestID.generate().rawValue
        let marker = "H1_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let arguments = ["-c", "read " + marker]
        let first = try fixture.client.createSession(requestID: requestID, executable: "/bin/sh", arguments: arguments)
        // Retry on another authenticated connection, as after a UI reconnect.
        let retry = try HostClient(socketPath: fixture.directory + "/s")
        defer { retry.disconnect() }
        let second = try retry.createSession(requestID: requestID, executable: "/bin/sh", arguments: arguments)
        #expect(first == second)
        #expect(try retry.list().sessions.map(\.id) == [first.id])
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        #expect(ps.terminationStatus == 0)
        let children = text.split(whereSeparator: \.isNewline).filter { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 3 && Int32(fields[1]) == getpid() && line.contains(marker)
        }
        #expect(children.count == 1)
        #expect(children.first?.split(whereSeparator: \.isWhitespace).first.flatMap { Int32($0) } == first.pid)
    }

    @Test func createAndListReturnLaunchMetadata() throws {
        let fixture = try ShellRPCFixture()
        let before = Date().timeIntervalSince1970
        let info = try fixture.client.createSession(executable: "/bin/cat", arguments: ["-u"], cwd: "/")
        #expect(info.executable == "/bin/cat")
        #expect(info.arguments == ["-u"])
        #expect(info.cwd == "/")
        let created = try #require(info.createdAt)
        #expect(created >= before && created <= Date().timeIntervalSince1970)
        #expect(try fixture.client.list().sessions.first == info)
    }

    @Test func legacySessionPayloadDecodesWithoutMetadata() throws {
        let data = Data(#"{"id":"old","pid":123,"startSeconds":1,"startMicroseconds":2,"running":true}"#.utf8)
        let info = try JSONDecoder().decode(SessionInfo.self, from: data)
        #expect(info.executable == nil)
        #expect(info.arguments == nil)
        #expect(info.cwd == nil)
        #expect(info.createdAt == nil)
    }

    @Test func idleShellOwnsForeground() throws {
        let fixture = try ShellRPCFixture()
        let info = try fixture.shell()
        let foreground = try fixture.client.foreground(id: info.id)
        #expect(foreground.isShell)
        #expect(foreground.pgid == info.pid)
        #expect(foreground.pid == info.pid)
        #expect(foreground.executable?.hasSuffix("/zsh") == true)
    }

    @Test func foregroundIdentifiesRunningSleep() throws {
        let fixture = try ShellRPCFixture()
        let info = try fixture.shell()
        try fixture.client.write(id: info.id, data: Data("sleep 30\n".utf8))
        #expect(try shellRPCEventually {
            let fg = try fixture.client.foreground(id: info.id)
            return !fg.isShell && fg.executable?.hasSuffix("/sleep") == true
        })
        let fg = try fixture.client.foreground(id: info.id)
        #expect(fg.pid == fg.pgid && fg.pid != info.pid)
        // Interrupt before teardown so the foreground job is reaped by zsh.
        try fixture.client.write(id: info.id, data: Data([0x03]))
        #expect(try shellRPCEventually { try fixture.client.foreground(id: info.id).isShell })
    }

    @Test func controlCReturnsForegroundToShellWithoutCachedResponse() throws {
        let fixture = try ShellRPCFixture()
        let info = try fixture.shell()
        struct Params: Encodable { let id: String }
        let requestID = RequestID.generate().rawValue
        func foreground() throws -> HostSessionForeground {
            try fixture.client.call(method: "session.foreground", params: Params(id: info.id), requestID: requestID)
        }
        #expect(try foreground().isShell)
        try fixture.client.write(id: info.id, data: Data("sleep 30\n".utf8))
        #expect(try shellRPCEventually { try !foreground().isShell })
        try fixture.client.write(id: info.id, data: Data([0x03]))
        #expect(try shellRPCEventually { try foreground().isShell })
        fixture.service.sessionManager.journalLock.lock()
        defer { fixture.service.sessionManager.journalLock.unlock() }
        #expect(try fixture.journal.entry(requestID: requestID) == nil)
    }

    @Test func foregroundUnknownSessionReturnsTypedError() throws {
        let fixture = try ShellRPCFixture()
        #expect(throws: HostClientError.hostError(code: "unknownSession")) {
            try fixture.client.foreground(id: "missing")
        }
    }

    @Test func foregroundClosedSessionReturnsNotRunning() throws {
        let fixture = try ShellRPCFixture()
        let info = try fixture.client.createSession(executable: "/bin/cat")
        try fixture.client.close(id: info.id)
        #expect(throws: HostClientError.hostError(code: "notRunning")) {
            try fixture.client.foreground(id: info.id)
        }
    }
}
