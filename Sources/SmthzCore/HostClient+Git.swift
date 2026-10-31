import Foundation

public struct HostGitStatus: Decodable, Equatable, Sendable {
    public struct Entry: Decodable, Equatable, Sendable {
        public let kind: String
        public let path: String
        public let originalPath: String?
        public let index: String
        public let worktree: String
    }
    public let branch: String?
    public let head: String?
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let operation: GitOperation
    public let entries: [Entry]
}

public struct HostGitBranch: Decodable, Equatable, Sendable {
    public let name: String
    public let commit: String
    public let isCurrent: Bool
    public let isRemote: Bool
    public let upstream: String?
}

public struct HostGitStash: Decodable, Equatable, Sendable {
    public let index: Int
    public let message: String
}

public struct HostGitBranchCompare: Decodable, Equatable, Sendable {
    public struct File: Decodable, Equatable, Sendable { public let status: String; public let path: String }
    public let mergeBase: String
    public let ahead: Int
    public let behind: Int
    public let added: Int
    public let removed: Int
    public let files: [File]
}

public struct HostJobSnapshot: Decodable, Sendable {
    public struct Event: Decodable, Sendable { public let seq: Int; public let kind: String; public let text: String }
    public let jobId: String
    public let state: String
    public let phase: String
    public let events: [Event]
    public let result: HostJSON?
    public let error: String?
    public let detail: String?
    public var isFinished: Bool { ["succeeded", "failed", "cancelled"].contains(state) }
}

/// Source Control calls. Failures throw `HostClientError.detailedHostError` (Git output in detail).
/// Mutations run hooks, so they get the 30 s request ceiling; remote operations are jobs.
extension HostClient {
    private struct Root: Encodable { let worktreePath: String }
    private struct Paths: Encodable { let worktreePath: String; let paths: [String] }
    private struct Empty: Decodable {}
    private struct JobID: Decodable { let jobId: String }

    public func gitStatus(worktreePath: String) throws -> HostGitStatus {
        try callWithDetail(method: "git.status", params: Root(worktreePath: worktreePath))
    }

    public func gitBranches(worktreePath: String) throws -> [HostGitBranch] {
        struct R: Decodable { let branches: [HostGitBranch] }
        let r: R = try callWithDetail(method: "git.branches", params: Root(worktreePath: worktreePath))
        return r.branches
    }

    public func gitStashList(worktreePath: String) throws -> [HostGitStash] {
        struct R: Decodable { let stashes: [HostGitStash] }
        let r: R = try callWithDetail(method: "git.stashList", params: Root(worktreePath: worktreePath))
        return r.stashes
    }

    public func gitBranchCompare(worktreePath: String, baseRef: String) throws -> HostGitBranchCompare {
        struct P: Encodable { let worktreePath: String; let baseRef: String }
        return try callWithDetail(method: "git.branchCompare", params: P(worktreePath: worktreePath, baseRef: baseRef))
    }

    public func gitDiff(worktreePath: String, path: String, staged: Bool = false) throws -> (diff: String, truncated: Bool) {
        struct P: Encodable { let worktreePath: String; let path: String; let staged: Bool }
        struct R: Decodable { let diff: String; let truncated: Bool }
        let r: R = try callWithDetail(method: "git.diff", params: P(worktreePath: worktreePath, path: path, staged: staged))
        return (r.diff, r.truncated)
    }

    public func gitStage(worktreePath: String, paths: [String]) throws {
        try mutate("git.stage", Paths(worktreePath: worktreePath, paths: paths))
    }

    public func gitUnstage(worktreePath: String, paths: [String]) throws {
        try mutate("git.unstage", Paths(worktreePath: worktreePath, paths: paths))
    }

    public func gitStageAll(worktreePath: String) throws { try mutate("git.stageAll", Root(worktreePath: worktreePath)) }
    public func gitUnstageAll(worktreePath: String) throws { try mutate("git.unstageAll", Root(worktreePath: worktreePath)) }

