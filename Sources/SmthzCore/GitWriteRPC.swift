import Foundation

/// Source Control RPC (`git.*`, M4-PLAN §5.2). Every method takes `worktreePath`;
/// file paths are relative to that root and must stay inside it.
public enum GitWriteRPC {
    public static func register(on router: HostRouter, store: WorkspaceStore) {
        register(on: router, store: store, environment: nil)
    }

    /// `environment` replaces the host environment for userContext Git (tests pass a temp global config).
    public static func register(on router: HostRouter, store: WorkspaceStore, environment: [String: String]?) {
        let key: HostRouter.RepoKey = { params in try resolveRoot(params, store: store).repositoryKey }
        @Sendable func scm(_ params: [String: HostJSON], _ control: GitProcessControl) throws -> GitSourceControl {
            GitService().sourceControl(root: try resolveRoot(params, store: store).url, environment: environment, control: control)
        }
        func read(_ method: String, _ body: @escaping @Sendable (GitSourceControl, [String: HostJSON]) async throws -> [String: HostJSON]) {
            router.register(method, methodClass: .read) { params, context in
                let source = try scm(params, context.processControl)
                return try blocking { try await body(source, params) }
            }
        }
        func mutation(_ method: String, _ body: @escaping @Sendable (GitSourceControl, [String: HostJSON]) async throws -> Void) {
            router.register(method, methodClass: .mutation, repository: key) { params, context in
                let source = try scm(params, context.processControl)
                try context.checkCancellation()
                try blocking { try await body(source, params) }
                return [:]
            }
        }
        func job(_ method: String, _ body: @escaping @Sendable (GitSourceControl, [String: HostJSON], HostJobContext) async throws -> HostJSON) {
            router.register(method, methodClass: .job, repository: key) { [jobs = router.jobs] params, _ in
                let root = try resolveRoot(params, store: store)
                let id = try jobs.submit(repository: root.repositoryKey) { context in
                    context.event("phase", method)
                    let source = GitService().sourceControl(root: root.url, environment: environment, control: context.processControl)
                    return try blocking { try await body(source, params, context) }
                }
                return ["jobId": .string(id)]
            }
        }

        read("git.status") { s, _ in try encode(await s.status()) }
        read("git.upstreamStatus") { s, _ in
            let u = try await s.upstreamStatus()
            var r: [String: HostJSON] = ["ahead": .number(Double(u.ahead)), "behind": .number(Double(u.behind))]
            r["upstream"] = u.upstream.map(HostJSON.string)
            return r
        }
        read("git.branchCompare") { s, p in
            let c = try await s.branchCompare(baseRef: try string(p, "baseRef"))
            return ["mergeBase": .string(c.mergeBase), "ahead": .number(Double(c.ahead)), "behind": .number(Double(c.behind)),
                    "added": .number(Double(c.added)), "removed": .number(Double(c.removed)),
                    "files": .array(c.files.map { .object(["status": .string($0.status), "path": .string($0.path)]) })]
        }
        read("git.diff") { s, p in
            let path = try relativePaths(p, root: s.root, key: "path").first!
            let text = try await s.git.diff(at: s.root, path: path, staged: p["staged"] == .bool(true))
            var bytes = text.utf8.prefix(512 * 1_024)
            while String(bytes: bytes, encoding: .utf8) == nil { bytes = bytes.dropLast() }
            return ["diff": .string(String(decoding: bytes, as: UTF8.self)), "truncated": .bool(bytes.count < text.utf8.count)]
        }
        read("git.history") { s, p in
            let limit = Int(p["limit"]?.number ?? 50)
            return ["commits": .array(try await s.history(limit: limit).map {
                .object(["commit": .string($0.commit), "subject": .string($0.subject), "author": .string($0.author),
                         "committedAt": .number($0.committedAt)])
            })]
        }
        read("git.branches") { s, _ in
            ["branches": .array(try await s.git.branches(at: s.root, includeRemote: true).map {
                var b: [String: HostJSON] = ["name": .string($0.name), "commit": .string($0.commit),
                                             "isCurrent": .bool($0.isCurrent), "isRemote": .bool($0.isRemote)]
                b["upstream"] = $0.upstream.map(HostJSON.string)
                return .object(b)
            })]
        }
        read("git.stashList") { s, _ in
            ["stashes": .array(try await s.stashList().map { .object(["index": .number(Double($0.index)), "message": .string($0.message)]) })]
        }
        read("git.checkIgnored") { s, p in
            ["ignored": .array(try await s.checkIgnored(try relativePaths(p, root: s.root)).map(HostJSON.string))]
        }

        mutation("git.stage") { s, p in try await s.stage(try relativePaths(p, root: s.root)) }
        mutation("git.unstage") { s, p in try await s.unstage(try relativePaths(p, root: s.root)) }
        mutation("git.stageAll") { s, _ in try await s.stageAll() }
        mutation("git.unstageAll") { s, _ in try await s.unstageAll() }
        mutation("git.discard") { s, p in
            try await s.discard(try relativePaths(p, root: s.root), includeUntracked: p["includeUntracked"] == .bool(true))
        }
        router.register("git.commit", methodClass: .mutation, repository: key) { params, context in
            let s = try scm(params, context.processControl)
            let message = params["message"]?.string ?? ""
            let commit = try blocking {
                try await s.commit(message: message, amend: params["amend"] == .bool(true),
                                   confirmPushedAmend: params["confirmPushedAmend"] == .bool(true))
            }
            return ["commit": .string(commit)]
        }
        mutation("git.abortMerge") { s, _ in try await s.abortMerge() }
        mutation("git.abortRebase") { s, _ in try await s.abortRebase() }
        mutation("git.continueOperation") { s, _ in try await s.continueOperation() }
        mutation("git.createBranch") { s, p in
            try await s.createBranch(try string(p, "name"), startPoint: p["startPoint"]?.string, checkout: p["checkout"] != .bool(false))
        }
        mutation("git.switchBranch") { s, p in try await s.switchBranch(try string(p, "name")) }
        mutation("git.deleteBranch") { s, p in try await s.deleteBranch(try string(p, "name"), force: p["force"] == .bool(true)) }
        mutation("git.stash") { s, p in
            try await s.stash(message: p["message"]?.string, includeUntracked: p["includeUntracked"] == .bool(true))
        }
        mutation("git.stashPop") { s, p in try await s.stashPop(index: try index(p)) }
        mutation("git.stashApply") { s, p in try await s.stashApply(index: try index(p)) }
        mutation("git.stashDrop") { s, p in try await s.stashDrop(index: try index(p)) }
        mutation("git.appendGitignore") { s, p in
            let pattern = try string(p, "pattern")
            guard !pattern.contains(where: \.isNewline), !pattern.utf8.contains(0) else { throw HostRPCError("badRequest", detail: "pattern") }
            let url = s.root.appendingPathComponent(".gitignore")
            var data = (try? Data(contentsOf: url)) ?? Data()
            if let last = data.last, last != 10 { data.append(10) }
            data.append(contentsOf: Array((pattern + "\n").utf8))
            try data.write(to: url, options: .atomic)
        }

        job("git.push") { s, p, c in
            let r = try await s.push(remote: p["remote"]?.string, forceWithLease: p["forceWithLease"] == .bool(true),
                                     expectedRemoteCommit: p["expectedRemoteCommit"]?.string,
                                     events: log(c), progress: progress(c))
            return .object(["remote": .string(r.remote), "branch": .string(r.branch), "upstreamSet": .bool(r.upstreamSet)])
        }
        job("git.pull") { s, _, c in try await s.pull(events: log(c), progress: progress(c)); return .object([:]) }
        job("git.fetch") { s, p, c in
            try await s.fetch(remote: p["remote"]?.string, events: log(c), progress: progress(c)); return .object([:])
        }
        job("git.sync") { s, _, c in
            c.event("phase", "pull")
            try await s.pull(events: log(c), progress: progress(c))
            try c.checkCancellation()
            c.event("phase", "push")
            let r = try await s.push(events: log(c), progress: progress(c))
            return .object(["remote": .string(r.remote), "branch": .string(r.branch), "upstreamSet": .bool(r.upstreamSet)])
        }
    }

