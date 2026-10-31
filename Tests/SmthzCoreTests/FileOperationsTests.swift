import Foundation
import Testing
@testable import SmthzCore

extension HostJSON: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

/// Host with `fs.*` and `repo.*` registered; `ripgrep` picks the search engine for jobs.
final class FilesFixture: @unchecked Sendable {
    let directory: URL
    let journal: EventJournal
    let router = HostRouter()
    let store: WorkspaceStore
    let service: HostService
    let watchers = FileWatchers()
    init(ripgrep: String? = nil) throws {
        let raw = URL(fileURLWithPath: "/tmp/smthz-fo-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        directory = URL(fileURLWithPath: try WorkspaceStore.canonicalPath(raw.path))
        journal = try EventJournal(path: directory.appendingPathComponent("journal").path)
        store = try WorkspaceStore(path: directory.appendingPathComponent("workspace.sqlite").path)
        service = HostService(journal: journal, hostIdentity: nil, router: router)
        RepoRPC.register(on: router, store: store, liveSessionCWDs: { [] })
        FilesRPC.register(on: router, store: store, watchers: watchers, ripgrep: { ripgrep })
    }
    func stop() { watchers.stopAll(); service.stop() }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func call(_ method: String, _ params: [String: HostJSON] = [:], id: String = UUID().uuidString) throws -> [String: HostJSON] {
        let request = RPCEnvelope(version: 1, requestID: id, method: method, payload: try JSONEncoder().encode(params))
        let envelope = try JSONDecoder().decode(RPCEnvelope.self, from: service.handleAuthenticatedTestRequest(JSONEncoder().encode(request)))
        return try JSONDecoder().decode([String: HostJSON].self, from: envelope.payload)
    }
    @discardableResult func ok(_ method: String, _ params: [String: HostJSON] = [:], id: String = UUID().uuidString) throws -> [String: HostJSON] {
        let result = try call(method, params, id: id)
        try #require(result["ok"] == .bool(true), "\(method) failed: \(result)")
        return result
    }
    func error(_ method: String, _ params: [String: HostJSON]) throws -> String? {
        let result = try call(method, params)
        #expect(result["ok"] == .bool(false), "\(method) unexpectedly succeeded")
        return result["error"]?.string
    }
    func job(_ method: String, _ params: [String: HostJSON]) throws -> (state: [String: HostJSON], items: [HostJSON]) {
        let id = try #require(try ok(method, params)["jobId"]?.string)
        let deadline = Date(timeIntervalSinceNow: 30)
        while Date() < deadline {
            let state = try router.jobs.get(id)
            if ["succeeded", "failed", "cancelled"].contains(state["state"]?.string ?? "") {
                var items: [HostJSON] = [], offset = 0.0
                while state["state"] == .string("succeeded") {
                    let page = try ok("fs.jobResults", ["jobId": .string(id), "offset": .number(offset)])
                    if case .array(let list)? = page["items"] { items += list }
                    guard let next = page["nextOffset"]?.number else { break }
                    offset = next
                }
                return (state, items)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        Issue.record("job \(method) did not finish"); return ([:], [])
    }
    @discardableResult func git(_ args: [String], at path: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Test", "-c", "user.email=t@example.com", "-c", "init.defaultBranch=main",
                             "-c", "commit.gpgsign=false"] + args
        process.currentDirectoryURL = path
        process.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "PATH": "/usr/bin:/bin"]
        let out = Pipe(); process.standardOutput = out; process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try #require(process.terminationStatus == 0, "git \(args) failed")
        return text
    }
    func makeRepo(_ name: String = "repo") throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(["init", "-q"], at: url)
        try write("README.md", "hello\n", in: url)
        try git(["add", "README.md"], at: url)
        try git(["commit", "-q", "-m", "init"], at: url)
        return url
    }
    func write(_ path: String, _ text: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func names(_ root: URL, _ path: String = "") throws -> [String] {
        let listed = try ok("fs.list", ["root": .string(root.path), "path": .string(path)])
        guard case .array(let entries)? = listed["entries"] else { return [] }
        return entries.compactMap { $0.object?["name"]?.string }
    }
}

@Suite(.serialized) struct FileOperationsTests {
    @Test func createListAndNaturalSort() throws {
        let f = try FilesFixture(); defer { f.stop(); f.remove() }
        let repo = try f.makeRepo()
        let root = HostJSON.string(repo.path)
        for name in ["100.txt", "9.txt", "99.txt"] { try f.ok("fs.createFile", ["root": root, "path": .string(name)]) }
        try f.ok("fs.createDir", ["root": root, "path": "zeta"])
        try f.ok("fs.createDir", ["root": root, "path": "alpha"])
        try f.ok("fs.createFile", ["root": root, "path": "alpha/inner.swift"])
        #expect(try f.names(repo) == ["alpha", "zeta", "9.txt", "99.txt", "100.txt", "README.md"])
        #expect(try f.names(repo, "alpha") == ["inner.swift"])
        #expect(try f.error("fs.createFile", ["root": root, "path": "9.txt"]) == "alreadyExists")
        #expect(try f.error("fs.createDir", ["root": root, "path": "alpha"]) == "alreadyExists")
        #expect(try f.error("fs.createFile", ["root": root, "path": "missing/x.txt"]) == "notFound")
        let stat = try f.ok("fs.stat", ["root": root, "path": "alpha"])
        #expect(stat["entry"]?.object?["kind"] == .string("dir"))
        #expect(try f.ok("fs.exists", ["root": root, "path": "nope"])["exists"] == .bool(false))
        #expect(try f.ok("fs.exists", ["root": root, "path": "9.txt"])["exists"] == .bool(true))
        #expect(!(try f.names(repo)).contains(".git"))
    }

