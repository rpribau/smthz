import Foundation
import Testing
@testable import SmthzCore

private final class RegistryFixture: @unchecked Sendable {
    let directory: URL
    let journal: EventJournal
    let router = HostRouter()
    let store: WorkspaceStore
    let service: HostService
    init(directory existing: URL? = nil) throws {
        directory = existing ?? URL(fileURLWithPath: "/tmp/smthz-rr-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        journal = try EventJournal(path: directory.appendingPathComponent("journal").path)
        store = try WorkspaceStore(path: directory.appendingPathComponent("workspace.sqlite").path)
        service = HostService(journal: journal, hostIdentity: nil, router: router)
        let manager = service.sessionManager
        RepoRPC.register(on: router, store: store, liveSessionCWDs: { manager.list().filter(\.running).compactMap(\.cwd) })
    }
    func stop() { service.stop() }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func call(_ method: String, _ params: [String: HostJSON] = [:], id: String = UUID().uuidString) throws -> [String: HostJSON] {
        let request = RPCEnvelope(version: 1, requestID: id, method: method, payload: try JSONEncoder().encode(params))
        let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: service.handleAuthenticatedTestRequest(JSONEncoder().encode(request)))
        return try JSONDecoder().decode([String: HostJSON].self, from: envelope.payload)
    }
    func ok(_ method: String, _ params: [String: HostJSON] = [:]) throws -> [String: HostJSON] {
        let result = try call(method, params)
        try #require(result["ok"] == .bool(true), "\(method) failed: \(result)")
        return result
    }
    func job(_ method: String, _ params: [String: HostJSON]) throws -> [String: HostJSON] {
        let id = try #require(try ok(method, params)["jobId"]?.string)
        let deadline = Date(timeIntervalSinceNow: 20)
        while Date() < deadline {
            let state = try router.jobs.get(id)
            if ["succeeded", "failed", "cancelled"].contains(state["state"]?.string ?? "") { return state }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Issue.record("job \(method) did not finish"); return [:]
    }
    @discardableResult func git(_ args: [String], at path: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=t@example.com", "-c", "init.defaultBranch=main",
                             "-c", "commit.gpgsign=false"] + args
        process.currentDirectoryURL = path
        process.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
        let out = Pipe(); process.standardOutput = out; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try #require(process.terminationStatus == 0, "git \(args) failed")
        return text
    }
    func makeRepo(_ name: String, in parent: URL? = nil) throws -> URL {
        let url = (parent ?? directory).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "-q"], at: url)
        try Data("hi\n".utf8).write(to: url.appendingPathComponent("README"))
        try git(["add", "README"], at: url)
        try git(["commit", "-q", "-m", "init"], at: url)
        return url
    }
    func canonical(_ url: URL) throws -> String { try WorkspaceStore.canonicalPath(url.path) }
}

