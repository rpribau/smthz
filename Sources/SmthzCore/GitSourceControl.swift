import Foundation

/// In-progress multi-step operation, read from the per-worktree Git directory markers.
public enum GitOperation: String, Codable, Sendable { case none, merge, rebase, cherryPick, revert }

public struct GitSourceControlStatus: Equatable, Sendable {
    public let status: GitStatus
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let operation: GitOperation
}

public struct GitCommitSummary: Equatable, Sendable {
    public let commit: String
    public let subject: String
    public let author: String
    public let committedAt: Double
}

public struct GitStashEntry: Equatable, Sendable {
    public let index: Int
    public let message: String
}

public struct GitBranchComparison: Equatable, Sendable {
    public struct File: Equatable, Sendable { public let status: String; public let path: String }
    public let mergeBase: String
    public let ahead: Int
    public let behind: Int
    public let files: [File]
    public let added: Int
    public let removed: Int
}

extension GitService {
    /// Source Control operations bound to one work tree root. `environment` replaces the
    /// process environment for userContext writes (tests supply a temporary global config).
    public func sourceControl(root: URL, environment: [String: String]? = nil,
                              control: GitProcessControl = GitProcessControl()) -> GitSourceControl {
        GitSourceControl(git: self, root: root, environment: environment, control: control)
    }
}

/// Every write uses userContext (identity, credential helpers, hooks); reads stay isolated.
/// Failures are thrown as `HostRPCError` with Git's combined output in `detail`.
public struct GitSourceControl: Sendable {
    public let git: GitService
    public let root: URL
    public let environment: [String: String]?
    public let control: GitProcessControl

    // MARK: Reads

    public func status() async throws -> GitSourceControlStatus {
        let output = try await read(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"])
        let status = try GitService.parseStatus(output)
        var upstream: String?, ahead = 0, behind = 0
        for record in output.split(separator: "\0") where record.hasPrefix("# branch.") {
            if record.hasPrefix("# branch.upstream ") { upstream = String(record.dropFirst(18)) }
            if record.hasPrefix("# branch.ab ") {
                let parts = record.dropFirst(12).split(separator: " ")
                if parts.count == 2 { ahead = Int(parts[0].dropFirst()) ?? 0; behind = Int(parts[1].dropFirst()) ?? 0 }
            }
        }
        return GitSourceControlStatus(status: status, upstream: upstream, ahead: ahead, behind: behind,
                                      operation: try await operation())
    }

    public func operation() async throws -> GitOperation {
        let gitDir = URL(fileURLWithPath: trimmed(try await read(["rev-parse", "--absolute-git-dir"])))
        let exists = { FileManager.default.fileExists(atPath: gitDir.appendingPathComponent($0).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return .none
    }

    public func upstreamStatus() async throws -> (upstream: String?, ahead: Int, behind: Int) {
        let upstream = try await git.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], at: root,
                                         mode: .isolatedRead, timeout: git.timeout, control: control, allowFailure: true)
        guard upstream.code == 0 else { return (nil, 0, 0) }
        let counts = trimmed(try await read(["rev-list", "--left-right", "--count", "@{u}...HEAD"])).split(separator: "\t")
        guard counts.count == 2, let behind = Int(counts[0]), let ahead = Int(counts[1]) else { throw GitError.malformedOutput }
        return (trimmed(upstream.stdout), ahead, behind)
    }

    public func branchCompare(baseRef: String) async throws -> GitBranchComparison {
        try Self.validateRef(baseRef)
        let base = trimmed(try await read(["merge-base", baseRef, "HEAD"]))
        let counts = trimmed(try await read(["rev-list", "--left-right", "--count", "\(baseRef)...HEAD"])).split(separator: "\t")
        guard counts.count == 2, let behind = Int(counts[0]), let ahead = Int(counts[1]) else { throw GitError.malformedOutput }
        let names = try await read(["diff", "--no-ext-diff", "--name-status", "-z", "\(base)", "HEAD"])
        var files: [GitBranchComparison.File] = []
        var fields = names.split(separator: "\0").map(String.init)[...]
        while let status = fields.popFirst() {
            if status.hasPrefix("R") || status.hasPrefix("C") { _ = fields.popFirst() }
            guard let path = fields.popFirst() else { throw GitError.malformedOutput }
            files.append(.init(status: String(status.prefix(1)), path: path))
        }
        var added = 0, removed = 0
        for line in try await read(["diff", "--no-ext-diff", "--numstat", "\(base)", "HEAD"]).split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if parts.count >= 2 { added += Int(parts[0]) ?? 0; removed += Int(parts[1]) ?? 0 }
        }
        return GitBranchComparison(mergeBase: base, ahead: ahead, behind: behind, files: files, added: added, removed: removed)
    }

