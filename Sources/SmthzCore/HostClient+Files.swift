import Foundation

public struct HostFileEntry: Decodable, Equatable, Sendable {
    public let name: String
    public let kind: String
    public let targetIsDirectory: Bool
    public let size: Double
    public let mtime: Double
    public var isDirectory: Bool { kind == "dir" || (kind == "symlink" && targetIsDirectory) }
    public init(name: String, kind: String, targetIsDirectory: Bool, size: Double, mtime: Double) {
        self.name = name; self.kind = kind; self.targetIsDirectory = targetIsDirectory; self.size = size; self.mtime = mtime
    }
}

public struct HostFileChanges: Decodable, Equatable, Sendable {
    public let cursor: UInt64
    public let changed: [String]
    public let overflow: Bool
}

public struct HostFileListing: Equatable, Sendable {
    public let tracked: [String]
    public let ignored: [String]
    public let truncated: Bool
    public let engine: String
}

public struct HostSearchMatch: Decodable, Equatable, Sendable {
    public let line: Int
    public let column: Int
    public let matchLength: Int
    public let lineContent: String
    public let displayColumn: Int?
    public let displayMatchLength: Int?
}

public struct HostSearchFile: Decodable, Equatable, Sendable {
    public let path: String
    public let matches: [HostSearchMatch]
}

public struct HostSearchResult: Equatable, Sendable {
    public let files: [HostSearchFile]
    public let totalMatches: Int
    public let truncated: Bool
    public let engine: String
}

public struct HostSearchRequest: Encodable, Equatable, Sendable {
    public var root: String
    public var query: String
    public var caseSensitive = false
    public var wholeWord = false
    public var useRegex = false
    public var includePattern = ""
    public var excludePattern = ""
    /// Root-relative folder (Explorer "Find in Folder"); empty searches the whole root.
    public var scope = ""
    public init(root: String, query: String) { self.root = root; self.query = query }
}

/// File calls (`fs.*`). `root` is an accepted root (registered path or Git top level); paths are
/// relative to it. Failures throw `HostClientError.detailedHostError`.
extension HostClient {
    private struct Root: Encodable { let root: String }
    private struct RootPath: Encodable { let root: String; let path: String }
    private struct Move: Encodable { let root: String; let from: String; let to: String }
    private struct Empty: Decodable {}
    private struct JobID: Decodable { let jobId: String }

    public func fsList(root: String, path: String = "") throws -> (entries: [HostFileEntry], truncated: Bool) {
        struct R: Decodable { let entries: [HostFileEntry]; let truncated: Bool }
        let r: R = try callWithDetail(method: "fs.list", params: RootPath(root: root, path: path))
        return (r.entries, r.truncated)
    }

    public func fsStat(root: String, path: String) throws -> HostFileEntry {
        struct R: Decodable { let entry: HostFileEntry }
        let r: R = try callWithDetail(method: "fs.stat", params: RootPath(root: root, path: path))
        return r.entry
    }

    public func fsExists(root: String, path: String) throws -> Bool {
        struct R: Decodable { let exists: Bool }
        let r: R = try callWithDetail(method: "fs.exists", params: RootPath(root: root, path: path))
        return r.exists
    }

    public func fsCreateFile(root: String, path: String) throws { try fsMutate("fs.createFile", RootPath(root: root, path: path)) }
    public func fsCreateDirectory(root: String, path: String) throws { try fsMutate("fs.createDir", RootPath(root: root, path: path)) }
    public func fsRename(root: String, from: String, to: String) throws { try fsMutate("fs.rename", Move(root: root, from: from, to: to)) }
    public func fsCopy(root: String, from: String, to: String) throws { try fsMutate("fs.copy", Move(root: root, from: from, to: to)) }

