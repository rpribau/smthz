import Darwin
import Foundation
import Testing
@testable import SmthzCore

private func durabilityEventually(_ predicate: () throws -> Bool) rethrows -> Bool {
    let deadline = Date(timeIntervalSinceNow: 10)
    repeat {
        if try predicate() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return try predicate()
}

private final class DurabilityOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

@Suite(.serialized)
struct PTYSessionDurabilityTests {
    @Test func stubbornGrandchildDiesWithProcessGroup() throws {
        let child = try PTYSession(executable: "/bin/sh", arguments: ["-c", "trap '' HUP TERM; /bin/sh -c 'trap \"\" HUP TERM; echo GRANDCHILD=$$; exec /bin/sleep 30' & wait"], environment: ProcessInfo.processInfo.environment, workingDirectory: nil, size: PTYSize(rows: 24, cols: 80))
        defer { child.close() }
        let output = DurabilityOutput()
        child.setOutputHandler { output.append($0) }
        #expect(durabilityEventually { output.text.contains("GRANDCHILD=") })
        let line = try #require(output.text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("GRANDCHILD=") })
        let pid = try #require(Int32(line.dropFirst("GRANDCHILD=".count)))
        let identity = try #require(ProcessIdentity.lookup(pid: pid))
        #expect(getpgid(pid) == child.pid)
        child.close()
        #expect(child.waitForExit(timeout: 0) == .signaled(SIGKILL))
        #expect(durabilityEventually { !identity.isStillRunning() })
    }

    @Test func exitedLeaderDoesNotLeaveGrandchild() throws {
        let child = try PTYSession(executable: "/bin/sh", arguments: ["-c", "/bin/sh -c 'trap \"\" HUP TERM; echo GRANDCHILD=$$; exec /bin/sleep 30' & read answer; exit 7"], environment: ProcessInfo.processInfo.environment, workingDirectory: nil, size: PTYSize(rows: 24, cols: 80))
        defer { child.close() }
        let output = DurabilityOutput()
        child.setOutputHandler { output.append($0) }
        #expect(durabilityEventually { output.text.contains("GRANDCHILD=") })
        let line = try #require(output.text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("GRANDCHILD=") })
        let pid = try #require(Int32(line.dropFirst("GRANDCHILD=".count)))
        let identity = try #require(ProcessIdentity.lookup(pid: pid))
        try child.write(Data("exit\n".utf8))
        #expect(child.waitForExit(timeout: 5) == .exited(7))
        #expect(durabilityEventually { !identity.isStillRunning() })
    }
}

@Suite(.serialized)
struct SessionManagerDurabilityTests {
    @Test func replaysMoreThanFourMiBFromDiskAndAfterTeardown() throws {
        let directory = URL(fileURLWithPath: "/tmp/smthz-d-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let journal = try EventJournal(path: directory.appendingPathComponent("journal").path)
        var manager: SessionManager? = SessionManager(journal: journal, scrollbackDirectory: directory.appendingPathComponent("output"), scrollbackLimit: 6 * 1_048_576)
        let info = try #require(manager).create(executable: "/bin/sh", arguments: ["-c", "stty -opost; printf BEGIN; head -c 5242880 /dev/zero; printf END"])
        #expect(try durabilityEventually { try manager?.read(id: info.id, from: 0, maxBytes: 1).exit != nil })
        let first = try #require(manager).read(id: info.id, from: 0, maxBytes: 5)
        #expect(first.data == Data("BEGIN".utf8))
        #expect(!first.truncated)
        var expected = Data("BEGIN".utf8)
        expected.append(Data(repeating: 0, count: 5 * 1_048_576))
        expected.append(Data("END".utf8))
        var all = Data()
        var cursor: UInt64 = 0
        while all.count < expected.count {
            let part = try #require(manager).read(id: info.id, from: cursor)
            #expect(!part.truncated)
            guard !part.data.isEmpty else { Issue.record("Replay ended early"); break }
            all.append(part.data)
            cursor = part.nextOffset
        }
        #expect(all == expected)
        try #require(manager).close(id: info.id)
        manager = nil
        let archived = try SessionManager.readScrollback(id: info.id, directory: directory.appendingPathComponent("output"), from: 0, maxBytes: 5)
        #expect(archived.data == Data("BEGIN".utf8))
        #expect(!archived.truncated)
        let ending = try SessionManager.readScrollback(id: info.id, directory: directory.appendingPathComponent("output"), from: UInt64(expected.count - 3))
        #expect(ending.data == Data("END".utf8))
        #expect(ending.nextOffset == UInt64(expected.count))
    }

    @Test func boundedRingWrapsAndPreservesAbsoluteCursors() throws {
        let directory = URL(fileURLWithPath: "/tmp/smthz-d-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SessionManager(journal: try EventJournal(path: directory.appendingPathComponent("journal").path), outputLimit: 8, scrollbackDirectory: directory.appendingPathComponent("output"), scrollbackLimit: 32)
        let info = try manager.create(executable: "/bin/sh", arguments: ["-c", "printf 0123456789abcdefghij; read answer; printf ABCDEFGHIJKLMNOPQRSTUVWXYZ"])
        #expect(try durabilityEventually { try manager.read(id: info.id, from: 0).nextOffset == 20 })
        try manager.write(id: info.id, data: Data("\n".utf8))
        #expect(try durabilityEventually { try manager.read(id: info.id, from: 0).exit != nil })
        try manager.close(id: info.id)
        let all = try manager.read(id: info.id, from: 0)
        #expect(all.truncated)
        #expect(all.data.count == 32)
        let part = try manager.read(id: info.id, from: all.nextOffset - 32, maxBytes: 7)
        #expect(!part.truncated)
        let rest = try manager.read(id: info.id, from: part.nextOffset)
        #expect(part.data + rest.data == all.data)
        #expect(String(decoding: all.data.suffix(26), as: UTF8.self) == "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let file = directory.appendingPathComponent("output/\(info.id).scrollback")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.size] as? NSNumber)?.intValue == 56)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let archived = try SessionManager.readScrollback(id: info.id, directory: directory.appendingPathComponent("output"), from: 0)
        #expect(archived.data == all.data)
        #expect(archived.nextOffset == all.nextOffset)
        #expect(archived.truncated)
        #expect(try manager.read(id: info.id, from: UInt64.max).data.isEmpty)
    }

    @Test func storageFailureDoesNotLaunchAChildAndInvalidReplayIDsAreRejected() throws {
        let directory = URL(fileURLWithPath: "/tmp/smthz-d-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("not-directory")
        try Data().write(to: blocker)
        let manager = SessionManager(journal: try EventJournal(path: directory.appendingPathComponent("journal").path), scrollbackDirectory: blocker)
        #expect(throws: SessionError.scrollbackFailure) { try manager.create(executable: "/bin/sleep", arguments: ["30"]) }
        #expect(manager.list().isEmpty)
        #expect(throws: SessionError.badRequest) { try SessionManager.readScrollback(id: "../../elsewhere", directory: directory, from: 0) }
        #expect(throws: SessionError.badRequest) { try SessionManager.readScrollback(id: UUID().uuidString.lowercased(), directory: directory, from: 0, maxBytes: 0) }
    }
}

@Suite(.serialized)
struct PTYWriteDurabilityTests {
    @Test func cancelsWriteWhilePTYInputIsFull() throws {
        let directory = URL(fileURLWithPath: "/tmp/smthz-c-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manager = SessionManager(journal: try EventJournal(path: directory.appendingPathComponent("journal").path))
        let info = try manager.create(executable: "/bin/sh", arguments: ["-c", "stty -echo -icanon; echo READY; exec /bin/sleep 30"])
        defer { try? manager.close(id: info.id) }
        #expect(try durabilityEventually { String(decoding: try manager.read(id: info.id, from: 0).data, as: UTF8.self).contains("READY") })
        let deadline = Date(timeIntervalSinceNow: 0.1)
        #expect(throws: SessionError.cancelled) {
            try manager.write(id: info.id, data: Data(repeating: 120, count: SessionManager.maximumTransferBytes), shouldCancel: { Date() >= deadline })
        }
        #expect(Date().timeIntervalSince(deadline) < 1)
        #expect(manager.list().first?.running == true)
        try manager.close(id: info.id)
        #expect(!manager.list().contains { $0.running })
    }
}

private func descriptorsForScrollback(_ id: String) -> [Int32] {
    let descriptors = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []).compactMap(Int32.init)
    return descriptors.filter { fd in
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        let result = path.withUnsafeMutableBufferPointer { fcntl(fd, F_GETPATH, $0.baseAddress!) }
        guard result == 0 else { return false }
        let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).hasSuffix("/\(id).scrollback")
    }
}

@Suite(.serialized)
struct ScrollbackDescriptorDurabilityTests {
    @Test func closesDiskDescriptorsAndRejectsCorruptOrSymlinkedArchives() throws {
        let directory = URL(fileURLWithPath: "/tmp/smthz-f-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent("output")
        let manager = SessionManager(journal: try EventJournal(path: directory.appendingPathComponent("journal").path), scrollbackDirectory: output, scrollbackLimit: 64)
        let info = try manager.create(executable: "/bin/sh", arguments: ["-c", "printf READY; read answer"])
        defer { try? manager.close(id: info.id) }
        #expect(try durabilityEventually { try manager.read(id: info.id, from: 0).data == Data("READY".utf8) })
        let descriptors = descriptorsForScrollback(info.id)
        #expect(descriptors.count == 1)
        #expect(descriptors.allSatisfy { fcntl($0, F_GETFD) & FD_CLOEXEC != 0 })
        try manager.close(id: info.id)
        #expect(descriptorsForScrollback(info.id).isEmpty)
        for _ in 0..<20 {
            #expect(try SessionManager.readScrollback(id: info.id, directory: output, from: 0).data == Data("READY".utf8))
        }
        #expect(descriptorsForScrollback(info.id).isEmpty)
        let file = output.appendingPathComponent(info.id + ".scrollback")
        let alias = UUID().uuidString.lowercased()
        try FileManager.default.createSymbolicLink(at: output.appendingPathComponent(alias + ".scrollback"), withDestinationURL: file)
        #expect(throws: SessionError.scrollbackFailure) { try SessionManager.readScrollback(id: alias, directory: output, from: 0) }
        try Data("broken".utf8).write(to: file)
        #expect(throws: SessionError.scrollbackFailure) { try SessionManager.readScrollback(id: info.id, directory: output, from: 0) }
        #expect(descriptorsForScrollback(info.id).isEmpty)
    }
}
