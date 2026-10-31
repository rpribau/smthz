import Foundation
import Testing
@testable import SmthzCore

struct WorktreeAppLogicTests {
    typealias L = WorkspaceComposerLogic

    @Test func shortcodeQueryNeedsLeadingColonAtWordStart() {
        #expect(L.shortcodeQuery(in: "fix :roc")?.partial == "roc")
        #expect(L.shortcodeQuery(in: ":rocket")?.partial == "rocket")
        #expect(L.shortcodeQuery(in: "fix login") == nil)
        #expect(L.shortcodeQuery(in: "fix :") == nil)
        #expect(L.shortcodeQuery(in: "a:b") == nil)
        #expect(L.shortcodeQuery(in: ":rocket: done") == nil)
    }

    @Test func shortcodeSuggestionsPreferPrefixMatches() {
        let suggestions = L.shortcodeSuggestions(for: "launch :rock")
        #expect(suggestions.first?.shortcode == "rock")
        #expect(suggestions.contains { $0.shortcode == "rocket" && $0.emoji == "🚀" })
        #expect(suggestions.count <= 8)
        #expect(L.shortcodeSuggestions(for: "plain").isEmpty)
    }

    @Test func applyingShortcodeReplacesOnlyTheTrailingToken() {
        #expect(L.applyShortcode("rocket", to: "fix :roc") == "fix :rocket: ")
        #expect(L.applyShortcode("rocket", to: "fix") == "fix")
    }

    @Test func sparseDirectoriesAreNormalizedAndValidated() throws {
        #expect(try L.parseSparseDirectories("./src/\npackages/app, docs\nsrc") == ["src", "packages/app", "docs"])
        #expect(throws: L.SparseError.empty) { try L.parseSparseDirectories(" \n , ") }
        #expect(throws: L.SparseError.invalid("../x")) { try L.parseSparseDirectories("../x") }
        #expect(throws: L.SparseError.invalid("/abs")) { try L.parseSparseDirectories("/abs") }
        #expect(throws: L.SparseError.invalid(".git/hooks")) { try L.parseSparseDirectories(".git/hooks") }
        #expect(throws: L.SparseError.invalid("a//b")) { try L.parseSparseDirectories("a//b") }
    }

    @Test func nameSourceUsesTypedOrGeneratedName() throws {
        var form = L.CreateForm(repoID: "r1")
        #expect(throws: L.FormError.missingName) { try L.createParams(form) }
        form.suggestedName = "octopus"
        var params = try L.createParams(form)
        #expect(params["name"] == .string("octopus"))
        #expect(params["nameWasGenerated"] == .bool(true))
        #expect(params["createdBy"] == .string("desktop"))
        #expect(params["noParent"] == .bool(true))
        #expect(params["setup"] == .string("inherit"))
        #expect(params["startFrom"] == nil && params["branchName"] == nil && params["sparse"] == nil)
        form.name = "  :rocket: fix login "
        form.ref = .init(name: "origin/main", kind: "remote")
        form.parentID = "w2"; form.comment = "note"; form.setup = .skip
        form.sparseDirectories = ["src"]; form.sparsePresetID = "p1"
        params = try L.createParams(form)
        #expect(params["name"] == .string(":rocket: fix login"))
        #expect(params["nameWasGenerated"] == nil)
        #expect(params["startFrom"] == .object(["kind": .string("base"), "ref": .string("origin/main")]))
        #expect(params["parentId"] == .string("w2") && params["noParent"] == nil)
        #expect(params["comment"] == .string("note") && params["setup"] == .string("skip"))
        #expect(params["sparse"] == .object(["directories": .array([.string("src")]), "presetId": .string("p1")]))
        form.ref = .init(name: "v1.0", kind: "tag")
        #expect(try L.createParams(form)["startFrom"]?.object?["kind"] == .string("commit"))
    }