    public func history(limit: Int) async throws -> [GitCommitSummary] {
        guard (1...200).contains(limit) else { throw HostRPCError("badRequest", detail: "limit must be 1...200") }
        let head = try await git.run(["rev-parse", "--verify", "-q", "HEAD"], at: root, mode: .isolatedRead,
                                     timeout: git.timeout, control: control, allowFailure: true)
        guard head.code == 0 else { return [] }
        let output = try await read(["log", "-n", "\(limit)", "-z", "--format=%H%x1f%s%x1f%an%x1f%ct"])
        return try output.split(separator: "\0").map { record in
            let f = record.split(separator: "\u{1f}", omittingEmptySubsequences: false)
            guard f.count == 4 else { throw GitError.malformedOutput }
            return GitCommitSummary(commit: String(f[0]), subject: String(f[1]), author: String(f[2]),
                                    committedAt: Double(f[3].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        }
    }

    /// `check-ignore` rejects the literal pathspec magic every call runs with, so ignored
    /// untracked paths come from `ls-files --others --ignored` over the same literal paths.
    public func checkIgnored(_ paths: [String]) async throws -> [String] {
        var ignored: Set<String> = []
        for chunk in stride(from: 0, to: paths.count, by: 500) {
            let slice = Array(paths[chunk..<min(chunk + 500, paths.count)])
            let output = try await read(["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory", "--"] + slice)
            ignored.formUnion(output.split(separator: "\0").map { String($0.hasSuffix("/") ? $0.dropLast() : $0) })
        }
        return paths.filter { path in
            ignored.contains(path) || ignored.contains { path.hasPrefix($0 + "/") }
        }
    }

    public func stashList() async throws -> [GitStashEntry] {
        try await read(["stash", "list", "-z", "--format=%gs"]).split(separator: "\0").enumerated().map {
            GitStashEntry(index: $0.offset, message: String($0.element))
        }
    }

    // MARK: Index and working tree

    /// Paths always travel as a NUL-separated pathspec file on stdin, so thousands of
    /// paths never hit argv limits and names are taken literally.
    public func stage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { throw HostRPCError("badRequest", detail: "no paths") }
        try await write(["add", "--pathspec-from-file=-", "--pathspec-file-nul"], stdin: Self.nulList(paths))
    }

    public func unstage(_ paths: [String]) async throws {
        guard !paths.isEmpty else { throw HostRPCError("badRequest", detail: "no paths") }
        if try await hasHead() {
            try await write(["reset", "-q", "--pathspec-from-file=-", "--pathspec-file-nul"], stdin: Self.nulList(paths))
        } else {
            try await write(["rm", "--cached", "-r", "-q", "--ignore-unmatch", "--pathspec-from-file=-", "--pathspec-file-nul"],
                            stdin: Self.nulList(paths))
        }
    }

    public func stageAll() async throws { try await write(["add", "-A"]) }

    public func unstageAll() async throws {
        if try await hasHead() { try await write(["reset", "-q"]) }
        else { try await write(["rm", "--cached", "-r", "-q", "--ignore-unmatch", "."]) }
    }

    /// Tracked paths are restored from the index; untracked paths are deleted only when
    /// `includeUntracked` is set (irreversible). Never runs a path-less clean.
    public func discard(_ paths: [String], includeUntracked: Bool) async throws {
        guard !paths.isEmpty else { throw HostRPCError("badRequest", detail: "no paths") }
        let untracked = Set(try await status().status.entries.filter { $0.kind == .untracked }.map(\.path))
        let untrackedRequested = paths.filter { path in
            untracked.contains(path) || untracked.contains { $0.hasPrefix(path.hasSuffix("/") ? path : path + "/") }
        }
        if !untrackedRequested.isEmpty && !includeUntracked {
            throw HostRPCError("untrackedRefused", detail: "untracked paths need includeUntracked: " +
                               untrackedRequested.prefix(20).joined(separator: ", "))
        }
        let tracked = paths.filter { !untracked.contains($0) }
        if !tracked.isEmpty {
            try await write(["restore", "--worktree", "--pathspec-from-file=-", "--pathspec-file-nul"], stdin: Self.nulList(tracked))
        }
        if includeUntracked && !untrackedRequested.isEmpty {
            for chunk in stride(from: 0, to: untrackedRequested.count, by: 500) {
                try await write(["clean", "-ffdx", "--"] + untrackedRequested[chunk..<min(chunk + 500, untrackedRequested.count)])
            }
        }
    }

    // MARK: Commits

    /// Hooks run. An amend of a commit already on any remote-tracking ref needs `confirmPushedAmend`.
    public func commit(message: String, amend: Bool = false, confirmPushedAmend: Bool = false) async throws -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard amend || !text.isEmpty else { throw HostRPCError("badRequest", detail: "empty commit message") }
        if amend {
            guard try await hasHead() else { throw HostRPCError("badRequest", detail: "nothing to amend") }
            if !confirmPushedAmend, try await isHeadPushed() {
                throw HostRPCError("amendPushedCommit", detail: "HEAD is already on a remote branch; confirm to amend it")
            }
        }
        var args = ["commit"]
        if amend { args.append("--amend") }
        if text.isEmpty { args.append("--no-edit") } else { args += ["--cleanup=strip", "-F", "-"] }
        try await write(args, stdin: text.isEmpty ? nil : Data((message + "\n").utf8), editor: true)
        return trimmed(try await read(["rev-parse", "HEAD"]))
    }

