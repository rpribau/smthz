import Foundation
import Observation
import SmthzCore

/// Worktree lifecycle for the app (WP-M4-WORKTREE-APP): row states from `worktree.list`,
/// create/remove jobs with progress and Cancel, Retry of failed creates, metadata edits and
/// repository settings. The host owns every row; blocking socket calls never run on the main actor.
@MainActor @Observable
final class WorktreeLifecycleModel {
    struct Row: Equatable {
        let id: String
        var repoID: String
        var path: String
        var branch: String?
        var state: String
        var lastError: String?
        var isMain: Bool
        var displayName: String
        var comment: String
        var isSparse: Bool
        var revealRequested: Bool
    }
    /// A create job started by this app process (survives until success, or kept as failure for Retry).
    struct Job: Equatable {
        let worktreeID: String
        var jobID: String?
        let repoID: String
        let title: String
        let params: [String: HostJSON]
        var phase = ""
        var fraction = 0.0
        var cancelling = false
        var failure: String?
    }
    struct CreateResult {
        let worktreeID: String
        let path: String
        let title: String
        let setupSessionID: String?
        let defaultTabs: [(title: String?, command: String?)]
        let warnings: [String]
    }
    enum CreateOutcome {
        case started(String)
        case blocked(WorkspaceComposerLogic.CreateBlock, params: [String: HostJSON])
        case failed(String)
    }

    private(set) var rows: [String: Row] = [:]
    private(set) var jobs: [String: Job] = [:]
    private(set) var removing: Set<String> = []
    let socketPath: String
    /// Called on the main actor when a create job finishes; ShellView opens the workspace.
    var onCreated: ((CreateResult) -> Void)?
    var onWarning: ((String, String) -> Void)?
    private var cancelFlags: [String: WorktreeJobCancelFlag] = [:]

    init(socketPath: String = HostController.socketPath) { self.socketPath = socketPath }

    func row(_ key: WorkspaceKey) -> Row? {
        guard key.rawValue.hasPrefix("worktree:") else { return nil }
        return rows[String(key.rawValue.dropFirst(9))]
    }
    func job(_ key: WorkspaceKey) -> Job? {
        guard key.rawValue.hasPrefix("worktree:") else { return nil }
        return jobs[String(key.rawValue.dropFirst(9))]
    }

