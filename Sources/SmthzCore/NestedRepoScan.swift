import Foundation

/// Breadth-first discovery of sibling repositories under a folder, with the limits of
/// Orca's `nested-repo-scan-rules.ts`: depth 1...8 (default 3), repos 1...500 (default 100),
/// optional timeout 500...30,000 ms. Uses `.git`/bare markers, never spawns Git per directory.
/// Reduction: per-folder `.gitignore` rules are not applied (only the fixed skip lists).
public struct NestedRepoScan: Sendable {
    public struct Candidate: Equatable, Sendable {
        public let path: String
        public let displayName: String
        public let depth: Int
    }
    public struct Result: Equatable, Sendable {
        public var selectedPathKind: String
        public var repos: [Candidate]
        public var truncated: Bool
        public var timedOut: Bool
        public var stopped: Bool
        public var json: HostJSON {
            .object(["selectedPathKind": .string(selectedPathKind), "truncated": .bool(truncated),
                     "timedOut": .bool(timedOut), "stopped": .bool(stopped),
                     "repos": .array(repos.map { .object(["path": .string($0.path), "displayName": .string($0.displayName),
                                                          "depth": .number(Double($0.depth))]) })])
        }
    }
    public let maxDepth: Int
    public let maxRepos: Int
    public let timeoutMs: Int?

    public init(maxDepth: Double? = nil, maxRepos: Double? = nil, timeoutMs: Double? = nil) {
        func clamp(_ value: Double?, _ low: Int, _ high: Int, _ fallback: Int?) -> Int? {
            guard let value, value.isFinite else { return fallback }
            return max(low, min(high, Int(value.rounded(.down))))
        }
        self.maxDepth = clamp(maxDepth, 1, 8, 3)!
        self.maxRepos = clamp(maxRepos, 1, 500, 100)!
        self.timeoutMs = clamp(timeoutMs, 500, 30_000, nil)
    }

    static let skipped: Set<String> = ["node_modules", ".next", "dist", "build", ".cache", "vendor", "__pycache__", ".turbo", ".parcel-cache"]
    static let vcsMetadata: Set<String> = [".git", ".svn", ".hg", ".jj", ".sl", ".repo", "CVS"]

    public static func hasGitMarker(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path + "/.git") { return true }
        let head = FileManager.default.fileExists(atPath: path + "/HEAD", isDirectory: &isDirectory) && !isDirectory.boolValue
        guard head else { return false }
        return [path + "/objects", path + "/refs"].allSatisfy {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    public func scan(_ root: String, cancelled: () -> Bool = { false },
                     progress: (Candidate) -> Void = { _ in }) -> Result {
        let started = Date()
        var result = Result(selectedPathKind: "non_git_folder", repos: [], truncated: false, timedOut: false, stopped: false)
        if Self.hasGitMarker(root) { result.selectedPathKind = "git_repo"; return result }
        func expired() -> Bool { timeoutMs.map { Date().timeIntervalSince(started) * 1_000 > Double($0) } ?? false }
        var queue: [(path: String, depth: Int)] = [(root, 0)]
        var next = 0
        traversal: while next < queue.count {
            if result.repos.count >= maxRepos { result.truncated = true; break }
            if expired() { result.timedOut = true; break }
            if cancelled() { result.stopped = true; break }
            let folder = queue[next]; next += 1
            guard folder.depth <= maxDepth,
                  let entries = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder.path, isDirectory: true),
                      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { continue }
            let directories = entries.filter {
                let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }.map(\.lastPathComponent).sorted { $0.compare($1, locale: .current) == .orderedAscending }
            for name in directories {
                if result.repos.count >= maxRepos { result.truncated = true; break traversal }
                if expired() { result.timedOut = true; break traversal }
                if cancelled() { result.stopped = true; break traversal }
                if Self.vcsMetadata.contains(name) || Self.skipped.contains(name) || (folder.depth > 0 && name.hasPrefix(".")) { continue }
                let child = folder.path == "/" ? "/" + name : folder.path + "/" + name
                if Self.hasGitMarker(child) {
                    let candidate = Candidate(path: child, displayName: name, depth: folder.depth + 1)
                    result.repos.append(candidate)
                    progress(candidate)
                    continue
                }
                if folder.depth < maxDepth { queue.append((child, folder.depth + 1)) }
            }
        }
        return result
    }
}
