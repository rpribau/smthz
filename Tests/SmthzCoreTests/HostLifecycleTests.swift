import Darwin
import Foundation
import Testing
@testable import SmthzCore

private func lifecycleEventually(_ predicate: () throws -> Bool) rethrows -> Bool {
    let deadline = Date(timeIntervalSinceNow: 20)
    repeat {
        if try predicate() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    } while Date() < deadline
    return try predicate()
}

private final class LifecycleBundleMarker: NSObject {}

private final class LifecycleHost {
    let directory = URL(fileURLWithPath: "/tmp/sz-h2-" + UUID().uuidString.prefix(8))
    var processes: [Process] = []
    var logs: [FileHandle] = []
    var socket: String { directory.appendingPathComponent("smthzd.sock").path }

    func launch(extra: [String] = []) throws -> Process {
        var parent = Bundle(for: LifecycleBundleMarker.self).bundleURL.deletingLastPathComponent()
        while parent.path != "/", !FileManager.default.isExecutableFile(atPath: parent.appendingPathComponent("smthzd").path) {
            parent.deleteLastPathComponent()
        }
        let binary = parent.appendingPathComponent("smthzd")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("host-\(processes.count).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        logs.append(log)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--state-dir", directory.path] + extra
        process.standardOutput = log
        process.standardError = log
        try process.run()
        processes.append(process)
        return process
    }

