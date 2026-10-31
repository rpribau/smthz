import Foundation

/// File methods (`fs.*`, M4-PLAN §5.2 / §10). Every method takes `root` (an accepted root, see
/// `FileOperations.acceptRoot`); paths are relative to it. Job results are paged through
/// `fs.jobResults` so a 38k-file listing never exceeds the 1 MiB frame. `fs.read`/`fs.write`
/// stay unregistered until M4-EDITOR.
public enum FilesRPC {
    public static func register(on router: HostRouter, store: WorkspaceStore) {
        register(on: router, store: store, watchers: FileWatchers(), ripgrep: { FileSearch.detectRipgrep() })
    }

    /// `ripgrep` is evaluated per job, so tests can force a specific engine (or none).
    public static func register(on router: HostRouter, store: WorkspaceStore, watchers: FileWatchers,
                                ripgrep: @escaping @Sendable () -> String?) {
        let results = FileJobResults()
        @Sendable func root(_ p: [String: HostJSON]) throws -> FileRoot {
            try FileOperations.acceptRoot(try string(p, "root"), store: store)
        }
        let key: HostRouter.RepoKey = { try root($0).key }
        func read(_ method: String, _ body: @escaping @Sendable (FileRoot, [String: HostJSON]) throws -> [String: HostJSON]) {
            router.register(method, methodClass: .read) { p, _ in try body(try root(p), p) }
        }
        func mutation(_ method: String, _ body: @escaping @Sendable (FileRoot, [String: HostJSON]) throws -> [String: HostJSON]) {
            router.register(method, methodClass: .mutation, repository: key) { p, context in
                let r = try root(p)
                try context.checkCancellation()
                return try body(r, p)
            }
        }

        read("fs.list") { r, p in
            let listed = try FileOperations.list(p["path"]?.string ?? "", in: r)
            return ["entries": .array(listed.entries.map(encode)), "truncated": .bool(listed.truncated)]
        }
        read("fs.stat") { r, p in ["entry": encode(try FileOperations.stat(try string(p, "path"), in: r))] }
        read("fs.exists") { r, p in
            do { _ = try FileOperations.stat(try string(p, "path"), in: r); return ["exists": .bool(true)] }
            catch let error as HostRPCError where error.code == "notFound" { return ["exists": .bool(false)] }
        }
        read("fs.changes") { r, p in
            let cursor = try p["cursor"].flatMap { value -> UInt64? in
                guard let n = value.number, n >= 0, let c = UInt64(exactly: n) else { throw HostRPCError("badRequest", detail: "cursor") }
                return c
            }
            let c = try watchers.changes(root: r.path, cursor: cursor)
            return ["cursor": .number(Double(c.cursor)), "changed": .array(c.changed.map(HostJSON.string)), "overflow": .bool(c.overflow)]
        }
        read("fs.searchEngine") { r, _ in
            let rg = ripgrep()
            var result: [String: HostJSON] = ["engine": .string(FileSearch.engine(for: r.url, ripgrep: rg).name)]
            result["ripgrepPath"] = rg.map(HostJSON.string)
            return result
        }
        router.register("fs.jobResults", methodClass: .read) { p, _ in
            guard let id = p["jobId"]?.string else { throw HostRPCError("badRequest", detail: "jobId") }
            let offset = Int(p["offset"]?.number ?? 0), limit = Int(p["limit"]?.number ?? 5_000)
            guard offset >= 0, limit > 0 else { throw HostRPCError("badRequest") }
            return try results.page(id, offset: offset, limit: min(limit, 5_000))
        }

        mutation("fs.createFile") { r, p in try FileOperations.createFile(try string(p, "path"), in: r); return [:] }
        mutation("fs.createDir") { r, p in try FileOperations.createDirectory(try string(p, "path"), in: r); return [:] }
        mutation("fs.rename") { r, p in try FileOperations.rename(try string(p, "from"), to: try string(p, "to"), in: r); return [:] }
        mutation("fs.copy") { r, p in try FileOperations.copy(try string(p, "from"), to: try string(p, "to"), in: r); return [:] }
        mutation("fs.trash") { r, p in ["trashedPath": .string(try FileOperations.trash(try string(p, "path"), in: r).path)] }
        mutation("fs.restore") { r, p in
            try FileOperations.restore(trashed: try string(p, "trashedPath"), to: try string(p, "path"), in: r); return [:]
        }
        mutation("fs.importExternal") { r, p in
            guard case .array(let list)? = p["sources"] else { throw HostRPCError("badRequest", detail: "sources") }
            let sources = try list.map { value -> String in
                guard let s = value.string else { throw HostRPCError("badRequest", detail: "sources") }
                return s
            }
            let created = try FileOperations.importExternal(sources, into: p["destDir"]?.string ?? "", in: r)
            return ["paths": .array(created.map(HostJSON.string))]
        }

        router.register("fs.listFiles", methodClass: .job, repository: { _ in nil }) { [jobs = router.jobs] p, _ in
            let r = try root(p)
            let buffer = FileJobResults.Buffer()
            let id = try jobs.submit { context in
                context.event("phase", "listing")
                let listed = try FileListing.list(root: r.url, ripgrep: ripgrep(), control: context.processControl,
                                                  isCancelled: { context.isCancelled })
                buffer.complete(listed.tracked.map(HostJSON.string) + listed.ignored.map(HostJSON.string))
                return .object(["total": .number(Double(listed.tracked.count + listed.ignored.count)),
                                "trackedCount": .number(Double(listed.tracked.count)),
                                "truncated": .bool(listed.truncated), "engine": .string(listed.engine)])
            }
            results.insert(id, buffer)
            return ["jobId": .string(id)]
        }
        router.register("fs.search", methodClass: .job, repository: { _ in nil }) { [jobs = router.jobs] p, _ in
            let r = try root(p)
            let options = try searchOptions(p)
            if !options.scope.isEmpty { _ = try FileOperations.resolve(options.scope, in: r, followLeaf: true) }
            let buffer = FileJobResults.Buffer()
            let id = try jobs.submit { context in
                let engine = FileSearch.engine(for: r.url, ripgrep: ripgrep())
                context.event("phase", engine.name)
                let found = try FileSearch.search(root: r.url, options: options, engine: engine,
                                                  control: context.processControl, isCancelled: { context.isCancelled })
                buffer.complete(found.files.map(encode))
                return .object(["fileCount": .number(Double(found.files.count)), "totalMatches": .number(Double(found.totalMatches)),
                                "truncated": .bool(found.truncated), "engine": .string(found.engine)])
            }
            results.insert(id, buffer)
            return ["jobId": .string(id)]
        }
    }

