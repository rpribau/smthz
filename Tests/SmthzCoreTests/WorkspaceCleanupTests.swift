import Foundation
import Testing
@testable import SmthzCore

private typealias WC = WorkspaceCleanup

private func evidence(_ change: (inout WC.Evidence) -> Void = { _ in }) -> WC.Evidence {
    var e = WC.Evidence(worktreeID: "w1", repoID: "r1", repoName: "repo", displayName: "task",
                        branch: "tester/task", head: "abc123", path: "/tmp/x")
    e.lastActivityAt = 0
    e.git = WC.GitEvidence(clean: true, upstreamAhead: 0, upstreamBehind: 0, checkedAt: 1)
    change(&e)
    return e
}

private let day: Double = 86_400
private let now: Double = 100 * day

@Suite struct WorkspaceCleanupClassifierTests {
    @Test func reasonsFollowIdleThresholds() {
        #expect(WC.reasons(isArchived: false, lastActivityAt: now - 29 * day, scannedAt: now) == [])
        #expect(WC.reasons(isArchived: false, lastActivityAt: now - 30 * day, scannedAt: now) == [.idleClean])
        #expect(WC.reasons(isArchived: true, lastActivityAt: now - 6 * day, scannedAt: now) == [])
        #expect(WC.reasons(isArchived: true, lastActivityAt: now - 7 * day, scannedAt: now) == [.archived])
        #expect(WC.reasons(isArchived: true, lastActivityAt: now - 31 * day, scannedAt: now) == [.archived, .idleClean])
    }

    @Test func idleCleanRowIsReady() {
        let c = WC.classify(evidence(), scannedAt: now)
        #expect(c.reasons == [.idleClean])
        #expect(c.blockers == [])
        #expect(c.isReady && c.canQueue && !c.needsForce)
        let fresh = WC.classify(evidence { $0.lastActivityAt = now - day }, scannedAt: now)
        #expect(!fresh.isReady && fresh.canQueue && !fresh.needsForce)
    }

    /// One row per blocker: (evidence change, blocker, can queue, needs force).
    @Test func blockerTable() {
        let table: [((inout WC.Evidence) -> Void, WC.Blocker, Bool, Bool)] = [
            ({ $0.isMain = true }, .mainWorktree, false, false),
            ({ $0.isFolderRepo = true; $0.git = WC.GitEvidence(clean: true, upstreamAhead: 0, checkedAt: 1) }, .folderRepo, false, false),
            ({ $0.isPinned = true }, .pinned, true, false),
            ({ $0.isActive = true }, .activeWorkspace, true, false),
            ({ $0.runningSessionCount = 1; $0.sessionCount = 1 }, .runningTerminal, true, false),
            ({ $0.git = .unreadable }, .gitStatusError, true, true),
            ({ $0.git.clean = false }, .dirtyFiles, true, true),
            ({ $0.git.upstreamAhead = 2 }, .unpushedCommits, true, true),
            ({ $0.git.upstreamAhead = nil; $0.git.unpushedWithoutUpstream = nil }, .unknownBase, true, true),
        ]
        for (change, blocker, canQueue, needsForce) in table {
            let c = WC.classify(evidence(change), scannedAt: now)
            #expect(c.blockers == [blocker], "\(blocker)")
            #expect(c.canQueue == canQueue, "\(blocker)")
            #expect(c.needsForce == needsForce, "\(blocker)")
            #expect(!c.isReady, "\(blocker)")
            #expect(c.reasons == [.idleClean], "\(blocker)")
        }
        let dismissed = WC.classify(evidence(), scannedAt: now,
                                    dismissal: .init(fingerprint: WC.classify(evidence(), scannedAt: now).fingerprint))
        #expect(dismissed.blockers == [.dismissed] && dismissed.canQueue && !dismissed.needsForce && !dismissed.isReady)
        #expect(Set(WC.Blocker.allCases) == Set(table.map(\.1) + [.dismissed]))
    }

    @Test func gitEvidenceWithoutUpstream() {
        #expect(WC.GitEvidence(clean: true, checkedAt: 1, unpushedWithoutUpstream: 0).blockers == [])
        #expect(WC.GitEvidence(clean: true, checkedAt: 1, unpushedWithoutUpstream: 3).blockers == [.unpushedCommits])
        #expect(WC.GitEvidence(clean: true, checkedAt: 1).blockers == [.unknownBase])
        // Dirty rows never probe the base (Orca only counts unpushed commits on clean checkouts).
        #expect(WC.GitEvidence(clean: false, checkedAt: 1).blockers == [.dirtyFiles])
        #expect(WC.GitEvidence(clean: false, upstreamAhead: 1, checkedAt: 1).blockers == [.dirtyFiles, .unpushedCommits])
        #expect(WC.GitEvidence(clean: nil).blockers == [.gitStatusError])
    }