    @Test func branchSourceChecksOutTheChosenBranch() throws {
        var form = L.CreateForm(repoID: "r1"); form.source = .branch
        #expect(throws: L.FormError.missingBranch) { try L.createParams(form) }
        form.ref = .init(name: "team/feature-x", kind: "local")
        var params = try L.createParams(form)
        #expect(params["startFrom"] == .object(["kind": .string("branch"), "ref": .string("team/feature-x")]))
        #expect(params["branchName"] == .string("team/feature-x"))
        #expect(params["name"] == .string("feature-x"))
        form.ref = .init(name: "origin/fix", kind: "remote")
        params = try L.createParams(form)
        #expect(params["startFrom"]?.object?["kind"] == .string("remote-branch"))
        #expect(params["branchName"] == .string("fix"))
        form.ref = .init(name: "v1", kind: "tag")
        #expect(throws: L.FormError.missingBranch) { try L.createParams(form) }
    }

    @Test func visualOnlySourcesAndBadBranchNamesAreRefused() {
        var form = L.CreateForm(repoID: "r1"); form.name = "x"
        for source in [L.Source.smart, .github, .gitlab, .linear, .jira] {
            form.source = source
            #expect(throws: L.FormError.sourceUnavailable) { try L.createParams(form) }
        }
        form.source = .name; form.branchName = "-evil"
        #expect(throws: L.FormError.invalidBranchName) { try L.createParams(form) }
        form.branchName = "has space"
        #expect(throws: L.FormError.invalidBranchName) { try L.createParams(form) }
        #expect(L.withSetup(["setup": .string("inherit")], .run)["setup"] == .string("run"))
    }

    @Test func progressAdvancesThroughPhasesAndGitCounters() {
        #expect(L.progressFraction(phase: "resolveBase", git: nil) == 0)
        let addStart = L.progressFraction(phase: "add", git: nil)
        let addHalf = L.progressFraction(phase: "add", git: (50, 100))
        let sparse = L.progressFraction(phase: "sparse", git: nil)
        #expect(addStart < addHalf && addHalf < sparse)
        #expect(L.progressFraction(phase: "defaultTabs", git: nil) < 1)
        #expect(L.progressFraction(phase: "unknown", git: nil) == 0)
        #expect(L.phaseLabel("add") == "Checking out files")
        #expect(L.phaseLabel("custom") == "custom")
    }

    @Test func setupBlocksAreRecognisedFromHostErrors() {
        let hash = String(repeating: "a", count: 64)
        #expect(L.createBlock(code: "setupDecisionRequired", detail: nil) == .setupDecision)
        #expect(L.createBlock(code: "untrustedCommand", detail: "setup: " + hash) == .untrusted(kind: "setup", hash: hash))
        #expect(L.createBlock(code: "untrustedCommand", detail: "setup: short") == nil)
        #expect(L.createBlock(code: "invalidRef", detail: nil) == nil)
        #expect(L.message(code: "branchExists", detail: nil) == "A branch or folder with that name already exists.")
        #expect(L.message(code: "gitFailed", detail: "boom") == "Git failed. boom")
    }

    @Test func removeParamsCarryEveryOption() {
        var options = L.RemoveOptions()
        #expect(L.removeParams(id: "w", options) == ["id": .string("w"), "force": .bool(false), "deleteBranch": .bool(true),
            "runHooks": .bool(true), "allowFailedArchiveHook": .bool(false), "closeSessions": .bool(true)])
        options.force = true; options.deleteBranch = false; options.runHooks = false
        let params = L.removeParams(id: "w", options)
        #expect(params["force"] == .bool(true) && params["deleteBranch"] == .bool(false) && params["runHooks"] == .bool(false))
    }
}