    public func isHeadPushed() async throws -> Bool {
        !(try await read(["for-each-ref", "--contains", "HEAD", "--format=%(refname)", "refs/remotes/"])).isEmpty
    }

    // MARK: Remotes

    public struct PushResult: Equatable, Sendable { public let remote: String; public let branch: String; public let upstreamSet: Bool }

    /// Pushes the current branch; sets the upstream on first push. Force is only ever
    /// `--force-with-lease`, and only when explicitly requested (never as a retry).
    public func push(remote requestedRemote: String? = nil, forceWithLease: Bool = false,
                     expectedRemoteCommit: String? = nil, events: (@Sendable (String) -> Void)? = nil,
                     progress: (@Sendable (GitProgress) -> Void)? = nil) async throws -> PushResult {
        let branch = try await currentBranch()
        var remote: String, target: String, setUpstream = false
        if try await upstreamStatus().upstream != nil, requestedRemote == nil {
            remote = trimmed(try await read(["config", "--get", "branch.\(branch).remote"]))
            let merge = trimmed(try await read(["config", "--get", "branch.\(branch).merge"]))
            target = merge.isEmpty ? "refs/heads/\(branch)" : merge
        } else {
            let remotes = try await read(["remote"]).split(separator: "\n").map(String.init)
            if let requestedRemote {
                try Self.validateRef(requestedRemote)
                guard remotes.contains(requestedRemote) else { throw HostRPCError("notFound", detail: "remote \(requestedRemote)") }
                remote = requestedRemote
            } else if remotes.contains("origin") { remote = "origin" }
            else if let first = remotes.first { remote = first }
            else { throw HostRPCError("notFound", detail: "this repository has no remote") }
            target = "refs/heads/\(branch)"; setUpstream = true
        }
        var args = ["push", "--porcelain", "--progress"]
        if setUpstream { args.append("--set-upstream") }
        if forceWithLease {
            if let expectedRemoteCommit {
                try Self.validateRef(expectedRemoteCommit)
                args.append("--force-with-lease=\(target):\(expectedRemoteCommit)")
            } else { args.append("--force-with-lease=\(target)") }
        }
        try await write(args + [remote, "HEAD:\(target)"], events: events, progress: progress)
        return PushResult(remote: remote, branch: branch, upstreamSet: setUpstream)
    }