    @Test func fingerprintChangesUndismiss() {
        let base = WC.classify(evidence(), scannedAt: now)
        let dismissal = WC.Dismissal(fingerprint: base.fingerprint)
        #expect(WC.classify(evidence(), scannedAt: now, dismissal: dismissal).isDismissed)
        // Activity later the same day keeps the fingerprint.
        #expect(WC.classify(evidence { $0.lastActivityAt = 3_600 }, scannedAt: now, dismissal: dismissal).isDismissed)
        let changes: [(inout WC.Evidence) -> Void] = [
            { $0.head = "def456" },
            { $0.branch = "tester/other" },
            { $0.git.clean = false },
            { $0.git = .unreadable },
            { $0.lastActivityAt = 2 * day },
        ]
        for change in changes {
            let c = WC.classify(evidence(change), scannedAt: now, dismissal: dismissal)
            #expect(c.fingerprint != base.fingerprint)
            #expect(!c.isDismissed)
        }
        let oldVersion = WC.Dismissal(fingerprint: base.fingerprint, classifierVersion: WC.classifierVersion - 1)
        #expect(!WC.classify(evidence(), scannedAt: now, dismissal: oldVersion).isDismissed)
        #expect(base.fingerprint.count == 64)
    }

    @Test func batchLimit() throws {
        let ids = (0..<WC.targetBatchLimit).map { "w\($0)" }
        #expect(try WC.validateTargets(ids + ["w0", "w1"]).count == WC.targetBatchLimit)
        #expect(throws: WC.BatchError.tooManyTargets(WC.targetBatchLimit + 1)) { try WC.validateTargets(ids + ["extra"]) }
    }
}

