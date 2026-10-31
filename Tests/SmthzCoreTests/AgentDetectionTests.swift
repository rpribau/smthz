import Darwin
import Foundation
import Testing
@testable import SmthzCore

private struct AgentProbeFixture {
    let directory: URL
    init() throws {
        directory = URL(fileURLWithPath: "/tmp/smthz-ag1-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    @discardableResult
    func binary(_ name: String, body: String, executable: Bool = true) throws -> String {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: url.path)
        return url.path
    }
    var path: String { directory.path }
}

struct AgentDetectionTests {
    @Test func emptyPathFindsNothing() async {
        #expect(await AgentDetector.detect(path: "").isEmpty)
    }

    @Test func findsVersionAndExactExecutable() async throws {
        let f = try AgentProbeFixture(); defer { f.cleanup() }
        let binary = try f.binary("claude", body: "[ \"$1\" = --version ] || exit 7\nprintf 'Claude Code v2.1.308\\n'")
        #expect(await AgentDetector.detect(path: f.path) == [DetectedAgent(id: .claude, executable: binary, version: "2.1.308")])
    }

    @Test func stderrVersionIsRecognized() async throws {
        let f = try AgentProbeFixture(); defer { f.cleanup() }
        try f.binary("codex", body: "echo 'codex-cli 1.2.3-beta.4+abc' >&2")
        let found = await AgentDetector.detect(path: f.path)
        #expect(found.first?.version == "1.2.3-beta.4+abc")
    }

    @Test func missingVersionAndFailedProbeStillDetectInstalledAgent() async throws {
        let f = try AgentProbeFixture(); defer { f.cleanup() }
        try f.binary("claude", body: "echo development")
        try f.binary("codex", body: "echo 9.9.9; exit 2")
        let found = await AgentDetector.detect(path: f.path)
        #expect(found.map(\.id) == [.claude, .codex])
        #expect(found.allSatisfy { $0.version == nil })
    }

    @Test func skipsNonExecutableAndDirectories() async throws {
        let f = try AgentProbeFixture(); defer { f.cleanup() }
        try f.binary("claude", body: "echo 1.0.0", executable: false)
        try FileManager.default.createDirectory(at: f.directory.appendingPathComponent("codex"), withIntermediateDirectories: false)
        #expect(await AgentDetector.detect(path: f.path).isEmpty)
    }

    @Test func aliasesAndRequiredCommands() async throws {
        let f = try AgentProbeFixture(); defer { f.cleanup() }
        let alias = try f.binary("dst", body: "echo 1.0.0")
        try f.binary("qoder", body: "echo 2.0.0")
        let before = await AgentDetector.detect(path: f.path)
        #expect(before.map(\.id) == [.qoder])
        try f.binary("dsh", body: "echo 3.0.0")
        let after = await AgentDetector.detect(path: f.path)
        #expect(after.first(where: { $0.id == .dsh })?.executable == alias)
    }

    @Test func teamsNeedsBothWrapperAndClaude() async throws {
        let f = try AgentProbeFixture(); defer { f.cleanup() }
        try f.binary("orca-ide", body: "echo 1.4.238")
        #expect(await AgentDetector.detect(path: f.path).isEmpty)
        try f.binary("claude", body: "echo 2.1.308")
        #expect(await AgentDetector.detect(path: f.path).map(\.id) == [.claude, .claudeAgentTeams])
    }

    @Test func preservesPathOrderAndHandlesSpacesWithoutShell() async throws {
        let f = try AgentProbeFixture(); defer { f.cleanup() }
        let nested = f.directory.appendingPathComponent("space ; literal")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedBinary = nested.appendingPathComponent("claude")
        try "#!/bin/sh\necho 1.0.0\n".write(to: nestedBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nestedBinary.path)
        try f.binary("claude", body: "echo 2.0.0")
        let found = await AgentDetector.detect(path: nested.path + ":" + f.path)
        #expect(found.first?.executable == nestedBinary.path)
        #expect(found.first?.version == "1.0.0")
    }

    @Test func probeReceivesRequestedSessionPath() async throws {
        let f = try AgentProbeFixture(); defer { f.cleanup() }
        try f.binary("helper", body: "echo 3.2.1")
        try f.binary("claude", body: "exec helper")
        #expect(await AgentDetector.detect(path: f.path).first?.version == "3.2.1")
    }

    @Test func boundedOutputDoesNotDeadlock() async throws {
        let f = try AgentProbeFixture(); defer { f.cleanup() }
        try f.binary("claude", body: "echo 1.2.3\ni=0; while [ $i -lt 20000 ]; do echo 'padding to fill output pipe'; i=$((i+1)); done")
        #expect(await AgentDetector.detect(path: f.path).first?.version == "1.2.3")
    }

    @Test func hangingProbeKilledAndReaped() async throws {
        let f = try AgentProbeFixture(); defer { f.cleanup() }
        let pidFile = f.directory.appendingPathComponent("pid")
        try f.binary("claude", body: "echo $$ > '\(pidFile.path)'\ntrap '' TERM\nwhile :; do :; done")
        let start = ContinuousClock.now
        let found = await AgentDetector.detect(path: f.path)
        let elapsed = start.duration(to: .now)
        #expect(found.map(\.id) == [.claude] && found.first?.version == nil)
        // Other concurrently running tests may queue probes ahead of this one;
        // the three-second deadline starts at spawn, not at queue submission.
        #expect(elapsed >= .seconds(3) && elapsed < .seconds(30))
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == -1 && errno == ECHILD)
    }

    @Test func concurrentProbesNeverExceedFour() async throws {
        let f = try AgentProbeFixture(); defer { f.cleanup() }
        // Each child owns a numbered directory while alive. Any fifth probe
        // observes all four slots taken and leaves durable violation evidence.
        let body = """
        slot=1
        while [ $slot -le 4 ]; do
          if /bin/mkdir '\(f.path)'/slot-$slot 2>/dev/null; then
            /bin/sleep 0.15
            /bin/rmdir '\(f.path)'/slot-$slot
            echo 1.0.0
            exit 0
          fi
          slot=$((slot+1))
        done
        echo violation > '\(f.path)/violation'
        """
        for name in ["claude", "codex", "aider", "goose", "amp", "kilo", "crush", "pi", "omp"] {
            try f.binary(name, body: body)
        }
        async let first = AgentDetector.detect(path: f.path)
        async let second = AgentDetector.detect(path: f.path)
        let results = await (first, second)
        #expect(results.0.count == 9 && results.1.count == 9)
        #expect(!FileManager.default.fileExists(atPath: f.path + "/violation"))
    }

    @Test func versionParsingRejectsDottedFragments() {
        #expect(AgentDetector.parseVersion("build 2026.10.31.4") == nil)
        #expect(AgentDetector.parseVersion("agent 0.9.17\n") == "0.9.17")
        #expect(AgentDetector.parseVersion("no version") == nil)
    }
}
