import Foundation

/// `worktree.cleanupScan` (job) and `worktree.cleanupDismiss` (mutation), WP-M4-CLEANUP.
/// The scan only reads: evidence per worktree row, then `WorkspaceCleanup.classify`.
/// Removal stays with `worktree.remove` jobs, issued by the client one row at a time.
public enum CleanupRPC {
    public static func register(on router: HostRouter, store: WorkspaceStore, sessions: SessionManager? = nil) {
        router.register("worktree.cleanupScan", methodClass: .job, repository: { _ in nil }) { p, _ in
            var targets: [String]?
            if let value = p["worktreeIds"] {
                guard case .array(let items) = value else { throw HostRPCError("badRequest") }
                let ids = try items.map { item -> String in
                    guard let id = item.string, !id.isEmpty else { throw HostRPCError("badRequest") }; return id
                }
                do { targets = try WorkspaceCleanup.validateTargets(ids) }
                catch { throw HostRPCError("badRequest", detail: "at most \(WorkspaceCleanup.targetBatchLimit) worktree ids per scan") }
            }
            let active = p["activeWorktreeId"]?.string, scanTargets = targets
            let includeHidden = p["includeHidden"] == .bool(true), includeSize = p["includeSize"] != .bool(false)
            let job = try router.jobs.submit { context in
                let result = try scan(store: store, sessions: sessions, targets: scanTargets, activeWorktreeID: active,
                                      includeHidden: includeHidden, includeSize: includeSize, context: context)
                return .object(result)
            }
            return ["jobId": .string(job)]
        }
        router.register("worktree.cleanupDismiss", methodClass: .mutation, repository: { _ in nil }) { p, _ in
            guard let id = p["worktreeId"]?.string, !id.isEmpty else { throw HostRPCError("badRequest", detail: "worktreeId is required") }
            _ = try store.worktreeRow(id)
            switch p["fingerprint"] {
            case .string(let print) where !print.isEmpty && print.utf8.count <= 256:
                try store.execute("INSERT OR REPLACE INTO cleanup_dismissals (worktree_id,fingerprint,classifier_version,dismissed_at) VALUES (?,?,?,?)", [
                    .text(id), .text(print), .integer(Int64(WorkspaceCleanup.classifierVersion)), .real(Date().timeIntervalSince1970)])
            case .null?:
                try store.execute("DELETE FROM cleanup_dismissals WHERE worktree_id=?", [.text(id)])
            default: throw HostRPCError("badRequest", detail: "fingerprint is required")
            }
            return [:]
        }
    }

    static func scan(store: WorkspaceStore, sessions: SessionManager?, targets: [String]?, activeWorktreeID: String?,
                     includeHidden: Bool, includeSize: Bool, context: HostJobContext,
                     now: Double = Date().timeIntervalSince1970) throws -> [String: HostJSON] {
        context.event("phase", "scan")
        var repos: [String: [String: WorkspaceSQLValue]] = [:]
        var errors: [HostJSON] = []
        for repo in try store.repoRows() {
            guard let id = repo["id"]?.string else { continue }
            repos[id] = repo
            do { try store.reconcileWorktrees(repoID: id) }
            catch { errors.append(.object(["repoId": .string(id), "repoName": .string(repo["display_name"]?.string ?? ""), "message": .string("\(error)")])) }
        }
        var rows = try store.worktreeRows().filter { $0["state"]?.string == "ready" }
        if let targets {
            let wanted = Set(targets); rows = rows.filter { wanted.contains($0["id"]?.string ?? "") }
        } else if !includeHidden {
            rows = rows.filter { $0["is_visible"]?.integer != 0 }
        }
        let dismissals = Dictionary(try store.query("SELECT * FROM cleanup_dismissals").compactMap { row -> (String, WorkspaceCleanup.Dismissal)? in
            guard let id = row["worktree_id"]?.string, let print = row["fingerprint"]?.string else { return nil }
            return (id, .init(fingerprint: print, classifierVersion: Int(row["classifier_version"]?.integer ?? 0)))
        }, uniquingKeysWith: { a, _ in a })
        let liveSessions = sessions?.list() ?? []
        var candidates: [HostJSON] = []
        for (index, row) in rows.enumerated() {
            try context.checkCancellation()
            guard let id = row["id"]?.string, let repoID = row["repo_id"]?.string, let repo = repos[repoID] else { continue }
            var evidence = try self.evidence(row: row, repo: repo, sessions: liveSessions, activeWorktreeID: activeWorktreeID,
                                             includeSize: includeSize, context: context, now: now)
            evidence.worktreeID = id
            let candidate = WorkspaceCleanup.classify(evidence, scannedAt: now, dismissal: dismissals[id])
            candidates.append(try JSONDecoder().decode(HostJSON.self, from: JSONEncoder().encode(candidate)))
            context.event("progress", evidence.displayName, done: index + 1, total: rows.count)
        }
        return ["scannedAt": .number(now), "candidates": .array(candidates), "errors": .array(errors),
                "classifierVersion": .number(Double(WorkspaceCleanup.classifierVersion))]
    }

