import Foundation

/// `.worktreeinclude`: gitignored paths of the primary checkout copied privately into a new
/// worktree (M4-PLAN §7.3, Orca `src/main/git/worktree-include-file.ts`). This file only parses;
/// existence, `git check-ignore` and copying belong to the worktree materializer.
public enum WorktreeInclude {
    public static let fileName = ".worktreeinclude"
    public static let maxFileBytes = 256 * 1024
    public static let maxCandidates = 1_000
    /// Byte budget for ordinary (non-clone) copies per new worktree.
    public static let maxCopyBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// Entry budget per new worktree; clones count too.
    public static let maxCopyEntries = 50_000

    public struct Parsed: Equatable, Sendable {
        /// Literal repo-relative paths in file order, at most `maxCandidates`.
        public var candidates: [String]
        public var warnings: [String]
    }

    /// One literal path per line; blank and `#` lines ignored, no inline comments.
    public static func parse(_ content: String) -> Parsed {
        var seen: Set<String> = []
        var parsed = Parsed(candidates: [], warnings: [])
        for rawLine in content.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            var entry = line.replacingOccurrences(of: "\\", with: "/")
            if entry.hasPrefix("./") { entry.removeFirst(2) }
            while entry.hasSuffix("/") { entry.removeLast() }
            guard !entry.isEmpty, seen.insert(entry).inserted else { continue }
            if parsed.candidates.count >= maxCandidates {
                parsed.warnings.append("\(fileName) lists more than \(maxCandidates) entries; ignoring the rest")
                break
            }
            if entry.hasPrefix("!") || entry.contains("*") || entry.contains("?") {
                parsed.warnings.append("Skipping unsupported \(fileName) pattern \"\(entry)\" (only literal paths are supported)")
                continue
            }
            guard isSafe(entry) else {
                parsed.warnings.append("Skipping unsafe \(fileName) path \"\(entry)\"")
                continue
            }
            parsed.candidates.append(entry)
        }
        return parsed
    }

    /// Repo-relative, no `..`, no empty segment, not inside `.git`.
    /// Orca rejects only a leading `.git`; any `.git` segment is refused here (M4-PLAN §7.3).
    public static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !SmthzConfigParser.hasDrivePrefix(path) else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return !segments.contains { $0.isEmpty || $0 == ".." || $0 == ".git" }
    }

    /// Reads `<repoRoot>/.worktreeinclude`; nil when missing, not a regular file (symlinks are
    /// not followed, as Orca's `lstat`), over 256 KiB, or not UTF-8.
    public static func load(repoRoot: String) -> Parsed? {
        let path = (repoRoot as NSString).appendingPathComponent(fileName)
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, Int(info.st_size) <= maxFileBytes,
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }
}
