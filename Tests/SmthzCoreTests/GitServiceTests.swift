import Foundation
import Testing
@testable import SmthzCore

private struct GitFixture {
    let directory: URL
    let repo: URL
    init(commit: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("smthz-git-tests-\(UUID().uuidString)")
        repo = directory.appendingPathComponent("repository with spaces")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Git Tests"])
        try git(["config", "user.email", "git-tests@example.invalid"])
        try git(["config", "commit.gpgsign", "false"])
        if commit {
            try write("tracked.txt", "first\n")
            try git(["add", "--", "tracked.txt"])
            try git(["commit", "-m", "initial"])
        }
    }
    func clean() { try? FileManager.default.removeItem(at: directory) }
    func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: repo.appendingPathComponent(path))
    }
    @discardableResult func git(_ args: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-pager", "-c", "core.hooksPath=/dev/null"] + args
        process.currentDirectoryURL = repo
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"; environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try pipe.fileHandleForReading.close(); try pipe.fileHandleForWriting.close()
        guard process.terminationStatus == 0 else { throw GitError.commandFailed(code: process.terminationStatus, stderr: "fixture") }
        return String(decoding: data, as: UTF8.self)
    }
}

struct GitServiceTests {
    @Test func repositoryDetectionAndUnbornStatus() async throws {
        let fixture = try GitFixture(commit: false); defer { fixture.clean() }
        let git = GitService()
        let repo = try #require(await git.repository(at: fixture.repo))
        #expect(repo.root.resolvingSymlinksInPath() == fixture.repo.resolvingSymlinksInPath())
        #expect(!repo.isBare)
        #expect(try await git.repository(at: fixture.directory) == nil)
        let status = try await git.status(at: fixture.repo)
        #expect(status.branch == "main")
        #expect(status.head == "(initial)")
        #expect(status.entries.isEmpty)
        #expect(try await git.branches(at: fixture.repo).isEmpty)
        let bare = fixture.directory.appendingPathComponent("bare.git")
        try fixture.git(["init", "--bare", bare.path])
        #expect(try await git.repository(at: bare)?.isBare == true)
    }

    @Test func statusPreservesRenameAndUnusualPaths() async throws {
        let fixture = try GitFixture(); defer { fixture.clean() }
        let git = GitService()
        let renamed = "renamed \nfile.txt"
        try fixture.git(["mv", "tracked.txt", renamed])
        try fixture.write(renamed, "first\nsecond\n")
        try fixture.write("untracked\tname.txt", "new")
        try fixture.write(".gitignore", "ignored.txt\n")
        try fixture.write("ignored.txt", "ignore")
        let status = try await git.status(at: fixture.repo, includeIgnored: true)
        let entry = try #require(status.entries.first { $0.path == renamed })
        #expect(entry.kind == .renamed)
        #expect(entry.originalPath == "tracked.txt")
        #expect(entry.indexStatus == "R")
        #expect(entry.worktreeStatus == "M")
        #expect(status.entries.contains { $0.kind == .untracked && $0.path == "untracked\tname.txt" })
        #expect(status.entries.contains { $0.kind == .ignored && $0.path == "ignored.txt" })
    }

