import Darwin
import Foundation
import Testing
@testable import SmthzCore

private struct ManagerFixture {
    let path = "/tmp/smthz-sm-\(UUID().uuidString)"
    func manager(limit: Int = 4 * 1_048_576) throws -> SessionManager {
        SessionManager(journal: try EventJournal(path: path), outputLimit: limit)
    }
    func cleanup() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }
}

private func managerEventually(_ predicate: () throws -> Bool) rethrows -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    repeat {
        if try predicate() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    } while clock.now < deadline
    return try predicate()
}

@Suite(.serialized)
struct SessionManagerTests {
    @Test func echoAndLifecycleJournal() throws {
        let fixture = ManagerFixture()
        defer { fixture.cleanup() }
        let manager = try fixture.manager()
        defer { manager.stop() }
        let info = try manager.create(executable: "/bin/echo", arguments: ["manager-echo"])
        #expect(try managerEventually {
            let result = try manager.read(id: info.id, from: 0)
            return String(decoding: result.data, as: UTF8.self).contains("manager-echo") && result.exit == .exited(0)
        })
        try manager.close(id: info.id)
        let entries = try EventJournal(path: fixture.path).read(after: 0, limit: 10)
        #expect(entries.map(\.kind) == ["session.create", "session.close"])
        for entry in entries {
            let body = try #require(JSONSerialization.jsonObject(with: entry.payload) as? [String: Any])
            #expect(body["id"] as? String == info.id)
            #expect(body["pid"] as? Int32 == info.pid)
            #expect(body["identity"] is [String: Any])
        }
    }

    @Test func catCursorContinuationAndNoReaderRetention() throws {
        let fixture = ManagerFixture()
        defer { fixture.cleanup() }
        let manager = try fixture.manager()
        defer { manager.stop() }
        let info = try manager.create(executable: "/bin/cat", arguments: [])
        defer { try? manager.close(id: info.id) }
        try manager.write(id: info.id, data: Data("first\n".utf8))
        // Reads observe retained output; they do not consume it or drive the PTY.
        #expect(try managerEventually { try manager.read(id: info.id, from: 0).data.count >= 7 })
        let first = try manager.read(id: info.id, from: 0, maxBytes: 3)
        #expect(first.data == Data("fir".utf8))
        let second = try manager.read(id: info.id, from: first.nextOffset)
        #expect(!second.data.isEmpty)
        #expect(second.nextOffset == first.nextOffset + UInt64(second.data.count))
        #expect(String(decoding: first.data + second.data, as: UTF8.self).contains("first"))
        #expect(!second.truncated)
        #expect(manager.list().first?.running == true)
        try manager.close(id: info.id)
        #expect(try manager.read(id: info.id, from: second.nextOffset).exit != nil)
        #expect(manager.list().first?.running == false)
        #expect(throws: SessionError.notRunning) { try manager.write(id: info.id, data: Data([1])) }
        #expect(throws: SessionError.notRunning) { try manager.resize(id: info.id, rows: 24, cols: 80) }
    }

    @Test func truncationPreservesAbsoluteOffsets() throws {
        let fixture = ManagerFixture()
        defer { fixture.cleanup() }
        let manager = try fixture.manager(limit: 32)
        defer { manager.stop() }
        let info = try manager.create(executable: "/bin/echo", arguments: [String(repeating: "x", count: 100)])
        #expect(try managerEventually { try manager.read(id: info.id, from: 0).nextOffset == 102 })
        let result = try manager.read(id: info.id, from: 0, maxBytes: 10)
        #expect(result.truncated)
        #expect(result.data.count == 10)
        #expect(result.nextOffset == 80)
        let next = try manager.read(id: info.id, from: result.nextOffset)
        #expect(!next.truncated)
        #expect(next.data.count == 22)
        #expect(next.nextOffset == 102)
        #expect(try manager.read(id: info.id, from: UInt64.max).nextOffset == 102)
    }

    @Test func resizeAndClamping() throws {
        let fixture = ManagerFixture()
        defer { fixture.cleanup() }
        let manager = try fixture.manager()
        defer { manager.stop() }
        let info = try manager.create(executable: "/bin/sh", arguments: ["-c", "stty size; read answer; stty size; read answer; stty size"], rows: 0, cols: 3000)
        defer { try? manager.close(id: info.id) }
        #expect(try managerEventually {
            String(decoding: try manager.read(id: info.id, from: 0).data, as: UTF8.self).contains("1 2000")
        })
        try manager.resize(id: info.id, rows: 40, cols: 120)
        try manager.write(id: info.id, data: Data("go\n".utf8))
        #expect(try managerEventually {
            String(decoding: try manager.read(id: info.id, from: 0).data, as: UTF8.self).contains("40 120")
        })
        try manager.resize(id: info.id, rows: Int.max, cols: Int.min)
        try manager.write(id: info.id, data: Data("go\n".utf8))
        #expect(try managerEventually {
            String(decoding: try manager.read(id: info.id, from: 0).data, as: UTF8.self).contains("2000 1")
        })
    }

    @Test func validationAndUnknownSessions() throws {
        let fixture = ManagerFixture()
        defer { fixture.cleanup() }
        let manager = try fixture.manager()
        defer { manager.stop() }
        for executable in ["bin/echo", "/tmp", "/nonexistent-smthz"] {
            #expect(throws: SessionError.badRequest) { try manager.create(executable: executable, arguments: []) }
        }
        #expect(throws: SessionError.unknownSession) { try manager.read(id: "missing", from: 0) }
        #expect(throws: SessionError.unknownSession) { try manager.write(id: "missing", data: Data()) }
        #expect(throws: SessionError.unknownSession) { try manager.resize(id: "missing", rows: 1, cols: 1) }
        #expect(throws: SessionError.unknownSession) { try manager.close(id: "missing") }
        let info = try manager.create(executable: "/bin/sleep", arguments: ["30"])
        defer { try? manager.close(id: info.id) }
        #expect(throws: SessionError.badRequest) {
            try manager.write(id: info.id, data: Data(repeating: 1, count: 1_048_577))
        }
        #expect(throws: SessionError.badRequest) { try manager.read(id: info.id, from: 0, maxBytes: 0) }
        #expect(throws: SessionError.spawnFailed) {
            try manager.create(executable: "/bin/echo", arguments: [], workingDirectory: "/nonexistent-smthz")
        }
    }

    @Test func thirtySessionsReapedAndDescriptorsClosed() throws {
        let fixture = ManagerFixture()
        defer { fixture.cleanup() }
        let manager = try fixture.manager()
        defer { manager.stop() }
        for _ in 0..<30 {
            // Keep the child alive until its own master descriptor is identified.
            // Process-wide fd totals fluctuate as other suites run concurrently.
            let info = try manager.create(executable: "/bin/sh", arguments: ["-c", "/usr/bin/tty; printf fd-check; read answer"])
            defer { try? manager.close(id: info.id) }
            try #require(try managerEventually {
                String(decoding: try manager.read(id: info.id, from: 0).data, as: UTF8.self).contains("fd-check")
            })
            let text = String(decoding: try manager.read(id: info.id, from: 0).data, as: UTF8.self)
            let terminal = try #require(text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("/dev/tty") }).description
            // Pin this tty number until inspection ends so another suite cannot
            // reuse it after the master closes and look like a leaked descriptor.
            let slave = Darwin.open(terminal, O_RDONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
            try #require(slave >= 0)
            defer { Darwin.close(slave) }
            try #require(masterDescriptors(for: terminal).count == 1)
            try manager.write(id: info.id, data: Data("go\n".utf8))
            try #require(try managerEventually { try manager.read(id: info.id, from: 0).exit == .exited(0) })
            try manager.close(id: info.id)
            #expect(try manager.read(id: info.id, from: 0).exit != nil)
            var status: Int32 = 0
            #expect(waitpid(info.pid, &status, WNOHANG) == -1)
            #expect(errno == ECHILD)
            #expect(ProcessIdentity.lookup(pid: info.pid) == nil)
            #expect(managerEventually { masterDescriptors(for: terminal).isEmpty },
                    "Master for \(terminal) remains open after child reap")
        }
        #expect(manager.list().count == 30)
        #expect(manager.list().allSatisfy { !$0.running })
    }
}

/// TIOCPTYGNAME is _IOC(IOC_OUT, 't', 83, 128) in Darwin's sys/ttycom.h.
/// Unlike F_GETPATH (always /dev/ptmx), it identifies the master's specific tty.
private func masterDescriptors(for terminal: String) -> [Int32] {
    ((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? [])
        .compactMap { Int32($0) }.filter { fd in
            var name = [UInt8](repeating: 0, count: 128)
            let result = name.withUnsafeMutableBytes { ioctl(fd, UInt(0x40807453), $0.baseAddress!) }
            return result == 0 && String(decoding: name.prefix { $0 != 0 }, as: UTF8.self) == terminal
        }
}