    func connect(socket override: String? = nil) throws -> HostClient {
        let path = override ?? socket
        #expect(lifecycleEventually {
            guard let client = try? HostClient(socketPath: path) else { return false }
            client.disconnect()
            return true
        })
        return try HostClient(socketPath: path)
    }

    func stopped(_ process: Process) -> Bool {
        lifecycleEventually { !process.isRunning }
    }

    func marker(_ client: HostClient) throws -> SessionInfo {
        let session = try client.createSession(executable: "/bin/sh", arguments: ["-c", "printf H2_REPLAY_MARKER"])
        #expect(try lifecycleEventually {
            let read = try client.read(id: session.id)
            return read.exit != nil && String(decoding: read.data, as: UTF8.self).contains("H2_REPLAY_MARKER")
        })
        return session
    }

    deinit {
        for process in processes where process.isRunning { process.terminate() }
        for process in processes {
            if !lifecycleEventually({ !process.isRunning }) {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        for log in logs { try? log.close() }
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite(.serialized)
struct HostLifecycleTests {
    @Test func secondHostExitsThreeAndFirstStillServes() throws {
        let host = LifecycleHost()
        let first = try host.launch()
        let client = try host.connect()
        defer { client.disconnect() }
        let second = try host.launch()
        #expect(host.stopped(second))
        #expect(second.terminationStatus == 3)
        let log = try String(contentsOf: host.directory.appendingPathComponent("host-1.log"), encoding: .utf8)
        #expect(log.contains("smthzd already running"))
        #expect(first.isRunning)
        #expect(try client.list().sessions.isEmpty)
        try client.shutdown()
        #expect(host.stopped(first))
    }

    @Test func racingHostsHaveExactlyOneWinner() throws {
        let host = LifecycleHost()
        let first = try host.launch()
        let second = try host.launch()
        #expect(lifecycleEventually { first.isRunning != second.isRunning })
        let loser = first.isRunning ? second : first
        let winner = first.isRunning ? first : second
        #expect(host.stopped(loser))
        #expect(loser.terminationStatus == 3)
        let client = try host.connect()
        defer { client.disconnect() }
        try client.shutdown()
        #expect(host.stopped(winner))
        #expect(winner.terminationStatus == 0)
    }

    @Test func shutdownFlushesAcknowledgementKillsProcessGroupAndRemovesSocket() throws {
        let host = LifecycleHost()
        let process = try host.launch()
        let client = try host.connect()
        defer { client.disconnect() }
        let session = try client.createSession(executable: "/bin/sh", arguments: ["-c", "sleep 300 & echo $!; wait"])
        var grandchild: Int32?
        #expect(try lifecycleEventually {
            let text = String(decoding: try client.read(id: session.id).data, as: UTF8.self)
            grandchild = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
            return grandchild != nil
        })
        let child = try #require(grandchild)
        #expect(try client.shutdown().ok)
        #expect(host.stopped(process))
        #expect(process.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: host.socket))
        #expect(lifecycleEventually { kill(session.pid, 0) == -1 && errno == ESRCH })
        #expect(lifecycleEventually { kill(child, 0) == -1 && errno == ESRCH })
    }

    @Test func restartReleasesLockAndReplaysPreviousIncarnation() throws {
        let host = LifecycleHost()
        let first = try host.launch()
        let client = try host.connect()
        let session = try host.marker(client)
        try client.shutdown()
        client.disconnect()
        #expect(host.stopped(first))
        let second = try host.launch()
        let nextClient = try host.connect()
        defer { nextClient.disconnect() }
        #expect(try nextClient.list().sessions.isEmpty)
        let replay = try nextClient.replay(id: session.id)
        #expect(String(decoding: replay.data, as: UTF8.self).contains("H2_REPLAY_MARKER"))
        #expect(replay.eof)
        try nextClient.shutdown()
        #expect(host.stopped(second))
    }

    @Test func replayPaginatesAndScrollbackIsPrivateWithDefaultCapacity() throws {
        let host = LifecycleHost()
        let process = try host.launch()
        let client = try host.connect()
        defer { client.disconnect() }
        let session = try host.marker(client)
        let first = try client.replay(id: session.id, maxBytes: 3)
        #expect(first.data == Data("H2_".utf8))
        #expect(first.next == 3 && !first.eof)
        let rest = try client.replay(id: session.id, from: first.next)
        #expect(first.data + rest.data == Data("H2_REPLAY_MARKER".utf8))
        #expect(rest.eof)
        let empty = try client.replay(id: session.id, from: rest.next)
        #expect(empty.data.isEmpty && empty.eof)
        let file = host.directory.appendingPathComponent("scrollback/" + session.id + ".scrollback")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((attributes[.size] as? NSNumber)?.intValue == 16 * 1_048_576 + 24)
        try client.shutdown()
        #expect(host.stopped(process))
    }

    @Test func replayRejectsTraversalUppercaseUnknownAndInvalidLimits() throws {
        let host = LifecycleHost()
        let process = try host.launch()
        let client = try host.connect()
        defer { client.disconnect() }
        for id in ["../journal.sqlite", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "bogus"] {
            #expect(throws: HostClientError.hostError(code: "badRequest")) { try client.replay(id: id) }
        }
        let missing = UUID().uuidString.lowercased()
        #expect(throws: HostClientError.hostError(code: "unknownSession")) { try client.replay(id: missing) }
        #expect(throws: HostClientError.hostError(code: "badRequest")) { try client.replay(id: missing, maxBytes: 0) }
        try client.shutdown()
        #expect(host.stopped(process))
    }

    @Test func shutdownIsAuthenticatedAndJournaled() throws {
        let host = LifecycleHost()
        let process = try host.launch()
        let client = try host.connect()
        defer { client.disconnect() }
        let raw = try UnixSocketClient(path: host.socket)
        let request = RPCEnvelope(version: RPCEnvelope.currentVersion, requestID: RequestID.generate().rawValue,
                                  method: "host.shutdown", payload: Data("{}".utf8))
        let response = try JSONDecoder().decode(RPCEnvelope.self, from: raw.request(JSONEncoder().encode(request)))
        let body = try JSONSerialization.jsonObject(with: response.payload) as? [String: Any]
        #expect(body?["error"] as? String == "unauthorized")
        raw.close()
        #expect(process.isRunning)
        struct Params: Encodable {}
        let id = RequestID.generate().rawValue
        let ack: HostAcknowledgement = try client.call(method: "host.shutdown", params: Params(), requestID: id)
        #expect(ack.ok)
        #expect(host.stopped(process))
        let journal = try EventJournal(path: host.directory.appendingPathComponent("journal.sqlite").path)
        #expect(try journal.entry(requestID: id) != nil)
    }

    @Test func explicitSocketAndJournalOverrideStateDefaults() throws {
        let host = LifecycleHost()
        let socket = host.directory.appendingPathComponent("override.sock").path
        let journal = host.directory.appendingPathComponent("override.sqlite").path
        let process = try host.launch(extra: ["--socket", socket, "--journal", journal])
        let client = try host.connect(socket: socket)
        defer { client.disconnect() }
        #expect(FileManager.default.fileExists(atPath: journal))
        #expect(!FileManager.default.fileExists(atPath: host.socket))
        #expect(!FileManager.default.fileExists(atPath: host.directory.appendingPathComponent("journal.sqlite").path))
        try client.shutdown()
        #expect(host.stopped(process))
    }
}
