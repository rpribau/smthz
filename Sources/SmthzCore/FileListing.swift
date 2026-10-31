import Foundation

/// Go to File listing (M4-PLAN §10.2, Orca `R/src/shared/quick-open-filter.ts`): a primary pass that
/// honours ignore rules, then a second pass with the gitignored files. Engine chain: rg → `git ls-files`
/// → bounded FileManager walk for plain folders.
public enum FileListing {
    public struct Result: Equatable, Sendable {
        public var tracked: [String] = []
        public var ignored: [String] = []
        public var truncated = false
        public var engine = ""
    }

    /// Orca `HIDDEN_DIR_BLOCKLIST` + `node_modules`: never listed, not even in the ignored pass.
    public static let prunedDirectories: Set<String> = [
        "node_modules", ".git", ".next", ".nuxt", ".cache", ".stably", ".vscode", ".idea", ".yarn", ".pnpm-store",
        ".terraform", ".docker", ".husky", ".npm", ".npm-global", ".gvfs",
    ]
    public static let walkLimit = 200_000

    static func pruned(_ path: String) -> Bool {
        path.contains(".local/share") || path.split(separator: "/").dropLast().contains { prunedDirectories.contains(String($0)) }
    }

    static func ripgrepGlobs() -> [String] {
        (prunedDirectories.sorted().map { "!**/\($0)" } + ["!**/.local/share"]).flatMap { ["--glob", $0] }
    }

    public static func list(root: URL, ripgrep: String?, control: GitProcessControl,
                            isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> Result {
        if let ripgrep {
            let base = ["--files", "--no-config", "--null", "--hidden"]
            let tracked = try collect(ripgrep, base + ripgrepGlobs() + ["."], root: root, environment: nil, control: control)
            try check(control, isCancelled)
            let all = try collect(ripgrep, base + ["--no-ignore-vcs"] + ripgrepGlobs() + ["."], root: root, environment: nil, control: control)
            let known = Set(tracked)
            return Result(tracked: tracked.sorted(by: order), ignored: all.filter { !known.contains($0) }.sorted(by: order), engine: "ripgrep")
        }
        if FileSearch.isGitWorkTree(root) {
            let env = FileSearch.gitEnvironment()
            let git = ["ls-files", "-z"]
            let tracked = try collect("/usr/bin/git", git + ["--cached", "--others", "--exclude-standard"], root: root,
                                      environment: env, control: control).filter { !pruned($0) }
            try check(control, isCancelled)
            let ignored = try collect("/usr/bin/git", git + ["--others", "--ignored", "--exclude-standard"], root: root,
                                      environment: env, control: control).filter { !pruned($0) }
            var seen = Set<String>()
            return Result(tracked: tracked.filter { seen.insert($0).inserted }.sorted(by: order),
                          ignored: ignored.filter { !seen.contains($0) }.sorted(by: order), engine: "git")
        }
        return try walk(root: root, isCancelled: isCancelled)
    }

    static func order(_ a: String, _ b: String) -> Bool { a.localizedStandardCompare(b) == .orderedAscending }

    static func check(_ control: GitProcessControl, _ isCancelled: () -> Bool) throws {
        if control.wasCancelled || isCancelled() { throw HostRPCError("cancelled") }
    }

    static func collect(_ executable: String, _ arguments: [String], root: URL, environment: [String: String]?,
                        control: GitProcessControl) throws -> [String] {
        var out: [String] = []
        let timedOut = try FileSearch.streamLines(executable, arguments, cwd: root, environment: environment, control: control,
                                                  deadline: Date(timeIntervalSinceNow: 30), separator: 0) { line in
            out.append(FileSearch.relative(String(decoding: line, as: UTF8.self)))
            return true
        }
        if timedOut { throw HostRPCError("limitExceeded", detail: "file listing timed out") }
        return out
    }

    /// Plain folders: regular files only, hidden files included, pruned directories and symlinked
    /// directories skipped, capped at `walkLimit` entries / 10 s (`truncated`).
    static func walk(root: URL, isCancelled: () -> Bool) throws -> Result {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsPackageDescendants]) else {
            throw HostRPCError("invalidPath", detail: root.path)
        }
        var result = Result(engine: "walk")
        let deadline = Date(timeIntervalSinceNow: 10)
        let rootRef = FileRoot(url: root, key: "")
        var inspected = 0
        for case let url as URL in walker {
            if isCancelled() { throw HostRPCError("cancelled") }
            inspected += 1
            if inspected > walkLimit || Date() > deadline { result.truncated = true; break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if prunedDirectories.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true || values.isSymbolicLink == true else { continue }
            result.tracked.append(FileOperations.relativePath(of: url, in: rootRef))
        }
        result.tracked.sort(by: order)
        return result
    }
}
