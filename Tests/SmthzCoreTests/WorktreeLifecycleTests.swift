import Foundation
import Testing
@testable import SmthzCore

private final class WorktreeFixture: @unchecked Sendable {
    let directory: URL
    let root: String
    let store: WorkspaceStore
    let router = HostRouter()
    let service: HostService
    let repoID: String
    init() throws {
        directory = URL(fileURLWithPath: "/tmp/smthz-wh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = try WorkspaceStore.canonicalPath(directory.path) + "/repo"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        store = try WorkspaceStore(path: directory.appendingPathComponent("store").path)
        let journal = try EventJournal(path: directory.appendingPathComponent("journal").path)
        service = HostService(journal: journal, hostIdentity: nil, router: router)
        _ = try GitService().worktreeGit(["init", "-q", "-b", "main"], at: root)
        _ = try GitService().worktreeGit(["config", "user.name", "worktree-tester"], at: root)
        _ = try GitService().worktreeGit(["config", "user.email", "test@example.invalid"], at: root)
        _ = try GitService().worktreeGit(["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "initial"], at: root)
        repoID = try store.insertRepo(path: root, kind: "git", displayName: "repo", branch: "main", projectGroupID: nil).row["id"]!.string!
        try store.setHostSettings(["workspaceDir": .string(directory.path + "/workspaces"), "branchPrefix": .string("custom"), "branchPrefixCustom": .string("tester")])
        WorktreeRPC.register(on: router, store: store, sessions: service.sessionManager)
    }
    deinit { service.stop(); try? FileManager.default.removeItem(at: directory) }
    @discardableResult func git(_ args: [String], path: String? = nil) throws -> String {
        try GitService().worktreeGit(args, at: path ?? root).stdout.trimmingCharacters(in: .newlines)
    }
    func write(_ name: String, _ content: String, at path: String? = nil) throws {
        let url = URL(fileURLWithPath: (path ?? root) + "/" + name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
    func commit() throws {
        try git(["add", "."])
        try git(["-c", "commit.gpgsign=false", "commit", "-qm", "fixture"])
    }
    func call(_ method: String, _ params: [String: HostJSON] = [:]) throws -> [String: HostJSON] {
        let req = RPCEnvelope(version: 1, requestID: UUID().uuidString, method: method, payload: try JSONEncoder().encode(params))
        let response = try JSONDecoder().decode(RPCEnvelope.self, from: service.handleAuthenticatedTestRequest(JSONEncoder().encode(req)))
        return try JSONDecoder().decode([String: HostJSON].self, from: response.payload)
    }
    func ok(_ method: String, _ params: [String: HostJSON] = [:]) throws -> [String: HostJSON] {
        let response = try call(method, params)
        try #require(response["ok"] == .bool(true), "\(method): \(response)")
        return response
    }
    func wait(_ id: String) throws -> [String: HostJSON] {
        let deadline = Date(timeIntervalSinceNow: 30)
        while Date() < deadline {
            let row = try router.jobs.get(id)
            if ["succeeded", "failed", "cancelled"].contains(row["state"]?.string ?? "") { return row }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw HostRPCError("testTimeout")
    }
    func job(_ method: String, _ params: [String: HostJSON]) throws -> [String: HostJSON] {
        try wait(#require(ok(method, params)["jobId"]?.string))
    }
    func create(_ name: String = "task", fields: [String: HostJSON] = [:]) throws -> [String: HostJSON] {
        var params = fields; params["repoId"] = .string(repoID); params["name"] = .string(name)
        let row = try job("worktree.create", params)
        try #require(row["state"] == .string("succeeded"), "\(row)")
        return try #require(row["result"]?.object)
    }
    func approve(_ kind: String, script: String) throws {
        _ = try ok("worktree.approveHooks", ["repoId": .string(repoID), "kind": .string(kind), "contentHash": .string(SmthzConfigTrust.contentHash(script))])
    }
}

@Suite(.serialized) struct WorktreeLifecycleTests {
    @Test func createPhasesAndSelectors() throws {
        let f = try WorktreeFixture()
        let created = try f.create(":rocket: fix login", fields: ["revealRequested": .bool(true)]), row = try #require(created["worktree"]?.object)
        #expect(row["branch"] == .string("tester/rocket-fix-login"))
        #expect(row["state"] == .string("ready"))
        #expect(row["revealRequested"] == .bool(true))
        let job = try #require(row["jobId"]?.string)
        if case .array(let events) = try f.router.jobs.get(job)["events"] {
            #expect(events.compactMap { $0.object?["kind"] == .string("phase") ? $0.object?["text"]?.string : nil } == ["resolveBase", "resolveName", "add", "materialize", "persist", "setup", "defaultTabs"])
        } else { Issue.record("missing job events") }
        let path = try #require(row["path"]?.string)
        #expect(try f.git(["worktree", "list", "--porcelain"]).contains(path))
        #expect(try f.ok("worktree.resolve", ["selector": .string("current"), "cwd": .string(path)])["worktree"]?.object?["id"] == row["id"])
        #expect(try f.ok("worktree.show", ["id": row["id"]!])["git"]?.object?["clean"] == .bool(true))
        #expect(try f.git(["config", "--get", "branch.tester/rocket-fix-login.base"]) == "main")
    }
    @Test func createsFromBranchAndCommit() throws {
        let f = try WorktreeFixture()
        try f.git(["branch", "base"])
        let head = try f.git(["rev-parse", "HEAD"])
        for (kind, ref) in [("branch", "base"), ("commit", head)] {
            let result = try f.create(kind, fields: ["startFrom": .object(["kind": .string(kind), "ref": .string(ref)])])
            #expect(try f.git(["rev-parse", "HEAD"], path: result["worktree"]!.object!["path"]!.string!) == head)
        }
    }
    @Test func createsFromLocalBareRemote() throws {
        let f = try WorktreeFixture(), bare = f.directory.path + "/remote.git"
        try f.git(["init", "--bare", "-q", bare])
        try f.git(["remote", "add", "origin", bare]); try f.git(["push", "-q", "origin", "main"])
        let row = try f.create("remote", fields: ["startFrom": .object(["kind": .string("remote-branch"), "ref": .string("origin/main")])])
        #expect(row["baseFallback"] == .bool(false))
    }
    @Test func collisionSuffixesAndExistingBranchPreservation() throws {
        let f = try WorktreeFixture()
        try f.git(["branch", "tester/task"])
        let first = try f.create(), row = first["worktree"]!.object!
        #expect(row["checkoutExistingBranch"] == .bool(true))
        #expect(try f.create()["worktree"]?.object?["branch"] == .string("tester/task-2"))
        let removed = try f.job("worktree.remove", ["id": row["id"]!])
        #expect(removed["result"]?.object?["preservedBranch"] == .string("tester/task"))
        #expect(try f.git(["rev-parse", "--verify", "tester/task"]).isEmpty == false)
    }
    @Test func generatedNamesRetire() throws {
        let f = try WorktreeFixture()
        let name = try #require(f.ok("worktree.suggestName", ["repoId": .string(f.repoID)])["name"]?.string)
        let row = try f.create(name, fields: ["nameWasGenerated": .bool(true)])["worktree"]!.object!
        _ = try f.job("worktree.remove", ["id": row["id"]!])
        #expect(try f.create(name, fields: ["nameWasGenerated": .bool(true)])["worktree"]?.object?["branch"] == .string("tester/" + name + "-2"))
        #expect(try f.create(name + "-2", fields: ["nameWasGenerated": .bool(true)])["worktree"]?.object?["branch"] == .string("tester/" + name + "-3"))
    }
    @Test func prefixStrategies() throws {
        let f = try WorktreeFixture()
        try f.store.setHostSettings(["branchPrefix": .string("none")])
        #expect(try f.create("none")["worktree"]?.object?["branch"] == .string("none"))
        try f.store.setHostSettings(["branchPrefix": .string("git-username")])
        #expect(try f.create("user")["worktree"]?.object?["branch"] == .string("worktree-tester/user"))
    }
    @Test func unsafeInputAndAskRefuseBeforeGit() throws {
        let f = try WorktreeFixture()
        try f.store.updateRow(table: "repos", id: f.repoID, values: ["setup_run_policy": .text("ask")])
        let before = try f.git(["branch", "--list"])
        #expect(try f.call("worktree.create", ["repoId": .string(f.repoID), "name": .string("asked")])["error"] == .string("setupDecisionRequired"))
        #expect(try f.git(["branch", "--list"]) == before)
        #expect(!FileManager.default.fileExists(atPath: f.directory.path + "/workspaces"))
        #expect(try f.call("worktree.create", ["repoId": .string(f.repoID), "name": .string("..")])["error"] == .string("invalidName"))
    }
    @Test func sparseCheckout() throws {
        let f = try WorktreeFixture()
        try f.write("one/file", "one"); try f.write("two/file", "two"); try f.commit()
        let row = try f.create("sparse", fields: ["sparse": .object(["directories": .array([.string("one")])])])["worktree"]!.object!
        let path = row["path"]!.string!
        #expect(FileManager.default.fileExists(atPath: path + "/one/file"))
        #expect(!FileManager.default.fileExists(atPath: path + "/two/file"))
    }
    @Test func materializesIgnoredIncludesAndSharedDirectories() throws {
        let f = try WorktreeFixture()
        try f.write(".gitignore", ".env\ncache/\n")
        try f.write(".worktreeinclude", ".env\ntracked\nmissing\n*.log\n")
        try f.write("smthz.yaml", "worktree:\n  sharedDirectories:\n    - cache\n")
        try f.write("tracked", "tracked"); try f.commit()
        try f.write(".env", "secret"); try f.write("cache/data", "cache")
        let result = try f.create(), path = result["worktree"]!.object!["path"]!.string!
        #expect(try String(contentsOfFile: path + "/.env", encoding: .utf8) == "secret")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path + "/cache") == f.root + "/cache")
        #expect(result["warnings"] != .array([]))
        try f.write(".env", "private", at: path)
        #expect(try String(contentsOfFile: f.root + "/.env", encoding: .utf8) == "secret")
    }
    @Test func materializeBudgetAndSymlinkEscape() throws {
        let f = try WorktreeFixture()
        try f.write(".gitignore", "copy/\n"); try f.write(".worktreeinclude", "copy\n")
        try f.write("copy/a", "a"); try f.write("copy/b", "b")
        let destination = f.directory.path + "/materialized"
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        let warnings = try WorktreeMaterializer.materialize(root: f.root, destination: destination, entryBudget: 1)
        #expect(!warnings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination + "/copy"))
    }
    @Test func setupTrustEnvironmentAndSetE() throws {
        let f = try WorktreeFixture()
        let script = "printf '%s' \"$SMTHZ_ROOT_PATH|$SMTHZ_WORKTREE_PATH|$SMTHZ_WORKSPACE_NAME\" > env; false; touch should-not-exist"
        try f.write("smthz.yaml", "scripts:\n  setup: |\n    " + script + "\n"); try f.commit()
        #expect(try f.call("worktree.create", ["repoId": .string(f.repoID), "name": .string("denied")])["error"] == .string("untrustedCommand"))
        try f.approve("setup", script: script)
        let result = try f.create(), path = result["worktree"]!.object!["path"]!.string!
        let session = try #require(result["setup"]?.object?["sessionId"]?.string)
        let deadline = Date(timeIntervalSinceNow: 5)
        while try f.service.sessionManager.read(id: session, from: 0, maxBytes: 1).exit == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(try String(contentsOfFile: path + "/env", encoding: .utf8) == f.root + "|" + path + "|task")
        #expect(!FileManager.default.fileExists(atPath: path + "/should-not-exist"))
        #expect(try f.service.sessionManager.read(id: session, from: 0, maxBytes: 1).exit == .exited(1))
    }
    @Test func removeDirtyForceAndMainGuard() throws {
        let f = try WorktreeFixture(), row = try f.create()["worktree"]!.object!
        try f.write("dirty", "data", at: row["path"]!.string!)
        #expect(try f.job("worktree.remove", ["id": row["id"]!])["error"] == .string("worktreeDirty"))
        #expect(try f.job("worktree.remove", ["id": row["id"]!, "force": .bool(true)])["state"] == .string("succeeded"))
        let main = try f.store.worktreeRows(repoID: f.repoID).first { $0["is_main"]?.integer == 1 }!
        #expect(try f.call("worktree.remove", ["id": .string(main["id"]!.string!)])["error"] == .string("badRequest"))
    }
    @Test func failingArchiveBlockedThenWaived() throws {
        let f = try WorktreeFixture()
        try f.write("smthz.yaml", "scripts:\n  archive: exit 7\n"); try f.commit(); try f.approve("archive", script: "exit 7")
        let row = try f.create()["worktree"]!.object!
        #expect(try f.job("worktree.remove", ["id": row["id"]!, "force": .bool(true)])["error"] == .string("archiveHookFailed"))
        #expect(FileManager.default.fileExists(atPath: row["path"]!.string!))
        let waived = try f.job("worktree.remove", ["id": row["id"]!, "allowFailedArchiveHook": .bool(true)])
        #expect(waived["state"] == .string("succeeded"))
        #expect(waived["result"]?.object?["archiveHookOverride"] == .bool(true))
    }
    @Test func preservesUnmergedBranchAndExplicitDeletion() throws {
        let f = try WorktreeFixture(), row = try f.create()["worktree"]!.object!, path = row["path"]!.string!
        try f.write("unique", "unique", at: path)
        try f.git(["add", "."], path: path); try f.git(["-c", "commit.gpgsign=false", "commit", "-qm", "unique"], path: path)
        #expect(try f.job("worktree.remove", ["id": row["id"]!])["result"]?.object?["preservedBranch"] == row["branch"])
        #expect(try f.ok("worktree.preservedBranches")["branches"] != .array([]))
        _ = try f.ok("worktree.deletePreservedBranch", ["repoId": .string(f.repoID), "branch": row["branch"]!])
        #expect(try f.ok("worktree.preservedBranches")["branches"] == .array([]))
    }
    @Test func externalImportPruneAndRestartReconciliation() throws {
        let f = try WorktreeFixture(), external = f.directory.path + "/external"
        try f.git(["worktree", "add", "-qb", "external", external])
        _ = try f.ok("worktree.list")
        let hidden = try #require(f.store.worktreeRows().first { $0["origin"]?.string == "external" })
        #expect(hidden["is_visible"]?.integer == 0)
        #expect(try f.ok("worktree.import", ["path": .string(external)])["worktree"]?.object?["isVisible"] == .bool(true))
        try f.git(["worktree", "remove", external]); _ = try f.ok("worktree.list")
        #expect(try f.store.worktreeRows().count == 1)
        let row = try f.create()["worktree"]!.object!, id = row["id"]!.string!
        try f.store.updateRow(table: "worktrees", id: id, values: ["state": .text("creating")])
        try f.store.reconcileWorktrees(repoID: f.repoID, afterRestart: true)
        #expect(try f.store.worktreeRow(id)["last_error"]?.string == "hostRestarted")
    }
    @Test func cancellationDuringSlowAddRollsBackOwnBranch() throws {
        let f = try WorktreeFixture()
        let marker = f.directory.path + "/in-hook"
        let hook = f.root + "/.git/hooks/post-checkout"
        try Data(("#!/bin/sh\ntouch '" + marker + "'\nexec /bin/sleep 2\n").utf8).write(to: URL(fileURLWithPath: hook))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        let accepted = try f.ok("worktree.create", ["repoId": .string(f.repoID), "name": .string("cancelled")])
        let deadline = Date(timeIntervalSinceNow: 10)
        while !FileManager.default.fileExists(atPath: marker), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(FileManager.default.fileExists(atPath: marker))
        let id = accepted["jobId"]!.string!
        try f.router.jobs.cancel(id)
        #expect(try f.wait(id)["state"] == .string("cancelled"))
        #expect(!FileManager.default.fileExists(atPath: f.directory.path + "/workspaces/repo/cancelled"))
        #expect(try f.git(["branch", "--list", "tester/cancelled"]).isEmpty)
        #expect(try f.git(["worktree", "list", "--porcelain"]).components(separatedBy: "worktree ").count == 2)
    }
    @Test func externalVisibilityFollowsRepoUnlessOverridden() throws {
        let f = try WorktreeFixture(), path = f.directory.path + "/external"
        try f.git(["worktree", "add", "-qb", "external", path])
        _ = try f.ok("worktree.list")
        let row = try #require(f.store.worktreeRows().first { $0["origin"]?.string == "external" })
        try f.store.updateRow(table: "repos", id: f.repoID, values: ["external_worktree_visibility": .text("show")])
        _ = try f.ok("worktree.list")
        #expect(try f.store.worktreeRow(row["id"]!.string!)["is_visible"]?.integer == 1)
        _ = try f.ok("worktree.set", ["id": .string(row["id"]!.string!), "visible": .bool(false)])
        _ = try f.ok("worktree.list")
        #expect(try f.store.worktreeRow(row["id"]!.string!)["is_visible"]?.integer == 0)
    }
    @Test func archiveSetGateAndLockedRemoval() throws {
        let f = try WorktreeFixture()
        try f.store.updateRow(table: "repos", id: f.repoID, values: ["local_archive_script": .text("exit 3")])
        let row = try f.create()["worktree"]!.object!
        #expect(try f.call("worktree.set", ["id": row["id"]!, "archived": .bool(true)])["error"] == .string("archiveHookFailed"))
        #expect(try f.store.worktreeRow(row["id"]!.string!)["is_archived"]?.integer == 0)
        _ = try f.ok("worktree.set", ["id": row["id"]!, "archived": .bool(true), "allowFailedArchiveHook": .bool(true)])
        try f.git(["worktree", "lock", row["path"]!.string!])
        #expect(try f.job("worktree.remove", ["id": row["id"]!, "force": .bool(true)])["error"] == .string("worktreeLocked"))
    }
    @Test func orcaFallbackEnvironmentAndLocalOnlyPolicy() throws {
        let f = try WorktreeFixture(), shared = "echo \"$ORCA_ROOT_PATH|$ORCA_WORKTREE_PATH\" > compatibility"
        try f.write("orca.yaml", "scripts:\n  setup: |\n    " + shared + "\n"); try f.commit()
        try f.approve("setup", script: shared)
        let result = try f.create(), path = result["worktree"]!.object!["path"]!.string!
        let session = try #require(result["setup"]?.object?["sessionId"]?.string), deadline = Date(timeIntervalSinceNow: 5)
        while try f.service.sessionManager.read(id: session, from: 0, maxBytes: 1).exit == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(try String(contentsOfFile: path + "/compatibility", encoding: .utf8) == f.root + "|" + path + "\n")
        try f.store.updateRow(table: "repos", id: f.repoID, values: ["command_source_policy": .text("local-only"), "local_setup_script": .text("touch local")])
        let second = try f.create("local"), localPath = second["worktree"]!.object!["path"]!.string!
        #expect(second["defaultTabs"] == nil)
        #expect(!FileManager.default.fileExists(atPath: localPath + "/compatibility"))
    }
    @Test func includeNeverFollowsDestinationSymlinkOutsideWorktree() throws {
        let f = try WorktreeFixture()
        try f.write(".gitignore", "copy/\n"); try f.write(".worktreeinclude", "copy/secret\n"); try f.write("copy/secret", "secret")
        let destination = f.directory.path + "/destination", outside = f.directory.path + "/outside"
        try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: destination + "/copy", withDestinationPath: outside)
        let warnings = try WorktreeMaterializer.materialize(root: f.root, destination: destination)
        #expect(!warnings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: outside + "/secret"))
    }
    @Test func rollbackKeepsPreexistingBranch() throws {
        let f = try WorktreeFixture()
        try f.git(["branch", "tester/existing"])
        let hook = f.root + "/.git/hooks/post-checkout"
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: URL(fileURLWithPath: hook))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
        #expect(try f.job("worktree.create", ["repoId": .string(f.repoID), "name": .string("existing")])["state"] == .string("failed"))
        #expect(!FileManager.default.fileExists(atPath: f.directory.path + "/workspaces/repo/existing"))
        #expect(try f.git(["branch", "--list", "tester/existing"]).contains("tester/existing"))
    }
    @Test func restartFinishesRemovedRowsAndClearsChildren() throws {
        let f = try WorktreeFixture(), parent = try f.create("parent")["worktree"]!.object!
        let child = try f.create("child", fields: ["parentId": parent["id"]!])["worktree"]!.object!
        try f.store.updateRow(table: "worktrees", id: parent["id"]!.string!, values: ["state": .text("removing")])
        try f.git(["worktree", "remove", parent["path"]!.string!])
        try f.store.reconcileAfterRestart(); try f.store.reconcileWorktrees(repoID: f.repoID, afterRestart: true)
        #expect(try f.call("worktree.show", ["id": parent["id"]!])["error"] == .string("notFound"))
        #expect(try f.ok("worktree.show", ["id": child["id"]!])["lineage"]?.object?["parent"] == .null)
    }
    @Test func invalidSparseRollsBackWithoutCreatingPath() throws {
        let f = try WorktreeFixture()
        #expect(try f.job("worktree.create", ["repoId": .string(f.repoID), "name": .string("unsafe"), "sparse": .object(["directories": .array([.string("../escape")])])])["state"] == .string("failed"))
        #expect(!FileManager.default.fileExists(atPath: f.directory.path + "/workspaces"))
        #expect(try f.git(["branch", "--list", "tester/unsafe"]).isEmpty)
        let root = f.directory.path + "/workspaces/repo", outside = f.directory.path + "/outside"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/trap", withDestinationPath: outside)
        #expect(try f.job("worktree.create", ["repoId": .string(f.repoID), "name": .string("trap")])["error"] == .string("invalidPath"))
        #expect(try f.git(["branch", "--list", "tester/trap"]).isEmpty)
    }
    @Test func defaultTabsCommandsRequireOwnTrust() throws {
        let f = try WorktreeFixture()
        try f.write("smthz.yaml", "defaultTabs:\n  - title: Build\n    command: echo trusted\n"); try f.commit()
        #expect(try f.call("worktree.create", ["repoId": .string(f.repoID), "name": .string("denied")])["error"] == .string("untrustedCommand"))
        try f.approve("defaultTabs", script: "echo trusted")
        #expect(try f.create()["defaultTabs"] == .array([.object(["title": .string("Build"), "command": .string("echo trusted")])]))
        #expect(try f.create("skip", fields: ["setup": .string("skip")])["defaultTabs"] == .array([.object(["title": .string("Build")])]))
    }
    @Test func lineageMetadataAndPS() throws {
        let f = try WorktreeFixture(), parent = try f.create("parent")["worktree"]!.object!
        let child = try f.create("child", fields: ["parentId": parent["id"]!])["worktree"]!.object!
        _ = try f.ok("worktree.set", ["id": child["id"]!, "comment": .string("comment"), "unread": .bool(true), "pinned": .bool(true)])
        #expect(try f.call("worktree.set", ["id": parent["id"]!, "parentId": child["id"]!])["error"] == .string("badRequest"))
        let show = try f.ok("worktree.show", ["id": child["id"]!])
        #expect(show["lineage"]?.object?["parent"] == .string("worktree:" + parent["id"]!.string!))
        let session = try f.service.sessionManager.create(executable: "/bin/sleep", arguments: ["30"], workingDirectory: child["path"]!.string!)
        let ps = try f.ok("worktree.ps")
        if case .array(let rows) = ps["rows"] {
            #expect(rows.contains { $0.object?["worktreeId"] == child["id"] && $0.object?["runningSessions"] == .number(1) })
        } else { Issue.record("missing ps rows") }
        _ = try f.job("worktree.remove", ["id": child["id"]!])
        #expect(!f.service.sessionManager.list().contains { $0.id == session.id && $0.running })
    }
}