    func observe() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        guard let result = try? await call("worktree.list", ["includeHidden": .bool(false)]) else { return }
        var next: [String: Row] = [:]
        for row in Self.objects(result["worktrees"]) {
            guard let id = row["id"]?.string, let path = row["path"]?.string else { continue }
            next[id] = Row(id: id, repoID: row["repoId"]?.string ?? "", path: path, branch: row["branch"]?.string,
                           state: row["state"]?.string ?? "ready", lastError: row["lastError"]?.string,
                           isMain: row["isMain"] == .bool(true), displayName: row["displayName"]?.string ?? "",
                           comment: row["comment"]?.string ?? "",
                           isSparse: { if case .array(let dirs) = row["sparseDirs"] ?? .null { !dirs.isEmpty } else { false } }(),
                           revealRequested: row["revealRequested"] == .bool(true))
        }
        if next != rows { rows = next }
    }

    // MARK: Create

    func suggestName(repoID: String) async -> String? {
        try? await call("worktree.suggestName", ["repoId": .string(repoID)])["name"]?.string
    }

    func searchRefs(repoID: String, query: String) async -> [WorkspaceComposerLogic.Ref] {
        guard let result = try? await call("repo.searchRefs", ["id": .string(repoID), "query": .string(query), "limit": .number(30)]),
              case .array(let refs) = result["refs"] ?? .null else { return [] }
        return refs.compactMap(WorkspaceComposerLogic.Ref.init)
    }

    /// Validates synchronously on the host; returns once the job starts (the composer closes then).
    func create(_ params: [String: HostJSON], title: String) async -> CreateOutcome {
        do {
            let started = try await call("worktree.create", params)
            guard let id = started["worktreeId"]?.string, let jobID = started["jobId"]?.string else { return .failed("badResponse") }
            jobs[id] = Job(worktreeID: id, jobID: jobID, repoID: params["repoId"]?.string ?? "", title: title, params: params, phase: "resolveBase")
            track(id, jobID: jobID)
            Task { await refresh() }
            return .started(id)
        } catch let failure as Failure {
            if let block = WorkspaceComposerLogic.createBlock(code: failure.code, detail: failure.detail) { return .blocked(block, params: params) }
            return .failed(WorkspaceComposerLogic.message(code: failure.code, detail: failure.detail))
        } catch { return .failed(String(describing: error)) }
    }

    func approveHooks(repoID: String, kind: String, hash: String) async throws {
        _ = try await call("worktree.approveHooks", ["repoId": .string(repoID), "kind": .string(kind), "contentHash": .string(hash)])
    }

    func cancel(_ worktreeID: String) {
        guard jobs[worktreeID] != nil else { return }
        jobs[worktreeID]?.cancelling = true
        cancelFlags[worktreeID]?.set()
    }

    /// Re-issues the original request with a new request id after clearing the failed row.
    func retry(_ worktreeID: String) async -> CreateOutcome {
        let job = jobs[worktreeID]
        let params = job?.params ?? fallbackParams(worktreeID)
        guard let params else { return .failed("The original request is not available. Delete the workspace and create it again.") }
        await discardFailed(worktreeID)
        return await create(params, title: job?.title ?? rows[worktreeID]?.displayName ?? "Workspace")
    }

    /// Removes the row of a failed create (no checkout exists, so nothing on disk is lost).
    func discardFailed(_ worktreeID: String) async {
        jobs.removeValue(forKey: worktreeID)
        if rows[worktreeID] != nil {
            _ = try? await remove(worktreeID, options: WorkspaceComposerLogic.discardFailedOptions)
        }
        await refresh()
    }

    private func fallbackParams(_ id: String) -> [String: HostJSON]? {
        guard let row = rows[id] else { return nil }
        return ["repoId": .string(row.repoID), "name": .string(row.displayName), "createdBy": .string("desktop"), "noParent": .bool(true)]
    }

    private func track(_ id: String, jobID: String) {
        let flag = WorktreeJobCancelFlag(); cancelFlags[id] = flag
        let socket = socketPath
        Task {
            do {
                let value = try await Task.detached { () throws -> HostJSON in
                    let client = try HostClient(socketPath: socket)
                    defer { client.disconnect() }
                    return try client.waitForJob(jobID, isCancelled: { flag.isSet }) { kind, text, progress in
                        Task { @MainActor in self.progress(id, kind: kind, text: text, git: progress) }
                    }
                }.value
                finish(id, result: value)
            } catch HostClientError.detailedHostError(let code, let detail) {
                fail(id, code == "cancelled" ? "Cancelled." : WorkspaceComposerLogic.message(code: code, detail: detail))
            } catch { fail(id, String(describing: error)) }
            cancelFlags.removeValue(forKey: id)
        }
    }

    private func progress(_ id: String, kind: String, text: String, git: (done: Int, total: Int)?) {
        guard var job = jobs[id] else { return }
        if kind == "phase" { job.phase = text }
        job.fraction = max(job.fraction, WorkspaceComposerLogic.progressFraction(phase: job.phase, git: kind == "progress" ? git : nil))
        jobs[id] = job
    }

    private func fail(_ id: String, _ message: String) {
        jobs[id]?.failure = message; jobs[id]?.cancelling = false
        Task { await refresh() }
    }

    private func finish(_ id: String, result: HostJSON) {
        let object = result.object ?? [:], worktree = object["worktree"]?.object ?? [:]
        let title = jobs[id]?.title ?? worktree["displayName"]?.string ?? "Workspace"
        jobs.removeValue(forKey: id)
        var tabs: [(String?, String?)] = []
        for tab in Self.objects(object["defaultTabs"]) { tabs.append((tab["title"]?.string, tab["command"]?.string)) }
        let warnings: [String] = { if case .array(let items) = object["warnings"] ?? .null { items.compactMap(\.string) } else { [] } }()
        if !warnings.isEmpty { onWarning?("Workspace created with warnings", warnings.joined(separator: "\n")) }
        if let path = worktree["path"]?.string {
            onCreated?(CreateResult(worktreeID: id, path: path, title: worktree["displayName"]?.string ?? title,
                setupSessionID: object["setup"]?.object?["sessionId"]?.string, defaultTabs: tabs, warnings: warnings))
        }
        Task { await refresh() }
    }

    // MARK: Remove

    /// Returns the preserved branch name when Git refused to delete an unmerged branch.
    func remove(_ worktreeID: String, options: WorkspaceComposerLogic.RemoveOptions) async throws -> String? {
        removing.insert(worktreeID)
        defer { removing.remove(worktreeID) }
        let started = try await call("worktree.remove", WorkspaceComposerLogic.removeParams(id: worktreeID, options))
        guard let jobID = started["jobId"]?.string else { throw Failure(code: "badResponse", detail: nil) }
        let socket = socketPath
        do {
            let result = try await Task.detached { () throws -> HostJSON in
                let client = try HostClient(socketPath: socket)
                defer { client.disconnect() }
                return try client.waitForJob(jobID)
            }.value
            await refresh()
            return result.object?["preservedBranch"]?.string
        } catch HostClientError.detailedHostError(let code, let detail) {
            await refresh()
            throw Failure(code: code, detail: detail)
        }
    }

    func preservedBranches(repoID: String) async -> [(branch: String, head: String, formerPath: String)] {
        guard let result = try? await call("worktree.preservedBranches", ["repoId": .string(repoID)]),
              case .array(let rows) = result["branches"] ?? .null else { return [] }
        return rows.compactMap(\.object).compactMap { row in
            row["branch"]?.string.map { ($0, row["head"]?.string ?? "", row["formerPath"]?.string ?? "") }
        }
    }

    func deletePreservedBranch(repoID: String, branch: String) async throws {
        _ = try await call("worktree.deletePreservedBranch", ["repoId": .string(repoID), "branch": .string(branch)])
    }

    // MARK: Metadata

    func set(_ worktreeID: String, _ fields: [String: HostJSON]) async throws {
        var params = fields; params["id"] = .string(worktreeID)
        _ = try await call("worktree.set", params)
        await refresh()
    }

    /// `worktree.show`: parent key and whether the checkout is clean.
    func details(_ worktreeID: String) async -> (parent: String?, clean: Bool?) {
        guard let result = try? await call("worktree.show", ["id": .string(worktreeID)]) else { return (nil, nil) }
        let parent = result["lineage"]?.object?["parent"]?.string
        return (parent, { if case .bool(let clean) = result["git"]?.object?["clean"] ?? .null { clean } else { nil } }())
    }

    func repo(_ id: String) async throws -> [String: HostJSON] {
        try await call("repo.show", ["id": .string(id)])["repo"]?.object ?? [:]
    }

    func updateRepo(_ id: String, _ fields: [String: HostJSON]) async throws {
        var params = fields; params["id"] = .string(id)
        _ = try await call("repo.update", params)
    }

    // MARK: Transport

    struct Failure: LocalizedError {
        let code: String
        let detail: String?
        var errorDescription: String? { WorkspaceComposerLogic.message(code: code, detail: detail) }
    }

    private static func objects(_ value: HostJSON?) -> [[String: HostJSON]] {
        guard case .array(let items) = value ?? .null else { return [] }
        return items.compactMap(\.object)
    }

    private func call(_ method: String, _ params: [String: HostJSON]) async throws -> [String: HostJSON] {
        let socket = socketPath
        do {
            return try await Task.detached {
                let client = try HostClient(socketPath: socket)
                defer { client.disconnect() }
                return try client.json(method, params, timeoutMilliseconds: 30_000)
            }.value
        } catch HostClientError.detailedHostError(let code, let detail) { throw Failure(code: code, detail: detail) }
    }
}

/// Cancellation signal read from the detached job poller.
private final class WorktreeJobCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