/// Serialized: these synchronous tests block on host handlers that wait for Git tasks; running them
/// side by side would starve the cooperative pool that timing-sensitive host tests rely on.
@Suite(.serialized) struct RepoRegistryTests {
    @Test func addGitRepoFolderAndMissingPath() throws {
        let f = try RegistryFixture(); defer { f.stop(); f.remove() }
        let repo = try f.makeRepo("alpha")
        let added = try f.ok("repo.add", ["path": .string(repo.path)])
        let row = try #require(added["repo"]?.object)
        #expect(row["kind"] == .string("git"))
        #expect(row["path"] == .string(try f.canonical(repo)))
        #expect(row["displayName"] == .string("alpha"))
        #expect(added["alreadyKnown"] == .bool(false))
        #expect(row["mainWorktreeId"]?.string != nil)
        let main = try f.store.worktreeRows(repoID: row["id"]!.string!)
        #expect(main.count == 1 && main[0]["is_main"]?.integer == 1 && main[0]["branch"]?.string == "main")

        let folder = f.directory.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(try f.ok("repo.add", ["path": .string(folder.path)])["repo"]?.object?["kind"] == .string("folder"))
        #expect(try f.ok("repo.add", ["path": .string(folder.path)])["alreadyKnown"] == .bool(true))
        let other = f.directory.appendingPathComponent("plain2", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        #expect(try f.call("repo.add", ["path": .string(other.path), "kind": .string("git")])["error"] == .string("notRepository"))
        #expect(try f.call("repo.add", ["path": .string(f.directory.path + "/missing")])["error"] == .string("invalidPath"))
        #expect(try f.call("repo.add", ["path": .string("relative/path")])["error"] == .string("invalidPath"))
        // A subdirectory of a repository is a folder project, not a second registration of the repository.
        let sub = repo.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        #expect(try f.call("repo.add", ["path": .string(sub.path), "kind": .string("git")])["error"] == .string("notRepository"))
        #expect(try f.ok("repo.list")["repos"].flatMap { if case .array(let a) = $0 { a.count } else { nil } } == 2)
    }

    @Test func duplicateAddIsAlreadyKnownThroughSymlinkedPath() throws {
        let f = try RegistryFixture(); defer { f.stop(); f.remove() }
        let repo = try f.makeRepo("dup")
        let first = try f.ok("repo.add", ["path": .string(repo.path)])
        // /tmp is a symlink to /private/tmp: the canonical row must be found again.
        let second = try f.ok("repo.add", ["path": .string(repo.path + "/")])
        let viaPrivate = try f.ok("repo.add", ["path": .string(try f.canonical(repo))])
        #expect(second["alreadyKnown"] == .bool(true) && viaPrivate["alreadyKnown"] == .bool(true))
        #expect(second["repo"]?.object?["id"] == first["repo"]?.object?["id"])
        #expect(try f.store.query("SELECT COUNT(*) AS n FROM repos").first?["n"]?.integer == 1)
        #expect(try f.store.query("SELECT COUNT(*) AS n FROM worktrees").first?["n"]?.integer == 1)
    }

    @Test func removeRefusedWhileSessionLivesInsideRepo() throws {
        let f = try RegistryFixture(); defer { f.stop(); f.remove() }
        let repo = try f.makeRepo("busy")
        let id = try #require(try f.ok("repo.add", ["path": .string(repo.path)])["repo"]?.object?["id"])
        let session = try f.service.sessionManager.create(executable: "/bin/cat", arguments: [], workingDirectory: repo.path)
        let refused = try f.call("repo.remove", ["id": id])
        #expect(refused["error"] == .string("hasLiveSessions"))
        try f.service.sessionManager.close(id: session.id)
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline, f.service.sessionManager.list().contains(where: { $0.id == session.id && $0.running }) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        _ = try f.ok("repo.remove", ["id": id])
        #expect(try f.store.query("SELECT COUNT(*) AS n FROM worktrees").first?["n"]?.integer == 0)
        // Files are never deleted.
        #expect(FileManager.default.fileExists(atPath: repo.appendingPathComponent("README").path))
        #expect(try f.call("repo.show", ["id": id])["error"] == .string("notFound"))
    }

    @Test func forcedRemoveIgnoresLiveSession() throws {
        let f = try RegistryFixture(); defer { f.stop(); f.remove() }
        let repo = try f.makeRepo("forced")
        let id = try #require(try f.ok("repo.add", ["path": .string(repo.path)])["repo"]?.object?["id"])
        let session = try f.service.sessionManager.create(executable: "/bin/cat", arguments: [], workingDirectory: repo.path)
        defer { try? f.service.sessionManager.close(id: session.id) }
        _ = try f.ok("repo.remove", ["id": id, "force": .bool(true)])
        #expect(try f.store.repoRows().isEmpty)
    }

    @Test func nestedScanHonoursDepthLimitAndSkips() throws {
        let f = try RegistryFixture(); defer { f.stop(); f.remove() }
        let root = f.directory.appendingPathComponent("many", isDirectory: true)
        for name in ["a", "b", "c"] { _ = try f.makeRepo(name, in: root) }
        _ = try f.makeRepo("deep", in: root.appendingPathComponent("x/y/z/w", isDirectory: true))
        _ = try f.makeRepo("hidden", in: root.appendingPathComponent("node_modules", isDirectory: true))
        let all = try f.job("repo.scanNested", ["path": .string(root.path)])
        let repos = try #require(all["result"]?.object?["repos"]).arrayCount
        #expect(all["result"]?.object?["selectedPathKind"] == .string("non_git_folder"))
        #expect(repos == 3) // depth 3 by default: x/y/z/w/deep (depth 5) and node_modules are skipped
        let deep = try f.job("repo.scanNested", ["path": .string(root.path), "maxDepth": .number(8)])
        #expect(try #require(deep["result"]?.object?["repos"]).arrayCount == 4)
        let limited = try f.job("repo.scanNested", ["path": .string(root.path), "maxRepos": .number(2)])
        #expect(limited["result"]?.object?["truncated"] == .bool(true))
        #expect(try #require(limited["result"]?.object?["repos"]).arrayCount == 2)
        let selfScan = try f.job("repo.scanNested", ["path": .string(root.appendingPathComponent("a").path)])
        #expect(selfScan["result"]?.object?["selectedPathKind"] == .string("git_repo"))
        // A zero-length timeout is clamped to 500 ms; a huge tree times out with a partial list.
        let scan = NestedRepoScan(timeoutMs: 0)
        #expect(scan.timeoutMs == 500)
        var calls = 0
        let stopped = NestedRepoScan().scan(root.path, cancelled: { calls += 1; return calls > 1 })
        #expect(stopped.stopped)

        let imported = try f.ok("projectGroup.importNested", ["parentPath": .string(root.path), "mode": .string("group"),
            "paths": .array(["a", "b"].map { .string(root.appendingPathComponent($0).path) } + [.string("/etc")])])
        let group = try #require(imported["group"]?.object)
        #expect(group["createdFrom"] == .string("folder-scan"))
        let statuses = try #require(imported["projects"]).arrayValues.compactMap { $0.object?["status"]?.string }
        #expect(statuses == ["imported", "imported", "failed"])
        #expect(try f.store.query("SELECT COUNT(*) AS n FROM repos WHERE project_group_id=?", [.text(group["id"]!.string!)]).first?["n"]?.integer == 2)
    }

    @Test func cloneFromLocalBareRepo() throws {
        let f = try RegistryFixture(); defer { f.stop(); f.remove() }
        let source = try f.makeRepo("source")
        let bare = f.directory.appendingPathComponent("remote.git")
        try f.git(["clone", "-q", "--bare", source.path, bare.path], at: f.directory)
        let parent = f.directory.appendingPathComponent("clones", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let done = try f.job("repo.clone", ["url": .string(bare.path), "destinationParent": .string(parent.path)])
        #expect(done["state"] == .string("succeeded"), "\(done)")
        let repo = try #require(done["result"]?.object?["repo"]?.object)
        #expect(repo["displayName"] == .string("remote"))
        #expect(repo["kind"] == .string("git"))
        #expect(FileManager.default.fileExists(atPath: parent.appendingPathComponent("remote/README").path))
        // Destination exists: refused before any job starts.
        #expect(try f.call("repo.clone", ["url": .string(bare.path), "destinationParent": .string(parent.path)])["error"] == .string("alreadyExists"))
        // A failing clone leaves no directory behind.
        let failed = try f.job("repo.clone", ["url": .string(f.directory.path + "/nope.git"), "destinationParent": .string(parent.path),
                                              "name": .string("broken")])
        #expect(failed["state"] == .string("failed"))
        #expect(!FileManager.default.fileExists(atPath: parent.appendingPathComponent("broken").path))
    }

    @Test func createProjectWithAndWithoutGit() throws {
        let f = try RegistryFixture(); defer { f.stop(); f.remove() }
        let git = try #require(try f.ok("repo.create", ["parentPath": .string(f.directory.path), "name": .string("fresh")])["repo"]?.object)
        #expect(git["kind"] == .string("git"))
        #expect(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("fresh/.git").path))
        let plain = try #require(try f.ok("repo.create", ["parentPath": .string(f.directory.path), "name": .string("notes"),
                                                          "initGit": .bool(false)])["repo"]?.object)
        #expect(plain["kind"] == .string("folder"))
        #expect(try f.call("repo.create", ["parentPath": .string(f.directory.path), "name": .string("fresh")])["error"] == .string("alreadyExists"))
        #expect(try f.call("repo.create", ["parentPath": .string(f.directory.path), "name": .string("../x")])["error"] == .string("invalidName"))
    }

    @Test func updateBaseRefSearchRefsAndDefaults() throws {
        let f = try RegistryFixture(); defer { f.stop(); f.remove() }
        let repo = try f.makeRepo("refs")
        try f.git(["branch", "feature/login"], at: repo)
        try f.git(["tag", "v1.0"], at: repo)
        let id = try #require(try f.ok("repo.add", ["path": .string(repo.path)])["repo"]?.object?["id"])
        #expect(try f.ok("repo.update", ["id": id, "worktreeBaseRef": .string("main")])["repo"]?.object?["worktreeBaseRef"] == .string("main"))
        #expect(try f.call("repo.update", ["id": id, "worktreeBaseRef": .string("no-such-ref")])["error"] == .string("invalidRef"))
        #expect(try f.call("repo.update", ["id": id, "badgeColor": .string("red")])["error"] == .string("badRequest"))
        let updated = try f.ok("repo.update", ["id": id, "displayName": .string("Refs"), "externalWorktreeVisibility": .string("hide"),
                                               "sharedPaths": .array([.string(".env")])])["repo"]?.object
        #expect(updated?["displayName"] == .string("Refs") && updated?["externalWorktreeVisibility"] == .string("hide"))
        #expect(updated?["sharedPaths"] == .array([.string(".env")]))
        let refs = try #require(try f.ok("repo.searchRefs", ["id": id, "query": .string("log")])["refs"]).arrayValues
        #expect(refs.map { $0.object?["name"] } == [.string("feature/login")])
        #expect(try f.ok("repo.searchRefs", ["id": id, "query": .string("")])["refs"]?.arrayCount == 3)
        let defaults = try f.ok("repo.baseRefDefault", ["id": id])
        #expect(defaults["ref"] == .string("main") && defaults["remoteCount"] == .number(0))
    }

    @Test func groupsFoldersAndHostSettings() throws {
        let f = try RegistryFixture(); defer { f.stop(); f.remove() }
        let group = try #require(try f.ok("projectGroup.create", ["name": .string("Work"), "parentPath": .string(f.directory.path),
                                                                  "color": .string("#22C55E")])["group"]?.object)
        #expect(group["color"] == .string("#22c55e") && group["isCollapsed"] == .bool(false))
        let gid = group["id"]!
        #expect(try f.ok("projectGroup.update", ["id": gid, "isCollapsed": .bool(true), "name": .string("Job")])["group"]?.object?["isCollapsed"] == .bool(true))
        let repo = try f.makeRepo("member")
        let rid = try #require(try f.ok("repo.add", ["path": .string(repo.path)])["repo"]?.object?["id"])
        #expect(try f.ok("projectGroup.moveProject", ["repoId": rid, "groupId": gid, "index": .number(0)])["repo"]?.object?["projectGroupId"] == gid)
        let folder = try #require(try f.ok("folderWorkspace.create", ["projectGroupId": gid, "name": .string("Notes")])["folderWorkspace"]?.object)
        #expect(folder["folderPath"] == .string(try f.canonical(f.directory)))
        #expect(try f.ok("folderWorkspace.update", ["id": folder["id"]!, "pinned": .bool(true)])["folderWorkspace"]?.object?["isPinned"] == .bool(true))
        #expect(try f.ok("folderWorkspace.list")["folderWorkspaces"]?.arrayCount == 1)
        // Deleting the group keeps the project (ungrouped) unless removeProjects, and cascades folder workspaces.
        _ = try f.ok("projectGroup.delete", ["id": gid])
        #expect(try f.ok("repo.show", ["id": rid])["repo"]?.object?["projectGroupId"] == nil)
        #expect(try f.ok("folderWorkspace.list")["folderWorkspaces"]?.arrayCount == 0)
        let second = try #require(try f.ok("projectGroup.create", ["name": .string("Tmp")])["group"]?.object?["id"])
        _ = try f.ok("projectGroup.moveProject", ["repoId": rid, "groupId": second])
        _ = try f.ok("projectGroup.delete", ["id": second, "removeProjects": .bool(true)])
        #expect(try f.store.repoRows().isEmpty)

        let defaults = try #require(try f.ok("hostSettings.get")["values"]?.object)
        #expect(defaults["branchPrefix"] == .string("git-username") && defaults["nestWorkspaces"] == .bool(true))
        #expect(defaults["workspaceDir"]?.string?.hasSuffix("/smthz/workspaces") == true)
        _ = try f.ok("hostSettings.set", ["values": .object(["branchPrefix": .string("none"), "workspaceDir": .string("~/ws")])])
        let changed = try #require(try f.ok("hostSettings.get", ["keys": .array([.string("branchPrefix")])])["values"]?.object)
        #expect(changed == ["branchPrefix": .string("none")])
        #expect(try f.call("hostSettings.set", ["values": .object(["branchPrefix": .string("bogus")])])["error"] == .string("badRequest"))
        #expect(try f.call("hostSettings.set", ["values": .object(["unknown": .bool(true)])])["error"] == .string("badRequest"))
    }

    @Test func storeSurvivesHostRestartAndReadsAreNotJournaled() throws {
        let first = try RegistryFixture()
        let repo = try first.makeRepo("durable")
        let id = try #require(try first.ok("repo.add", ["path": .string(repo.path)])["repo"]?.object?["id"])
        _ = try first.ok("repo.update", ["id": id, "worktreeBaseRef": .string("main")])
        let journalRows = try first.journal.read(after: 0, limit: 100).count
        _ = try first.ok("repo.list"); _ = try first.ok("repo.show", ["id": id]); _ = try first.ok("hostSettings.get")
        #expect(try first.journal.read(after: 0, limit: 100).count == journalRows)
        first.stop()
        let second = try RegistryFixture(directory: first.directory)
        defer { second.stop(); second.remove() }
        let shown = try second.ok("repo.show", ["id": id])
        #expect(shown["repo"]?.object?["worktreeBaseRef"] == .string("main"))
        #expect(shown["mainWorktreeId"]?.string != nil)
    }

    @Test func mutationRetryReplaysTheSameRepo() throws {
        let f = try RegistryFixture(); defer { f.stop(); f.remove() }
        let repo = try f.makeRepo("replay")
        let requestID = UUID().uuidString
        let a = try f.call("repo.add", ["path": .string(repo.path)], id: requestID)
        let b = try f.call("repo.add", ["path": .string(repo.path)], id: requestID)
        #expect(a == b && a["alreadyKnown"] == .bool(false))
        #expect(try f.call("repo.add", ["path": .string(f.directory.path)], id: requestID)["error"] == .string("idempotencyConflict"))
    }
}

private extension HostJSON {
    var arrayValues: [HostJSON] { if case .array(let a) = self { return a }; return [] }
    var arrayCount: Int? { if case .array(let a) = self { return a.count }; return nil }
}