    static func evidence(row: [String: WorkspaceSQLValue], repo: [String: WorkspaceSQLValue], sessions: [SessionInfo],
                         activeWorktreeID: String?, includeSize: Bool, context: HostJobContext,
                         now: Double) throws -> WorkspaceCleanup.Evidence {
        func real(_ value: WorkspaceSQLValue?) -> Double {
            switch value { case .real(let v)?: return v; case .integer(let v)?: return Double(v); default: return 0 }
        }
        let path = row["path"]?.string ?? ""
        var evidence = WorkspaceCleanup.Evidence(
            worktreeID: row["id"]?.string ?? "", repoID: repo["id"]?.string ?? "", repoName: repo["display_name"]?.string ?? "",
            displayName: row["display_name"]?.string ?? "", branch: row["branch"]?.string ?? "", head: "", path: path)
        evidence.isMain = row["is_main"]?.integer == 1
        evidence.isFolderRepo = repo["kind"]?.string == "folder"
        evidence.isPinned = row["is_pinned"]?.integer == 1
        evidence.isArchived = row["is_archived"]?.integer == 1
        evidence.isActive = activeWorktreeID != nil && activeWorktreeID == row["id"]?.string
        let inside = sessions.filter { $0.cwd.map { WorkspaceSelectors.contains(root: path, path: $0) } == true }
        evidence.sessionCount = inside.count
        evidence.runningSessionCount = inside.filter(\.running).count
        evidence.createdAt = real(row["created_at"])
        evidence.lastActivityAt = ([real(row["last_activity_at"]), evidence.createdAt] + inside.compactMap(\.createdAt)).max() ?? 0
        if !evidence.isFolderRepo {
            let (git, head, branch) = try gitEvidence(path: path, context: context, now: now)
            evidence.git = git
            evidence.head = head
            if evidence.branch.isEmpty { evidence.branch = branch }
        }
        if includeSize, !evidence.isMain, FileManager.default.fileExists(atPath: path) {
            let size = WorkspaceCleanup.directorySize(path, maxEntries: 100_000, deadline: Date(timeIntervalSinceNow: 1))
            evidence.sizeBytes = size.bytes; evidence.sizeTruncated = size.truncated
        }
        return evidence
    }

    /// `git status --porcelain=v2 --branch`: entries, HEAD oid, upstream ahead/behind; then
    /// `rev-list --count HEAD --not --remotes` for a clean checkout with no upstream.
    static func gitEvidence(path: String, context: HostJobContext, now: Double)
        throws -> (WorkspaceCleanup.GitEvidence, head: String, branch: String) {
        guard FileManager.default.fileExists(atPath: path) else { return (.unreadable, "", "") }
        let git = GitService()
        let status: GitService.Output
        do { status = try git.worktreeGit(["status", "--porcelain=v2", "--branch", "--untracked-files=normal"], at: path, context: context, allowFailure: true) }
        catch let error as HostRPCError where error.code == "cancelled" { throw error }
        catch { return (.unreadable, "", "") }
        guard status.code == 0 else { return (.unreadable, "", "") }
        var head = "", branch = "", hasUpstream = false, ahead: Int?, behind: Int?, entries = 0
        for line in status.stdout.split(separator: "\n") {
            if line.hasPrefix("# branch.oid ") { head = String(line.dropFirst(13)) }
            else if line.hasPrefix("# branch.head ") { branch = String(line.dropFirst(14)) }
            else if line.hasPrefix("# branch.upstream ") { hasUpstream = true }
            else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst(12).split(separator: " ")
                if parts.count == 2 { ahead = Int(parts[0].dropFirst()); behind = Int(parts[1].dropFirst()) }
            } else if !line.hasPrefix("#") { entries += 1 }
        }
        if head == "(initial)" { head = "" }
        if branch == "(detached)" { branch = "" }
        var evidence = WorkspaceCleanup.GitEvidence(clean: entries == 0, checkedAt: now)
        if hasUpstream { evidence.upstreamAhead = ahead; evidence.upstreamBehind = behind }
        // An upstream that is gone has no ahead/behind line: treat it like no upstream.
        if evidence.clean == true, evidence.upstreamAhead == nil {
            let count = try git.worktreeGit(["rev-list", "--count", "HEAD", "--not", "--remotes"], at: path, context: context, allowFailure: true)
            if count.code == 0 { evidence.unpushedWithoutUpstream = Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return (evidence, head, branch)
    }
}
