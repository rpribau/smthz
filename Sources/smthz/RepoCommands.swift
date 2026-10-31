import Foundation
import SmthzCore

/// `smthz repo list|add|show|set|set-base-ref|search-refs`, `smthz project list` (M4-PLAN §6.1).
enum RepoCommands {
    static func run(command: String, flags: CLIFlags, client: HostClient) throws -> [String: HostJSON] {
        let verb = flags.positional.first ?? "list"
        if command == "project" {
            guard verb == "list" else { throw HostRPCError("badRequest", detail: "usage: smthz project list") }
            let repos = try CLICommon.call(client, "repo.list")["repos"] ?? .array([])
            let groups = try CLICommon.call(client, "projectGroup.list")["groups"] ?? .array([])
            return ["repos": repos, "groups": groups]
        }
        switch verb {
        case "list": return strip(try CLICommon.call(client, "repo.list"))
        case "add":
            guard let path = flags.values["path"] ?? flags.positional.dropFirst().first else {
                throw HostRPCError("badRequest", detail: "pass --path")
            }
            var params: [String: HostJSON] = ["path": .string(absolute(path))]
            if let kind = flags.values["kind"] { params["kind"] = .string(kind) }
            if let name = flags.values["display-name"] { params["displayName"] = .string(name) }
            return strip(try CLICommon.call(client, "repo.add", params))
        case "show":
            return strip(try CLICommon.call(client, "repo.show", ["id": .string(try repoID(flags, client))]))
        case "set":
            var params: [String: HostJSON] = ["id": .string(try repoID(flags, client))]
            if let visibility = flags.values["external-worktree-visibility"] { params["externalWorktreeVisibility"] = .string(visibility) }
            if let name = flags.values["display-name"] { params["displayName"] = .string(name) }
            if let color = flags.values["badge-color"] { params["badgeColor"] = .string(color) }
            guard params.count > 1 else { throw HostRPCError("badRequest", detail: "nothing to set") }
            return strip(try CLICommon.call(client, "repo.update", params))
        case "set-base-ref":
            guard let ref = flags.values["ref"] else { throw HostRPCError("badRequest", detail: "pass --ref") }
            return strip(try CLICommon.call(client, "repo.update", ["id": .string(try repoID(flags, client)), "worktreeBaseRef": .string(ref)]))
        case "search-refs":
            var params: [String: HostJSON] = ["id": .string(try repoID(flags, client)), "query": .string(flags.values["query"] ?? "")]
            if let limit = flags.values["limit"].flatMap(Double.init) { params["limit"] = .number(limit) }
            return strip(try CLICommon.call(client, "repo.searchRefs", params))
        default:
            throw HostRPCError("badRequest", detail: "usage: smthz repo list|add|show|set|set-base-ref|search-refs")
        }
    }

    /// Repo selectors: `id:`, `path:`, `name:` (a bare value is treated as a path when it starts with `/`, else a name).
    static func repoID(_ flags: CLIFlags, _ client: HostClient) throws -> String {
        guard var selector = flags.values["repo"] else { throw HostRPCError("badRequest", detail: "pass --repo") }
        if !selector.contains(":") { selector = (selector.hasPrefix("/") || selector.hasPrefix(".") ? "path:" : "name:") + selector }
        if selector.hasPrefix("path:") { selector = "path:" + absolute(String(selector.dropFirst(5))) }
        guard case .array(let repos) = try CLICommon.call(client, "repo.list")["repos"] ?? .null else { return "" }
        let candidates = repos.compactMap { $0.object }.compactMap { repo -> WorkspaceSelectorCandidate? in
            guard let id = repo["id"]?.string, let path = repo["path"]?.string else { return nil }
            return WorkspaceSelectorCandidate(id: id, path: path, name: repo["displayName"]?.string ?? "", repoID: id)
        }
        return try WorkspaceSelectors.resolve(selector, candidates: candidates, repository: true).id
    }
    private static func absolute(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
    }
    private static func strip(_ result: [String: HostJSON]) -> [String: HostJSON] {
        var result = result; result.removeValue(forKey: "ok"); return result
    }
}
