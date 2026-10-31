import Foundation
import Observation
import SmthzCore

/// Host-owned projects and their workspaces (WP-M4-REGISTRY). The host is the single
/// writer; this model polls `repo.list`/`projectGroup.list`/`folderWorkspace.list` and
/// re-reads after every mutation. Blocking socket calls never run on the main actor.
@MainActor @Observable
final class WorkspaceCatalogModel {
    struct Workspace: Identifiable, Equatable {
        var id: String { key.rawValue }
        let key: WorkspaceKey
        var title: String
        var path: String
        var branch: String?
        var isMain: Bool
        var isFolder: Bool
        var repoID: String?
        var isPinned = false
        var isUnread = false
    }
    struct Project: Identifiable, Equatable {
        let id: String
        var title: String
        var path: String
        var kind: String
        var color: String
        var groupID: String?
        var pathMissing: Bool
        var workspaces: [Workspace]
    }
    struct Group: Identifiable, Equatable {
        let id: String
        var name: String
        var color: String?
        var parentPath: String?
        var collapsed: Bool
        var folders: [Workspace]
    }
    struct ScanResult: Equatable {
        var selectedPathKind: String
        var repos: [(path: String, name: String)]
        var truncated: Bool
        var timedOut: Bool
        static func == (a: Self, b: Self) -> Bool {
            a.selectedPathKind == b.selectedPathKind && a.repos.map(\.path) == b.repos.map(\.path)
                && a.truncated == b.truncated && a.timedOut == b.timedOut
        }
    }
    struct HostFailure: LocalizedError {
        let code: String
        let detail: String?
        var errorDescription: String? { detail.map { "\(code): \($0)" } ?? code }
    }

    private(set) var projects: [Project] = []
    private(set) var groups: [Group] = []
    private(set) var loaded = false
    private(set) var lastError: String?
    let socketPath: String

    init(socketPath: String = HostController.socketPath) { self.socketPath = socketPath }

    var allWorkspaces: [Workspace] { projects.flatMap(\.workspaces) + groups.flatMap(\.folders) }
    func workspace(_ key: WorkspaceKey) -> Workspace? { allWorkspaces.first { $0.key == key } }
    func project(containing key: WorkspaceKey) -> Project? { projects.first { $0.workspaces.contains { $0.key == key } } }

