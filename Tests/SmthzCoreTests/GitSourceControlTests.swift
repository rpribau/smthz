import Darwin
import Foundation
import Testing
@testable import SmthzCore

/// Temp work tree with a temp global identity, Source Control RPC registered on a test host.
final class SourceControlFixture: @unchecked Sendable {
    let host = try! HostCoreFixture()
    let store: WorkspaceStore
    let environment: [String: String]
    let repo: URL
    var directory: URL { host.directory }

    /// Host calls block on Git work, so they run on a dedicated thread, never on the test's executor.
    static func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in Thread.detachNewThread { c.resume(with: Result { try body() }) } }
    }

    static func make() async throws -> SourceControlFixture { try await offPool { try SourceControlFixture() } }

    private init() throws {
        store = try WorkspaceStore(path: host.directory.appendingPathComponent("workspace.sqlite").path)
        let config = host.directory.appendingPathComponent("gitconfig")
        try Data("""
        [user]
        \tname = SC Test
        \temail = sc@example.invalid
        [init]
        \tdefaultBranch = main
        [pull]
        \trebase = false
        [commit]
        \tgpgsign = false
        """.utf8).write(to: config)
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_CONFIG_GLOBAL"] = config.path; env["GIT_CONFIG_NOSYSTEM"] = "1"; env["HOME"] = host.directory.path
        environment = env
        repo = host.directory.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: false)
        _ = try gitSync(["init", "-q"])
        GitWriteRPC.register(on: host.router, store: store, environment: environment)
    }

    @discardableResult
    func git(_ arguments: [String], at directory: URL? = nil) async throws -> String {
        try await Self.offPool { try self.gitSync(arguments, at: directory) }
    }

    private func gitSync(_ arguments: [String], at directory: URL? = nil) throws -> String {
        let at = directory ?? repo, env = environment
        return try GitWriteRPC.blocking { try await GitService().run(arguments, at: at, environment: env).stdout }
    }

    func write(_ path: String, _ text: String, in root: URL? = nil) throws {
        let url = (root ?? repo).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func scm(_ root: URL? = nil) -> GitSourceControl { GitService().sourceControl(root: root ?? repo, environment: environment) }

    func call(_ method: String, _ params: [String: HostJSON] = [:], root: URL? = nil) async throws -> [String: HostJSON] {
        var p = params; p["worktreePath"] = .string((root ?? repo).path)
        return try await hostCall(method, p)
    }

    func hostCall(_ method: String, _ params: [String: HostJSON]) async throws -> [String: HostJSON] {
        try await Self.offPool { try self.host.call(method, params) }
    }

    func accept(_ path: String) async throws -> GitWriteRPC.AcceptedRoot {
        try await Self.offPool { try GitWriteRPC.acceptRoot(path, store: self.store) }
    }

    func status(_ root: URL? = nil) async throws -> GitSourceControlStatus { try await scm(root).status() }

    /// Polls job.get until the job finishes, returning the final snapshot.
    func runJob(_ method: String, _ params: [String: HostJSON] = [:], root: URL? = nil) async throws -> [String: HostJSON] {
        let started = try await call(method, params, root: root)
        guard let id = started["jobId"]?.string else { Issue.record("no jobId: \(started)"); return started }
        while true {
            let snapshot = try await hostCall("job.get", ["jobId": .string(id)])
            if ["succeeded", "failed", "cancelled"].contains(snapshot["state"]?.string ?? "") { return snapshot }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Bare remote at `remote.git` with one commit on main, plus `work` tracking it.
    func withRemote() async throws -> URL {
        let bare = host.directory.appendingPathComponent("remote.git")
        try await git(["init", "-q", "--bare", bare.path])
        try write("README.md", "hello\n")
        try await git(["add", "README.md"]); try await git(["commit", "-q", "-m", "initial"])
        try await git(["remote", "add", "origin", bare.path])
        try await git(["push", "-q", "-u", "origin", "main"])
        return bare
    }

    /// A second clone of the bare remote that can push competing commits.
    func otherClone(of bare: URL) async throws -> URL {
        let other = host.directory.appendingPathComponent("other")
        try await git(["clone", "-q", bare.path, other.path], at: host.directory)
        return other
    }
}

private func indexed(_ s: GitSourceControlStatus) -> Set<String> {
    Set(s.status.entries.filter { $0.kind != .untracked && $0.indexStatus != "." }.map(\.path))
}

/// Serialized: each test drives many real Git processes, and running them all at once
/// competes with the timing-sensitive host tests in the same run.
@Suite(.serialized)
struct GitSourceControlTests {
    @Test func stageAndUnstageSingleManyAndNonASCIIPaths() async throws {
        let f = try await SourceControlFixture.make()
        try f.write("README.md", "x\n"); try await f.git(["add", "README.md"]); try await f.git(["commit", "-q", "-m", "base"])
        let odd = ["café/naïve 日本.txt", "a*.txt", "ab.txt", "-leading dash.txt", "space name.txt"]
        for path in odd { try f.write(path, path) }
        #expect(try await f.call("git.stage", ["paths": .array([.string("a*.txt")])])["ok"] == .bool(true))
        #expect(indexed(try await f.status()) == ["a*.txt"], "pathspec magic must be literal")
        #expect(try await f.call("git.stage", ["paths": .array(odd.map(HostJSON.string))])["ok"] == .bool(true))
        #expect(indexed(try await f.status()) == Set(odd))
        #expect(try await f.call("git.unstage", ["paths": .array([.string("café/naïve 日本.txt")])])["ok"] == .bool(true))
        #expect(indexed(try await f.status()) == Set(odd).subtracting(["café/naïve 日本.txt"]))
        _ = try await f.call("git.unstageAll")
        #expect(indexed(try await f.status()).isEmpty)

        let many = (0..<5_000).map { "bulk/dir-\($0 % 50)/file-\($0).txt" }
        for path in many { try f.write(path, "n") }
        #expect(try await f.call("git.stage", ["paths": .array(many.map(HostJSON.string))])["ok"] == .bool(true))
        #expect(indexed(try await f.status()).count == 5_000)
        #expect(try await f.call("git.unstage", ["paths": .array(many.map(HostJSON.string))])["ok"] == .bool(true))
        #expect(indexed(try await f.status()).isEmpty)
        _ = try await f.call("git.stageAll")
        #expect(indexed(try await f.status()).count == 5_000 + odd.count)
    }

    @Test func unstageWorksBeforeTheFirstCommit() async throws {
        let f = try await SourceControlFixture.make()
        try f.write("new.txt", "n")
        _ = try await f.call("git.stage", ["paths": .array([.string("new.txt")])])
        #expect(indexed(try await f.status()) == ["new.txt"])
        #expect(try await f.call("git.unstage", ["paths": .array([.string("new.txt")])])["ok"] == .bool(true))
        #expect(indexed(try await f.status()).isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("new.txt").path))
    }

    @Test func discardTrackedRestoresAndUntrackedNeedsTheFlag() async throws {
        let f = try await SourceControlFixture.make()
        try f.write("tracked.txt", "original\n"); try await f.git(["add", "."]); try await f.git(["commit", "-q", "-m", "base"])
        try f.write("tracked.txt", "edited\n"); try f.write("scratch/new.txt", "untracked")
        _ = try await f.call("git.discard", ["paths": .array([.string("tracked.txt")])])
        #expect(try String(contentsOf: f.repo.appendingPathComponent("tracked.txt"), encoding: .utf8) == "original\n")
        let refused = try await f.call("git.discard", ["paths": .array([.string("scratch/new.txt")])])
        #expect(refused["error"] == .string("untrackedRefused"))
        #expect(FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("scratch/new.txt").path))
        let mixed = try await f.call("git.discard", ["paths": .array([.string("tracked.txt"), .string("scratch")])])
        #expect(mixed["error"] == .string("untrackedRefused"))
        #expect(try await f.call("git.discard", ["paths": .array([.string("scratch/new.txt")]),
                                          "includeUntracked": .bool(true)])["ok"] == .bool(true))
        #expect(!FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("scratch/new.txt").path))
        #expect(try await f.status().status.entries.isEmpty)
    }

    @Test func commitUsesGlobalIdentityAndAmendGuardsPushedCommits() async throws {
        let f = try await SourceControlFixture.make()
        let bare = try await f.withRemote()
        #expect(try await f.call("git.commit", ["message": .string("nothing staged")])["error"] == .string("gitFailed"))
        #expect(try await f.call("git.commit", ["message": .string("  ")])["error"] == .string("badRequest"))
        try f.write("README.md", "changed\n")
        _ = try await f.call("git.stage", ["paths": .array([.string("README.md")])])
        let committed = try await f.call("git.commit", ["message": .string("Change readme\n\nBody line")])
        let sha = try #require(committed["commit"]?.string)
        #expect(try await f.git(["log", "-1", "--format=%an <%ae>|%s|%b"]) == "SC Test <sc@example.invalid>|Change readme|Body line\n\n")
        #expect(try await f.git(["rev-parse", "HEAD"]) == sha + "\n")
        // Local-only commit: amend allowed without confirmation; the message changes, the parent stays.
        let amended = try await f.call("git.commit", ["message": .string("Reworded"), "amend": .bool(true)])
        #expect(amended["commit"]?.string != sha)
        #expect(try await f.git(["log", "-1", "--format=%s"]) == "Reworded\n")
        #expect(try await f.git(["rev-list", "--count", "HEAD"]) == "2\n")
        // Once pushed, amend needs explicit confirmation.
        _ = try await f.git(["push", "-q", "origin", "main"])
        #expect(try await f.call("git.commit", ["message": .string("again"), "amend": .bool(true)])["error"] == .string("amendPushedCommit"))
        #expect(try await f.call("git.commit", ["message": .string(""), "amend": .bool(true),
                                          "confirmPushedAmend": .bool(true)])["ok"] == .bool(true))
        #expect(try await f.git(["log", "-1", "--format=%s"]) == "Reworded\n")
        _ = bare
    }

    @Test func preCommitHookFailureIsReportedWithItsOutput() async throws {
        let f = try await SourceControlFixture.make()
        let hook = f.repo.appendingPathComponent(".git/hooks/pre-commit")
        try Data("#!/bin/sh\necho 'lint: 3 problems found' >&2\necho 'stdout from hook'\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try f.write("a.txt", "a"); _ = try await f.call("git.stage", ["paths": .array([.string("a.txt")])])
        let result = try await f.call("git.commit", ["message": .string("blocked")])
        #expect(result["error"] == .string("gitFailed"))
        #expect(result["detail"]?.string?.contains("lint: 3 problems found") == true)
        #expect(result["detail"]?.string?.contains("stdout from hook") == true)
        let source = f.scm()
        let hasHead = try await source.hasHead()
        #expect(!hasHead)
        #expect(indexed(try await f.status()) == ["a.txt"], "staged changes survive a rejected commit")
    }

    @Test func pushSetsUpstreamFirstThenPushesAgain() async throws {
        let f = try await SourceControlFixture.make()
        let bare = try await f.withRemote()
        try await f.git(["switch", "-q", "-c", "feature"])
        try f.write("f.txt", "1"); try await f.git(["add", "."]); try await f.git(["commit", "-q", "-m", "feature 1"])
        #expect(try await f.call("git.upstreamStatus")["upstream"] == nil)
        let first = try await f.runJob("git.push")
        #expect(first["state"] == .string("succeeded"), "\(first)")
        #expect(first["result"]?.object?["upstreamSet"] == .bool(true))
        #expect(try await f.git(["rev-parse", "--abbrev-ref", "@{u}"]) == "origin/feature\n")
        #expect(try await f.git(["log", "-1", "--format=%s", "feature"], at: bare) == "feature 1\n")
        try f.write("f.txt", "2"); try await f.git(["commit", "-q", "-am", "feature 2"])
        #expect(try await f.call("git.status")["ahead"] == .number(1))
        let second = try await f.runJob("git.push")
        #expect(second["state"] == .string("succeeded"))
        #expect(second["result"]?.object?["upstreamSet"] == .bool(false))
        #expect(try await f.git(["log", "-1", "--format=%s", "feature"], at: bare) == "feature 2\n")
        #expect(try await f.call("git.status")["ahead"] == .number(0))
    }

    @Test func rejectedPushIsReportedAndNeverForced() async throws {
        let f = try await SourceControlFixture.make()
        let bare = try await f.withRemote()
        let other = try await f.otherClone(of: bare)
        try f.write("theirs.txt", "t", in: other); try await f.git(["add", "."], at: other)
        try await f.git(["commit", "-q", "-m", "theirs"], at: other); try await f.git(["push", "-q"], at: other)
        let theirs = try await f.git(["rev-parse", "main"], at: bare)
        try f.write("ours.txt", "o"); try await f.git(["add", "."]); try await f.git(["commit", "-q", "-m", "ours"])
        let rejected = try await f.runJob("git.push")
        #expect(rejected["state"] == .string("failed"))
        #expect(rejected["error"] == .string("pushRejected"), "\(rejected)")
        #expect(try await f.git(["rev-parse", "main"], at: bare) == theirs, "remote unchanged: no automatic force")
        // A lease against a stale expectation fails; one that matches the remote succeeds.
        let staleLease = try await f.runJob("git.push", ["forceWithLease": .bool(true),
            "expectedRemoteCommit": .string(try await f.git(["rev-parse", "HEAD~1"]).trimmingCharacters(in: .newlines))])
        #expect(staleLease["error"] == .string("pushRejected"))
        #expect(try await f.git(["rev-parse", "main"], at: bare) == theirs)
        let lease = try await f.runJob("git.push", ["forceWithLease": .bool(true),
            "expectedRemoteCommit": .string(theirs.trimmingCharacters(in: .newlines))])
        #expect(lease["state"] == .string("succeeded"), "\(lease)")
        #expect(try await f.git(["log", "-1", "--format=%s", "main"], at: bare) == "ours\n")
    }

    @Test func pullFastForwardsThenReportsMergeConflictAndAborts() async throws {
        let f = try await SourceControlFixture.make()
        let bare = try await f.withRemote()
        let other = try await f.otherClone(of: bare)
        try f.write("README.md", "remote edit\n", in: other); try await f.git(["commit", "-q", "-am", "remote 1"], at: other)
        try await f.git(["push", "-q"], at: other)
        #expect(try await f.runJob("git.fetch")["state"] == .string("succeeded"))
        #expect(try await f.call("git.status")["behind"] == .number(1))
        #expect(try await f.runJob("git.pull")["state"] == .string("succeeded"))
        #expect(try String(contentsOf: f.repo.appendingPathComponent("README.md"), encoding: .utf8) == "remote edit\n")

        try f.write("README.md", "remote again\n", in: other); try await f.git(["commit", "-q", "-am", "remote 2"], at: other)
        try await f.git(["push", "-q"], at: other)
        try f.write("README.md", "local edit\n"); try await f.git(["commit", "-q", "-am", "local"])
        let conflict = try await f.runJob("git.pull")
        #expect(conflict["state"] == .string("failed"))
        #expect(conflict["detail"]?.string?.contains("CONFLICT") == true, "\(conflict)")
        let status = try await f.call("git.status")
        #expect(status["operation"] == .string("merge"))
        #expect(status["entries"].map { "\($0)" }?.contains("unmerged") == true)
        #expect(try await f.call("git.abortMerge")["ok"] == .bool(true))
        #expect(try await f.call("git.status")["operation"] == .string("none"))
        #expect(try String(contentsOf: f.repo.appendingPathComponent("README.md"), encoding: .utf8) == "local edit\n")
    }

    @Test func rebaseConflictCanBeAbortedOrContinued() async throws {
        let f = try await SourceControlFixture.make()
        try f.write("x.txt", "base\n"); try await f.git(["add", "."]); try await f.git(["commit", "-q", "-m", "base"])
        try await f.git(["switch", "-q", "-c", "topic"]); try f.write("x.txt", "topic\n"); try await f.git(["commit", "-q", "-am", "topic"])
        try await f.git(["switch", "-q", "main"]); try f.write("x.txt", "main\n"); try await f.git(["commit", "-q", "-am", "main"])
        try await f.git(["switch", "-q", "topic"])
        _ = try? await f.git(["rebase", "main"])
        #expect(try await f.status().operation == .rebase)
        #expect(try await f.call("git.abortRebase")["ok"] == .bool(true))
        #expect(try await f.status().operation == GitOperation.none)
        #expect(try await f.git(["log", "-1", "--format=%s"]) == "topic\n")
        _ = try? await f.git(["rebase", "main"])
        try f.write("x.txt", "resolved\n")
        _ = try await f.call("git.stage", ["paths": .array([.string("x.txt")])])
        #expect(try await f.call("git.continueOperation")["ok"] == .bool(true))
        #expect(try await f.status().operation == GitOperation.none)
        #expect(try await f.git(["log", "-2", "--format=%s"]) == "topic\nmain\n")
    }

    @Test func credentialsAndUnreachableRemotesFailFast() async throws {
        let f = try await SourceControlFixture.make()
        try f.write("a", "a"); try await f.git(["add", "."]); try await f.git(["commit", "-q", "-m", "a"])
        let server = try UnauthorizedHTTPServer()
        defer { server.stop() }
        try await f.git(["remote", "add", "origin", "http://127.0.0.1:\(server.port)/x.git"])
        let start = ContinuousClock.now
        let auth = try await f.runJob("git.fetch")
        #expect(auth["error"] == .string("authenticationRequired"), "\(auth)")
        try await f.git(["remote", "set-url", "origin", "http://127.0.0.1:1/x.git"])
        let refused = try await f.runJob("git.push")
        #expect(refused["state"] == .string("failed"))
        #expect(refused["error"] == .string("gitFailed"))
        #expect(start.duration(to: .now) < .seconds(15))
    }

    @Test func rootAcceptanceRule() async throws {
        let f = try await SourceControlFixture.make()
        try f.write("sub/file.txt", "x")
        let accepted = try await f.accept(f.repo.path)
        #expect(!accepted.registered)
        #expect(accepted.repositoryKey.hasPrefix("gitdir:/private/tmp/"))
        #expect(accepted.url.path.hasPrefix("/private/tmp/"))
        // Subdirectory of a work tree, plain folder, file, bare repo, missing path.
        #expect(try await f.call("git.status", root: f.repo.appendingPathComponent("sub"))["error"] == .string("invalidPath"))
        let plain = f.directory.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: false)
        #expect(try await f.call("git.status", root: plain)["error"] == .string("notRepository"))
        #expect(try await f.call("git.status", root: f.repo.appendingPathComponent("sub/file.txt"))["error"] == .string("invalidPath"))
        let bare = f.directory.appendingPathComponent("bare.git")
        try await f.git(["init", "-q", "--bare", bare.path])
        #expect(try await f.call("git.status", root: bare)["error"] == .string("notRepository"))
        #expect(try await f.call("git.status", root: f.directory.appendingPathComponent("missing"))["error"] == .string("invalidPath"))
        #expect(try await f.hostCall("git.status", ["worktreePath": .string("relative/path")])["error"] == .string("invalidPath"))
        // A symlink to the top level resolves to the canonical root.
        let link = f.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.repo)
        #expect(try await f.accept(link.path).url == accepted.url)
        // Registered repo id becomes the gate key.
        try f.store.execute("INSERT INTO repos (id, kind, path, display_name, badge_color, added_at, updated_at) VALUES ('r1','git',?,'w','#fff',0,0)",
                            [.text(accepted.url.path)])
        let registered = try await f.accept(f.repo.path)
        #expect(registered.registered && registered.repositoryKey == "r1")
    }

    @Test func pathsMustStayInsideTheRoot() async throws {
        let f = try await SourceControlFixture.make()
        let outside = f.directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: f.repo.appendingPathComponent("escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: f.repo.appendingPathComponent("link-file"),
                                                   withDestinationURL: outside.appendingPathComponent("x"))
        for (path, code) in [("../outside/x", "pathOutsideRoot"), ("a/../../x", "pathOutsideRoot"), ("/etc/passwd", "invalidPath"),
                             (".git/config", "pathOutsideRoot"), ("escape/x", "pathOutsideRoot")] {
            #expect(try await f.call("git.stage", ["paths": .array([.string(path)])])["error"] == .string(code), "\(path)")
        }
        // The symlink itself is a valid Git path even though its target is outside.
        #expect(try await f.call("git.stage", ["paths": .array([.string("link-file")])])["ok"] == .bool(true))
        #expect(indexed(try await f.status()) == ["link-file"])
    }

    @Test func branchesStashAndGitignore() async throws {
        let f = try await SourceControlFixture.make()
        try f.write("a.txt", "1\n"); try await f.git(["add", "."]); try await f.git(["commit", "-q", "-m", "base"])
        #expect(try await f.call("git.createBranch", ["name": .string("feature/x")])["ok"] == .bool(true))
        #expect(try await f.call("git.status")["branch"] == .string("feature/x"))
        #expect(try await f.call("git.createBranch", ["name": .string("feature/x")])["error"] == .string("branchExists"))
        #expect(try await f.call("git.createBranch", ["name": .string("bad..name")])["error"] == .string("invalidName"))
        #expect(try await f.call("git.createBranch", ["name": .string("--force")])["error"] == .string("invalidRef"))
        #expect(try await f.call("git.switchBranch", ["name": .string("main")])["ok"] == .bool(true))
        let branches = try await f.call("git.branches")["branches"].map { "\($0)" } ?? ""
        #expect(branches.contains("feature/x"))
        #expect(try await f.call("git.deleteBranch", ["name": .string("feature/x")])["ok"] == .bool(true))

        try f.write("a.txt", "2\n"); try f.write("u.txt", "u")
        #expect(try await f.call("git.stash", ["includeUntracked": .bool(true), "message": .string("wip")])["ok"] == .bool(true))
        #expect(try await f.status().status.entries.isEmpty)
        let stashes = try await f.call("git.stashList")["stashes"]
        #expect(stashes.map { "\($0)" }?.contains("wip") == true)
        #expect(try await f.call("git.stashPop")["ok"] == .bool(true))
        #expect(try String(contentsOf: f.repo.appendingPathComponent("a.txt"), encoding: .utf8) == "2\n")
        #expect(FileManager.default.fileExists(atPath: f.repo.appendingPathComponent("u.txt").path))

        #expect(try await f.call("git.appendGitignore", ["pattern": .string("*.log")])["ok"] == .bool(true))
        #expect(try await f.call("git.appendGitignore", ["pattern": .string("a\nb")])["error"] == .string("badRequest"))
        try f.write("debug.log", "x")
        let ignored = try await f.call("git.checkIgnored", ["paths": .array([.string("debug.log"), .string("a.txt")])])
        #expect(ignored["ignored"] == .array([.string("debug.log")]))
        let history = try await f.call("git.history", ["limit": .number(5)])["commits"]
        #expect(history.map { "\($0)" }?.contains("base") == true)
    }

    @Test func branchCompareAndDiff() async throws {
        let f = try await SourceControlFixture.make()
        try f.write("a.txt", "1\n"); try await f.git(["add", "."]); try await f.git(["commit", "-q", "-m", "base"])
        try await f.git(["switch", "-q", "-c", "topic"])
        try f.write("a.txt", "1\n2\n3\n"); try f.write("b.txt", "b\n"); try await f.git(["add", "."]); try await f.git(["commit", "-q", "-m", "t"])
        let compare = try await f.call("git.branchCompare", ["baseRef": .string("main")])
        #expect(compare["ahead"] == .number(1) && compare["behind"] == .number(0))
        #expect(compare["added"] == .number(3) && compare["removed"] == .number(0))
        try f.write("a.txt", "changed\n")
        let diff = try await f.call("git.diff", ["path": .string("a.txt")])
        #expect(diff["diff"]?.string?.contains("+changed") == true)
        #expect(try await f.call("git.diff", ["path": .string("a.txt"), "staged": .bool(true)])["diff"] == .string(""))
    }

    @Test func typedClientRoundTripOverSocket() async throws {
        let f = try await SourceControlFixture.make()
        let bare = try await f.withRemote()
        let socket = f.directory.appendingPathComponent("s").path
        let server = try UnixSocketServer(path: socket) { f.host.service.handle($0) }
        defer { server.stop() }
        let root = f.repo.path
        let sha = try await SourceControlFixture.offPool { () throws -> String in
            let client = try HostClient(socketPath: socket)
            defer { client.disconnect() }
            try Data("n".utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent("new.txt"))
            guard try client.gitStatus(worktreePath: root).entries.map(\.path) == ["new.txt"] else { throw HostClientError.invalidResponse }
            try client.gitStage(worktreePath: root, paths: ["new.txt"])
            let sha = try client.gitCommit(worktreePath: root, message: "typed")
            try client.waitForJob(id: try client.gitStartJob("git.push", worktreePath: root))
            do { try client.gitDiscard(worktreePath: root, paths: ["zzz"], includeUntracked: false) }
            catch HostClientError.detailedHostError { return sha }
            throw HostClientError.invalidResponse
        }
        #expect(try await f.git(["rev-parse", "main"], at: bare) == sha + "\n")
    }
}

/// Answers every HTTP request with 401 so Git asks for credentials (prompts are disabled).
final class UnauthorizedHTTPServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { close(fd); throw POSIXError(.EADDRINUSE) }
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                var buffer = [UInt8](repeating: 0, count: 4_096)
                _ = read(client, &buffer, buffer.count)
                let reply = "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"x\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                _ = reply.withCString { Darwin.write(client, $0, strlen($0)) }
                close(client)
            }
        }
    }

    func stop() {
        lock.withLock { guard !stopped else { return }; stopped = true; shutdown(fd, SHUT_RDWR); close(fd) }
    }
}
