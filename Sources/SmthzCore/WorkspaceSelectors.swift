import Foundation

public struct WorkspaceSelectorCandidate: Equatable, Sendable {
    public let id: String
    public let path: String
    public let name: String
    public let branch: String?
    public let repoID: String
    public init(id: String, path: String, name: String, branch: String? = nil, repoID: String) {
        self.id = id; self.path = path; self.name = name; self.branch = branch; self.repoID = repoID
    }
}

public enum WorkspaceSelectors {
    public static func contains(root: String, path: String) -> Bool {
        root == path || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    public static func resolve(_ selector: String, candidates: [WorkspaceSelectorCandidate], cwd: String? = nil,
                               repository: Bool = false) throws -> WorkspaceSelectorCandidate {
        let matches: [WorkspaceSelectorCandidate]
        if selector == "active" || selector == "current" {
            guard !repository, let cwd else { throw HostRPCError("badRequest", detail: "cwd is required") }
            matches = try pathMatches(cwd, candidates: candidates)
        } else {
            let parts = selector.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[1].isEmpty else { throw HostRPCError("badRequest", detail: "invalid selector") }
            let value = String(parts[1])
            switch parts[0] {
            case "id": matches = candidates.filter { $0.id == value.lowercased() }
            case "path": matches = try pathMatches(value, candidates: candidates)
            case "name": matches = candidates.filter { $0.name.caseInsensitiveCompare(value) == .orderedSame }
            case "branch" where !repository: matches = candidates.filter { $0.branch == value }
            default: throw HostRPCError("badRequest", detail: "unsupported selector")
            }
        }
        guard !matches.isEmpty else { throw HostRPCError("notFound") }
        guard matches.count == 1 else {
            throw HostRPCError("badRequest", detail: "ambiguous selector: " + matches.map { "id:\($0.id) (\($0.name), \($0.path))" }.joined(separator: ", "))
        }
        return matches[0]
    }
    private static func pathMatches(_ path: String, candidates: [WorkspaceSelectorCandidate]) throws -> [WorkspaceSelectorCandidate] {
        let canonical = try WorkspaceStore.canonicalPath(path)
        let matches = candidates.filter { contains(root: $0.path, path: canonical) }
        let length = matches.map { $0.path.count }.max()
        return matches.filter { $0.path.count == length }
    }
    public static func defaultRepository(cwd: String?, worktrees: [WorkspaceSelectorCandidate]) throws -> String {
        guard let cwd, let current = try? resolve("current", candidates: worktrees, cwd: cwd) else {
            throw HostRPCError("badRequest", detail: "pass --repo")
        }
        return current.repoID
    }
}
