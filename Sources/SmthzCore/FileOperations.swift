import Darwin
import Foundation

/// A directory the file methods may touch (M4-PLAN §5.1): a registered repo, worktree or folder
/// workspace path, or (interim, like `GitWriteRPC.acceptRoot`) the exact top level of a Git work tree.
/// C `stat` (follows symlinks); `FileOperations.stat` shadows the name inside the enum.
private func followStat(_ path: String, _ info: inout Darwin.stat) -> Int32 { stat(path, &info) }

public struct FileRoot: Equatable, Sendable {
    public let url: URL
    /// Gate key for mutations: repo id, `folder:<id>`, or `gitdir:<common dir>`.
    public let key: String
    public var path: String { url.path }
}

public struct FileEntry: Equatable, Sendable {
    public enum Kind: String, Sendable { case file, dir, symlink }
    public let name: String
    public let kind: Kind
    /// For symlinks: whether the target is a directory (inside or outside the root).
    public let targetIsDirectory: Bool
    public let size: Int64
    public let mtime: Double
}

/// Host-side file operations confined to one root. Paths are root-relative; `..`, absolute paths,
/// `.git` and anything whose resolved parent leaves the root are refused (`pathOutsideRoot`).
/// Deletes always go to the Trash; nothing here overwrites an existing item.
public enum FileOperations {
    public static let listLimit = 5_000

    public static func acceptRoot(_ path: String, store: WorkspaceStore) throws -> FileRoot {
        let canonical = try WorkspaceStore.canonicalPath(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HostRPCError("invalidPath", detail: "not a directory")
        }
        let url = URL(fileURLWithPath: canonical, isDirectory: true)
        let registered = try store.query("""
            SELECT repo_id AS id FROM worktrees WHERE path=?1
            UNION ALL SELECT id FROM repos WHERE path=?1
            UNION ALL SELECT 'folder:' || id FROM folder_workspaces WHERE folder_path=?1
            """, [.text(canonical)]).first?["id"]?.string
        if let registered { return FileRoot(url: url, key: registered) }
        let git = try GitWriteRPC.acceptRoot(canonical, store: store)
        return FileRoot(url: git.url, key: git.repositoryKey)
    }

