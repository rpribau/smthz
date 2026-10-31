import CryptoKit
import Foundation

/// Workspace cleanup classifier (WP-M4-CLEANUP), a port of Orca's
/// `src/shared/workspace-cleanup.ts` and `src/main/ipc/workspace-cleanup-git-evidence.ts`.
/// Pure: the host gathers `Evidence`, this decides reasons, blockers and selection.
/// Agent, editor-buffer and SSH blockers return when those features exist.
public enum WorkspaceCleanup {
    public static let classifierVersion = 2
    public static let idleSeconds: Double = 30 * 24 * 60 * 60
    public static let archivedIdleSeconds: Double = 7 * 24 * 60 * 60
    /// Orca `WORKSPACE_CLEANUP_TARGET_BATCH_LIMIT`: most worktree ids one scan or bulk delete accepts.
    public static let targetBatchLimit = 500

    public enum Reason: String, Codable, Sendable, CaseIterable {
        case archived
        case idleClean = "idle-clean"
    }

    public enum Blocker: String, Codable, Sendable, CaseIterable {
        case mainWorktree = "main-worktree"
        case folderRepo = "folder-repo"
        case pinned
        case activeWorkspace = "active-workspace"
        case runningTerminal = "running-terminal"
        case gitStatusError = "git-status-error"
        case dirtyFiles = "dirty-files"
        case unpushedCommits = "unpushed-commits"
        case unknownBase = "unknown-base"
        case dismissed
    }

    /// Never queued for removal.
    public static let queueBlockers: Set<Blocker> = [.mainWorktree, .folderRepo]
    /// Removable only with an explicit force (`worktree.remove {force: true}`).
    public static let forceRemoveBlockers: Set<Blocker> = [.dirtyFiles, .unpushedCommits, .unknownBase]
    /// Every blocker keeps a row out of the default ("ready") selection.
    public static let hardBlockers: Set<Blocker> = Set(Blocker.allCases)

    public struct GitEvidence: Codable, Equatable, Sendable {
        /// nil when status could not be read.
        public var clean: Bool?
        public var upstreamAhead: Int?
        public var upstreamBehind: Int?
        public var checkedAt: Double?
        /// Commits on HEAD that no remote-tracking ref contains; nil when unknown. Read only when
        /// the checkout is clean and has no upstream (Orca `readUnpushedCommitCount`).
        public var unpushedWithoutUpstream: Int?
        public var statusError: Bool
        public init(clean: Bool? = nil, upstreamAhead: Int? = nil, upstreamBehind: Int? = nil,
                    checkedAt: Double? = nil, unpushedWithoutUpstream: Int? = nil, statusError: Bool = false) {
            self.clean = clean; self.upstreamAhead = upstreamAhead; self.upstreamBehind = upstreamBehind
            self.checkedAt = checkedAt; self.unpushedWithoutUpstream = unpushedWithoutUpstream; self.statusError = statusError
        }
        public static let unreadable = GitEvidence(statusError: true)

        /// Orca git-evidence blockers, in its order.
        public var blockers: [Blocker] {
            if statusError || clean == nil { return [.gitStatusError] }
            var result: [Blocker] = []
            if clean == false { result.append(.dirtyFiles) }
            if let ahead = upstreamAhead, ahead > 0 { result.append(.unpushedCommits) }
            if clean == true, upstreamAhead == nil {
                if let count = unpushedWithoutUpstream { if count > 0, !result.contains(.unpushedCommits) { result.append(.unpushedCommits) } }
                else { result.append(.unknownBase) }
            }
            return result
        }
    }

    public struct Evidence: Equatable, Sendable {
        public var worktreeID: String
        public var repoID: String
        public var repoName: String
        public var displayName: String
        public var branch: String
        public var head: String
        public var path: String
        public var isMain = false
        public var isFolderRepo = false
        public var isPinned = false
        public var isArchived = false
        public var isActive = false
        public var sessionCount = 0
        public var runningSessionCount = 0
        public var createdAt: Double = 0
        public var lastActivityAt: Double = 0
        public var sizeBytes: Int64?
        public var sizeTruncated = false
        public var git = GitEvidence()
        public init(worktreeID: String, repoID: String, repoName: String, displayName: String,
                    branch: String, head: String, path: String) {
            self.worktreeID = worktreeID; self.repoID = repoID; self.repoName = repoName
            self.displayName = displayName; self.branch = branch; self.head = head; self.path = path
        }
    }

    public struct Dismissal: Equatable, Sendable {
        public var fingerprint: String
        public var classifierVersion: Int
        public init(fingerprint: String, classifierVersion: Int = WorkspaceCleanup.classifierVersion) {
            self.fingerprint = fingerprint; self.classifierVersion = classifierVersion
        }
    }