    @Test func renameAndCopyNeverOverwrite() throws {
        let f = try FilesFixture(); defer { f.stop(); f.remove() }
        let repo = try f.makeRepo()
        let root = HostJSON.string(repo.path)
        try f.write("a.txt", "A", in: repo); try f.write("b.txt", "B", in: repo)
        #expect(try f.error("fs.rename", ["root": root, "from": "a.txt", "to": "b.txt"]) == "alreadyExists")
        #expect(try String(contentsOf: repo.appendingPathComponent("b.txt"), encoding: .utf8) == "B")
        try f.ok("fs.rename", ["root": root, "from": "a.txt", "to": "c.txt"])
        #expect(try String(contentsOf: repo.appendingPathComponent("c.txt"), encoding: .utf8) == "A")
        try f.ok("fs.rename", ["root": root, "from": "c.txt", "to": "C.txt"])  // case-only rename
        #expect(try f.names(repo).contains("C.txt"))
        #expect(try f.error("fs.copy", ["root": root, "from": "C.txt", "to": "b.txt"]) == "alreadyExists")
        try f.ok("fs.copy", ["root": root, "from": "C.txt", "to": "C copy.txt"])
        #expect(try String(contentsOf: repo.appendingPathComponent("C copy.txt"), encoding: .utf8) == "A")
        try f.ok("fs.createDir", ["root": root, "path": "dir"])
        try f.write("dir/x", "x", in: repo)
        try f.ok("fs.copy", ["root": root, "from": "dir", "to": "dir2"])
        #expect(try f.names(repo, "dir2") == ["x"])
        #expect(try f.error("fs.rename", ["root": root, "from": "dir", "to": "dir/sub"]) == "invalidPath")
        #expect(FileOperations.duplicateName(for: "a.txt", existing: ["a.txt"]) == "a copy.txt")
        #expect(FileOperations.duplicateName(for: "a.txt", existing: ["a.txt", "a copy.txt"]) == "a copy 2.txt")
        #expect(FileOperations.duplicateName(for: ".env", existing: []) == ".env copy")
        #expect(FileOperations.duplicateName(for: "Makefile", existing: [], always: false) == "Makefile")
    }

