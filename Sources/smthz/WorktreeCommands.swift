import Foundation
import SmthzCore

enum WorktreeCommands {
    static func run(flags: CLIFlags, client: HostClient) throws -> [String: HostJSON] {
        let verb = flags.positional.first ?? "list"
        var p: [String: HostJSON] = [:]
        if let raw = flags.values["limit"] { guard let n = Double(raw) else { throw HostRPCError("badRequest") }; p["limit"] = .number(n) }
        if flags.values["repo"] != nil { p["repoId"] = .string(try RepoCommands.repoID(flags, client)) }
        func bool(_ key: String) -> Bool { flags.values[key] == "true" || flags.positional.contains("--" + key) }
        func resolve() throws -> String {
            let selector = flags.values["worktree"] ?? "current"
            let value = try CLICommon.call(client, "worktree.resolve", ["selector": .string(selector), "cwd": .string(FileManager.default.currentDirectoryPath)])
            guard let id = value["worktree"]?.object?["id"]?.string else { throw HostRPCError("notFound") }; return id
        }
        let method: String
        switch verb {
        case "list":
            p["includeHidden"] = .bool(bool("include-hidden")); p["includeArchived"] = .bool(bool("include-archived")); method = "worktree.list"
        case "show": p["id"] = .string(try resolve()); method = "worktree.show"
        case "current":
            return try CLICommon.call(client, "worktree.resolve", ["selector": .string("current"), "cwd": .string(FileManager.default.currentDirectoryPath)])
        case "ps": method = "worktree.ps"
        case "create":
            if p["repoId"] == nil {
                let current = try CLICommon.call(client, "worktree.resolve", ["selector": .string("current"), "cwd": .string(FileManager.default.currentDirectoryPath)])
                p["repoId"] = current["worktree"]?.object?["repoId"]
            }
            if let name = flags.values["name"] { p["name"] = .string(name) }
            else {
                let suggestion = try CLICommon.call(client, "worktree.suggestName", p)
                p["name"] = suggestion["name"]; p["nameWasGenerated"] = .bool(true)
            }
            for (flag, key) in ["branch": "branchName", "display-name": "displayName", "comment": "comment", "setup": "setup"] { p[key] = flags.values[flag].map(HostJSON.string) }
            if bool("run-hooks"), p["setup"] == nil { p["setup"] = .string("run") }
            p["revealRequested"] = .bool(bool("activate") || bool("run-hooks"))
            if let ref = flags.values["base-branch"] { p["startFrom"] = .object(["kind": .string("base"), "ref": .string(ref)]) }
            if let ref = flags.values["commit"] { p["startFrom"] = .object(["kind": .string("commit"), "ref": .string(ref)]) }
            if let dirs = flags.values["sparse-directories"] { p["sparse"] = .object(["directories": .array(dirs.split(separator: ",").map { .string(String($0)) })]) }
            if let parent = flags.values["parent-worktree"] {
                if parent.hasPrefix("folder:") { p["parentId"] = .string(parent) }
                else { p["parentId"] = try CLICommon.call(client, "worktree.resolve", ["selector": .string(parent), "cwd": .string(FileManager.default.currentDirectoryPath)])["worktree"]?.object?["id"] }
            } else if !bool("no-parent"), let current = try? CLICommon.call(client, "worktree.resolve", ["selector": .string("current"), "cwd": .string(FileManager.default.currentDirectoryPath)]) {
                if current["worktree"]?.object?["repoId"] == p["repoId"] { p["parentId"] = current["worktree"]?.object?["id"]; p["parentInferred"] = .bool(true) }
            }
            p["noParent"] = .bool(bool("no-parent")); method = "worktree.create"
        case "set":
            p["id"] = .string(try resolve())
            for (flag, key) in ["display-name": "displayName", "comment": "comment", "workspace-status": "workspaceStatus"] { p[key] = flags.values[flag].map(HostJSON.string) }
            for (flag, key) in ["unread": "unread", "pinned": "pinned", "archived": "archived", "visible": "visible"] {
                if flags.values[flag] != nil { p[key] = .bool(bool(flag)) }
            }
            for (flag, key) in ["sort-order": "sortOrder", "manual-order": "manualOrder"] {
                if let value = flags.values[flag] { guard let n = Double(value), n.isFinite else { throw HostRPCError("badRequest") }; p[key] = .number(n) }
            }
            if let parent = flags.values["parent-worktree"] {
                p["parentId"] = parent.hasPrefix("folder:") ? .string(parent) : try CLICommon.call(client, "worktree.resolve", ["selector": .string(parent), "cwd": .string(FileManager.default.currentDirectoryPath)])["worktree"]?.object?["id"]
            }
            if bool("no-parent") { p["noParent"] = .bool(true) }
            if bool("read") { p["unread"] = .bool(false) }
            method = "worktree.set"
        case "rm", "remove", "delete":
            p["id"] = .string(try resolve()); p["force"] = .bool(bool("force"))
            p["allowFailedArchiveHook"] = .bool(bool("allow-failed-archive-hook"))
            p["runHooks"] = .bool(flags.values["run-hooks"] != "false")
            p["deleteBranch"] = .bool(flags.values["delete-branch"] != "false")
            p["closeSessions"] = .bool(flags.values["close-sessions"] != "false"); method = "worktree.remove"
        default: throw HostRPCError("badRequest", detail: "worktree list|show|current|create|set|rm|ps")
        }
        let response = try CLICommon.call(client, method, p)
        if let job = response["jobId"]?.string { return try CLICommon.waitJob(job, client: client) }
        var result = response; result.removeValue(forKey: "ok"); return result
    }
}