    public func pull(events: (@Sendable (String) -> Void)? = nil, progress: (@Sendable (GitProgress) -> Void)? = nil) async throws {
        try await write(["pull", "--progress"], editor: true, events: events, progress: progress)
    }

    public func fetch(remote: String? = nil, events: (@Sendable (String) -> Void)? = nil,
                      progress: (@Sendable (GitProgress) -> Void)? = nil) async throws {
        var args = ["fetch", "--prune", "--progress"]
        if let remote { try Self.validateRef(remote); args.append(remote) }
        try await write(args, events: events, progress: progress)
    }

    // MARK: Multi-step operations

    public func abortMerge() async throws { try await write(["merge", "--abort"]) }
    public func abortRebase() async throws { try await write(["rebase", "--abort"]) }

    public func continueOperation() async throws {
        switch try await operation() {
        case .none: throw HostRPCError("badRequest", detail: "no operation in progress")
        case .merge: try await write(["commit", "--no-edit"], editor: true)
        case .rebase: try await write(["rebase", "--continue"], editor: true)
        case .cherryPick: try await write(["cherry-pick", "--continue"], editor: true)
        case .revert: try await write(["revert", "--continue"], editor: true)
        }
    }

    // MARK: Branches and stash

    public func currentBranch() async throws -> String {
        let result = try await git.run(["symbolic-ref", "--short", "-q", "HEAD"], at: root, mode: .isolatedRead,
                                       timeout: git.timeout, control: control, allowFailure: true)
        guard result.code == 0 else { throw HostRPCError("badRequest", detail: "HEAD is detached") }
        return trimmed(result.stdout)
    }

    public func createBranch(_ name: String, startPoint: String? = nil, checkout: Bool = true) async throws {
        try await validateBranchName(name)
        let exists = try await git.run(["show-ref", "--verify", "-q", "refs/heads/\(name)"], at: root,
                                       mode: .isolatedRead, timeout: git.timeout, control: control, allowFailure: true)
        guard exists.code != 0 else { throw HostRPCError("branchExists", detail: name) }
        if let startPoint { try Self.validateRef(startPoint) }
        let args = checkout ? ["switch", "-c", name] : ["branch", name]
        try await write(args + (startPoint.map { [$0] } ?? []))
    }

    public func switchBranch(_ name: String) async throws {
        try await validateBranchName(name)
        try await write(["switch", name])
    }

    public func deleteBranch(_ name: String, force: Bool = false) async throws {
        try await validateBranchName(name)
        try await write(["branch", force ? "-D" : "-d", name])
    }

    /// Under `--literal-pathspecs`, `stash push --include-untracked` saves untracked files but
    /// leaves them in the work tree (Git 2.54), so the exact stashed files are cleaned afterwards.
    public func stash(message: String? = nil, includeUntracked: Bool = false) async throws {
        var args = ["stash", "push"]
        if includeUntracked { args.append("--include-untracked") }
        if let message, !message.isEmpty { args += ["-m", message] }
        let before = try await stashHead()
        try await write(args)
        // "No local changes to save" leaves refs/stash unchanged: never clean against an older entry.
        guard includeUntracked, let after = try await stashHead(), after != before else { return }
        let saved = try await read(["stash", "show", "--include-untracked", "--only-untracked", "--name-only", "-z", "stash@{0}"])
            .split(separator: "\0").map(String.init)
        for chunk in stride(from: 0, to: saved.count, by: 500) {
            try await write(["clean", "-f", "--"] + saved[chunk..<min(chunk + 500, saved.count)])
        }
    }