    /// Moves to the Trash; returns the trashed location for `fsRestore`.
    public func fsTrash(root: String, path: String) throws -> String {
        struct R: Decodable { let trashedPath: String }
        let r: R = try callWithDetail(method: "fs.trash", params: RootPath(root: root, path: path), timeoutMilliseconds: 30_000)
        return r.trashedPath
    }

    public func fsRestore(root: String, trashedPath: String, to path: String) throws {
        struct P: Encodable { let root: String; let trashedPath: String; let path: String }
        try fsMutate("fs.restore", P(root: root, trashedPath: trashedPath, path: path))
    }

    public func fsImportExternal(root: String, destDir: String, sources: [String]) throws -> [String] {
        struct P: Encodable { let root: String; let destDir: String; let sources: [String] }
        struct R: Decodable { let paths: [String] }
        let r: R = try callWithDetail(method: "fs.importExternal", params: P(root: root, destDir: destDir, sources: sources),
                                      timeoutMilliseconds: 30_000)
        return r.paths
    }

    /// Poll for changes; pass nil the first time. `overflow` means reload everything.
    public func fsChanges(root: String, cursor: UInt64?) throws -> HostFileChanges {
        struct P: Encodable { let root: String; let cursor: UInt64? }
        return try callWithDetail(method: "fs.changes", params: P(root: root, cursor: cursor))
    }

    public func fsSearchEngine(root: String) throws -> String {
        struct R: Decodable { let engine: String }
        let r: R = try callWithDetail(method: "fs.searchEngine", params: Root(root: root))
        return r.engine
    }

    /// Lists files for Go to File (tracked pass, then gitignored pass), paging the result.
    public func fsListFiles(root: String) throws -> HostFileListing {
        let id: JobID = try callWithDetail(method: "fs.listFiles", params: Root(root: root))
        let job = try waitForJob(id: id.jobId)
        let summary = job.result?.object ?? [:]
        let paths: [String] = try fsJobResults(id.jobId)
        let tracked = min(Int(summary["trackedCount"]?.number ?? Double(paths.count)), paths.count)
        return HostFileListing(tracked: Array(paths[..<tracked]), ignored: Array(paths[tracked...]),
                               truncated: summary["truncated"] == .bool(true), engine: summary["engine"]?.string ?? "")
    }

    /// Starts `fs.search`; use `fsSearchResult(jobID:)` to wait, `fsCancelJob` to cancel.
    public func fsStartSearch(_ request: HostSearchRequest) throws -> String {
        let id: JobID = try callWithDetail(method: "fs.search", params: request)
        return id.jobId
    }

    public func fsSearchResult(jobID: String) throws -> HostSearchResult {
        let job = try waitForJob(id: jobID)
        let summary = job.result?.object ?? [:]
        let files: [HostSearchFile] = try fsJobResults(jobID)
        return HostSearchResult(files: files, totalMatches: Int(summary["totalMatches"]?.number ?? 0),
                                truncated: summary["truncated"] == .bool(true), engine: summary["engine"]?.string ?? "")
    }

    public func fsCancelJob(_ jobID: String) throws {
        struct P: Encodable { let jobId: String }
        let _: Empty = try callWithDetail(method: "job.cancel", params: P(jobId: jobID))
    }

    private func fsJobResults<T: Decodable>(_ jobID: String) throws -> [T] {
        var out: [T] = [], offset = 0
        while true {
            let page: FilePage<T> = try callWithDetail(method: "fs.jobResults", params: FilePageRequest(jobId: jobID, offset: offset))
            out += page.items
            guard let next = page.nextOffset, next > offset else { return out }
            offset = next
        }
    }

    private func fsMutate<P: Encodable>(_ method: String, _ params: P) throws {
        let _: Empty = try callWithDetail(method: method, params: params, timeoutMilliseconds: 30_000)
    }
}

private struct FilePageRequest: Encodable { let jobId: String; let offset: Int }
private struct FilePage<Item: Decodable>: Decodable { let items: [Item]; let nextOffset: Int? }