    /// Splits and checks a root-relative path. An empty path (or ".") is the root itself.
    public static func components(_ path: String) throws -> [String] {
        guard !path.hasPrefix("/"), !path.utf8.contains(0), !path.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            throw HostRPCError("invalidPath", detail: path)
        }
        let parts = path.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !parts.contains(".."), parts.first != ".git" else { throw HostRPCError("pathOutsideRoot", detail: path) }
        return parts
    }

    /// Resolves `path` under `root`. The parent must resolve inside root; with `followLeaf` the item
    /// itself must too (listing a symlinked directory that points outside is refused).
    public static func resolve(_ path: String, in root: FileRoot, followLeaf: Bool = false,
                               allowRoot: Bool = false) throws -> URL {
        let parts = try components(path)
        if parts.isEmpty {
            guard allowRoot else { throw HostRPCError("invalidPath", detail: "root") }
            return root.url
        }
        let parent = parts.dropLast().reduce(root.url) { $0.appendingPathComponent($1) }
        guard let resolvedParent = try? WorkspaceStore.canonicalPath(parent.path) else {
            throw HostRPCError("notFound", detail: parts.dropLast().joined(separator: "/"))
        }
        guard inside(resolvedParent, root) else { throw HostRPCError("pathOutsideRoot", detail: path) }
        let url = URL(fileURLWithPath: resolvedParent).appendingPathComponent(parts.last!)
        if followLeaf, let resolved = try? WorkspaceStore.canonicalPath(url.path), !inside(resolved, root) {
            throw HostRPCError("pathOutsideRoot", detail: path)
        }
        return url
    }

    static func inside(_ path: String, _ root: FileRoot) -> Bool {
        path == root.path || path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    public static func relativePath(of url: URL, in root: FileRoot) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    // MARK: Reads

    public static func entry(at url: URL) throws -> FileEntry {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { throw posixError(url.lastPathComponent) }
        let type = info.st_mode & S_IFMT
        let kind: FileEntry.Kind = type == S_IFLNK ? .symlink : type == S_IFDIR ? .dir : .file
        var target = Darwin.stat()
        let targetIsDirectory = kind == .symlink && followStat(url.path, &target) == 0 && (target.st_mode & S_IFMT) == S_IFDIR
        let mtime = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
        return FileEntry(name: url.lastPathComponent, kind: kind, targetIsDirectory: targetIsDirectory,
                         size: Int64(info.st_size), mtime: mtime)
    }

    /// Directories (and symlinks to directories) first, then Finder-style natural order.
    public static func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted { a, b in
            let ad = a.kind == .dir || a.targetIsDirectory, bd = b.kind == .dir || b.targetIsDirectory
            if ad != bd { return ad }
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.name < b.name : order == .orderedAscending
        }
    }

    public static func list(_ path: String, in root: FileRoot) throws -> (entries: [FileEntry], truncated: Bool) {
        let url = try resolve(path, in: root, followLeaf: true, allowRoot: true)
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: url.path) } catch {
            throw HostRPCError(FileManager.default.fileExists(atPath: url.path) ? "invalidPath" : "notFound", detail: path)
        }
        var entries: [FileEntry] = []
        for name in names where name != ".git" {
            if let entry = try? entry(at: url.appendingPathComponent(name)) { entries.append(entry) }
        }
        let sorted = sorted(entries)
        return (Array(sorted.prefix(listLimit)), sorted.count > listLimit)
    }

    public static func stat(_ path: String, in root: FileRoot) throws -> FileEntry {
        let url = try resolve(path, in: root, allowRoot: true)
        do { return try entry(at: url) } catch { throw HostRPCError("notFound", detail: path) }
    }

    // MARK: Mutations

    public static func createFile(_ path: String, in root: FileRoot) throws {
        let url = try resolve(path, in: root)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posixError(path) }
        close(fd)
    }

    public static func createDirectory(_ path: String, in root: FileRoot) throws {
        let url = try resolve(path, in: root)
        guard mkdir(url.path, 0o755) == 0 else { throw posixError(path) }
    }

    /// Moves within the root; never replaces an existing item. A case-only rename of the same
    /// item (case-insensitive APFS) is allowed.
    public static func rename(_ from: String, to: String, in root: FileRoot) throws {
        let source = try resolve(from, in: root), destination = try resolve(to, in: root)
        guard lstatExists(source) else { throw HostRPCError("notFound", detail: from) }
        if source.path != destination.path, source.path.lowercased() == destination.path.lowercased(),
           sameItem(source, destination) {
            guard Darwin.rename(source.path, destination.path) == 0 else { throw posixError(to) }
            return
        }
        if destination.path.hasPrefix(source.path + "/") { throw HostRPCError("invalidPath", detail: "into itself") }
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw posixError(to) }
    }

    /// Clones when the volume supports it, else copies; symlinks are copied as links.
    public static func copy(_ from: String, to: String, in root: FileRoot) throws {
        let source = try resolve(from, in: root), destination = try resolve(to, in: root)
        guard lstatExists(source) else { throw HostRPCError("notFound", detail: from) }
        if destination.path.hasPrefix(source.path + "/") { throw HostRPCError("invalidPath", detail: "into itself") }
        try copyItem(source, to: destination, label: to)
    }

    static func copyItem(_ source: URL, to destination: URL, label: String) throws {
        guard !lstatExists(destination) else { throw HostRPCError("alreadyExists", detail: label) }
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            let error = posixError(label)
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Moves the item (not a symlink's target) to the Trash and returns where it landed.
    public static func trash(_ path: String, in root: FileRoot) throws -> URL {
        let url = try resolve(path, in: root)
        guard lstatExists(url) else { throw HostRPCError("notFound", detail: path) }
        var landed: NSURL?
        do { try FileManager.default.trashItem(at: url, resultingItemURL: &landed) } catch {
            throw HostRPCError("trashFailed", detail: error.localizedDescription)
        }
        guard let landed = landed as URL? else { throw HostRPCError("trashFailed", detail: path) }
        return landed
    }

    /// Undo of `trash`: moves an item that is inside a Trash folder back to `path` (never overwrites).
    public static func restore(trashed: String, to path: String, in root: FileRoot) throws {
        guard trashed.hasPrefix("/"), isInTrash(trashed) else { throw HostRPCError("invalidPath", detail: "not in the Trash") }
        let destination = try resolve(path, in: root)
        guard lstatExists(URL(fileURLWithPath: trashed)) else { throw HostRPCError("notFound", detail: trashed) }
        if renamex_np(trashed, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
        guard errno == EXDEV else { throw posixError(path) }
        try copyItem(URL(fileURLWithPath: trashed), to: destination, label: path)
        try? FileManager.default.removeItem(atPath: trashed)
    }

    static func isInTrash(_ path: String) -> Bool {
        guard !path.split(separator: "/").contains(".."),
              let resolvedParent = try? WorkspaceStore.canonicalPath((path as NSString).deletingLastPathComponent) else { return false }
        var trashes: [String] = []
        if let user = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false),
           let canonical = try? WorkspaceStore.canonicalPath(user.path) { trashes.append(canonical) }
        if resolvedParent.contains("/.Trashes/\(getuid())") { return true }
        return trashes.contains { resolvedParent == $0 || resolvedParent.hasPrefix($0 + "/") }
    }

    /// Copies absolute `sources` (e.g. a Finder drop) into `destDir`; a name clash gets a
    /// "name copy" suffix. Returns the created root-relative paths.
    public static func importExternal(_ sources: [String], into destDir: String, in root: FileRoot) throws -> [String] {
        let directory = try resolve(destDir, in: root, followLeaf: true, allowRoot: true)
        var created: [String] = []
        for source in sources {
            guard source.hasPrefix("/"), !source.utf8.contains(0) else { throw HostRPCError("invalidPath", detail: source) }
            let sourceURL = URL(fileURLWithPath: source)
            guard lstatExists(sourceURL) else { throw HostRPCError("notFound", detail: source) }
            if let canonical = try? WorkspaceStore.canonicalPath(source), canonical == directory.path || directory.path.hasPrefix(canonical + "/") {
                throw HostRPCError("invalidPath", detail: "into itself")
            }
            let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            let name = duplicateName(for: sourceURL.lastPathComponent, existing: existing, always: false)
            let destination = directory.appendingPathComponent(name)
            try copyItem(sourceURL, to: destination, label: name)
            created.append(relativePath(of: destination, in: root))
        }
        return created
    }

    /// Finder-style copy name: `a.txt` → `a copy.txt` → `a copy 2.txt`. With `always: false`
    /// the original name is returned when it is free.
    public static func duplicateName(for name: String, existing: Set<String>, always: Bool = true) -> String {
        if !always && !existing.contains(name) { return name }
        let ext = (name as NSString).pathExtension
        let isDotfile = name.hasPrefix(".") && !name.dropFirst().contains(".")
        let base = ext.isEmpty || isDotfile ? name : (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty || isDotfile ? "" : "." + ext
        var candidate = "\(base) copy\(suffix)"
        var index = 2
        while existing.contains(candidate) { candidate = "\(base) copy \(index)\(suffix)"; index += 1 }
        return candidate
    }

    // MARK: Helpers

    static func lstatExists(_ url: URL) -> Bool {
        var info = Darwin.stat()
        return lstat(url.path, &info) == 0
    }

    static func sameItem(_ a: URL, _ b: URL) -> Bool {
        var x = Darwin.stat(), y = Darwin.stat()
        return lstat(a.path, &x) == 0 && lstat(b.path, &y) == 0 && x.st_ino == y.st_ino && x.st_dev == y.st_dev
    }

    static func posixError(_ detail: String) -> HostRPCError {
        let code = errno
        switch code {
        case EEXIST, ENOTEMPTY: return HostRPCError("alreadyExists", detail: detail)
        case ENOENT: return HostRPCError("notFound", detail: detail)
        case EACCES, EPERM: return HostRPCError("permissionDenied", detail: detail)
        case ELOOP: return HostRPCError("pathOutsideRoot", detail: detail)
        default: return HostRPCError("ioFailed", detail: "\(detail): \(String(cString: strerror(code)))")
        }
    }
}