    private func stashHead() async throws -> String? {
        let result = try await git.run(["rev-parse", "-q", "--verify", "refs/stash"], at: root, mode: .isolatedRead,
                                       timeout: git.timeout, control: control, allowFailure: true)
        return result.code == 0 ? trimmed(result.stdout) : nil
    }

    public func stashPop(index: Int = 0) async throws { try await write(["stash", "pop", "stash@{\(try Self.stashIndex(index))}"]) }
    public func stashApply(index: Int = 0) async throws { try await write(["stash", "apply", "stash@{\(try Self.stashIndex(index))}"]) }
    public func stashDrop(index: Int = 0) async throws { try await write(["stash", "drop", "stash@{\(try Self.stashIndex(index))}"]) }

    // MARK: Helpers

    func hasHead() async throws -> Bool {
        try await git.run(["rev-parse", "--verify", "-q", "HEAD"], at: root, mode: .isolatedRead,
                          timeout: git.timeout, control: control, allowFailure: true).code == 0
    }

    private func validateBranchName(_ name: String) async throws {
        try Self.validateRef(name)
        let check = try await git.run(["check-ref-format", "--branch", name], at: root, mode: .isolatedRead,
                                      timeout: git.timeout, control: control, allowFailure: true)
        guard check.code == 0 else { throw HostRPCError("invalidName", detail: name) }
    }

    private func read(_ arguments: [String]) async throws -> String {
        let result = try await git.run(arguments, at: root, mode: .isolatedRead, timeout: git.timeout,
                                       control: control, allowFailure: true)
        guard result.code == 0 else { throw failure(result) }
        return result.stdout
    }

    private func write(_ arguments: [String], stdin: Data? = nil, editor: Bool = false,
                       events: (@Sendable (String) -> Void)? = nil,
                       progress: (@Sendable (GitProgress) -> Void)? = nil) async throws {
        var env = environment ?? ProcessInfo.processInfo.environment
        if editor { env["GIT_EDITOR"] = "true"; env["GIT_SEQUENCE_EDITOR"] = "true" }
        env["GIT_MERGE_AUTOEDIT"] = "no"
        let result = try await git.run(arguments, at: root, mode: .userContext, stdin: stdin, environment: env,
                                       control: control, stderr: events, progress: progress, allowFailure: true)
        guard result.code == 0 else { throw failure(result) }
    }

    private func failure(_ result: GitService.Output) -> HostRPCError {
        let detail = [result.stdout, result.stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
        if ["could not read Username", "could not read Password", "Permission denied (publickey)",
            "terminal prompts disabled", "Authentication failed"].contains(where: result.stderr.contains) {
            return HostRPCError("authenticationRequired", detail: detail)
        }
        if result.stdout.contains("[rejected]") || result.stdout.contains("[remote rejected]")
            || result.stderr.contains("[rejected]") || result.stderr.contains("[remote rejected]") {
            return HostRPCError("pushRejected", detail: detail)
        }
        if result.stderr.contains("not a git repository") { return HostRPCError("notRepository", detail: detail) }
        return HostRPCError("gitFailed", detail: detail.isEmpty ? "git exited with status \(result.code)" : detail)
    }

    private func trimmed(_ text: String) -> String { text.hasSuffix("\n") ? String(text.dropLast()) : text }

    static func nulList(_ paths: [String]) -> Data { Data(paths.joined(separator: "\0").utf8 + [0]) }

    static func validateRef(_ ref: String) throws {
        guard !ref.isEmpty, !ref.hasPrefix("-"), !ref.utf8.contains(0),
              !ref.contains(where: { $0.isNewline }) else { throw HostRPCError("invalidRef", detail: ref) }
    }

    private static func stashIndex(_ index: Int) throws -> Int {
        guard index >= 0 else { throw HostRPCError("badRequest", detail: "stash index") }
        return index
    }
}