    public func gitDiscard(worktreePath: String, paths: [String], includeUntracked: Bool) throws {
        struct P: Encodable { let worktreePath: String; let paths: [String]; let includeUntracked: Bool }
        try mutate("git.discard", P(worktreePath: worktreePath, paths: paths, includeUntracked: includeUntracked))
    }

    @discardableResult
    public func gitCommit(worktreePath: String, message: String, amend: Bool = false,
                          confirmPushedAmend: Bool = false) throws -> String {
        struct P: Encodable { let worktreePath: String; let message: String; let amend: Bool; let confirmPushedAmend: Bool }
        struct R: Decodable { let commit: String }
        let r: R = try callWithDetail(method: "git.commit", params: P(worktreePath: worktreePath, message: message,
            amend: amend, confirmPushedAmend: confirmPushedAmend), timeoutMilliseconds: 30_000)
        return r.commit
    }

    public func gitAbortMerge(worktreePath: String) throws { try mutate("git.abortMerge", Root(worktreePath: worktreePath)) }
    public func gitAbortRebase(worktreePath: String) throws { try mutate("git.abortRebase", Root(worktreePath: worktreePath)) }
    public func gitContinueOperation(worktreePath: String) throws { try mutate("git.continueOperation", Root(worktreePath: worktreePath)) }

    public func gitCreateBranch(worktreePath: String, name: String, checkout: Bool = true) throws {
        struct P: Encodable { let worktreePath: String; let name: String; let checkout: Bool }
        try mutate("git.createBranch", P(worktreePath: worktreePath, name: name, checkout: checkout))
    }

    public func gitSwitchBranch(worktreePath: String, name: String) throws {
        struct P: Encodable { let worktreePath: String; let name: String }
        try mutate("git.switchBranch", P(worktreePath: worktreePath, name: name))
    }

    public func gitStash(worktreePath: String, includeUntracked: Bool = false) throws {
        struct P: Encodable { let worktreePath: String; let includeUntracked: Bool }
        try mutate("git.stash", P(worktreePath: worktreePath, includeUntracked: includeUntracked))
    }

    public func gitStashPop(worktreePath: String, index: Int = 0) throws {
        struct P: Encodable { let worktreePath: String; let index: Int }
        try mutate("git.stashPop", P(worktreePath: worktreePath, index: index))
    }

    /// Starts a remote job (`git.push`, `git.pull`, `git.fetch`, `git.sync`) and returns its id.
    public func gitStartJob(_ method: String, worktreePath: String, forceWithLease: Bool = false) throws -> String {
        precondition(["git.push", "git.pull", "git.fetch", "git.sync"].contains(method))
        struct P: Encodable { let worktreePath: String; let forceWithLease: Bool? }
        let r: JobID = try callWithDetail(method: method, params: P(worktreePath: worktreePath,
            forceWithLease: forceWithLease ? true : nil))
        return r.jobId
    }

    public func job(id: String, afterSeq: Int = 0) throws -> HostJobSnapshot {
        struct P: Encodable { let jobId: String; let afterSeq: Int }
        return try callWithDetail(method: "job.get", params: P(jobId: id, afterSeq: afterSeq))
    }

    /// Polls `job.get` every 250 ms (the M4 contract) until the job finishes.
    /// A failed or cancelled job throws `detailedHostError` with its error code and detail.
    @discardableResult
    public func waitForJob(id: String, onEvent: (HostJobSnapshot.Event) -> Void = { _ in }) throws -> HostJobSnapshot {
        var after = 0
        while true {
            let snapshot = try job(id: id, afterSeq: after)
            for event in snapshot.events { after = max(after, event.seq); onEvent(event) }
            if snapshot.isFinished {
                guard snapshot.state == "succeeded" else {
                    throw HostClientError.detailedHostError(code: snapshot.error ?? snapshot.state, detail: snapshot.detail)
                }
                return snapshot
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private func mutate<P: Encodable>(_ method: String, _ params: P) throws {
        let _: Empty = try callWithDetail(method: method, params: params, timeoutMilliseconds: 30_000)
    }
}