/// Composer/delete-dialog params against the real worktree RPC (temp repo, in-process host).
private final class ComposerHostFixture: @unchecked Sendable {
    let directory: URL
    let root: String
    let store: WorkspaceStore
    let router = HostRouter()
    let service: HostService
    let repoID: String
    init() throws {
        directory = URL(fileURLWithPath: "/tmp/smthz-wa-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        root = try WorkspaceStore.canonicalPath(directory.path) + "/repo"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        store = try WorkspaceStore(path: directory.appendingPathComponent("store").path)
        service = HostService(journal: try EventJournal(path: directory.appendingPathComponent("journal").path), hostIdentity: nil, router: router)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "composer-tester"], ["config", "user.email", "test@example.invalid"],
                     ["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "initial"], ["branch", "feature/login"]] {
            _ = try GitService().worktreeGit(args, at: root)
        }
        repoID = try store.insertRepo(path: root, kind: "git", displayName: "repo", branch: "main", projectGroupID: nil).row["id"]!.string!
        try store.setHostSettings(["workspaceDir": .string(directory.path + "/workspaces"), "branchPrefix": .string("custom"), "branchPrefixCustom": .string("tester")])
        WorktreeRPC.register(on: router, store: store, sessions: service.sessionManager)
        RepoRPC.register(on: router, store: store)
    }
    deinit { service.stop(); try? FileManager.default.removeItem(at: directory) }
    func git(_ args: [String], at path: String? = nil) throws -> String {
        try GitService().worktreeGit(args, at: path ?? root).stdout.trimmingCharacters(in: .newlines)
    }
    func call(_ method: String, _ params: [String: HostJSON]) throws -> [String: HostJSON] {
        let request = RPCEnvelope(version: 1, requestID: UUID().uuidString, method: method, payload: try JSONEncoder().encode(params))
        let response = try JSONDecoder().decode(RPCEnvelope.self, from: service.handleAuthenticatedTestRequest(JSONEncoder().encode(request)))
        return try JSONDecoder().decode([String: HostJSON].self, from: response.payload)
    }
    /// Polls with `Task.sleep` so a waiting test never blocks a cooperative-pool thread.
    func job(_ method: String, _ params: [String: HostJSON]) async throws -> [String: HostJSON] {
        let started = try call(method, params)
        let id = try #require(started["jobId"]?.string, "\(method): \(started)")
        let deadline = Date(timeIntervalSinceNow: 30)
        while Date() < deadline {
            let row = try router.jobs.get(id)
            if ["succeeded", "failed", "cancelled"].contains(row["state"]?.string ?? "") { return row }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw HostRPCError("testTimeout")
    }
}

@Suite(.serialized) struct WorktreeComposerHostContractTests {
    typealias L = WorkspaceComposerLogic

    @Test func nameAndBranchSourcesCreateTheExpectedWorktrees() async throws {
        let f = try ComposerHostFixture()
        var form = L.CreateForm(repoID: f.repoID)
        form.name = ":rocket: fix login"; form.comment = "from composer"
        let named = try await f.job("worktree.create", try L.createParams(form))
        let row = try #require(named["result"]?.object?["worktree"]?.object, "\(named)")
        #expect(row["branch"] == .string("tester/rocket-fix-login"))
        #expect(row["comment"] == .string("from composer"))
        let refs = try f.call("repo.searchRefs", ["id": .string(f.repoID), "query": .string("login")])
        let ref = try #require({ if case .array(let items) = refs["refs"] ?? .null { items.compactMap(L.Ref.init).first { $0.name == "feature/login" } } else { nil } }())
        form = L.CreateForm(repoID: f.repoID); form.source = .branch; form.ref = ref
        let branched = try #require(await f.job("worktree.create", try L.createParams(form))["result"]?.object?["worktree"]?.object)
        #expect(branched["branch"] == .string("feature/login"))
        #expect(try f.git(["rev-parse", "--abbrev-ref", "HEAD"], at: branched["path"]!.string!) == "feature/login")
        form = L.CreateForm(repoID: f.repoID); form.suggestedName = "nautilus"
        let generated = try #require(await f.job("worktree.create", try L.createParams(form))["result"]?.object?["worktree"]?.object)
        #expect(generated["branch"] == .string("tester/nautilus"))
    }

