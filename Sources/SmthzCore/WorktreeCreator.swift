import Foundation

public enum WorktreeCreator {
    static func canonicalFuturePath(_ path: String) throws -> String {
        var current = URL(fileURLWithPath: path).standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: current.path), current.path != "/" {
            suffix.insert(current.lastPathComponent, at: 0)
            current.deleteLastPathComponent()
        }
        var result = try WorkspaceStore.canonicalPath(current.path)
        for part in suffix { result = (result as NSString).appendingPathComponent(part) }
        return result
    }
    static func baseRef(repo: [String: WorkspaceSQLValue], params: [String: HostJSON]) throws -> String {
        if let ref = params["startFrom"]?.object?["ref"]?.string ?? repo["worktree_base_ref"]?.string { return ref }
        let git = GitService(), root = repo["path"]!.string!
        let symbolic = try git.worktreeGit(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], at: root, allowFailure: true)
        if symbolic.code == 0 { return symbolic.stdout.trimmingCharacters(in: .newlines) }
        for ref in ["origin/main", "origin/master", "main", "master"] {
            if try git.worktreeGit(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], at: root, allowFailure: true).code == 0 { return ref }
        }
        return "HEAD"
    }
    static func setupRuns(_ params: [String: HostJSON], repo: [String: WorkspaceSQLValue]) throws -> Bool {
        let choice = params["setup"]?.string ?? "inherit"
        guard ["run", "skip", "inherit"].contains(choice) else { throw HostRPCError("badRequest") }
        if choice == "run" { return true }; if choice == "skip" { return false }
        let policy = repo["setup_run_policy"]?.string ?? "run-by-default"
        guard policy != "ask" else { throw HostRPCError("setupDecisionRequired") }
        return policy == "run-by-default"
    }
    static func validate(store: WorkspaceStore, params: [String: HostJSON]) throws -> [String: WorkspaceSQLValue] {
        guard let id = params["repoId"]?.string else { throw HostRPCError("badRequest") }
        let repo = try store.repoRow(id)
        guard repo["kind"]?.string == "git" else { throw HostRPCError("notRepository") }
        do { _ = try WorktreeNaming.sanitize(params["name"]?.string ?? "") }
        catch { throw HostRPCError("invalidName") }
        if let branch = params["branchName"]?.string {
            do { try WorktreeNaming.validateExplicitBranchName(branch) } catch { throw HostRPCError("invalidRef") }
            guard try GitService().worktreeGit(["check-ref-format", "--branch", branch], at: repo["path"]!.string!, allowFailure: true).code == 0 else { throw HostRPCError("invalidRef") }
        }
        if let start = params["startFrom"]?.object {
            guard ["base", "branch", "commit", "remote-branch"].contains(start["kind"]?.string ?? ""),
                  let ref = start["ref"]?.string, !ref.isEmpty, !ref.hasPrefix("-"), !ref.utf8.contains(0) else { throw HostRPCError("invalidRef") }
        }
        let runs = try setupRuns(params, repo: repo)
        let ref = try baseRef(repo: repo, params: params)
        guard !ref.hasPrefix("-"), !ref.isEmpty, !ref.utf8.contains(0),
              try GitService().worktreeGit(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], at: repo["path"]!.string!, allowFailure: true).code == 0 else { throw HostRPCError("invalidRef") }
        if runs {
            // Hooks come from the destination revision, not the primary checkout.
            var file: SmthzConfigFile?
            for source in [SmthzConfigFile.Source.smthz, .orca] {
                let output = try GitService().worktreeGit(["show", ref + ":" + source.rawValue], at: repo["path"]!.string!, allowFailure: true)
                if output.code == 0 {
                    file = .init(source: source, path: source.rawValue, result: Result { () throws(SmthzConfigError) in try SmthzConfigParser.parse(output.stdout) })
                    break
                }
            }
            _ = try SetupRunner.selectedScript(store: store, repo: repo, kind: "setup", file: file)
            if params["defaultTabs"] != .bool(false), SetupRunner.sharedCommandsEnabled(repo) {
                try SetupRunner.requireTrust(store: store, repoID: id, kind: "defaultTabs", script: (file?.config?.defaultTabs ?? []).compactMap(\.command).joined(separator: "\n"))
            }
        }
        if let parent = params["parentId"]?.string {
            guard params["noParent"] != .bool(true) else { throw HostRPCError("badRequest") }
            let key = parent.hasPrefix("worktree:") || parent.hasPrefix("folder:") ? parent : "worktree:" + parent
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            let row = parts[0] == "folder" ? try store.folderRow(parts[1]) : try store.worktreeRow(parts[1])
            guard (row["repo_id"]?.string ?? row["source_repo_id"]?.string) == id else { throw HostRPCError("badRequest", detail: "parent belongs to another repo") }
        }
        return repo
    }
    static func create(store: WorkspaceStore, id: String, params: [String: HostJSON],
                       sessions: SessionManager?, context: HostJobContext, jobID: String? = nil) throws -> HostJSON {
        let repo = try validate(store: store, params: params), root = repo["path"]!.string!, repoID = repo["id"]!.string!
        let git = GitService(), settings = try store.hostSettings()
        var warnings: [String] = [], fallback = false
        context.event("phase", "resolveBase")
        let start = params["startFrom"]?.object
        let base = try baseRef(repo: repo, params: params)
        guard !base.hasPrefix("-"), !base.isEmpty, !base.utf8.contains(0) else { throw HostRPCError("invalidRef") }
        let remote = try git.worktreeGit(["rev-parse", "--verify", "--quiet", "refs/remotes/" + base], at: root, context: context, allowFailure: true)
        if remote.code == 0 || start?["kind"]?.string == "remote-branch" {
            let parts = base.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].hasPrefix("-"), !parts[1].hasPrefix("-") else { throw HostRPCError("invalidRef") }
            let fetched = try git.worktreeGit(["fetch", "--", parts[0], parts[1]], at: root, context: context, allowFailure: true)
            if fetched.code != 0 { fallback = true; warnings.append("baseFallback: using local " + base) }
        }
        let commit = try git.worktreeGit(["rev-parse", "--verify", base + "^{commit}"], at: root, context: context, allowFailure: true)
        guard commit.code == 0 else { throw HostRPCError("invalidRef") }
        try context.checkCancellation()
        context.event("phase", "resolveName")
        let typed = params["name"]!.string!, leaf = try WorktreeNaming.sanitize(typed)
        var username = repo["git_username"]?.string
        if username == nil {
            for key in ["github.user", "user.username", "user.name"] {
                let value = try git.worktreeGit(["config", "--get", key], at: root, context: context, allowFailure: true).stdout.trimmingCharacters(in: .newlines)
                if !value.isEmpty, WorktreeNaming.isValidBranchPrefix(value) { username = value; break }
            }
        }
        let initialBranch = try params["branchName"]?.string ?? WorktreeNaming.branchName(for: leaf,
            strategy: WorktreeNaming.PrefixStrategy(rawValue: settings["branchPrefix"]?.string ?? "git-username") ?? .gitUsername,
            customPrefix: settings["branchPrefixCustom"]?.string, gitUsername: username)
        var workspaceRoot = repo["worktree_base_path"]?.string ?? settings["workspaceDir"]!.string!
        workspaceRoot = NSString(string: workspaceRoot).expandingTildeInPath
        if !workspaceRoot.hasPrefix("/") { workspaceRoot = root + "/" + workspaceRoot }
        workspaceRoot = try canonicalFuturePath(workspaceRoot)
        let generated = params["nameWasGenerated"] == .bool(true)
        let retired = Set(try store.query("SELECT name FROM retired_names WHERE repo_id=?", [.text(repoID)]).compactMap { $0["name"]?.string })
        var path = "", branch = "", chosen = "", reuse = false, found = false
        for attempt in 1...WorktreeNaming.maxSuffixAttempts {
            chosen = generated ? WorktreeNaming.generatedCandidate(leaf, attempt: attempt) : WorktreeNaming.candidate(leaf, attempt: attempt)
            if generated && retired.contains(chosen) { continue }
            if generated, params["branchName"] == nil {
                branch = try WorktreeNaming.branchName(for: chosen,
                    strategy: WorktreeNaming.PrefixStrategy(rawValue: settings["branchPrefix"]?.string ?? "git-username") ?? .gitUsername,
                    customPrefix: settings["branchPrefixCustom"]?.string, gitUsername: username)
            } else { branch = WorktreeNaming.candidate(initialBranch, attempt: attempt) }
            path = try WorktreeNaming.worktreePath(sanitized: chosen, repoPath: root, workspaceRoot: workspaceRoot,
                nestWorkspaces: settings["nestWorkspaces"] != .bool(false))
            guard WorkspaceSelectors.contains(root: workspaceRoot, path: try canonicalFuturePath(path)), path != workspaceRoot else { throw HostRPCError("invalidPath") }
            var info = stat()
            if lstat(path, &info) == 0 { continue }
            guard try git.worktreeGit(["check-ref-format", "--branch", branch], at: root, context: context, allowFailure: true).code == 0 else { throw HostRPCError("invalidRef") }
            let exists = try git.worktreeGit(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], at: root, context: context, allowFailure: true)
            reuse = exists.code == 0 && exists.stdout == commit.stdout
            if exists.code == 0 && !reuse { continue }
            let listed = try git.worktreeGit(["worktree", "list", "--porcelain", "-z"], at: root, context: context).stdout
            if listed.components(separatedBy: "\0").contains("branch refs/heads/" + branch) { continue }
            if try git.worktreeGit(["for-each-ref", "--format=%(refname:strip=3)", "refs/remotes"], at: root, context: context).stdout.split(separator: "\n").contains(Substring(branch)) { continue }
            found = true; break
        }
        guard found, !path.isEmpty, !FileManager.default.fileExists(atPath: path) else { throw HostRPCError("branchExists") }
        // Recheck branch occupancy after exhaustion; never let a suffix collision reuse a branch with different history.
        let existing = try git.worktreeGit(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], at: root, context: context, allowFailure: true)
        guard existing.code != 0 || reuse else { throw HostRPCError("branchExists") }
        let sparse = params["sparse"]?.object
        let dirs: [String]
        if case .array(let values) = sparse?["directories"] { dirs = values.compactMap(\.string) }
        else if let preset = sparse?["presetId"]?.string {
            guard let json = try store.query("SELECT directories_json FROM sparse_presets WHERE id=? AND repo_id=?", [.text(preset), .text(repoID)]).first?["directories_json"]?.string,
                  let decoded = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { throw HostRPCError("notFound") }
            dirs = decoded
        } else { dirs = [] }
        guard dirs.allSatisfy({ WorktreeInclude.isSafe($0) && !$0.hasPrefix("-") && !$0.split(separator: "/").contains(".") }) else { throw HostRPCError("invalidPath") }
        try context.checkCancellation()
        try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path, withIntermediateDirectories: true)
        // Exclusive directory ownership prevents rollback from touching another creator's path.
        guard mkdir(path, 0o700) == 0 else { throw HostRPCError("alreadyExists") }
        var added = false, branchCreated = false, persisted = false
        do {
            _ = try store.insertWorktree(id: id, repoID: repoID, path: path, branch: branch, name: params["displayName"]?.string ?? typed)
            if let jobID { try store.updateRow(table: "worktrees", id: id, values: ["job_id": .text(jobID)]) }
            context.event("phase", "add")
            if !reuse {
                // Compare-and-create the ref before checkout. An external Git process racing
                // us cannot make rollback claim a pre-existing branch as its own.
                let zero = String(repeating: "0", count: commit.stdout.trimmingCharacters(in: .newlines).count)
                _ = try git.worktreeGit(["update-ref", "--create-reflog", "-m", "smthz worktree " + id, "refs/heads/" + branch, commit.stdout.trimmingCharacters(in: .newlines), zero], at: root)
                branchCreated = true
            }
            // update-ref creates no tracking config; --no-track is invalid without -b.
            let args = ["worktree", "add"] + (dirs.isEmpty ? [] : ["--no-checkout"]) + [path, branch]
            _ = try git.worktreeGit(args, at: root, context: context)
            added = true
            _ = try git.worktreeGit(["config", "--local", "branch.\(branch).base", base], at: root, context: context)
            if try git.worktreeGit(["config", "--get", "push.autoSetupRemote"], at: root, context: context, allowFailure: true).code != 0 {
                _ = try git.worktreeGit(["config", "--local", "push.autoSetupRemote", "true"], at: root, context: context)
            }
            if !dirs.isEmpty {
                context.event("phase", "sparse")
                _ = try git.worktreeGit(["sparse-checkout", "init", "--cone"], at: path, context: context)
                _ = try git.worktreeGit(["sparse-checkout", "set", "--"] + dirs, at: path, context: context)
                _ = try git.worktreeGit(["checkout", branch], at: path, context: context)
            }
            context.event("phase", "materialize")
            let shared = repo["shared_paths_json"]?.string.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
            warnings += try WorktreeMaterializer.materialize(root: root, destination: path, sharedPaths: shared, context: context)
            let yamlShared = SmthzConfigLoader.load(repoRoot: root)?.config?.sharedDirectories ?? []
            let combined = Array(Set(shared + yamlShared)).sorted()
            if combined != shared.sorted() {
                try store.updateRow(table: "repos", id: repoID, values: ["shared_paths_json": .text(String(decoding: try JSONEncoder().encode(combined), as: UTF8.self))])
            }
            try context.checkCancellation()
            context.event("phase", "persist")
            try store.updateRow(table: "worktrees", id: id, values: ["state": .text("ready"), "base_ref": .text(base),
                "start_from_kind": .text(start?["kind"]?.string ?? "base"), "checkout_existing_branch": .integer(reuse ? 1 : 0),
                "preserve_branch_on_delete": .integer(reuse ? 1 : 0), "comment": .text(params["comment"]?.string ?? ""),
                "name_was_generated": .integer(generated ? 1 : 0), "sparse_dirs_json": .text(String(decoding: try JSONEncoder().encode(dirs), as: UTF8.self)),
                "sparse_base_ref": sparse == nil ? .null : .text(base), "sparse_preset_id": sparse?["presetId"]?.string.map(WorkspaceSQLValue.text) ?? .null,
                "created_by": .text(params["createdBy"]?.string == "desktop" ? "desktop" : "cli")])
            if let parent = params["parentId"]?.string, params["noParent"] != .bool(true) {
                try store.setLineage(child: "worktree:" + id, parent: parent.contains(":") ? parent : "worktree:" + parent, origin: "cli",
                    captureSource: params["parentInferred"] == .bool(true) ? "cwd-context" : "explicit",
                    confidence: params["parentInferred"] == .bool(true) ? "inferred" : "explicit")
            }
            if generated { try store.execute("INSERT OR IGNORE INTO retired_names (repo_id,name,retired_at) VALUES (?,?,?)", [.text(repoID), .text(chosen), .real(Date().timeIntervalSince1970)]) }
            if params["revealRequested"] == .bool(true) {
                try store.execute("INSERT OR REPLACE INTO host_settings (key,value_json,updated_at) VALUES (?,'true',?)", [.text("revealRequested:" + id), .real(Date().timeIntervalSince1970)])
            }
            persisted = true
            var result: [String: HostJSON] = ["worktree": try store.worktreeJSON(store.worktreeRow(id)), "baseFallback": .bool(fallback)]
            context.event("phase", "setup")
            if try setupRuns(params, repo: repo) {
                do {
                    let (script, source) = try SetupRunner.script(store: store, repo: repo, kind: "setup", root: path)
                    if !script.isEmpty {
                        guard let sessions else { throw HostRPCError("badRequest", detail: "session manager unavailable") }
                        let info = try SetupRunner.start(script: script, source: source, root: root, path: path, sessions: sessions)
                        result["setup"] = .object(["sessionId": .string(info.id)])
                    }
                } catch { warnings.append("Setup not started: \(error)") }
            }
            context.event("phase", "defaultTabs")
            if params["defaultTabs"] != .bool(false), SetupRunner.sharedCommandsEnabled(repo) {
                let tabs = SmthzConfigLoader.load(repoRoot: path)?.config?.defaultTabs ?? []
                let runCommands = (try? setupRuns(params, repo: repo)) == true && (try? SetupRunner.requireTrust(store: store, repoID: repoID, kind: "defaultTabs", script: tabs.compactMap(\.command).joined(separator: "\n"))) != nil
                result["defaultTabs"] = .array(tabs.map { tab in
                    var value: [String: HostJSON] = [:]
                    value["title"] = tab.title.map(HostJSON.string); value["color"] = tab.color.map(HostJSON.string)
                    value["command"] = runCommands ? tab.command.map(HostJSON.string) : nil
                    return .object(value)
                })
            }
            result["warnings"] = .array(warnings.map(HostJSON.string))
            return .object(result)
        } catch {
            if !persisted {
                // A killed add can leave a registered worktree even before returning success.
                let listing = try? git.worktreeGit(["worktree", "list", "--porcelain", "-z"], at: root).stdout
                if added || listing?.components(separatedBy: "\0").contains("worktree " + path) == true {
                    _ = try? git.worktreeGit(["worktree", "remove", "--force", "--", path], at: root)
                }
                // The exclusive directory can remain after a killed checkout; it is ours.
                if FileManager.default.fileExists(atPath: path) { try? FileManager.default.removeItem(atPath: path) }
                if branchCreated {
                    _ = try? git.worktreeGit(["update-ref", "-d", "refs/heads/" + branch, commit.stdout.trimmingCharacters(in: .newlines)], at: root)
                }
                try? store.updateRow(table: "worktrees", id: id, values: ["state": .text("failed"), "last_error": .text((error as? HostRPCError)?.code ?? "gitFailed")])
            }
            throw error
        }
    }
}
