import Foundation
import Testing
@testable import SmthzCore

final class GitProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var count: Int { lock.withLock { lines.count } }
}
struct GitRunModeTests {
    @Test func userIdentityComesFromGlobalConfigWhileIsolatedModeFails() async throws {
        let f = try HostCoreFixture(), git = GitService()
        let config = f.directory.appendingPathComponent("global")
        try Data("[user]\n name = Host Core Test\n email = hostcore@example.invalid\n".utf8).write(to: config)
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_GLOBAL"] = config.path; environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["HOME"] = f.directory.path
        _ = try await git.run(["init", "-q"], at: f.directory, environment: environment)
        let isolated = try await git.run(["commit", "--allow-empty", "-m", "isolated"], at: f.directory,
            mode: .isolatedRead, environment: environment, allowFailure: true)
        #expect(isolated.code != 0)
        _ = try await git.run(["commit", "--allow-empty", "-m", "user"], at: f.directory, environment: environment)
        let author = try await git.run(["log", "-1", "--format=%an <%ae>"], at: f.directory, mode: .isolatedRead)
        #expect(author.stdout.contains("Host Core Test <hostcore@example.invalid>"))
    }
    @Test func stdinAndHooksAndLiveStderrWork() async throws {
        let f = try HostCoreFixture(), git = GitService()
        _ = try await git.run(["init", "-q"], at: f.directory)
        let hook = f.directory.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\necho 'hook-progress' >&2\nsleep 0.2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let capture = GitProgressCapture()
        let result = try await git.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "test"],
            at: f.directory, stderr: { capture.append($0) }, allowFailure: true)
        #expect(result.code != 0)
        #expect(capture.count == 1)
        let hashed = try await git.run(["hash-object", "--stdin"], at: f.directory, stdin: Data("hello\n".utf8))
        #expect(hashed.stdout == "ce013625030ba8dba906f756967f9e9ca394464a\n")
    }
    @Test func recordedProgressParser() throws {
        for line in ["Updating files:  42% (42/100)\r", "Receiving objects: 100% (7/7), done.", "Resolving deltas: 50% (1/2)"] {
            let progress = try #require(GitProgress.parse(line))
            #expect(progress.done > 0); #expect(progress.total >= progress.done)
        }
        #expect(GitProgress.parse("fatal: failure") == nil)
    }
    @Test func nilWriteTimeoutAndExplicitTimeout() async throws {
        let f = try HostCoreFixture(), git = GitService(timeout: 0.01)
        // A write call's nil timeout does not inherit the read-service deadline.
        _ = try await git.run(["-c", "alias.slow=!sleep 0.1", "slow"], at: f.directory)
        await #expect(throws: GitError.timedOut) {
            try await git.run(["-c", "alias.slow=!sleep 10", "slow"], at: f.directory, timeout: 0.02)
        }
    }
    @Test func authenticationFailureIsTyped() async throws {
        let f = try HostCoreFixture()
        do {
            _ = try await GitService().run(["-c", "alias.auth=!echo 'fatal: could not read Username: terminal prompts disabled' >&2; exit 1", "auth"], at: f.directory)
            Issue.record("expected authenticationRequired")
        } catch GitError.authenticationRequired(let detail) { #expect(detail.contains("terminal prompts disabled")) }
    }
}