    static func string(_ p: [String: HostJSON], _ key: String) throws -> String {
        guard let value = p[key]?.string else { throw HostRPCError("badRequest", detail: key) }
        return value
    }

    static func searchOptions(_ p: [String: HostJSON]) throws -> FileSearch.Options {
        var o = FileSearch.Options(query: try string(p, "query"))
        guard !o.query.isEmpty, !o.query.utf8.contains(0) else { throw HostRPCError("badRequest", detail: "query") }
        o.caseSensitive = p["caseSensitive"] == .bool(true)
        o.wholeWord = p["wholeWord"] == .bool(true)
        o.useRegex = p["useRegex"] == .bool(true)
        o.includePattern = p["includePattern"]?.string ?? ""
        o.excludePattern = p["excludePattern"]?.string ?? ""
        o.scope = p["scope"]?.string ?? ""
        if let max = p["maxResults"]?.number { o.maxResults = Swift.max(1, Swift.min(Int(max), 10_000)) }
        return o
    }

    static func encode(_ e: FileEntry) -> HostJSON {
        .object(["name": .string(e.name), "kind": .string(e.kind.rawValue), "targetIsDirectory": .bool(e.targetIsDirectory),
                 "size": .number(Double(e.size)), "mtime": .number(e.mtime)])
    }

    static func encode(_ f: FileSearch.FileResult) -> HostJSON {
        .object(["path": .string(f.path), "matches": .array(f.matches.map { m in
            var o: [String: HostJSON] = ["line": .number(Double(m.line)), "column": .number(Double(m.column)),
                                         "matchLength": .number(Double(m.matchLength)), "lineContent": .string(m.lineContent)]
            o["displayColumn"] = m.displayColumn.map { .number(Double($0)) }
            o["displayMatchLength"] = m.displayMatchLength.map { .number(Double($0)) }
            return .object(o)
        })])
    }
}

/// Result pages for `fs.listFiles` / `fs.search` jobs; kept 15 minutes, at most 16 jobs.
final class FileJobResults: @unchecked Sendable {
    final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [HostJSON] = []
        private var done = false
        let created = Date()
        func complete(_ items: [HostJSON]) { lock.withLock { self.items = items; done = true } }
        var snapshot: (items: [HostJSON], done: Bool) { lock.withLock { (items, done) } }
    }

    private let lock = NSLock()
    private var buffers: [(id: String, buffer: Buffer)] = []

    func insert(_ id: String, _ buffer: Buffer) {
        lock.withLock {
            let cutoff = Date(timeIntervalSinceNow: -900)
            buffers.removeAll { $0.buffer.created < cutoff }
            buffers.append((id, buffer))
            if buffers.count > 16 { buffers.removeFirst(buffers.count - 16) }
        }
    }

    /// Pages stop at `limit` items or about 600 KiB of JSON, whichever comes first.
    func page(_ id: String, offset: Int, limit: Int) throws -> [String: HostJSON] {
        guard let buffer = lock.withLock({ buffers.first { $0.id == id }?.buffer }) else { throw HostRPCError("jobNotFound") }
        let (items, done) = buffer.snapshot
        guard done else { return ["items": .array([]), "total": .number(0), "complete": .bool(false)] }
        var page: [HostJSON] = [], bytes = 0, index = min(offset, items.count)
        let encoder = JSONEncoder()
        while index < items.count, page.count < limit {
            let size = (try? encoder.encode(items[index]).count) ?? 0
            if !page.isEmpty, bytes + size > 600 * 1_024 { break }
            page.append(items[index]); bytes += size + 1; index += 1
        }
        var result: [String: HostJSON] = ["items": .array(page), "total": .number(Double(items.count)), "complete": .bool(true)]
        if index < items.count { result["nextOffset"] = .number(Double(index)) }
        return result
    }
}