    @Test func branchesAndWorktreeLifecycle() async throws {
        let fixture = try GitFixture(); defer { fixture.clean() }
        let git = GitService()
        try fixture.git(["branch", "feature"])
        try fixture.git(["update-ref", "refs/remotes/origin/main", "HEAD"])
        let branches = try await git.branches(at: fixture.repo, includeRemote: true)
        #expect(branches.contains { $0.name == "main" && $0.isCurrent && !$0.isRemote })
        #expect(branches.contains { $0.name == "origin/main" && $0.isRemote })
        let path = fixture.directory.appendingPathComponent("worktree with \nnewline")
        try await git.addWorktree(at: fixture.repo, path: path, branch: "feature")
        let worktrees = try await git.worktrees(at: fixture.repo)
        #expect(worktrees.count == 2)
        #expect(worktrees.contains {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == path.resolvingSymlinksInPath()
                && $0.branch == "refs/heads/feature"
        })
        try await git.removeWorktree(at: fixture.repo, path: path)
        #expect(try await git.worktrees(at: fixture.repo).count == 1)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        let detached = fixture.directory.appendingPathComponent("detached")
        try await git.addWorktree(at: fixture.repo, path: detached, detached: true)
        #expect(try await git.worktrees(at: fixture.repo).contains {
            $0.isDetached && URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == detached.resolvingSymlinksInPath()
        })
        try await git.removeWorktree(at: fixture.repo, path: detached)
        let fresh = fixture.directory.appendingPathComponent("fresh")
        try await git.addWorktree(at: fixture.repo, path: fresh, newBranch: "new-feature")
        #expect(try await git.branches(at: fixture.repo).contains { $0.name == "new-feature" })
        try await git.removeWorktree(at: fixture.repo, path: fresh)
    }

    @Test func literalDiffAndLargeOutput() async throws {
        let fixture = try GitFixture(); defer { fixture.clean() }
        let git = GitService()
        try fixture.write("[a].txt", "before\n")
        try fixture.write("a.txt", "other\n")
        try fixture.git(["add", "."]); try fixture.git(["commit", "-m", "paths"])
        try fixture.write("[a].txt", "literal change\n")
        try fixture.write("a.txt", "unrelated change\n")
        let diff = try await git.diff(at: fixture.repo, path: "[a].txt")
        #expect(diff.contains("+literal change"))
        #expect(!diff.contains("unrelated change"))
        try fixture.git(["--literal-pathspecs", "add", "--", "[a].txt"])
        #expect(try await git.diff(at: fixture.repo, path: "[a].txt").isEmpty)
        #expect(try await git.diff(at: fixture.repo, path: "[a].txt", staged: true).contains("+literal change"))
        try fixture.write("tracked.txt", String(repeating: "a long line of text\n", count: 100_000))
        #expect(try await git.diff(at: fixture.repo, path: "tracked.txt").utf8.count > 1_000_000)
    }

    @Test func unmergedStatus() async throws {
        let fixture = try GitFixture(); defer { fixture.clean() }
        try fixture.git(["checkout", "-b", "side"])
        try fixture.write("tracked.txt", "side\n")
        try fixture.git(["commit", "-am", "side"])
        try fixture.git(["checkout", "main"])
        try fixture.write("tracked.txt", "main\n")
        try fixture.git(["commit", "-am", "main"])
        do { try fixture.git(["merge", "side"]); Issue.record("Expected conflict") } catch {}
        let entry = try #require(await GitService().status(at: fixture.repo).entries.first)
        #expect(entry.kind == .unmerged)
        #expect(entry.path == "tracked.txt")
        #expect(entry.indexStatus == "U" && entry.worktreeStatus == "U")
    }

    @Test func typedFailuresAndDirtyWorktreeProtection() async throws {
        let fixture = try GitFixture(); defer { fixture.clean() }
        let git = GitService()
        await #expect(throws: GitError.notRepository) { try await git.status(at: fixture.directory) }
        await #expect(throws: GitError.invalidInput("ref")) {
            try await git.addWorktree(at: fixture.repo, path: fixture.directory.appendingPathComponent("bad"), branch: "--help")
        }
        await #expect(throws: GitError.invalidInput("timeout")) { try await GitService(timeout: 0).status(at: fixture.repo) }
        let path = fixture.directory.appendingPathComponent("dirty")
        try await git.addWorktree(at: fixture.repo, path: path, newBranch: "dirty")
        try Data("dirty\n".utf8).write(to: path.appendingPathComponent("tracked.txt"))
        do {
            try await git.removeWorktree(at: fixture.repo, path: path)
            Issue.record("Expected dirty worktree refusal")
        } catch GitError.commandFailed(let code, let stderr) { #expect(code != 0); #expect(!stderr.isEmpty) }
        try await git.removeWorktree(at: fixture.repo, path: path, force: true)
    }

    @Test func timeoutAndCancellationReapProcesses() async throws {
        let fixture = try GitFixture(); defer { fixture.clean() }
        // A microsecond deadline expires before Git can finish its real process startup.
        for _ in 0..<5 {
            await #expect(throws: GitError.timedOut) {
                try await GitService(timeout: 0.000001).status(at: fixture.repo)
            }
        }
        let task = Task { try await GitService().status(at: fixture.repo) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch GitError.cancelled {}
        #expect(try await GitService().status(at: fixture.repo).entries.isEmpty)
    }

    @Test func parserRejectsTruncatedRename() throws {
        #expect(throws: GitError.malformedOutput) {
            try GitService.parseStatus("2 R. N... 100644 100644 100644 abc abc R100 renamed\0")
        }
    }
}
