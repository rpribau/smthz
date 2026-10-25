import Darwin
import Foundation
import Testing
@testable import SmthzCore

private func hostStopJournal() throws -> (String, EventJournal) {
    let path = "/tmp/smthz-hs-\(UUID().uuidString.prefix(8))"
    return (path, try EventJournal(path: path))
}

private func hostStopCleanup(_ path: String) {
    for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
}

private func hostStopEventually(_ predicate: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: 3)
    repeat {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return predicate()
}

@Suite(.serialized)
struct HostStopTests {
    @Test func managerStopKillsLeaderAndGrandchild() throws {
        let (path, journal) = try hostStopJournal()
        defer { hostStopCleanup(path) }
        let manager = SessionManager(journal: journal)
        let session = try manager.create(executable: "/bin/sh", arguments: ["-c", "sleep 30 & echo $!; wait"])
        let grandchildPID: Int32? = {
            let deadline = Date(timeIntervalSinceNow: 3)
            while Date() < deadline {
                if let read = try? manager.read(id: session.id, from: 0),
                   let text = String(data: read.data, encoding: .utf8),
                   let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return value }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return nil
        }()
        let leader = session.pid
        manager.stop(timeout: 3)
        #expect(kill(leader, 0) == -1 && errno == ESRCH)
        if let grandchildPID {
            #expect(hostStopEventually { kill(grandchildPID, 0) == -1 && errno == ESRCH })
        } else {
            Issue.record("shell did not report its grandchild pid")
        }
        #expect(throws: SessionError.notRunning) {
            try manager.create(executable: "/bin/sleep", arguments: ["30"])
        }
    }

    @Test func hostServiceStopAndDeinitKillLiveChildren() throws {
        let (path, journal) = try hostStopJournal()
        defer { hostStopCleanup(path) }
        var service: HostService? = HostService(journal: journal, hostIdentity: nil)
        let session = try service!.sessionManager.create(executable: "/bin/sleep", arguments: ["30"])
        service!.stop()
        #expect(kill(session.pid, 0) == -1 && errno == ESRCH)

        service = HostService(journal: journal, hostIdentity: nil)
        let second = try service!.sessionManager.create(executable: "/bin/sleep", arguments: ["30"])
        service = nil
        #expect(kill(second.pid, 0) == -1 && errno == ESRCH)
    }
}