    public struct Candidate: Codable, Equatable, Sendable {
        public var worktreeId: String
        public var repoId: String
        public var repoName: String
        public var displayName: String
        public var branch: String
        public var path: String
        public var reasons: [Reason]
        public var blockers: [Blocker]
        public var lastActivityAt: Double
        public var createdAt: Double
        public var sizeBytes: Int64?
        public var sizeTruncated: Bool
        public var sessionCount: Int
        public var runningSessionCount: Int
        public var git: GitEvidence
        public var fingerprint: String

        /// Can be queued for removal at all (Orca `canQueueWorkspaceCleanupCandidate`).
        public var canQueue: Bool { !blockers.contains(where: queueBlockers.contains) }
        /// Removal needs `force` (Orca `shouldForceWorkspaceCleanupRemoval`).
        public var needsForce: Bool {
            git.clean != true || git.checkedAt == nil || blockers.contains(where: forceRemoveBlockers.contains)
        }
        /// Selectable without force or any override: an inactivity reason, verified clean, no blocker
        /// (Orca's "ready" tier, `selectedByDefault`).
        public var isReady: Bool {
            !reasons.isEmpty && git.clean == true && git.checkedAt != nil && !blockers.contains(where: hardBlockers.contains)
        }
        public var isDismissed: Bool { blockers.contains(.dismissed) }
    }

    public static func reasons(isArchived: Bool, lastActivityAt: Double, scannedAt: Double) -> [Reason] {
        var result: [Reason] = []
        let idle = scannedAt - lastActivityAt
        if isArchived && idle >= archivedIdleSeconds { result.append(.archived) }
        if idle >= idleSeconds { result.append(.idleClean) }
        return result
    }

    /// Hash of the evidence a dismissal is bound to: a new commit, a branch switch, a dirty/clean
    /// change or activity on another day changes it and the row comes back.
    public static func fingerprint(branch: String, head: String, gitClean: Bool?, lastActivityAt: Double,
                                   classifierVersion: Int = WorkspaceCleanup.classifierVersion) -> String {
        let bucket = Int((lastActivityAt.isFinite ? max(lastActivityAt, 0) : 0) / 86_400)
        let clean = gitClean.map { $0 ? "clean" : "dirty" } ?? "unknown"
        let text = "\(classifierVersion)|\(branch)|\(head)|\(clean)|\(bucket)"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func classify(_ evidence: Evidence, scannedAt: Double, dismissal: Dismissal? = nil) -> Candidate {
        var blockers: [Blocker] = []
        if evidence.isMain { blockers.append(.mainWorktree) }
        if evidence.isFolderRepo { blockers.append(.folderRepo) }
        if evidence.isPinned { blockers.append(.pinned) }
        if evidence.isActive { blockers.append(.activeWorkspace) }
        if evidence.runningSessionCount > 0 { blockers.append(.runningTerminal) }
        if !evidence.isFolderRepo { blockers += evidence.git.blockers }
        let print = fingerprint(branch: evidence.branch, head: evidence.head, gitClean: evidence.git.clean,
                                lastActivityAt: evidence.lastActivityAt)
        if let dismissal, dismissal.fingerprint == print, dismissal.classifierVersion == classifierVersion {
            blockers.append(.dismissed)
        }
        var unique: [Blocker] = []
        for blocker in blockers where !unique.contains(blocker) { unique.append(blocker) }
        return Candidate(worktreeId: evidence.worktreeID, repoId: evidence.repoID, repoName: evidence.repoName,
                         displayName: evidence.displayName, branch: evidence.branch, path: evidence.path,
                         reasons: reasons(isArchived: evidence.isArchived, lastActivityAt: evidence.lastActivityAt, scannedAt: scannedAt),
                         blockers: unique, lastActivityAt: evidence.lastActivityAt, createdAt: evidence.createdAt,
                         sizeBytes: evidence.sizeBytes, sizeTruncated: evidence.sizeTruncated,
                         sessionCount: evidence.sessionCount, runningSessionCount: evidence.runningSessionCount,
                         git: evidence.git, fingerprint: print)
    }

    public enum BatchError: Error, Equatable, Sendable { case tooManyTargets(Int) }

    /// Rejects a targeted scan or bulk delete larger than `targetBatchLimit`; drops duplicates.
    public static func validateTargets(_ ids: [String]) throws(BatchError) -> [String] {
        var seen: Set<String> = [], unique: [String] = []
        for id in ids where seen.insert(id).inserted { unique.append(id) }
        guard unique.count <= targetBatchLimit else { throw .tooManyTargets(unique.count) }
        return unique
    }

    /// `du`-like size with a bounded walk; `truncated` when the entry or time budget ran out.
    public static func directorySize(_ path: String, maxEntries: Int = 200_000,
                                     deadline: Date = Date(timeIntervalSinceNow: 2)) -> (bytes: Int64, truncated: Bool) {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys,
                                                          options: [], errorHandler: { _, _ in true }) else { return (0, false) }
        var total: Int64 = 0, count = 0
        for case let url as URL in walker {
            count += 1
            if count > maxEntries || (count % 1_000 == 0 && Date() > deadline) { return (total, true) }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return (total, false)
    }
}