    @Test func trashAndRestore() throws {
        let f = try FilesFixture(); defer { f.stop(); f.remove() }
        let repo = try f.makeRepo()
        let root = HostJSON.string(repo.path)
        try f.write("doomed.txt", "bye", in: repo)
        let requestID = UUID().uuidString
        let trashed = try #require(try f.ok("fs.trash", ["root": root, "path": "doomed.txt"], id: requestID)["trashedPath"]?.string)
        defer { try? FileManager.default.removeItem(atPath: trashed) }
        #expect(!FileManager.default.fileExists(atPath: repo.appendingPathComponent("doomed.txt").path))
        #expect(FileManager.default.fileExists(atPath: trashed))
        #expect(trashed.contains("/.Trash"))
        // Replaying the same request answers from the journal instead of trashing again.
        #expect(try f.ok("fs.trash", ["root": root, "path": "doomed.txt"], id: requestID)["trashedPath"] == .string(trashed))
        // Restore refuses paths that are not in a Trash, and never overwrites.
        #expect(try f.error("fs.restore", ["root": root, "trashedPath": .string(repo.appendingPathComponent("README.md").path),
                                           "path": "x.txt"]) == "invalidPath")
        try f.write("doomed.txt", "new", in: repo)
        #expect(try f.error("fs.restore", ["root": root, "trashedPath": .string(trashed), "path": "doomed.txt"]) == "alreadyExists")
        try FileManager.default.removeItem(at: repo.appendingPathComponent("doomed.txt"))
        try f.ok("fs.restore", ["root": root, "trashedPath": .string(trashed), "path": "doomed.txt"])
        #expect(try String(contentsOf: repo.appendingPathComponent("doomed.txt"), encoding: .utf8) == "bye")
        #expect(!FileManager.default.fileExists(atPath: trashed))
        // A symlink is trashed itself, never its target.
        try f.write("target.txt", "keep", in: repo)
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("link").path, withDestinationPath: "target.txt")
        let link = try #require(try f.ok("fs.trash", ["root": root, "path": "link"])["trashedPath"]?.string)
        defer { try? FileManager.default.removeItem(atPath: link) }
        #expect(try String(contentsOf: repo.appendingPathComponent("target.txt"), encoding: .utf8) == "keep")
    }

    @Test func refusesEscapesAndUnacceptedRoots() throws {
        let f = try FilesFixture(); defer { f.stop(); f.remove() }
        let repo = try f.makeRepo()
        let outside = f.directory.appendingPathComponent("outside", isDirectory: true)
        try f.write("secret.txt", "s", in: outside)
        try FileManager.default.createSymbolicLink(atPath: repo.appendingPathComponent("escape").path, withDestinationPath: outside.path)
        let root = HostJSON.string(repo.path)
        #expect(try f.error("fs.createFile", ["root": root, "path": "../evil.txt"]) == "pathOutsideRoot")
        #expect(try f.error("fs.createFile", ["root": root, "path": "a/../../evil.txt"]) == "pathOutsideRoot")
        #expect(try f.error("fs.createFile", ["root": root, "path": "/tmp/evil.txt"]) == "invalidPath")
        #expect(try f.error("fs.createFile", ["root": root, "path": ".git/hooks/pre-commit"]) == "pathOutsideRoot")
        #expect(try f.error("fs.createFile", ["root": root, "path": "escape/evil.txt"]) == "pathOutsideRoot")
        #expect(try f.error("fs.list", ["root": root, "path": "escape"]) == "pathOutsideRoot")
        #expect(try f.error("fs.rename", ["root": root, "from": "README.md", "to": "escape/README.md"]) == "pathOutsideRoot")
        #expect(try f.error("fs.trash", ["root": root, "path": "escape/secret.txt"]) == "pathOutsideRoot")
        #expect(try f.error("fs.copy", ["root": root, "from": "escape/secret.txt", "to": "stolen.txt"]) == "pathOutsideRoot")
        #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("evil.txt").path))
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("evil.txt").path))
        // The link itself can still be listed (as a symlink) and trashed.
        #expect(try f.names(repo).contains("escape"))
        // A subdirectory of a work tree and an unregistered plain folder are not roots.
        try f.ok("fs.createDir", ["root": root, "path": "sub"])
        #expect(try f.error("fs.list", ["root": .string(repo.appendingPathComponent("sub").path)]) == "invalidPath")
        #expect(try f.error("fs.list", ["root": .string(outside.path)]) == "notRepository")
        // Once registered as a folder project, the plain folder is accepted.
        try f.ok("repo.add", ["path": .string(outside.path), "kind": "folder"])
        #expect(try f.names(outside) == ["secret.txt"])
    }

    @Test func importExternalCopiesWithUniqueNames() throws {
        let f = try FilesFixture(); defer { f.stop(); f.remove() }
        let repo = try f.makeRepo()
        let source = f.directory.appendingPathComponent("drop", isDirectory: true)
        try f.write("README.md", "dropped", in: source)
        try f.write("folder/a.txt", "a", in: source)
        let result = try f.ok("fs.importExternal", ["root": .string(repo.path), "destDir": "",
            "sources": .array([.string(source.appendingPathComponent("README.md").path), .string(source.appendingPathComponent("folder").path)])])
        #expect(result["paths"] == .array(["README copy.md", "folder"]))
        #expect(try String(contentsOf: repo.appendingPathComponent("README copy.md"), encoding: .utf8) == "dropped")
        #expect(try String(contentsOf: repo.appendingPathComponent("README.md"), encoding: .utf8) == "hello\n")
        #expect(try f.names(repo, "folder") == ["a.txt"])
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("README.md").path))
        #expect(try f.error("fs.importExternal", ["root": .string(repo.path), "destDir": "",
                                                  "sources": .array([.string(repo.path)])]) == "invalidPath")
    }

    @Test func changesReportExternalWriteWithinTwoSeconds() throws {
        let f = try FilesFixture(); defer { f.stop(); f.remove() }
        let repo = try f.makeRepo()
        let root = HostJSON.string(repo.path)
        let first = try f.ok("fs.changes", ["root": root])
        let cursor = try #require(first["cursor"]?.number)
        #expect(first["overflow"] == .bool(false))
        Thread.sleep(forTimeInterval: 0.3)  // FSEvents starts "since now"
        try f.write("src/external.txt", "touched", in: repo)
        let deadline = Date(timeIntervalSinceNow: 10)
        var seen = false, next = cursor
        while Date() < deadline, !seen {
            let changes = try f.ok("fs.changes", ["root": root, "cursor": .number(next)])
            #expect(changes["overflow"] == .bool(false))
            if case .array(let paths)? = changes["changed"], paths.contains(.string("src/external.txt")) { seen = true }
            next = changes["cursor"]?.number ?? next
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(seen, "external write not reported within 10 s")
        // A cursor from before this watcher (or from the future) asks the caller to reload.
        #expect(try f.ok("fs.changes", ["root": root, "cursor": .number(next + 1_000)])["overflow"] == .bool(true))
        #expect(f.watchers.watchedRoots == [repo.path])
    }

    @Test func watcherOverflowAndIdleClose() throws {
        let watchers = FileWatchers(capacity: 3, idleTimeout: 0.2)
        defer { watchers.stopAll() }
        let dir = URL(fileURLWithPath: try WorkspaceStore.canonicalPath("/tmp")).appendingPathComponent("smthz-fw-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = try watchers.changes(root: dir.path, cursor: nil).cursor
        Thread.sleep(forTimeInterval: 0.3)
        _ = try watchers.changes(root: dir.path, cursor: start)  // keep alive
        for i in 0..<8 { try Data("x".utf8).write(to: dir.appendingPathComponent("f\(i)")) ; Thread.sleep(forTimeInterval: 0.02) }
        let deadline = Date(timeIntervalSinceNow: 10)
        var overflow = false
        while Date() < deadline, !overflow {
            overflow = try watchers.changes(root: dir.path, cursor: start).overflow
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(overflow, "ring buffer of 3 must overflow after 8 writes")
        Thread.sleep(forTimeInterval: 0.4)
        #expect(watchers.watchedRoots.isEmpty)
        #expect(try watchers.changes(root: dir.path, cursor: start).overflow)  // restarted watcher
    }
}
