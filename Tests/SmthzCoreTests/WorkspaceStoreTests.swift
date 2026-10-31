import Foundation
import Testing
@testable import SmthzCore

struct WorkspaceStoreTests {
    @Test func emptyDatabaseMigratesToV2AndReopeningPreservesRows() throws {
        let f = try HostCoreFixture(), path = f.directory.appendingPathComponent("workspace.sqlite").path
        do {
            let store = try WorkspaceStore(path: path)
            #expect(try store.query("PRAGMA user_version").first?["user_version"] == .integer(2))
            #expect(try store.query("PRAGMA foreign_keys").first?["foreign_keys"] == .integer(1))
            #expect(try store.query("PRAGMA journal_mode").first?["journal_mode"] == .text("wal"))
            try store.execute("INSERT INTO host_settings VALUES (?,?,?)", [.text("nestWorkspaces"), .text("true"), .real(42)])
        }
        let reopened = try WorkspaceStore(path: path)
        #expect(try reopened.query("SELECT value_json FROM host_settings").first?["value_json"] == .text("true"))
        let tables = try reopened.query("SELECT name FROM sqlite_master WHERE type='table'")
        #expect(tables.count == 18)  // 11 v1 + 6 orchestration + sqlite_sequence
    }
    @Test func transactionsRollbackAndConstraintsRejectDanglingRepo() throws {
        let f = try HostCoreFixture(), store = try WorkspaceStore(path: f.directory.appendingPathComponent("w").path)
        #expect(throws: HostRPCError("rollback")) {
            try store.transaction {
                try store.execute("INSERT INTO host_settings VALUES ('x','true',1)")
                throw HostRPCError("rollback")
            }
        }
        #expect(try store.query("SELECT * FROM host_settings").isEmpty)
        #expect(throws: (any Error).self) {
            try store.execute("INSERT INTO retired_names VALUES ('missing','name',1)")
        }
        #expect(try store.query("SELECT * FROM retired_names").isEmpty)
    }
    @Test func concurrentAccessIsSerialized() async throws {
        let f = try HostCoreFixture(), store = try WorkspaceStore(path: f.directory.appendingPathComponent("w").path)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<100 { group.addTask {
                try store.transaction {
                    try store.execute("INSERT INTO host_settings VALUES (?, 'true', 1)", [.text(String(i))])
                    #expect(!(try store.query("SELECT * FROM host_settings")).isEmpty)
                }
            } }
            try await group.waitForAll()
        }
        #expect(try store.query("SELECT * FROM host_settings").count == 100)
    }
    @Test func newerSchemaRefused() throws {
        let f = try HostCoreFixture(), path = f.directory.appendingPathComponent("w").path
        do { let store = try WorkspaceStore(path: path); try store.execute("PRAGMA user_version=3") }
        #expect(throws: (any Error).self) { try WorkspaceStore(path: path) }
    }
    @Test func interruptedStatesAndLineageGuards() throws {
        let f = try HostCoreFixture(), store = try WorkspaceStore(path: f.directory.appendingPathComponent("w").path)
        for repo in ["r", "s"] {
            try store.execute("INSERT INTO repos (id,kind,path,display_name,badge_color,added_at,updated_at) VALUES (?,'git',?,?,'blue',1,1)", [.text(repo), .text("/" + repo), .text(repo)])
        }
        for (id, repo, state) in [("a","r","creating"), ("b","r","removing"), ("c","s","ready")] {
            try store.execute("INSERT INTO worktrees (id,instance_id,repo_id,path,origin,display_name,created_by,state,created_at,last_activity_at,updated_at) VALUES (?,?,?,?, 'smthz',?,'cli',?,1,1,1)", [.text(id), .text(id + "-instance"), .text(repo), .text("/" + id), .text(id), .text(state)])
        }
        try store.setLineage(child: "worktree:b", parent: "worktree:a", origin: "cli", captureSource: "cwd-context", confidence: "inferred")
        #expect(try store.query("SELECT parent_instance_id FROM lineage").first?["parent_instance_id"] == .text("a-instance"))
        #expect(throws: (any Error).self) { try store.setLineage(child: "worktree:a", parent: "worktree:b", origin: "cli", captureSource: "test", confidence: "explicit") }
        #expect(throws: (any Error).self) { try store.setLineage(child: "worktree:a", parent: "worktree:c", origin: "cli", captureSource: "test", confidence: "explicit") }
        try store.reconcileAfterRestart()
        let rows = try store.query("SELECT state,last_error FROM worktrees ORDER BY id")
        #expect(rows[0]["state"] == .text("failed")); #expect(rows[0]["last_error"] == .text("hostRestarted"))
        #expect(rows[1]["state"] == .text("remove_failed")); #expect(rows[2]["state"] == .text("ready"))
        #expect(throws: (any Error).self) { try store.execute("DELETE FROM repos WHERE id='r'") }
    }

    @Test func canonicalPathsResolveSymlinksAndRejectRelative() throws {
        let f = try HostCoreFixture(), link = f.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.directory)
        #expect(try WorkspaceStore.canonicalPath(link.path) == WorkspaceStore.canonicalPath(f.directory.path))
        #expect(throws: HostRPCError("invalidPath")) { try WorkspaceStore.canonicalPath("relative") }
    }
}
