import Darwin
import Foundation
import Testing
@testable import SmthzCore

private final class LauncherBundleMarker: NSObject {}

private func launcherEventually(_ predicate: () -> Bool) -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    repeat {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.025)
    } while ContinuousClock.now < deadline
    return predicate()
}

private final class LauncherFixture {
    let endpoint = HostEndpoint(stateDirectory: URL(fileURLWithPath: "/tmp/sz-h3-" + UUID().uuidString.prefix(8)))
    let executable: URL
    var identities: [ProcessIdentity] = []

    init() throws {
        var parent = Bundle(for: LauncherBundleMarker.self).bundleURL.deletingLastPathComponent()
        while parent.path != "/", !FileManager.default.isExecutableFile(atPath: parent.appendingPathComponent("smthzd").path) {
            parent.deleteLastPathComponent()
        }
        executable = parent.appendingPathComponent("smthzd")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path), "Run swift build before swift test")
        #expect(endpoint.socketPath.utf8.count < 104)
    }

    func launcher(appVersion: String = ApplicationIdentity.version,
                  throttle: (attempts: Int, window: Duration) = (3, .seconds(60))) -> HostLauncher {
        HostLauncher(endpoint: endpoint, executable: executable, appVersion: appVersion, throttle: throttle)
    }

    func started(_ state: HostLaunchState) throws -> ProcessIdentity {
        guard case .startedByUs(let identity) = state else {
            Issue.record("Expected startedByUs, got \(state)")
            throw HostLauncherError.invalidResponse
        }
        identities.append(identity)
        return identity
    }

    deinit {
        // Also discover a child if an assertion failed before its identity was recorded.
        if let client = try? HostClient(socketPath: endpoint.socketPath) {
            struct Empty: Encodable {}
            if let id: ProcessIdentity = try? client.call(method: "host.identity", params: Empty()) {
                identities.append(id)
            }
            _ = try? client.shutdown()
            client.disconnect()
        }
        for identity in identities where identity.isStillRunning() {
            if !launcherEventually({ !identity.isStillRunning() }) {
                if identity.isStillRunning() { Darwin.kill(identity.pid, SIGTERM) }
                if !launcherEventually({ !identity.isStillRunning() }), identity.isStillRunning() {
                    Darwin.kill(identity.pid, SIGKILL)
                }
            }
        }
        try? FileManager.default.removeItem(at: endpoint.stateDirectory)
    }
}

@Suite(.serialized)
struct HostLauncherTests {
    @Test func endpointPaths() {
        let home = URL(fileURLWithPath: "/tmp/test-home")
        let endpoint = HostEndpoint.standard(home: home)
        #expect(endpoint.stateDirectory == ApplicationIdentity.applicationSupportDirectory(home: home))
        #expect(endpoint.socketPath == home.path + "/Library/Application Support/smthz/smthzd.sock")
        #expect(endpoint.logPath == home.path + "/Library/Logs/smthz/smthzd.log")
    }