    func observe() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        do {
            let socket = socketPath
            let snapshot = try await Task.detached { () throws -> ([String: HostJSON], [String: HostJSON], [String: HostJSON], [String: HostJSON]?) in
                let client = try HostClient(socketPath: socket)
                defer { client.disconnect() }
                let repos = try client.json("repo.list")
                let groups = try client.json("projectGroup.list")
                let folders = try client.json("folderWorkspace.list")
                // Linked worktrees arrive with WP-M4-WORKTREE-HOST; until then each repo shows its main checkout.
                let worktrees = try? client.json("worktree.list", ["includeHidden": .bool(false)])
                return (repos, groups, folders, worktrees)
            }.value
            apply(repos: snapshot.0, groups: snapshot.1, folders: snapshot.2, worktrees: snapshot.3)
            loaded = true
            lastError = nil
        } catch {
            lastError = describe(error)
        }
    }

    private func apply(repos: [String: HostJSON], groups: [String: HostJSON], folders: [String: HostJSON],
                       worktrees: [String: HostJSON]?) {
        let worktreeRows = Self.objects(worktrees?["worktrees"])
        let next = Self.objects(repos["repos"]).compactMap { repo -> Project? in
            guard let id = repo["id"]?.string, let path = repo["path"]?.string else { return nil }
            let title = repo["displayName"]?.string ?? (path as NSString).lastPathComponent
            var cards = worktreeRows.filter { $0["repoId"]?.string == id }.compactMap { row -> Workspace? in
                guard let wid = row["id"]?.string, let wpath = row["path"]?.string else { return nil }
                if row["isVisible"] == .bool(false) || row["isArchived"] == .bool(true) { return nil }
                return Workspace(key: WorkspaceKey(rawValue: "worktree:" + wid), title: row["displayName"]?.string ?? title,
                                 path: wpath, branch: nil, isMain: row["isMain"] == .bool(true), isFolder: false, repoID: id,
                                 isPinned: row["isPinned"] == .bool(true), isUnread: row["isUnread"] == .bool(true))
            }
            if !cards.contains(where: \.isMain), let main = repo["mainWorktreeId"]?.string {
                cards.insert(Workspace(key: WorkspaceKey(rawValue: "worktree:" + main), title: title, path: path, branch: nil,
                                       isMain: true, isFolder: repo["kind"]?.string == "folder", repoID: id), at: 0)
            }
            cards.sort { ($0.isMain ? 0 : 1, $0.title) < ($1.isMain ? 0 : 1, $1.title) }
            return Project(id: id, title: title, path: path, kind: repo["kind"]?.string ?? "git",
                           color: repo["badgeColor"]?.string ?? "#737373", groupID: repo["projectGroupId"]?.string,
                           pathMissing: repo["pathMissing"] == .bool(true), workspaces: cards)
        }
        let folderRows = Self.objects(folders["folderWorkspaces"])
        let nextGroups = Self.objects(groups["groups"]).compactMap { group -> Group? in
            guard let id = group["id"]?.string else { return nil }
            let cards = folderRows.filter { $0["projectGroupId"]?.string == id && $0["isArchived"] != .bool(true) }.compactMap { row -> Workspace? in
                guard let fid = row["id"]?.string, let path = row["folderPath"]?.string else { return nil }
                return Workspace(key: WorkspaceKey(rawValue: "folder:" + fid), title: row["name"]?.string ?? "Folder",
                                 path: path, branch: nil, isMain: false, isFolder: true, repoID: row["sourceRepoId"]?.string,
                                 isPinned: row["isPinned"] == .bool(true), isUnread: row["isUnread"] == .bool(true))
            }
            return Group(id: id, name: group["name"]?.string ?? "Group", color: group["color"]?.string,
                         parentPath: group["parentPath"]?.string, collapsed: group["isCollapsed"] == .bool(true), folders: cards)
        }
        if next != projects { projects = next }
        if nextGroups != self.groups { self.groups = nextGroups }
    }

    // MARK: Mutations (each re-reads the catalog)

    /// Adds a Git repository or plain folder; returns the main workspace key.
    @discardableResult func addRepo(path: String, kind: String = "auto") async throws -> WorkspaceKey? {
        let result = try await call("repo.add", ["path": .string(path), "kind": .string(kind)])
        await refresh()
        return (result["repo"]?.object?["mainWorktreeId"]?.string).map { WorkspaceKey(rawValue: "worktree:" + $0) }
    }

    func scanNested(path: String) async throws -> ScanResult {
        let job = try await call("repo.scanNested", ["path": .string(path)])
        guard let id = job["jobId"]?.string else { throw HostFailure(code: "badResponse", detail: nil) }
        let result = try await wait(id) { _, _ in }
        let object = result.object ?? [:]
        return ScanResult(selectedPathKind: object["selectedPathKind"]?.string ?? "non_git_folder",
                          repos: Self.objects(object["repos"]).compactMap { repo in
                              repo["path"]?.string.map { ($0, repo["displayName"]?.string ?? ($0 as NSString).lastPathComponent) } },
                          truncated: object["truncated"] == .bool(true), timedOut: object["timedOut"] == .bool(true))
    }

    /// Returns per-path statuses (`imported`, `already-known`, `failed`).
    func importNested(parentPath: String, group: Bool, paths: [String]) async throws -> [String: String] {
        let result = try await call("projectGroup.importNested", ["parentPath": .string(parentPath),
            "mode": .string(group ? "group" : "separate"), "paths": .array(paths.map(HostJSON.string))])
        await refresh()
        var statuses: [String: String] = [:]
        for item in Self.objects(result["projects"]) {
            if let path = item["path"]?.string { statuses[path] = item["status"]?.string ?? "failed" }
        }
        return statuses
    }

    /// Runs `repo.clone`; `progress` receives phase/log lines and a 0...1 fraction when Git reports one.
    @discardableResult func clone(url: String, destinationParent: String, name: String?,
                                  isCancelled: @escaping @Sendable () -> Bool,
                                  progress: @escaping @MainActor (String, Double?) -> Void) async throws -> WorkspaceKey? {
        var params: [String: HostJSON] = ["url": .string(url), "destinationParent": .string(destinationParent)]
        if let name, !name.isEmpty { params["name"] = .string(name) }
        let job = try await call("repo.clone", params)
        guard let id = job["jobId"]?.string else { throw HostFailure(code: "badResponse", detail: nil) }
        let result = try await wait(id, isCancelled: isCancelled, progress: progress)
        await refresh()
        return (result.object?["repo"]?.object?["mainWorktreeId"]?.string).map { WorkspaceKey(rawValue: "worktree:" + $0) }
    }

    @discardableResult func create(parentPath: String, name: String, initGit: Bool) async throws -> WorkspaceKey? {
        let result = try await call("repo.create", ["parentPath": .string(parentPath), "name": .string(name), "initGit": .bool(initGit)])
        await refresh()
        return (result["repo"]?.object?["mainWorktreeId"]?.string).map { WorkspaceKey(rawValue: "worktree:" + $0) }
    }

    func removeRepo(_ id: String, force: Bool = false) async throws {
        _ = try await call("repo.remove", ["id": .string(id), "force": .bool(force)])
        await refresh()
    }

    func setGroupCollapsed(_ id: String, _ collapsed: Bool) async {
        _ = try? await call("projectGroup.update", ["id": .string(id), "isCollapsed": .bool(collapsed)])
        await refresh()
    }

    func setFolderFlags(_ id: String, pinned: Bool? = nil, unread: Bool? = nil) async {
        var params: [String: HostJSON] = ["id": .string(id)]
        params["pinned"] = pinned.map(HostJSON.bool); params["unread"] = unread.map(HostJSON.bool)
        _ = try? await call("folderWorkspace.update", params)
        await refresh()
    }

    // MARK: Transport

    private func call(_ method: String, _ params: [String: HostJSON]) async throws -> [String: HostJSON] {
        let socket = socketPath
        do {
            return try await Task.detached {
                let client = try HostClient(socketPath: socket)
                defer { client.disconnect() }
                return try client.json(method, params)
            }.value
        } catch HostClientError.detailedHostError(let code, let detail) { throw HostFailure(code: code, detail: detail) }
    }

    private func wait(_ jobID: String, isCancelled: @escaping @Sendable () -> Bool = { false },
                      progress: @escaping @MainActor (String, Double?) -> Void) async throws -> HostJSON {
        let socket = socketPath
        do {
            return try await Task.detached {
                let client = try HostClient(socketPath: socket)
                defer { client.disconnect() }
                return try client.waitForJob(jobID, isCancelled: isCancelled) { kind, text, fraction in
                    let value = fraction.flatMap { $0.total > 0 ? Double($0.done) / Double($0.total) : nil }
                    Task { @MainActor in progress(kind == "phase" ? text.capitalized : text, value) }
                }
            }.value
        } catch HostClientError.detailedHostError(let code, let detail) { throw HostFailure(code: code, detail: detail) }
    }

    private func describe(_ error: any Error) -> String {
        if case HostClientError.detailedHostError(let code, let detail) = error { return detail.map { "\(code): \($0)" } ?? code }
        return String(describing: error)
    }

    private static func objects(_ value: HostJSON?) -> [[String: HostJSON]] {
        guard case .array(let items) = value ?? .null else { return [] }
        return items.compactMap(\.object)
    }
}
