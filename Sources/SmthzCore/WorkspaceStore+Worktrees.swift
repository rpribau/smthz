import Foundation

public extension WorkspaceStore {
    func worktreeJSON(_ row: [String: WorkspaceSQLValue]) throws -> HostJSON {
        var value = WorkspaceRowJSON.worktree(row).object ?? [:]
        if let id = row["id"]?.string {
            value["revealRequested"] = .bool(!(try query("SELECT key FROM host_settings WHERE key=?", [.text("revealRequested:" + id)])).isEmpty)
        }
        return .object(value)
    }
    func worktreeRow(_ id: String) throws -> [String: WorkspaceSQLValue] {
        guard let row = try query("SELECT * FROM worktrees WHERE id=?", [.text(id)]).first else { throw HostRPCError("notFound") }
        return row
    }
    func deleteWorktreeRow(_ id: String) throws {
        try transaction {
            let key = "worktree:" + id
            try execute("DELETE FROM lineage WHERE child_key=? OR parent_key=?", [.text(key), .text(key)])
            try execute("DELETE FROM cleanup_dismissals WHERE worktree_id=?", [.text(id)])
            try execute("DELETE FROM worktrees WHERE id=?", [.text(id)])
            try execute("DELETE FROM host_settings WHERE key=?", [.text("externalVisibility:" + id)])
            try execute("DELETE FROM host_settings WHERE key=?", [.text("revealRequested:" + id)])
        }
    }
    func insertWorktree(id: String = WorkspaceStore.newID(), repoID: String, path: String,
                        branch: String?, name: String, origin: String = "smthz", state: String = "creating",
                        visible: Bool = true) throws -> String {
        let now = Date().timeIntervalSince1970
        try execute("INSERT INTO worktrees (id,instance_id,repo_id,path,origin,branch,display_name,is_visible,created_by,state,created_at,last_activity_at,updated_at) VALUES (?,?,?,?,?,?,?,?,'cli',?,?,?,?)", [
            .text(id), .text(Self.newID()), .text(repoID), .text(path), .text(origin), branch.map(WorkspaceSQLValue.text) ?? .null,
            .text(name), .integer(visible ? 1 : 0), .text(state), .real(now), .real(now), .real(now)])
        return id
    }
    /// Git is authoritative for external checkouts; pending/failed jobs keep their evidence.
    func reconcileWorktrees(repoID: String, afterRestart: Bool = false) throws {
        let repo = try repoRow(repoID)
        guard repo["kind"]?.string == "git", let root = repo["path"]?.string,
              FileManager.default.fileExists(atPath: root) else { return }
        let output = try GitService().worktreeGit(["worktree", "list", "--porcelain", "-z"], at: root).stdout
        var paths: Set<String> = []
        for record in output.components(separatedBy: "\0\0") {
            let fields = record.components(separatedBy: "\0")
            guard let raw = fields.first(where: { $0.hasPrefix("worktree ") }) else { continue }
            let path = String(raw.dropFirst(9))
            guard let canonical = try? Self.canonicalPath(path) else { continue }
            paths.insert(canonical)
            let branch = fields.first(where: { $0.hasPrefix("branch refs/heads/") }).map { String($0.dropFirst(18)) }
            if let row = try query("SELECT id,state,origin FROM worktrees WHERE path=?", [.text(canonical)]).first {
                if row["state"]?.string == "ready" {
                    let id = row["id"]!.string!
                    var values: [String: WorkspaceSQLValue] = ["branch": branch.map(WorkspaceSQLValue.text) ?? .null]
                    if row["origin"]?.string == "external", try query("SELECT key FROM host_settings WHERE key=?", [.text("externalVisibility:" + id)]).isEmpty {
                        values["is_visible"] = .integer(repo["external_worktree_visibility"]?.string == "show" ? 1 : 0)
                    }
                    try updateRow(table: "worktrees", id: id, values: values)
                }
            } else {
                _ = try insertWorktree(repoID: repoID, path: canonical, branch: branch,
                    name: URL(fileURLWithPath: canonical).lastPathComponent, origin: "external", state: "ready",
                    visible: repo["external_worktree_visibility"]?.string == "show")
            }
        }
        for row in try worktreeRows(repoID: repoID) where row["is_main"]?.integer != 1 {
            guard let path = row["path"]?.string, let id = row["id"]?.string else { continue }
            let state = row["state"]?.string
            if afterRestart && (state == "removing" || (state == "remove_failed" && row["last_error"]?.string == "hostRestarted")) {
                if !paths.contains(path), !FileManager.default.fileExists(atPath: path) {
                    try WorktreeRemover.finishBranch(store: self, row: row, repo: repo, delete: true)
                    try deleteWorktreeRow(id)
                } else { try updateRow(table: "worktrees", id: id, values: ["state": .text("remove_failed"), "last_error": .text("hostRestarted")]) }
            } else if afterRestart && state == "creating" {
                try updateRow(table: "worktrees", id: id, values: ["state": .text("failed"), "last_error": .text("hostRestarted")])
            } else if state == "ready", !paths.contains(path), !FileManager.default.fileExists(atPath: path) {
                try deleteWorktreeRow(id)
            }
        }
    }
}