    @Test func startsRealHostAndPingWorksWithPrivateLog() async throws {
        let fixture = try LauncherFixture()
        let launcher = fixture.launcher()
        let identity = try fixture.started(await launcher.ensureRunning(timeout: .seconds(20)))
        #expect(identity.isStillRunning())
        let client = try HostClient(socketPath: fixture.endpoint.socketPath)
        defer { client.disconnect() }
        struct Empty: Encodable {}
        struct Pong: Decodable { let result: String }
        let pong: Pong = try client.call(method: "ping", params: Empty())
        #expect(pong.result == "pong")
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.endpoint.logPath)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        try await launcher.stop(expected: identity, timeout: .seconds(20))
    }

    @Test func alreadyRunningReturnsSameIdentityWithoutSpawning() async throws {
        let fixture = try LauncherFixture()
        let first = fixture.launcher()
        let id = try fixture.started(await first.ensureRunning(timeout: .seconds(20)))
        let second = fixture.launcher(throttle: (0, .seconds(60)))
        #expect(await second.ensureRunning(timeout: .seconds(20)) == .running(
            identity: id, version: ApplicationIdentity.version, compatible: true))
        try await first.stop(expected: id, timeout: .seconds(20))
    }

    @Test func survivesOwningTaskAndLauncherInSeparateSession() async throws {
        let fixture = try LauncherFixture()
        let endpoint = fixture.endpoint
        let binary = fixture.executable
        let state = await Task {
            let launcher = HostLauncher(endpoint: endpoint, executable: binary)
            return await launcher.ensureRunning(timeout: .seconds(20))
        }.value
        let id = try fixture.started(state)
        #expect(getsid(id.pid) == id.pid)
        #expect(getsid(id.pid) != getsid(getpid()))
        #expect(id.isStillRunning())
        let client = try HostClient(socketPath: endpoint.socketPath)
        #expect(try client.list().sessions.isEmpty)
        client.disconnect()
        try await fixture.launcher().stop(expected: id, timeout: .seconds(20))
    }

    @Test func failedExecutableLogsAndFourthAttemptIsThrottled() async throws {
        let fixture = try LauncherFixture()
        try FileManager.default.createDirectory(at: fixture.endpoint.stateDirectory, withIntermediateDirectories: true)
        let fake = fixture.endpoint.stateDirectory.appendingPathComponent("fail.sh")
        try "#!/bin/sh\necho H3_FAILURE_MARKER >&2\nexit 1\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let launcher = HostLauncher(endpoint: fixture.endpoint, executable: fake)
        for _ in 0..<3 {
            let state = await launcher.ensureRunning(timeout: .seconds(20))
            guard case .failed(let status, let tail) = state else {
                Issue.record("Expected failure, got \(state)"); return
            }
            #expect(status == 1)
            #expect(tail.contains("H3_FAILURE_MARKER"))
        }
        guard case .throttled(let retry) = await launcher.ensureRunning() else {
            Issue.record("Expected throttle"); return
        }
        #expect(retry > .zero && retry <= .seconds(60))
    }

    @Test func wrongStartTimeRefusesWithoutStoppingHost() async throws {
        let fixture = try LauncherFixture()
        let launcher = fixture.launcher()
        let id = try fixture.started(await launcher.ensureRunning(timeout: .seconds(20)))
        let wrong = ProcessIdentity(pid: id.pid, startSeconds: id.startSeconds + 1, startMicroseconds: id.startMicroseconds)
        await #expect(throws: HostLauncherError.identityMismatch) {
            try await launcher.stop(expected: wrong, timeout: .seconds(20))
        }
        #expect(id.isStillRunning())
        let client = try HostClient(socketPath: fixture.endpoint.socketPath)
        #expect(try client.list().sessions.isEmpty)
        client.disconnect()
        try await launcher.stop(expected: id, timeout: .seconds(20))
    }

    @Test func stopExitsRemovesSocketAndCanRestart() async throws {
        let fixture = try LauncherFixture()
        let launcher = fixture.launcher()
        let first = try fixture.started(await launcher.ensureRunning(timeout: .seconds(20)))
        try await launcher.stop(expected: first, timeout: .seconds(20))
        #expect(!first.isStillRunning())
        #expect(!FileManager.default.fileExists(atPath: fixture.endpoint.socketPath))
        let second = try fixture.started(await launcher.ensureRunning(timeout: .seconds(20)))
        #expect(second != first)
        try await launcher.stop(expected: second, timeout: .seconds(20))
    }

    @Test func acceptingNonResponderIsUnreachableAndNeverSpawns() async throws {
        let fixture = try LauncherFixture()
        try FileManager.default.createDirectory(at: fixture.endpoint.stateDirectory, withIntermediateDirectories: true)
        _ = try HostCapabilityToken.load(path: HostCapabilityToken.path(socketPath: fixture.endpoint.socketPath), create: true)
        let server = try UnixSocketServer(path: fixture.endpoint.socketPath) { _ in
            Thread.sleep(forTimeInterval: 3)
            return Data()
        }
        defer { server.stop() }
        let state = await fixture.launcher().ensureRunning(timeout: .seconds(1))
        guard case .unreachable = state else { Issue.record("Expected unreachable, got \(state)"); return }
        #expect(!FileManager.default.fileExists(atPath: fixture.endpoint.logPath))
        // Remove the dummy before fixture cleanup attempts an authenticated RPC.
        server.stop()
    }

    @Test func versionMismatchIsReportedWithoutRestart() async throws {
        let fixture = try LauncherFixture()
        let launcher = fixture.launcher()
        let id = try fixture.started(await launcher.ensureRunning(timeout: .seconds(20)))
        let other = fixture.launcher(appVersion: "future-app")
        #expect(await other.ensureRunning(timeout: .seconds(20)) == .running(
            identity: id, version: ApplicationIdentity.version, compatible: false))
        #expect(id.isStillRunning())
        try await launcher.stop(expected: id, timeout: .seconds(20))
    }

    @Test func fallbackSignalsOnlyVerifiedIdentityWhenEndpointMissing() async throws {
        let fixture = try LauncherFixture()
        let id = try fixture.started(await fixture.launcher().ensureRunning(timeout: .seconds(20)))
        let missing = HostEndpoint(stateDirectory: fixture.endpoint.stateDirectory.appendingPathComponent("missing"))
        let fallback = HostLauncher(endpoint: missing, executable: fixture.executable)
        try await fallback.stop(expected: id, timeout: .seconds(20))
        #expect(!id.isStillRunning())
        #expect(!FileManager.default.fileExists(atPath: fixture.endpoint.socketPath))
    }

    @Test func simultaneousRequestsLaunchOnce() async throws {
        let fixture = try LauncherFixture()
        let launcher = fixture.launcher()
        async let first = launcher.ensureRunning(timeout: .seconds(20))
        async let second = launcher.ensureRunning(timeout: .seconds(20))
        let states = await [first, second]
        let started = states.compactMap { state -> ProcessIdentity? in
            if case .startedByUs(let id) = state { return id }
            return nil
        }
        #expect(started.count == 1)
        let id = try #require(started.first)
        fixture.identities.append(id)
        #expect(states.contains(.running(identity: id, version: ApplicationIdentity.version, compatible: true)))
        try await launcher.stop(expected: id, timeout: .seconds(20))
    }

    @Test func endpointIdentityMismatchRefusesShutdownOfEitherHost() async throws {
        let first = try LauncherFixture()
        let second = try LauncherFixture()
        let firstLauncher = first.launcher()
        let secondLauncher = second.launcher()
        let a = try first.started(await firstLauncher.ensureRunning(timeout: .seconds(20)))
        let b = try second.started(await secondLauncher.ensureRunning(timeout: .seconds(20)))
        await #expect(throws: HostLauncherError.identityMismatch) {
            try await secondLauncher.stop(expected: a, timeout: .seconds(20))
        }
        #expect(a.isStillRunning() && b.isStillRunning())
        try await firstLauncher.stop(expected: a, timeout: .seconds(20))
        try await secondLauncher.stop(expected: b, timeout: .seconds(20))
    }

    @Test func authenticationFailureDoesNotConsumeSpawnBudget() async throws {
        let fixture = try LauncherFixture()
        let server = try UnixSocketServer(path: fixture.endpoint.socketPath) { _ in Data() }
        let launcher = fixture.launcher(throttle: (0, .seconds(60)))
        for _ in 0..<2 {
            guard case .unreachable = await launcher.ensureRunning(timeout: .seconds(20)) else {
                Issue.record("Expected unreachable for missing capability token")
                server.stop()
                return
            }
        }
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: fixture.endpoint.logPath))
        guard case .throttled = await launcher.ensureRunning() else {
            Issue.record("Expected zero spawn budget after endpoint disappeared"); return
        }
    }

    @Test func refusedNonSocketNeverUnlinksExistingName() async throws {
        let fixture = try LauncherFixture()
        try FileManager.default.createDirectory(at: fixture.endpoint.stateDirectory, withIntermediateDirectories: true)
        try Data("not a socket".utf8).write(to: URL(fileURLWithPath: fixture.endpoint.socketPath))
        // A regular file is refused by connect on Darwin. Preserve its name and
        // contents regardless of whether that refusal permits a spawn attempt.
        _ = await fixture.launcher().ensureRunning(timeout: .seconds(20))
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.endpoint.socketPath)) == Data("not a socket".utf8))
    }
}
