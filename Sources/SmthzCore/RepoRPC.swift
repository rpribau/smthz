import Foundation

/// WP-M4-REGISTRY: `repo.*`, `projectGroup.*`, `folderWorkspace.*`, `hostSettings.*` (M4-PLAN §5.2).
/// Handlers are synchronous; Git work runs on a detached task while the router thread waits.
public enum RepoRPC {
    public static func register(on router: HostRouter, store: WorkspaceStore,
                                liveSessionCWDs: (@Sendable () -> [String])? = nil) {
        let git = GitService()
        let byID: HostRouter.RepoKey = { $0["id"]?.string }

        // MARK: repo.*
        router.register("repo.list", methodClass: .read) { _, _ in
            ["repos": .array(try store.repoRows().map(WorkspaceRowJSON.repo))]
        }
        router.register("repo.show", methodClass: .read) { p, _ in
            let row = try store.repoRow(try id(p))
            return ["repo": WorkspaceRowJSON.repo(row), "mainWorktreeId": row["main_worktree_id"]?.string.map(HostJSON.string) ?? .null]
        }
        router.register("repo.add", methodClass: .mutation, repository: { _ in nil }) { p, context in
            guard let path = p["path"]?.string else { throw HostRPCError("badRequest", detail: "path") }
            let kind = p["kind"]?.string ?? "auto"
            guard ["auto", "git", "folder"].contains(kind) else { throw HostRPCError("badRequest", detail: "kind") }
            let added = try addRepo(path: path, kind: kind, displayName: p["displayName"]?.string,
                                    groupID: p["projectGroupId"]?.string, store: store, git: git, context: context.processControl)
            return ["repo": WorkspaceRowJSON.repo(added.row), "alreadyKnown": .bool(added.alreadyKnown)]
        }
        router.register("repo.update", methodClass: .mutation, repository: byID) { p, context in
            let row = try store.repoRow(try id(p))
            let repoID = row["id"]!.string!
            var values: [String: WorkspaceSQLValue] = [:]
            func text(_ key: String, _ column: String, allowed: Set<String>? = nil, nullable: Bool = false) throws {
                guard let value = p[key] else { return }
                if value == .null, nullable { values[column] = .null; return }
                guard let string = value.string, allowed.map({ $0.contains(string) }) ?? true else { throw HostRPCError("badRequest", detail: key) }
                values[column] = .text(string)
            }
            if let name = p["displayName"] {
                guard let name = name.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { throw HostRPCError("invalidName") }
                values["display_name"] = .text(name)
            }
            if let color = p["badgeColor"] {
                guard let color = color.string, color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else { throw HostRPCError("badRequest", detail: "badgeColor") }
                values["badge_color"] = .text(color.lowercased())
            }
            if let ref = p["worktreeBaseRef"] {
                if ref == .null { values["worktree_base_ref"] = .null }
                else {
                    guard let ref = ref.string, !ref.isEmpty, !ref.hasPrefix("-") else { throw HostRPCError("invalidRef") }
                    guard row["kind"]?.string == "git" else { throw HostRPCError("notRepository") }
                    let out = try runGit(git, ["rev-parse", "--verify", "--quiet", ref + "^{commit}"], at: row["path"]!.string!,
                                         mode: .isolatedRead, control: context.processControl, allowFailure: true)
                    guard out.code == 0 else { throw HostRPCError("invalidRef", detail: ref) }
                    values["worktree_base_ref"] = .text(ref)
                }
            }
            if let base = p["worktreeBasePath"] {
                if base == .null { values["worktree_base_path"] = .null }
                else { values["worktree_base_path"] = .text(try WorkspaceStore.canonicalPath(base.string ?? "")) }
            }
            try text("setupRunPolicy", "setup_run_policy", allowed: ["ask", "run-by-default", "skip-by-default"])
            try text("setupAgentStartupPolicy", "setup_agent_startup_policy", allowed: ["start-immediately", "wait-for-setup"], nullable: true)
            try text("commandSourcePolicy", "command_source_policy", allowed: ["shared-only", "local-only", "run-both"], nullable: true)
            try text("localSetupScript", "local_setup_script")
            try text("localArchiveScript", "local_archive_script")
            if let visibility = p["externalWorktreeVisibility"] {
                switch visibility.string {
                case "show", "hide": values["external_worktree_visibility"] = .text(visibility.string!)
                case "inherit": values["external_worktree_visibility"] = .null
                default: guard visibility == .null else { throw HostRPCError("badRequest", detail: "externalWorktreeVisibility") }
                    values["external_worktree_visibility"] = .null
                }
            }
            if let shared = p["sharedPaths"] {
                guard case .array(let items) = shared, items.allSatisfy({ $0.string != nil }) else { throw HostRPCError("badRequest", detail: "sharedPaths") }
                values["shared_paths_json"] = .text(String(decoding: try JSONEncoder().encode(shared), as: UTF8.self))
            }
            try store.updateRow(table: "repos", id: repoID, values: values)
            if let name = values["display_name"] {
                try store.execute("UPDATE worktrees SET display_name=? WHERE repo_id=? AND is_main=1 AND display_name_pinned=0", [name, .text(repoID)])
            }
            return ["repo": WorkspaceRowJSON.repo(try store.repoRow(repoID))]
        }
        router.register("repo.remove", methodClass: .mutation, repository: byID) { p, _ in
            let repoID = try id(p)
            if p["force"] != .bool(true) { try refuseLiveSessions(roots: try store.repoRoots(repoID), provider: liveSessionCWDs) }
            try store.deleteRepo(repoID)
            return [:]
        }
        router.register("repo.reorder", methodClass: .mutation, repository: { _ in nil }) { p, _ in
            guard case .array(let ids) = p["ids"] ?? .null else { throw HostRPCError("badRequest", detail: "ids") }
            try store.reorderRepos(ids.compactMap { $0.string?.lowercased() }, projectGroupID: p["projectGroupId"]?.string)
            return [:]
        }
        router.register("repo.searchRefs", methodClass: .read) { p, context in
            let row = try store.repoRow(try id(p))
            guard row["kind"]?.string == "git" else { throw HostRPCError("notRepository") }
            let query = (p["query"]?.string ?? "").lowercased()
            let limit = max(1, min(50, Int(p["limit"]?.number ?? 20)))
            let out = try runGit(git, ["for-each-ref", "--sort=-committerdate",
                                       "--format=%(refname)%00%(objectname)%00%(committerdate:unix)",
                                       "refs/heads", "refs/remotes", "refs/tags"],
                                 at: row["path"]!.string!, mode: .isolatedRead, control: context.processControl)
            var refs: [HostJSON] = []
            for line in out.stdout.split(separator: "\n") where refs.count < limit {
                let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 3 else { continue }
                let (kind, name): (String, String)
                if fields[0].hasPrefix("refs/heads/") { kind = "local"; name = String(fields[0].dropFirst(11)) }
                else if fields[0].hasPrefix("refs/remotes/") { kind = "remote"; name = String(fields[0].dropFirst(13)) }
                else { kind = "tag"; name = String(fields[0].dropFirst(10)) }
                if kind == "remote", name.hasSuffix("/HEAD") { continue }
                guard query.isEmpty || name.lowercased().contains(query) else { continue }
                refs.append(.object(["name": .string(name), "kind": .string(kind), "commit": .string(fields[1]),
                                     "committedAt": .number(Double(fields[2]) ?? 0)]))
            }
            return ["refs": .array(refs)]
        }
        router.register("repo.baseRefDefault", methodClass: .read) { p, context in
            let row = try store.repoRow(try id(p))
            guard row["kind"]?.string == "git", let path = row["path"]?.string else { throw HostRPCError("notRepository") }
            func verify(_ ref: String) throws -> Bool {
                try runGit(git, ["rev-parse", "--verify", "--quiet", ref + "^{commit}"], at: path, mode: .isolatedRead,
                           control: context.processControl, allowFailure: true).code == 0
            }
            let remotes = try runGit(git, ["remote"], at: path, mode: .isolatedRead, control: context.processControl)
                .stdout.split(separator: "\n").count
            var ref: String?
            let head = try runGit(git, ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], at: path,
                                  mode: .isolatedRead, control: context.processControl, allowFailure: true)
            if head.code == 0 { ref = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
            if ref == nil { ref = try ["origin/main", "origin/master", "main", "master"].first(where: verify) }
            return ["ref": ref.map(HostJSON.string) ?? .null, "remoteCount": .number(Double(remotes))]
        }
        router.register("repo.gitUsername", methodClass: .read) { p, context in
            let row = try store.repoRow(try id(p))
            guard row["kind"]?.string == "git", let path = row["path"]?.string else { throw HostRPCError("notRepository") }
            for key in ["github.user", "user.username", "user.name"] {
                let out = try runGit(git, ["config", "--get", key], at: path, mode: .userContext,
                                     control: context.processControl, allowFailure: true)
                let value = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if out.code == 0, isBranchSafeLogin(value) { return ["username": .string(value)] }
            }
            return ["username": .null]
        }
        router.register("repo.scanNested", methodClass: .job, repository: { _ in nil }) { p, _ in
            guard let raw = p["path"]?.string else { throw HostRPCError("badRequest", detail: "path") }
            let path = try directory(raw)
            let scan = NestedRepoScan(maxDepth: p["maxDepth"]?.number, maxRepos: p["maxRepos"]?.number, timeoutMs: p["timeoutMs"]?.number)
            let jobID = try router.jobs.submit { job in
                job.event("phase", "scanning")
                let result = scan.scan(path, cancelled: { job.isCancelled }) { job.event("log", $0.path, done: nil, total: nil) }
                try job.checkCancellation()
                return result.json
            }
            return ["jobId": .string(jobID)]
        }
        router.register("repo.clone", methodClass: .job, repository: { _ in nil }) { p, _ in
            guard let url = p["url"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty, !url.hasPrefix("-")
            else { throw HostRPCError("badRequest", detail: "url") }
            let parent = try directory(p["destinationParent"]?.string ?? "")
            let name = p["name"]?.string ?? cloneName(url)
            guard isPlainName(name) else { throw HostRPCError("invalidName") }
            let destination = parent == "/" ? "/" + name : parent + "/" + name
            guard !FileManager.default.fileExists(atPath: destination) else { throw HostRPCError("alreadyExists", detail: destination) }
            guard ClonePaths.claim(destination) else { throw HostRPCError("repoBusy", detail: "a clone into this destination is running") }
            do {
                let jobID = try router.jobs.submit { job in
                    defer { ClonePaths.release(destination) }
                    job.event("phase", "cloning")
                    var created = false
                    do {
                        _ = try runGit(git, ["clone", "--progress", "--", url, destination], at: parent, mode: .userContext,
                                       control: job.processControl, stderr: { line in job.event("log", line) },
                                       progress: { job.event("progress", $0.phase, done: $0.done, total: $0.total) })
                        created = true
                        try job.checkCancellation()
                        job.event("phase", "registering")
                        let added = try addRepo(path: destination, kind: "git", displayName: nil, groupID: p["projectGroupId"]?.string,
                                                store: store, git: git, context: job.processControl)
                        return .object(["repo": WorkspaceRowJSON.repo(added.row)])
                    } catch {
                        // Only the directory this job created is removed; never a pre-existing path.
                        if !created || job.isCancelled { try? FileManager.default.removeItem(atPath: destination) }
                        throw error
                    }
                }
                return ["jobId": .string(jobID)]
            } catch { ClonePaths.release(destination); throw error }
        }
        router.register("repo.create", methodClass: .mutation, repository: { _ in nil }) { p, context in
            let parent = try directory(p["parentPath"]?.string ?? "")
            guard let name = p["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), isPlainName(name) else { throw HostRPCError("invalidName") }
            let path = parent == "/" ? "/" + name : parent + "/" + name
            guard !FileManager.default.fileExists(atPath: path) else { throw HostRPCError("alreadyExists", detail: path) }
            do { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false) }
            catch { throw HostRPCError("invalidPath", detail: error.localizedDescription) }
            let initGit = p["initGit"] != .bool(false)
            do {
                if initGit { _ = try runGit(git, ["init", "--quiet"], at: path, mode: .userContext, control: context.processControl) }
                let added = try addRepo(path: path, kind: initGit ? "git" : "folder", displayName: nil,
                                        groupID: p["projectGroupId"]?.string, store: store, git: git, context: context.processControl)
                return ["repo": WorkspaceRowJSON.repo(added.row)]
            } catch { try? FileManager.default.removeItem(atPath: path); throw error }
        }

        // MARK: projectGroup.*
        router.register("projectGroup.list", methodClass: .read) { _, _ in
            ["groups": .array(try store.groupRows().map(WorkspaceRowJSON.group))]
        }
        router.register("projectGroup.create", methodClass: .mutation, repository: { _ in nil }) { p, _ in
            guard let name = p["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { throw HostRPCError("invalidName") }
            let parentPath = try p["parentPath"]?.string.map(directory)
            let row = try store.insertGroup(name: name, color: try color(p["color"]), parentPath: parentPath,
                                            parentGroupID: p["parentGroupId"]?.string, createdFrom: "manual")
            return ["group": WorkspaceRowJSON.group(row)]
        }
        router.register("projectGroup.update", methodClass: .mutation, repository: { _ in nil }) { p, _ in
            let groupID = try id(p)
            var values: [String: WorkspaceSQLValue] = [:]
            if let name = p["name"] {
                guard let name = name.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { throw HostRPCError("invalidName") }
                values["name"] = .text(name)
            }
            if p["color"] != nil { values["color"] = try color(p["color"]).map(WorkspaceSQLValue.text) ?? .null }
            if let collapsed = p["isCollapsed"] {
                guard case .bool(let flag) = collapsed else { throw HostRPCError("badRequest", detail: "isCollapsed") }
                values["is_collapsed"] = .integer(flag ? 1 : 0)
            }
            if let order = p["tabOrder"]?.number { values["tab_order"] = .integer(Int64(order)) }
            try store.updateRow(table: "project_groups", id: groupID, values: values)
            return ["group": WorkspaceRowJSON.group(try store.groupRow(groupID))]
        }
        router.register("projectGroup.delete", methodClass: .mutation, repository: { _ in nil }) { p, _ in
            let groupID = try id(p)
            _ = try store.groupRow(groupID)
            if p["removeProjects"] == .bool(true) {
                let repos = try store.query("SELECT id FROM repos WHERE project_group_id=?", [.text(groupID)]).compactMap { $0["id"]?.string }
                if p["force"] != .bool(true) {
                    try refuseLiveSessions(roots: try repos.flatMap(store.repoRoots), provider: liveSessionCWDs)
                }
                for repo in repos { try store.deleteRepo(repo) }
            }
            try store.deleteGroup(groupID)
            return [:]
        }
        router.register("projectGroup.moveProject", methodClass: .mutation, repository: { $0["repoId"]?.string }) { p, _ in
            guard let repoID = p["repoId"]?.string?.lowercased() else { throw HostRPCError("badRequest", detail: "repoId") }
            try store.moveRepo(repoID, toGroup: p["groupId"]?.string?.lowercased(), index: p["index"]?.number.map { Int(max(0, min($0, 1e9))) } ?? .max)
            return ["repo": WorkspaceRowJSON.repo(try store.repoRow(repoID))]
        }
        router.register("projectGroup.importNested", methodClass: .mutation, repository: { _ in nil }) { p, context in
            let parent = try directory(p["parentPath"]?.string ?? "")
            guard let mode = p["mode"]?.string, ["group", "separate"].contains(mode),
                  case .array(let paths) = p["paths"] ?? .null, !paths.isEmpty else { throw HostRPCError("badRequest") }
            var group: [String: WorkspaceSQLValue]?
            if mode == "group" {
                group = try store.insertGroup(name: p["groupName"]?.string ?? (parent as NSString).lastPathComponent,
                                              color: nil, parentPath: parent, parentGroupID: nil, createdFrom: "folder-scan")
            }
            var projects: [HostJSON] = []
            for item in paths {
                guard let raw = item.string else { continue }
                var entry: [String: HostJSON] = ["path": .string(raw)]
                do {
                    let canonical = try WorkspaceStore.canonicalPath(raw)
                    guard WorkspaceSelectors.contains(root: parent, path: canonical) else { throw HostRPCError("pathOutsideRoot") }
                    let added = try addRepo(path: canonical, kind: "auto", displayName: nil, groupID: group?["id"]?.string,
                                            store: store, git: git, context: context.processControl)
                    if added.alreadyKnown, let groupID = group?["id"]?.string, let repoID = added.row["id"]?.string {
                        try store.moveRepo(repoID, toGroup: groupID, index: .max)
                    }
                    entry["repoId"] = added.row["id"]?.string.map(HostJSON.string)
                    entry["status"] = .string(added.alreadyKnown ? "already-known" : "imported")
                } catch {
                    entry["status"] = .string("failed")
                    entry["error"] = .string((error as? HostRPCError)?.code ?? String(describing: error))
                }
                projects.append(.object(entry))
            }
            return ["group": group.map(WorkspaceRowJSON.group) ?? .null, "projects": .array(projects)]
        }

        // MARK: folderWorkspace.*
        router.register("folderWorkspace.list", methodClass: .read) { p, _ in
            ["folderWorkspaces": .array(try store.folderRows(projectGroupID: p["projectGroupId"]?.string).map(WorkspaceRowJSON.folder))]
        }
        router.register("folderWorkspace.create", methodClass: .mutation, repository: { _ in nil }) { p, _ in
            guard let groupID = p["projectGroupId"]?.string?.lowercased() else { throw HostRPCError("badRequest", detail: "projectGroupId") }
            guard let name = p["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { throw HostRPCError("invalidName") }
            let group = try store.groupRow(groupID)
            guard let folder = p["folderPath"]?.string ?? group["parent_path"]?.string else {
                throw HostRPCError("badRequest", detail: "the project group has no folder; pass folderPath")
            }
            let row = try store.insertFolder(groupID: groupID, name: name, folderPath: try directory(folder),
                                             sourceRepoID: p["sourceRepoId"]?.string?.lowercased(), comment: p["comment"]?.string ?? "")
            return ["folderWorkspace": WorkspaceRowJSON.folder(row)]
        }
        router.register("folderWorkspace.update", methodClass: .mutation, repository: { _ in nil }) { p, _ in
            let folderID = try id(p)
            var values: [String: WorkspaceSQLValue] = [:]
            if let name = p["name"] {
                guard let name = name.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { throw HostRPCError("invalidName") }
                values["name"] = .text(name)
            }
            if let comment = p["comment"]?.string { values["comment"] = .text(comment) }
            if let status = p["workspaceStatus"] { values["workspace_status"] = status.string.map(WorkspaceSQLValue.text) ?? .null }
            for (key, column) in [("pinned", "is_pinned"), ("unread", "is_unread"), ("archived", "is_archived")] {
                guard let value = p[key] else { continue }
                guard case .bool(let flag) = value else { throw HostRPCError("badRequest", detail: key) }
                values[column] = .integer(flag ? 1 : 0)
            }
            if let order = p["sortOrder"]?.number { values["sort_order"] = .integer(Int64(order)) }
            try store.updateRow(table: "folder_workspaces", id: folderID, values: values)
            return ["folderWorkspace": WorkspaceRowJSON.folder(try store.folderRow(folderID))]
        }
        router.register("folderWorkspace.delete", methodClass: .mutation, repository: { _ in nil }) { p, _ in
            try store.deleteFolder(try id(p))
            return [:]
        }

        // MARK: hostSettings.*
        router.register("hostSettings.get", methodClass: .read) { p, _ in
            var keys: [String]?
            if case .array(let items) = p["keys"] ?? .null { keys = items.compactMap(\.string) }
            return ["values": .object(try store.hostSettings(keys: keys))]
        }
        router.register("hostSettings.set", methodClass: .mutation, repository: { _ in nil }) { p, _ in
            guard let values = p["values"]?.object, !values.isEmpty else { throw HostRPCError("badRequest", detail: "values") }
            var checked: [String: HostJSON] = [:]
            for (key, value) in values {
                switch (key, value) {
                case ("workspaceDir", .string(let path)):
                    let expanded = NSString(string: path).expandingTildeInPath
                    guard expanded.hasPrefix("/"), !expanded.utf8.contains(0) else { throw HostRPCError("invalidPath") }
                    checked[key] = .string(expanded)
                case ("nestWorkspaces", .bool), ("refreshLocalBaseRefOnCreate", .bool), ("branchPrefixCustom", .string): checked[key] = value
                case ("branchPrefix", .string(let mode)) where ["git-username", "custom", "none"].contains(mode): checked[key] = value
                case ("defaultSetupRunPolicy", .string(let mode)) where ["ask", "run-by-default", "skip-by-default"].contains(mode): checked[key] = value
                default: throw HostRPCError("badRequest", detail: "invalid setting \(key)")
                }
            }
            try store.setHostSettings(checked)
            return ["values": .object(try store.hostSettings())]
        }
    }

    // MARK: Helpers

    static func id(_ p: [String: HostJSON]) throws -> String {
        guard let id = p["id"]?.string, !id.isEmpty else { throw HostRPCError("badRequest", detail: "id") }
        return id.lowercased()
    }
    static func directory(_ raw: String) throws -> String {
        let path = try WorkspaceStore.canonicalPath(raw)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HostRPCError("invalidPath", detail: "not a directory")
        }
        return path
    }
    static func color(_ value: HostJSON?) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let color = value.string, color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
            throw HostRPCError("badRequest", detail: "color")
        }
        return color.lowercased()
    }
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0) && name.utf8.count <= 255
    }
    static func cloneName(_ url: String) -> String {
        var last = url.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? "repository"
        if last.hasSuffix(".git") { last.removeLast(4) }
        return last.isEmpty ? "repository" : last
    }
    static func isBranchSafeLogin(_ value: String) -> Bool {
        value.count <= 255 && value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
            && !value.contains("..") && !value.hasSuffix(".") && !value.hasSuffix(".lock")
    }
    static func refuseLiveSessions(roots: [String], provider: (@Sendable () -> [String])?) throws {
        guard let provider else { return }
        let live = provider().compactMap { try? WorkspaceStore.canonicalPath($0) }
        let busy = live.filter { cwd in roots.contains { WorkspaceSelectors.contains(root: $0, path: cwd) } }
        guard busy.isEmpty else { throw HostRPCError("hasLiveSessions", detail: "\(busy.count) live session(s) inside the project") }
    }

    /// `auto` registers a Git repository when the folder is a work tree top level (or has a `.git` marker), else a folder.
    static func addRepo(path raw: String, kind: String, displayName: String?, groupID: String?,
                        store: WorkspaceStore, git: GitService, context: GitProcessControl)
        throws -> (row: [String: WorkspaceSQLValue], alreadyKnown: Bool) {
        let path = try directory(raw)
        if let known = try store.repoRow(path: path) { return (known, true) }
        var resolvedKind = "folder"
        var branch: String?
        if kind != "folder" {
            let top = try runGit(git, ["rev-parse", "--show-toplevel"], at: path, mode: .isolatedRead, control: context, allowFailure: true)
            let root = top.code == 0 ? (try? WorkspaceStore.canonicalPath(top.stdout.trimmingCharacters(in: .newlines))) : nil
            if root == path || (root == nil && NestedRepoScan.hasGitMarker(path)) {
                resolvedKind = "git"
                let head = try runGit(git, ["symbolic-ref", "--quiet", "--short", "HEAD"], at: path, mode: .isolatedRead,
                                      control: context, allowFailure: true)
                if head.code == 0 { branch = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
            } else if kind == "git" {
                throw HostRPCError("notRepository", detail: root.map { "the repository root is \($0)" })
            }
        }
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? (path as NSString).lastPathComponent
        return try store.insertRepo(path: path, kind: resolvedKind, displayName: name, branch: branch,
                                    projectGroupID: groupID?.lowercased())
    }

    /// Router handlers are synchronous and run on dedicated host threads, never on the cooperative pool.
    static func runGit(_ git: GitService, _ arguments: [String], at path: String, mode: GitRunMode,
                       control: GitProcessControl, stderr: (@Sendable (String) -> Void)? = nil,
                       progress: (@Sendable (GitProgress) -> Void)? = nil,
                       allowFailure: Bool = false) throws -> GitService.Output {
        let box = ResultBox<GitService.Output>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.value = .success(try await git.run(arguments, at: URL(fileURLWithPath: path, isDirectory: true), mode: mode,
                    timeout: mode == .isolatedRead ? 30 : nil, control: control, stderr: stderr, progress: progress,
                    allowFailure: allowFailure))
            } catch { box.value = .failure(error) }
            done.signal()
        }
        done.wait()
        do { return try box.value!.get() }
        catch let error as GitError {
            switch error {
            case .cancelled: throw HostRPCError("cancelled")
            case .authenticationRequired(let detail): throw HostRPCError("authenticationRequired", detail: detail)
            case .commandFailed(_, let detail): throw HostRPCError("gitFailed", detail: detail)
            default: throw HostRPCError("gitFailed", detail: String(describing: error))
            }
        }
    }
}

private final class ResultBox<T>: @unchecked Sendable { var value: Result<T, any Error>? }

private enum ClonePaths {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active: Set<String> = []
    static func claim(_ path: String) -> Bool { lock.withLock { active.insert(path).inserted } }
    static func release(_ path: String) { _ = lock.withLock { active.remove(path) } }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
