import Foundation

public extension HostClient {
    func worktrees(repoID: String? = nil, includeHidden: Bool = false, includeArchived: Bool = false) throws -> [HostJSON] {
        var params: [String: HostJSON] = ["includeHidden": .bool(includeHidden), "includeArchived": .bool(includeArchived)]
        params["repoId"] = repoID.map(HostJSON.string)
        guard case .array(let rows) = try json("worktree.list", params)["worktrees"] else { throw HostRPCError("badResponse") }
        return rows
    }
    func resolveWorktree(_ selector: String, cwd: String? = nil) throws -> HostJSON {
        var params: [String: HostJSON] = ["selector": .string(selector)]; params["cwd"] = cwd.map(HostJSON.string)
        return try json("worktree.resolve", params)["worktree"] ?? .null
    }
    func createWorktree(_ params: [String: HostJSON]) throws -> [String: HostJSON] { try json("worktree.create", params) }
    func removeWorktree(id: String, force: Bool = false, allowFailedArchiveHook: Bool = false) throws -> [String: HostJSON] {
        try json("worktree.remove", ["id": .string(id), "force": .bool(force), "allowFailedArchiveHook": .bool(allowFailedArchiveHook)])
    }
    func setWorktree(id: String, fields: [String: HostJSON]) throws -> HostJSON {
        var p = fields; p["id"] = .string(id); return try json("worktree.set", p)["worktree"] ?? .null
    }
}
