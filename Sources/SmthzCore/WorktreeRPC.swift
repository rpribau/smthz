import Foundation

public enum WorktreeRPC {
    public static func register(on router: HostRouter, store: WorkspaceStore, sessions: SessionManager? = nil) {
        for repo in (try? store.repoRows()) ?? [] {
            if let id = repo["id"]?.string { try? store.reconcileWorktrees(repoID: id, afterRestart: true) }
        }
        router.register("worktree.list", methodClass: .read) { p, _ in
            let repos = try store.repoRows().filter { p["repoId"] == nil || $0["id"]?.string == p["repoId"]?.string }
            for repo in repos { try store.reconcileWorktrees(repoID: repo["id"]!.string!) }
            let rows = try store.worktreeRows(repoID: p["repoId"]?.string).filter {
                (p["includeArchived"] == .bool(true) || $0["is_archived"]?.integer != 1) &&
                (p["includeHidden"] == .bool(true) || $0["is_visible"]?.integer != 0)
            }
            return ["worktrees": .array(try rows.prefix(limit(p)).map { try store.worktreeJSON($0) }),
                "folderWorkspaces": .array(try store.folderRows(projectGroupID: nil).map(WorkspaceRowJSON.folder))]
        }
        router.register("worktree.resolve", methodClass: .read) { p, _ in
            guard let selector = p["selector"]?.string else { throw HostRPCError("badRequest") }
            let candidates = try store.worktreeRows().map { row in
                WorkspaceSelectorCandidate(id: row["id"]!.string!, path: row["path"]!.string!, name: row["display_name"]!.string!, branch: row["branch"]?.string, repoID: row["repo_id"]!.string!)
            }
            let selected = try WorkspaceSelectors.resolve(selector, candidates: candidates, cwd: p["cwd"]?.string)
            return ["worktree": WorkspaceRowJSON.worktree(try store.worktreeRow(selected.id))]
        }
        router.register("worktree.show", methodClass: .read) { p, _ in
            let row = try store.worktreeRow(try required(p, "id")), id = row["id"]!.string!
            let path = row["path"]!.string!, git = GitService()
            let status = try git.worktreeGit(["status", "--porcelain"], at: path)
            let head = try git.worktreeGit(["rev-parse", "HEAD"], at: path, allowFailure: true)
            let parent = try store.query("SELECT parent_key FROM lineage WHERE child_key=?", [.text("worktree:" + id)]).first?["parent_key"]?.string
            let children = try store.query("SELECT child_key FROM lineage WHERE parent_key=?", [.text("worktree:" + id)]).compactMap { $0["child_key"]?.string }
            var info: [String: HostJSON] = ["clean": .bool(status.stdout.isEmpty), "head": .string(head.stdout.trimmingCharacters(in: .newlines))]
            info["branch"] = row["branch"]?.string.map(HostJSON.string)
            let counts = try git.worktreeGit(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], at: path, allowFailure: true)
            let nums = counts.stdout.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
            if counts.code == 0, nums.count == 2 { info["ahead"] = .number(nums[0]); info["behind"] = .number(nums[1]) }
            return ["worktree": WorkspaceRowJSON.worktree(row), "lineage": .object(["parent": parent.map(HostJSON.string) ?? .null, "children": .array(children.map(HostJSON.string))]), "git": .object(info)]
        }
        router.register("worktree.suggestName", methodClass: .read) { p, _ in
            let id = try required(p, "repoId"); _ = try store.repoRow(id)
            let used = try store.worktreeRows(repoID: id).compactMap { $0["path"]?.string.map { URL(fileURLWithPath: $0).lastPathComponent } } + store.query("SELECT name FROM retired_names WHERE repo_id=?", [.text(id)]).compactMap { $0["name"]?.string }
            return ["name": .string(CreatureNames.suggest(used: used))]
        }
        router.register("worktree.create", methodClass: .job) { p, _ in
            let repo = try WorktreeCreator.validate(store: store, params: p), id = WorkspaceStore.newID()
            let launch = WorktreeJobLaunch()
            let job = try router.jobs.submit(repository: repo["id"]?.string) { context in
                try WorktreeCreator.create(store: store, id: id, params: p, sessions: sessions, context: context, jobID: launch.wait())
            }
            launch.release(job)
            return ["jobId": .string(job), "worktreeId": .string(id)]
        }
        router.register("worktree.prefetchBase", methodClass: .job) { p, _ in
            let repo = try store.repoRow(try required(p, "repoId")), ref = try required(p, "ref")
            let parts = ref.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts.contains(where: { $0.hasPrefix("-") }) else { throw HostRPCError("invalidRef") }
            let job = try router.jobs.submit(repository: repo["id"]?.string) { context in
                context.event("phase", "fetch")
                _ = try GitService().worktreeGit(["fetch", "--", parts[0], parts[1]], at: repo["path"]!.string!, context: context)
                return .object([:])
            }
            return ["jobId": .string(job)]
        }
        router.register("worktree.remove", methodClass: .job) { p, _ in
            let id = try required(p, "id"), row = try store.worktreeRow(id)
            guard row["is_main"]?.integer != 1 else { throw HostRPCError("badRequest") }
            let job = try router.jobs.submit(repository: row["repo_id"]?.string) { context in
                try WorktreeRemover.remove(store: store, id: id, params: p, sessions: sessions, context: context)
            }
            return ["jobId": .string(job)]
        }
        router.register("worktree.set", methodClass: .mutation, repository: { p in
            try store.worktreeRow(required(p, "id"))["repo_id"]?.string
        }) { p, request in
            let id = try required(p, "id"), row = try store.worktreeRow(id)
            var values: [String: WorkspaceSQLValue] = [:]
            for (key, column) in ["displayName": "display_name", "comment": "comment", "workspaceStatus": "workspace_status"] {
                if let value = p[key] {
                    if value == .null { values[column] = .null }
                    else if let string = value.string, string.utf8.count <= 65_536 { values[column] = .text(string) }
                    else { throw HostRPCError("badRequest") }
                }
            }
            for (key, column) in ["unread": "is_unread", "pinned": "is_pinned", "archived": "is_archived", "visible": "is_visible"] {
                if let value = p[key] { guard case .bool(let b) = value else { throw HostRPCError("badRequest") }; values[column] = .integer(b ? 1 : 0) }
            }
            for (key, column) in ["sortOrder": "sort_order", "manualOrder": "manual_order"] {
                if let n = p[key]?.number { guard let i = Int64(exactly: n) else { throw HostRPCError("badRequest") }; values[column] = .integer(i) }
            }
            if p["archived"] == .bool(true), row["is_archived"]?.integer != 1, p["runHooks"] != .bool(false) {
                _ = try SetupRunner.archive(store: store, repo: store.repoRow(row["repo_id"]!.string!), path: row["path"]!.string!, sessions: sessions, allowFailure: p["allowFailedArchiveHook"] == .bool(true), cancellation: request.cancellationError)
            }
            if let parent = p["parentId"]?.string {
                try store.setLineage(child: "worktree:" + id, parent: parent.contains(":") ? parent : "worktree:" + parent, origin: "cli", captureSource: "explicit", confidence: "explicit")
            } else if p["noParent"] == .bool(true) || p["parentId"] == .null {
                try store.execute("DELETE FROM lineage WHERE child_key=?", [.text("worktree:" + id)])
            }
            try store.updateRow(table: "worktrees", id: id, values: values)
            if row["origin"]?.string == "external", p["visible"] != nil {
                try store.execute("INSERT OR REPLACE INTO host_settings (key,value_json,updated_at) VALUES (?,'true',?)", [.text("externalVisibility:" + id), .real(Date().timeIntervalSince1970)])
            }
            if let reveal = p["revealRequested"] {
                guard case .bool(let enabled) = reveal else { throw HostRPCError("badRequest") }
                if enabled { try store.execute("INSERT OR REPLACE INTO host_settings (key,value_json,updated_at) VALUES (?,'true',?)", [.text("revealRequested:" + id), .real(Date().timeIntervalSince1970)]) }
                else { try store.execute("DELETE FROM host_settings WHERE key=?", [.text("revealRequested:" + id)]) }
            }
            return ["worktree": try store.worktreeJSON(store.worktreeRow(id))]
        }
        router.register("worktree.import", methodClass: .mutation) { p, _ in
            let path = try WorkspaceStore.canonicalPath(required(p, "path"))
            for repo in try store.repoRows() { try store.reconcileWorktrees(repoID: repo["id"]!.string!) }
            guard let row = try store.query("SELECT * FROM worktrees WHERE path=?", [.text(path)]).first else { throw HostRPCError("notFound") }
            try store.updateRow(table: "worktrees", id: row["id"]!.string!, values: ["is_visible": .integer(1)])
            try store.execute("INSERT OR REPLACE INTO host_settings (key,value_json,updated_at) VALUES (?,'true',?)", [.text("externalVisibility:" + row["id"]!.string!), .real(Date().timeIntervalSince1970)])
            return ["worktree": WorkspaceRowJSON.worktree(try store.worktreeRow(row["id"]!.string!))]
        }
        router.register("worktree.ps", methodClass: .read) { p, _ in
            let rows = try store.worktreeRows().prefix(limit(p)).map { row -> HostJSON in
                let current = sessions?.list().filter { $0.cwd.map { WorkspaceSelectors.contains(root: row["path"]!.string!, path: $0) } == true } ?? []
                return .object(["worktreeId": .string(row["id"]!.string!), "displayName": .string(row["display_name"]!.string!),
                    "branch": row["branch"]?.string.map(HostJSON.string) ?? .null,
                    "sessions": .number(Double(current.count)), "runningSessions": .number(Double(current.filter(\.running).count)),
                    "lastActivityAt": WorkspaceRowJSON.worktree(row).object?["lastActivityAt"] ?? .null, "unread": .bool(row["is_unread"]?.integer == 1)])
            }
            return ["rows": .array(rows)]
        }
        router.register("worktree.approveHooks", methodClass: .mutation) { p, _ in
            let id = try required(p, "repoId"), kind = try required(p, "kind"), hash = try required(p, "contentHash")
            _ = try store.repoRow(id)
            guard ["setup", "archive", "defaultTabs", "issueCommand"].contains(kind), hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw HostRPCError("badRequest") }
            try store.execute("INSERT OR REPLACE INTO hook_trust (repo_id,kind,content_hash,approved_at) VALUES (?,?,?,?)", [.text(id), .text(kind), .text(hash), .real(Date().timeIntervalSince1970)])
            return [:]
        }
        router.register("worktree.preservedBranches", methodClass: .read) { p, _ in
            let rows = try store.query("SELECT * FROM preserved_branches" + (p["repoId"] == nil ? "" : " WHERE repo_id=?"), p["repoId"]?.string.map { [.text($0)] } ?? [])
            return ["branches": .array(rows.map { WorkspaceRowJSON.object($0) })]
        }
        router.register("worktree.deletePreservedBranch", methodClass: .mutation) { p, _ in
            let id = try required(p, "repoId"), branch = try required(p, "branch"), repo = try store.repoRow(id)
            guard !(try store.query("SELECT branch FROM preserved_branches WHERE repo_id=? AND branch=?", [.text(id), .text(branch)]).isEmpty) else { throw HostRPCError("notFound") }
            _ = try GitService().worktreeGit(["branch", "-D", "--", branch], at: repo["path"]!.string!)
            try store.execute("DELETE FROM preserved_branches WHERE repo_id=? AND branch=?", [.text(id), .text(branch)])
            return [:]
        }
    }
    static func required(_ p: [String: HostJSON], _ key: String) throws -> String {
        guard let value = p[key]?.string, !value.isEmpty, !value.utf8.contains(0) else { throw HostRPCError("badRequest", detail: key + " is required") }; return value
    }
    static func limit(_ p: [String: HostJSON]) throws -> Int {
        guard let n = Int(exactly: p["limit"]?.number ?? 500), n > 0, n <= 500 else { throw HostRPCError("badRequest") }; return n
    }
}

private final class WorktreeJobLaunch: @unchecked Sendable {
    private let condition = NSCondition()
    private var id: String?
    func release(_ value: String) { condition.lock(); id = value; condition.broadcast(); condition.unlock() }
    func wait() -> String {
        condition.lock(); defer { condition.unlock() }
        while id == nil { condition.wait() }
        return id!
    }
}
