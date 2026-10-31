import Foundation

public enum WorktreeRemover {
    @discardableResult static func finishBranch(store: WorkspaceStore, row: [String: WorkspaceSQLValue],
                                               repo: [String: WorkspaceSQLValue], delete: Bool) throws -> String? {
        guard let branch = row["branch"]?.string else { return nil }
        let root = repo["path"]!.string!, git = GitService()
        if delete, row["preserve_branch_on_delete"]?.integer != 1 {
            if try git.worktreeGit(["branch", "-d", "--", branch], at: root, allowFailure: true).code == 0 { return nil }
            // A squash-merged branch may lack ancestry but have no unique tree change.
            if let base = row["base_ref"]?.string {
                let merge = try git.worktreeGit(["merge-base", base, branch], at: root, allowFailure: true)
                if merge.code == 0 {
                    let head = try git.worktreeGit(["rev-parse", "--verify", branch], at: root).stdout.trimmingCharacters(in: .newlines)
                    let tree = try git.worktreeGit(["merge-tree", "--write-tree", base, branch], at: root, allowFailure: true)
                    let baseTree = try git.worktreeGit(["rev-parse", base + "^{tree}"], at: root, allowFailure: true)
                    if tree.code == 0, tree.stdout.trimmingCharacters(in: .newlines) == baseTree.stdout.trimmingCharacters(in: .newlines), !head.isEmpty {
                        _ = try git.worktreeGit(["branch", "-D", "--", branch], at: root)
                        return nil
                    }
                }
            }
        }
        let head = try git.worktreeGit(["rev-parse", "--verify", "refs/heads/" + branch], at: root, allowFailure: true)
        guard head.code == 0 else { return nil }
        try store.execute("INSERT OR REPLACE INTO preserved_branches (repo_id,branch,head,former_path,preserved_at) VALUES (?,?,?,?,?)", [
            .text(repo["id"]!.string!), .text(branch), .text(head.stdout.trimmingCharacters(in: .newlines)), .text(row["path"]!.string!), .real(Date().timeIntervalSince1970)])
        return branch
    }
    static func remove(store: WorkspaceStore, id: String, params: [String: HostJSON],
                       sessions: SessionManager?, context: HostJobContext) throws -> HostJSON {
        let row = try store.worktreeRow(id), repo = try store.repoRow(row["repo_id"]!.string!)
        guard row["is_main"]?.integer != 1 else { throw HostRPCError("badRequest", detail: "cannot remove main worktree") }
        let path = row["path"]!.string!, root = repo["path"]!.string!, git = GitService()
        let listing = try git.worktreeGit(["worktree", "list", "--porcelain", "-z"], at: root, context: context).stdout
        if listing.components(separatedBy: "\0\0").contains(where: { $0.hasPrefix("worktree " + path + "\0") && $0.components(separatedBy: "\0").contains(where: { $0 == "locked" || $0.hasPrefix("locked ") }) }) { throw HostRPCError("worktreeLocked") }
        if FileManager.default.fileExists(atPath: path), params["force"] != .bool(true),
           !(try git.worktreeGit(["status", "--porcelain"], at: path, context: context).stdout.isEmpty) { throw HostRPCError("worktreeDirty") }
        var removing: [String: WorkspaceSQLValue] = ["state": .text("removing")]
        if params["deleteBranch"] == .bool(false) { removing["preserve_branch_on_delete"] = .integer(1) }
        try store.updateRow(table: "worktrees", id: id, values: removing)
        do {
            context.event("phase", "archive")
            let override = params["runHooks"] == .bool(false) ? false : try SetupRunner.archive(store: store, repo: repo, path: path, sessions: sessions,
                allowFailure: params["allowFailedArchiveHook"] == .bool(true), context: context)
            try context.checkCancellation()
            context.event("phase", "closeSessions")
            if params["closeSessions"] != .bool(false), let sessions {
                for s in sessions.list() where s.cwd.map({ WorkspaceSelectors.contains(root: path, path: $0) }) == true { try sessions.close(id: s.id) }
            }
            context.event("phase", "remove")
            if FileManager.default.fileExists(atPath: path) {
                _ = try git.worktreeGit(["worktree", "remove"] + (params["force"] == .bool(true) ? ["--force"] : []) + ["--", path], at: root, context: context)
            }
            context.event("phase", "branch")
            let preserved = try finishBranch(store: store, row: row, repo: repo, delete: params["deleteBranch"] != .bool(false))
            try store.deleteWorktreeRow(id)
            return .object(["preservedBranch": preserved.map(HostJSON.string) ?? .null, "archiveHookOverride": .bool(override)])
        } catch {
            try? store.updateRow(table: "worktrees", id: id, values: ["state": .text("remove_failed"), "last_error": .text((error as? HostRPCError)?.code ?? "gitFailed")])
            throw error
        }
    }
}
