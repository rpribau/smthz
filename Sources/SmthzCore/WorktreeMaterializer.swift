import Foundation
import Darwin

public enum WorktreeMaterializer {
    /// Only ignored inputs are materialized. Destination ancestors are checked after
    /// resolving links, so a tracked symlink cannot redirect a copy outside the checkout.
    public static func materialize(root: String, destination: String, sharedPaths: [String] = [],
                                   byteBudget: Int64 = WorktreeInclude.maxCopyBytes,
                                   entryBudget: Int = WorktreeInclude.maxCopyEntries,
                                   context: HostJobContext? = nil) throws -> [String] {
        let fm = FileManager.default, git = GitService()
        var warnings: [String] = [], bytes: Int64 = 0, entries = 0
        let file = SmthzConfigLoader.load(repoRoot: root), config = file?.config
        warnings += config?.diagnostics ?? []
        if case .failure(let error) = file?.result { warnings.append("Configuration ignored: \(error)") }
        let include = WorktreeInclude.load(repoRoot: root)
        warnings += include?.warnings ?? []
        func exists(_ path: String) -> Bool { var info = stat(); return lstat(path, &info) == 0 }
        func ignored(_ path: String) throws -> Bool {
            // check-ignore accepts literal filenames, but rejects Git's literal pathspec magic.
            try git.worktreeGit(["--no-literal-pathspecs", "check-ignore", "--quiet", "--", path], at: root, context: context, allowFailure: true).code == 0
        }
        func copy(_ source: String, _ target: String, top: Bool, cloneOnly: Bool) throws {
            try context?.checkCancellation()
            guard entries < entryBudget else { throw HostRPCError("materializeBudget") }
            var info = stat()
            guard (top ? stat(source, &info) : lstat(source, &info)) == 0 else { return }
            entries += 1
            if info.st_mode & S_IFMT == S_IFDIR {
                try fm.createDirectory(atPath: target, withIntermediateDirectories: false)
                for child in try fm.contentsOfDirectory(atPath: source) {
                    try copy(source + "/" + child, target + "/" + child, top: false, cloneOnly: cloneOnly)
                }
            } else if info.st_mode & S_IFMT == S_IFLNK {
                try fm.createSymbolicLink(atPath: target, withDestinationPath: fm.destinationOfSymbolicLink(atPath: source))
            } else if info.st_mode & S_IFMT == S_IFREG {
                let input = top ? try WorkspaceStore.canonicalPath(source) : source
                if clonefile(input, target, 0) != 0 {
                    if cloneOnly { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    guard info.st_size <= byteBudget - bytes else { throw HostRPCError("materializeBudget") }
                    bytes += info.st_size
                    try fm.copyItem(atPath: input, toPath: target)
                }
            }
        }
        let yaml = config?.sharedDirectories ?? []
        let inputs = sharedPaths.map { ($0, 0) } + yaml.map { ($0, 1) } + (include?.candidates ?? []).map { ($0, 2) }
        for (relative, kind) in inputs {
            try context?.checkCancellation()
            guard WorktreeInclude.isSafe(relative), !relative.split(separator: "/").contains(".") else {
                warnings.append("Skipping unsafe shared path \(relative)"); continue
            }
            let source = root + "/" + relative, target = destination + "/" + relative
            guard exists(source), !exists(target), try ignored(relative) else { continue }
            let parent = URL(fileURLWithPath: target).deletingLastPathComponent()
            guard WorkspaceSelectors.contains(root: try WorkspaceStore.canonicalPath(destination), path: try WorktreeCreator.canonicalFuturePath(parent.path)) else {
                warnings.append("Skipping destination outside worktree: \(relative)"); continue
            }
            do {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                if kind == 1 {
                    var info = stat()
                    guard stat(source, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
                    try fm.createSymbolicLink(atPath: target, withDestinationPath: source)
                } else {
                    do { try copy(source, target, top: true, cloneOnly: kind == 0) }
                    catch {
                        try? fm.removeItem(atPath: target)
                        if kind == 0, !(error is HostRPCError) {
                            try fm.createSymbolicLink(atPath: target, withDestinationPath: source)
                        } else { throw error }
                    }
                }
            } catch {
                try context?.checkCancellation()
                warnings.append("Skipping \(relative): \(error)")
            }
        }
        return warnings
    }
}