    public struct AcceptedRoot: Equatable, Sendable {
        public let url: URL
        /// Registered repository id, else `gitdir:<canonical common dir>`.
        public let repositoryKey: String
        public let registered: Bool
    }

    /// Interim until REGISTRY app wiring registers every root; then switch to registered-only.
    /// Accepts `worktreePath` when it canonicalizes to a registered Git root (repos.path or
    /// worktrees.path), or to the exact top level of a non-bare Git work tree. A path inside a
    /// work tree, a non-directory, a non-Git folder and a bare repository are refused.
    public static func acceptRoot(_ path: String, store: WorkspaceStore) throws -> AcceptedRoot {
        let canonical = try WorkspaceStore.canonicalPath(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HostRPCError("invalidPath", detail: "not a directory")
        }
        let url = URL(fileURLWithPath: canonical, isDirectory: true)
        let registered = try store.query("SELECT repo_id AS id FROM worktrees WHERE path=? UNION ALL SELECT id FROM repos WHERE path=? AND kind='git'",
                                         [.text(canonical), .text(canonical)]).first?["id"]?.string
        let git = GitService()
        let probe = try blocking {
            try await git.run(["rev-parse", "--is-bare-repository", "--show-toplevel", "--path-format=absolute", "--git-common-dir"],
                              at: url, mode: .isolatedRead, timeout: git.timeout, allowFailure: true)
        }
        guard probe.code == 0 else { throw HostRPCError("notRepository", detail: canonical) }
        let lines = probe.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3, lines[0] == "false" else { throw HostRPCError("notRepository", detail: "bare repository") }
        guard (try? WorkspaceStore.canonicalPath(lines[1])) == canonical else {
            throw HostRPCError("invalidPath", detail: "worktreePath must be the work tree top level")
        }
        if let registered { return AcceptedRoot(url: url, repositoryKey: registered, registered: true) }
        let common = (try? WorkspaceStore.canonicalPath(lines[2])) ?? lines[2]
        return AcceptedRoot(url: url, repositoryKey: "gitdir:" + common, registered: false)
    }

