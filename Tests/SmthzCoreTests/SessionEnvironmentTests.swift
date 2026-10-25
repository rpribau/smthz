import Darwin
import Foundation
import Testing
@testable import SmthzCore

private let testAccount = SessionEnvironment.Account(name: "tester", home: "/Users/tester", shell: "/bin/zsh")

private final class EnvFixture {
    let directory = "/tmp/smthz-env-\(UUID().uuidString.prefix(8))"
    let service: HostService
    let server: UnixSocketServer
    init(hostEnvironment: [String: String]) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let host = HostService(journal: try EventJournal(path: directory + "/j"), hostIdentity: nil,
                               hostEnvironment: hostEnvironment)
        service = host
        server = try UnixSocketServer(path: directory + "/s") { host.handle($0) }
    }
    func client() throws -> HostClient { try HostClient(socketPath: directory + "/s") }
    deinit {
        for session in service.sessionManager.list() { try? service.sessionManager.close(id: session.id) }
        server.stop()
        try? FileManager.default.removeItem(atPath: directory)
    }
}

private func envEventually(_ predicate: () throws -> Bool) rethrows -> Bool {
    let deadline = Date(timeIntervalSinceNow: 8)
    repeat {
        if try predicate() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    } while Date() < deadline
    return try predicate()
}

private func readAll(_ client: HostClient, _ id: String) throws -> Data {
    try client.read(id: id).data
}

struct SessionEnvironmentTests {
    @Test func dumbHostGetsTerminalDefaults() {
        let env = SessionEnvironment.build(base: ["TERM": "dumb", "FOO": "bar"], account: testAccount)
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["LANG"] == "en_US.UTF-8")
        #expect(env["FOO"] == "bar")
        #expect(env["HOME"] == "/Users/tester")
        #expect(env["USER"] == "tester")
        #expect(env["LOGNAME"] == "tester")
        #expect(env["SHELL"] == "/bin/zsh")
    }

    @Test func unsetTermIsDefaulted() {
        #expect(SessionEnvironment.build(base: [:], account: testAccount)["TERM"] == "xterm-256color")
    }

    @Test func utf8LangIsKeptOthersReplaced() {
        #expect(SessionEnvironment.build(base: ["LANG": "es_ES.UTF-8"], account: testAccount)["LANG"] == "es_ES.UTF-8")
        #expect(SessionEnvironment.build(base: ["LANG": "es_ES.utf8"], account: testAccount)["LANG"] == "es_ES.utf8")
        #expect(SessionEnvironment.build(base: ["LANG": "C"], account: testAccount)["LANG"] == "en_US.UTF-8")
        let env = SessionEnvironment.build(base: ["LC_ALL": "C", "LC_CTYPE": "en_US.UTF-8"], account: testAccount)
        #expect(env["LC_ALL"] == nil)
        #expect(env["LC_CTYPE"] == "en_US.UTF-8")
    }

    @Test func pathStartsWithStandardEntriesWithoutXcodeToolchain() {
        let host = "/Applications/Xcode.app/Contents/Developer/usr/bin:/usr/bin:/opt/tools/bin:/bin"
        let path = SessionEnvironment.build(base: ["PATH": host], account: testAccount)["PATH"]
        #expect(path == "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/tools/bin")
        #expect(SessionEnvironment.build(base: [:], account: testAccount)["PATH"]
                == "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func hostIdentityVariablesAreKept() {
        let env = SessionEnvironment.build(base: ["HOME": "/h", "USER": "u", "LOGNAME": "l", "SHELL": "/bin/sh"], account: testAccount)
        #expect(env["HOME"] == "/h" && env["USER"] == "u" && env["LOGNAME"] == "l" && env["SHELL"] == "/bin/sh")
    }

    @Test func hostTerminalLeftoversAreDropped() {
        let env = SessionEnvironment.build(base: ["TERM_PROGRAM": "Apple_Terminal", "COLUMNS": "200", "LINES": "50"], account: testAccount)
        #expect(env["TERM_PROGRAM"] == nil && env["COLUMNS"] == nil && env["LINES"] == nil)
    }

    @Test func explicitOverrideWins() {
        let env = SessionEnvironment.build(base: ["TERM": "dumb", "A": "1"],
                                           override: ["TERM": "vt100", "B": "2", "LANG": "C"], account: testAccount)
        #expect(env["TERM"] == "vt100")
        #expect(env["LANG"] == "C")
        #expect(env["A"] == "1" && env["B"] == "2")
    }
}

@Suite(.serialized)
struct SessionEnvironmentHostTests {
    private static let dumbHost = ["TERM": "dumb", "PATH": "/Applications/Xcode.app/Contents/Developer/usr/bin:/usr/bin:/bin"]

    @Test func sessionUnderDumbHostSeesTerminalDefaults() throws {
        let fixture = try EnvFixture(hostEnvironment: Self.dumbHost)
        let client = try fixture.client()
        defer { client.disconnect() }
        let session = try client.createSession(executable: "/bin/sh",
            arguments: ["-c", "echo T=$TERM C=$COLORTERM L=$LANG P=$PATH"])
        #expect(try envEventually {
            String(decoding: try readAll(client, session.id), as: UTF8.self).contains("P=")
        })
        let text = String(decoding: try readAll(client, session.id), as: UTF8.self)
        #expect(text.contains("T=xterm-256color C=truecolor L=en_US.UTF-8"))
        #expect(text.contains("P=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"))
        #expect(!text.contains("Xcode.app"))
    }

    @Test func clearEmitsClearSequenceUnderDumbHost() throws {
        let fixture = try EnvFixture(hostEnvironment: Self.dumbHost)
        let client = try fixture.client()
        defer { client.disconnect() }
        let session = try client.createSession(executable: "/usr/bin/clear")
        let expected = Data([0x1B, 0x5B, 0x33, 0x4A, 0x1B, 0x5B, 0x48, 0x1B, 0x5B, 0x32, 0x4A])
        #expect(try envEventually { try readAll(client, session.id).range(of: expected) != nil })
    }

    @Test func explicitEnvironmentOverrideIsHonoured() throws {
        let fixture = try EnvFixture(hostEnvironment: Self.dumbHost)
        let client = try fixture.client()
        defer { client.disconnect() }
        let session = try client.createSession(executable: "/bin/sh", arguments: ["-c", "echo T=$TERM X=$EXTRA"],
                                               environment: ["TERM": "vt100", "EXTRA": "yes"])
        #expect(try envEventually {
            String(decoding: try readAll(client, session.id), as: UTF8.self).contains("T=vt100 X=yes")
        })
    }
}