    @Test func setupBlocksResolveThroughDecisionAndTrust() async throws {
        let f = try ComposerHostFixture()
        var form = L.CreateForm(repoID: f.repoID); form.name = "asked"
        try f.store.updateRow(table: "repos", id: f.repoID, values: ["setup_run_policy": .text("ask")])
        let params = try L.createParams(form), refused = try f.call("worktree.create", params)
        #expect(L.createBlock(code: refused["error"]?.string ?? "", detail: refused["detail"]?.string) == .setupDecision)
        #expect(try await f.job("worktree.create", L.withSetup(params, .skip))["state"] == .string("succeeded"))
        try f.store.updateRow(table: "repos", id: f.repoID, values: ["setup_run_policy": .text("run-by-default")])
        try Data("scripts:\n  setup: echo ready\n".utf8).write(to: URL(fileURLWithPath: f.root + "/smthz.yaml"))
        _ = try f.git(["add", "."]); _ = try f.git(["-c", "commit.gpgsign=false", "commit", "-qm", "setup"])
        form.name = "trusted"
        let untrusted = try f.call("worktree.create", try L.createParams(form))
        guard case .untrusted(let kind, let hash)? = L.createBlock(code: untrusted["error"]?.string ?? "", detail: untrusted["detail"]?.string) else {
            Issue.record("expected untrustedCommand, got \(untrusted)"); return
        }
        #expect(kind == "setup" && hash == SmthzConfigTrust.contentHash("echo ready"))
        #expect(try f.call("worktree.approveHooks", ["repoId": .string(f.repoID), "kind": .string(kind), "contentHash": .string(hash)])["ok"] == .bool(true))
        let created = try await f.job("worktree.create", try L.createParams(form))
        #expect(created["result"]?.object?["setup"]?.object?["sessionId"]?.string != nil, "\(created)")
    }

    @Test func deleteOptionsPreserveUnmergedBranchesForReview() async throws {
        let f = try ComposerHostFixture()
        var form = L.CreateForm(repoID: f.repoID); form.name = "review me"
        let row = try #require(await f.job("worktree.create", try L.createParams(form))["result"]?.object?["worktree"]?.object)
        let id = row["id"]!.string!, path = row["path"]!.string!
        try Data("x".utf8).write(to: URL(fileURLWithPath: path + "/dirty"))
        let dirty = try await f.job("worktree.remove", L.removeParams(id: id, .init()))
        #expect(dirty["error"] == .string("worktreeDirty"))
        _ = try f.git(["add", "."], at: path); _ = try f.git(["-c", "commit.gpgsign=false", "commit", "-qm", "unique"], at: path)
        let removed = try await f.job("worktree.remove", L.removeParams(id: id, .init()))
        #expect(removed["result"]?.object?["preservedBranch"] == .string("tester/review-me"), "\(removed)")
        #expect(!FileManager.default.fileExists(atPath: path))
        var keep = L.RemoveOptions(); keep.deleteBranch = false
        let second = try #require(await f.job("worktree.create", try L.createParams({ var g = form; g.name = "kept"; return g }()))["result"]?.object?["worktree"]?.object)
        #expect(try await f.job("worktree.remove", L.removeParams(id: second["id"]!.string!, keep))["state"] == .string("succeeded"))
        #expect(try f.git(["branch", "--list", "tester/kept"]).contains("tester/kept"))
    }

    @Test func discardingAFailedCreateRemovesOnlyTheRow() async throws {
        let f = try ComposerHostFixture()
        let id = try f.store.insertWorktree(repoID: f.repoID, path: f.directory.path + "/workspaces/repo/gone", branch: "main", name: "gone", state: "failed")
        let removed = try await f.job("worktree.remove", L.removeParams(id: id, L.discardFailedOptions))
        #expect(removed["state"] == .string("succeeded"), "\(removed)")
        #expect(try f.store.query("SELECT id FROM worktrees WHERE id=?", [.text(id)]).isEmpty)
        #expect(try f.git(["branch", "--list", "main"]).contains("main"))
    }
}