private final class CleanupFixture: @unchecked Sendable {
    let directory: URL
    let root: String
    let store: WorkspaceStore
    let router = HostRouter()
    let service: HostService
    let repoID: String
    init() throws {
        directory = URL(fileURLWithPath: "/tmp/smthz-wc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = try WorkspaceStore.canonicalPath(directory.path)
        root = base + "/repo"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
        store = try WorkspaceStore(path: directory.appendingPathComponent("store").path)
        let journal = try EventJournal(path: directory.appendingPathComponent("journal").path)
        service = HostService(journal: journal, hostIdentity: nil, router: router)
        let git = GitService()
        _ = try git.worktreeGit(["init", "-q", "--bare", base + "/remote.git"], at: base)
        _ = try git.worktreeGit(["init", "-q", "-b", "main"], at: root)
        _ = try git.worktreeGit(["config", "user.name", "cleanup-tester"], at: root)
        _ = try git.worktreeGit(["config", "user.email", "test@example.invalid"], at: root)
        _ = try git.worktreeGit(["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "initial"], at: root)
        _ = try git.worktreeGit(["remote", "add", "origin", base + "/remote.git"], at: root)
        _ = try git.worktreeGit(["push", "-q", "-u", "origin", "main"], at: root)
        repoID = try store.insertRepo(path: root, kind: "git", displayName: "repo", branch: "main", projectGroupID: nil).row["id"]!.string!
        try store.setHostSettings(["workspaceDir": .string(base + "/workspaces"), "branchPrefix": .string("custom"), "branchPrefixCustom": .string("tester")])
        WorktreeRPC.register(on: router, store: store, sessions: service.sessionManager)
        CleanupRPC.register(on: router, store: store, sessions: service.sessionManager)
    }
    deinit { service.stop(); try? FileManager.default.removeItem(at: directory) }
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
    func job(_ method: String, _ params: [String: HostJSON]) throws -> [String: HostJSON] {
        let id = try #require(ok(method, params)["jobId"]?.string)
        let deadline = Date(timeIntervalSinceNow: 30)
        while Date() < deadline {
            let row = try router.jobs.get(id)
            if ["succeeded", "failed", "cancelled"].contains(row["state"]?.string ?? "") { return row }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw HostRPCError("testTimeout")
    }
    func create(_ name: String) throws -> (id: String, path: String) {
        let row = try job("worktree.create", ["repoId": .string(repoID), "name": .string(name)])
        try #require(row["state"] == .string("succeeded"), "\(row)")
        let worktree = try #require(row["result"]?.object?["worktree"]?.object)
        return (try #require(worktree["id"]?.string), try #require(worktree["path"]?.string))
    }
    func age(_ id: String, days: Double) throws {
        let then = Date().timeIntervalSince1970 - days * 86_400
        try store.execute("UPDATE worktrees SET created_at=?, last_activity_at=? WHERE id=?", [.real(then), .real(then), .text(id)])
    }
    func scan(_ params: [String: HostJSON] = [:]) throws -> [String: WC.Candidate] {
        let row = try job("worktree.cleanupScan", params)
        try #require(row["state"] == .string("succeeded"), "\(row)")
        guard case .array(let items) = row["result"]?.object?["candidates"] ?? .null else { throw HostRPCError("badResponse") }
        let candidates = try items.map { try JSONDecoder().decode(WC.Candidate.self, from: JSONEncoder().encode($0)) }
        return Dictionary(uniqueKeysWithValues: candidates.map { ($0.worktreeId, $0) })
    }
}

@Suite(.serialized) struct WorkspaceCleanupTests {
    @Test func scanClassifiesRealWorktreesAndBulkDeleteRemovesOnlyReady() throws {
        let f = try CleanupFixture()
        let idle = try f.create("idle"), dirty = try f.create("dirty"), pinned = try f.create("pinned")
        try Data("scratch".utf8).write(to: URL(fileURLWithPath: dirty.path + "/notes.txt"))
        _ = try f.ok("worktree.set", ["id": .string(pinned.id), "pinned": .bool(true)])
        for id in [idle.id, dirty.id, pinned.id] { try f.age(id, days: 40) }

        let candidates = try f.scan()
        #expect(candidates.count == 4)
        let main = try #require(candidates.values.first { $0.blockers.contains(.mainWorktree) })
        #expect(!main.canQueue && !main.isReady)
        let idleRow = try #require(candidates[idle.id])
        #expect(idleRow.isReady && !idleRow.needsForce && idleRow.blockers.isEmpty, "\(idleRow)")
        #expect(idleRow.git.upstreamAhead == nil && idleRow.git.unpushedWithoutUpstream == 0)
        #expect((idleRow.sizeBytes ?? 0) > 0)
        let dirtyRow = try #require(candidates[dirty.id])
        #expect(dirtyRow.blockers == [.dirtyFiles] && dirtyRow.needsForce && !dirtyRow.isReady)
        let pinnedRow = try #require(candidates[pinned.id])
        #expect(pinnedRow.blockers == [.pinned] && !pinnedRow.isReady)
        #expect(candidates.values.filter(\.isReady).map(\.worktreeId) == [idle.id])

        // Bulk delete: one worktree.remove job per ready row, never forced.
        for row in candidates.values where row.isReady {
            let removed = try f.job("worktree.remove", ["id": .string(row.worktreeId), "force": .bool(row.needsForce)])
            #expect(removed["state"] == .string("succeeded"), "\(removed)")
        }
        let after = try f.scan()
        #expect(after[idle.id] == nil)
        #expect(Set(after.keys) == Set([main.worktreeId, dirty.id, pinned.id]))
        #expect(!FileManager.default.fileExists(atPath: idle.path))
        #expect(FileManager.default.fileExists(atPath: dirty.path + "/notes.txt"))
    }

    @Test func runningTerminalActiveAndUnpushedBlockers() throws {
        let f = try CleanupFixture()
        let running = try f.create("running"), committed = try f.create("committed")
        for id in [running.id, committed.id] { try f.age(id, days: 40) }
        let session = try f.service.sessionManager.create(executable: "/bin/sleep", arguments: ["30"], workingDirectory: running.path)
        defer { try? f.service.sessionManager.close(id: session.id) }
        _ = try GitService().worktreeGit(["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "local"], at: committed.path)

        let rows = try f.scan(["activeWorktreeId": .string(committed.id)])
        let runningRow = try #require(rows[running.id])
        #expect(runningRow.blockers == [.runningTerminal] && runningRow.runningSessionCount == 1)
        // Session activity counts as activity, so the row is no longer idle.
        #expect(runningRow.reasons.isEmpty)
        #expect(try #require(rows[committed.id]).blockers == [.activeWorkspace, .unpushedCommits])
    }

    @Test func dismissHoldsUntilFingerprintChanges() throws {
        let f = try CleanupFixture()
        let row = try f.create("quiet")
        try f.age(row.id, days: 40)
        let first = try #require(f.scan(["worktreeIds": .array([.string(row.id)])])[row.id])
        _ = try f.ok("worktree.cleanupDismiss", ["worktreeId": .string(row.id), "fingerprint": .string(first.fingerprint)])
        let dismissed = try #require(f.scan()[row.id])
        #expect(dismissed.isDismissed && !dismissed.isReady && dismissed.fingerprint == first.fingerprint)

        try Data("x".utf8).write(to: URL(fileURLWithPath: row.path + "/a.txt"))
        let changed = try #require(f.scan()[row.id])
        #expect(changed.fingerprint != first.fingerprint && !changed.isDismissed && changed.blockers == [.dirtyFiles])

        try FileManager.default.removeItem(atPath: row.path + "/a.txt")
        #expect(try #require(f.scan()[row.id]).isDismissed)
        _ = try f.ok("worktree.cleanupDismiss", ["worktreeId": .string(row.id), "fingerprint": .null])
        #expect(try #require(f.scan()[row.id]).isReady)
        #expect(try f.call("worktree.cleanupDismiss", ["worktreeId": .string("missing"), "fingerprint": .string("x")])["ok"] == .bool(false))
    }

    @Test func scanRejectsTooManyTargets() throws {
        let f = try CleanupFixture()
        let ids = HostJSON.array((0...WC.targetBatchLimit).map { .string("w\($0)") })
        let response = try f.call("worktree.cleanupScan", ["worktreeIds": ids])
        #expect(response["ok"] == .bool(false))
        let limit = HostJSON.array((0..<WC.targetBatchLimit).map { .string("w\($0)") })
        #expect(try f.scan(["worktreeIds": limit]).isEmpty)
    }
}