    /// Relative, no `..`, not inside `.git`, and the deepest existing ancestor directory resolves
    /// inside root. The leaf is not resolved: a symlink is a valid Git path wherever it points,
    /// and a deleted file has no realpath.
    public static func validateRelativePath(_ path: String, root: URL) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.utf8.contains(0), !path.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            throw HostRPCError("invalidPath", detail: path)
        }
        let components = path.split(separator: "/")
        guard !components.contains(where: { $0 == ".." }), components.first != ".git" else {
            throw HostRPCError("pathOutsideRoot", detail: path)
        }
        let rootPath = root.path
        var candidate = (root.appendingPathComponent(path).path as NSString).deletingLastPathComponent
        while candidate.count > rootPath.count {
            if let resolved = try? WorkspaceStore.canonicalPath(candidate) {
                guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else { throw HostRPCError("pathOutsideRoot", detail: path) }
                return path
            }
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        return path
    }

    static func resolveRoot(_ params: [String: HostJSON], store: WorkspaceStore) throws -> AcceptedRoot {
        try acceptRoot(try string(params, "worktreePath"), store: store)
    }

    static func relativePaths(_ params: [String: HostJSON], root: URL, key: String = "paths") throws -> [String] {
        let raw: [String]
        switch params[key] {
        case .array(let values): raw = try values.map { guard let s = $0.string else { throw HostRPCError("badRequest") }; return s }
        case .string(let value): raw = [value]
        default: throw HostRPCError("badRequest", detail: "missing \(key)")
        }
        guard !raw.isEmpty, raw.count <= 20_000 else { throw HostRPCError("badRequest", detail: "\(key) count") }
        return try raw.map { try validateRelativePath($0, root: root) }
    }

    private static func string(_ params: [String: HostJSON], _ key: String) throws -> String {
        guard let value = params[key]?.string, !value.isEmpty else { throw HostRPCError("badRequest", detail: "missing \(key)") }
        return value
    }

    private static func index(_ params: [String: HostJSON]) throws -> Int {
        guard let n = Int(exactly: params["index"]?.number ?? 0), n >= 0 else { throw HostRPCError("badRequest", detail: "index") }
        return n
    }

    private static func log(_ c: HostJobContext) -> @Sendable (String) -> Void { { c.event("log", $0) } }
    private static func progress(_ c: HostJobContext) -> @Sendable (GitProgress) -> Void {
        { c.event("progress", $0.phase, done: $0.done, total: $0.total) }
    }

    static func encode(_ s: GitSourceControlStatus) -> [String: HostJSON] {
        var result: [String: HostJSON] = [
            "ahead": .number(Double(s.ahead)), "behind": .number(Double(s.behind)), "operation": .string(s.operation.rawValue),
            "entries": .array(s.status.entries.map { e in
                var o: [String: HostJSON] = ["kind": .string(e.kind.rawValue), "path": .string(e.path),
                                             "index": .string(String(e.indexStatus)), "worktree": .string(String(e.worktreeStatus))]
                o["originalPath"] = e.originalPath.map(HostJSON.string)
                return .object(o)
            })]
        result["branch"] = s.status.branch.map(HostJSON.string)
        result["head"] = s.status.head.map(HostJSON.string)
        result["upstream"] = s.upstream.map(HostJSON.string)
        return result
    }

    private final class Box<T>: @unchecked Sendable { var value: Result<T, any Error>? }

    /// Router handlers run on dedicated host threads, so blocking on async Git work is safe here.
    static func blocking<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = Box<T>(), done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.value!.get()
    }
}
