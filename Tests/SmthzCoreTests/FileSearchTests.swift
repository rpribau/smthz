import Foundation
import Testing
@testable import SmthzCore

/// An `rg` for the ripgrep-engine cases: `SMTHZ_TEST_RG`, else whatever the host would detect.
/// Without one those cases only exercise git grep and the in-process engine.
private let testRipgrep: String? = {
    if let path = ProcessInfo.processInfo.environment["SMTHZ_TEST_RG"], FileManager.default.isExecutableFile(atPath: path) { return path }
    return FileSearch.detectRipgrep()
}()

private func engines(gitRoot: Bool) -> [FileSearch.Engine] {
    (testRipgrep.map { [FileSearch.Engine.ripgrep($0)] } ?? []) + (gitRoot ? [.gitGrep] : []) + [.inProcess]
}

private func run(_ root: URL, _ engine: FileSearch.Engine, _ query: String,
                 _ configure: (inout FileSearch.Options) -> Void = { _ in }) throws -> FileSearch.Result {
    var options = FileSearch.Options(query: query)
    configure(&options)
    return try FileSearch.search(root: root, options: options, engine: engine, control: GitProcessControl())
}

private func paths(_ r: FileSearch.Result) -> [String] { r.files.map(\.path) }

@Suite(.serialized) struct FileSearchTests {
    private func corpus(_ f: FilesFixture) throws -> URL {
        let repo = try f.makeRepo()
        try f.write("src/main.swift", "let needle = 1\nprint(Needle)\nneedles everywhere\n", in: repo)
        try f.write("src/util.ts", "const x = 'needle'\n", in: repo)
        try f.write("docs/guide.md", "No match here\nfoo(bar)\n", in: repo)
        try f.write(".hidden/conf", "needle\n", in: repo)
        return repo
    }

    @Test func fixedStringCaseAndWholeWordAcrossEngines() throws {
        let f = try FilesFixture(); defer { f.stop(); f.remove() }
        let repo = try corpus(f)
        for engine in engines(gitRoot: true) {
            let insensitive = try run(repo, engine, "needle")
            #expect(paths(insensitive) == [".hidden/conf", "src/main.swift", "src/util.ts"], "\(engine)")
            #expect(insensitive.totalMatches == 5, "\(engine)")
            let main = try #require(insensitive.files.first { $0.path == "src/main.swift" })
            #expect(main.matches.map(\.line) == [1, 2, 3], "\(engine)")
            #expect(main.matches[0].column == 5 && main.matches[0].matchLength == 6, "\(engine)")
            let sensitive = try run(repo, engine, "Needle") { $0.caseSensitive = true }
            #expect(sensitive.totalMatches == 1, "\(engine)")
            let word = try run(repo, engine, "needle") { $0.wholeWord = true }
            #expect(word.totalMatches == 4, "\(engine): 'needles' is not a whole word")
            let literal = try run(repo, engine, "foo(bar)")
            #expect(paths(literal) == ["docs/guide.md"], "\(engine): parentheses are literal without regex")
            #expect(!insensitive.truncated)
        }
    }

    @Test func regexIncludeExcludeAndScope() throws {
        let f = try FilesFixture(); defer { f.stop(); f.remove() }
        let repo = try corpus(f)
        for engine in engines(gitRoot: true) {
            let regex = try run(repo, engine, "need(le|ful)s?") { $0.useRegex = true }
            #expect(regex.totalMatches == 5, "\(engine)")
            let include = try run(repo, engine, "needle") { $0.includePattern = "*.ts, *.md" }
            #expect(paths(include) == ["src/util.ts"], "\(engine)")
            let exclude = try run(repo, engine, "needle") { $0.excludePattern = "src" }
            #expect(paths(exclude) == [".hidden/conf"], "\(engine)")
            let braces = try run(repo, engine, "needle") { $0.includePattern = "*.{swift,ts}" }
            #expect(paths(braces) == ["src/main.swift", "src/util.ts"], "\(engine)")
            let scoped = try run(repo, engine, "needle") { $0.scope = "src" }
            #expect(paths(scoped) == ["src/main.swift", "src/util.ts"], "\(engine)")
        }
        #expect(FileSearch.splitGlobs("*.ts, {a,b}.md ,[,x]") == ["*.ts", "{a,b}.md", "[,x]"])
        #expect(FileSearch.expandBraces("*.{swift,t{s,sx}}") == ["*.swift", "*.ts", "*.tsx"])
        #expect(FileSearch.globMatches("*.ts", "src/util.ts"))
        #expect(FileSearch.globMatches("src", "src/util.ts"))
        #expect(FileSearch.globMatches("src/*.ts", "src/util.ts"))
        #expect(!FileSearch.globMatches("*.md", "src/util.ts"))
    }

    @Test func truncatesAtMaxResultsAndClampsLongLines() throws {
        let f = try FilesFixture(); defer { f.stop(); f.remove() }
        let repo = try f.makeRepo()
        try f.write("many.txt", String(repeating: "hit\n", count: 2_100), in: repo)
        try f.write("long.txt", String(repeating: "a", count: 1_000) + "TARGET" + String(repeating: "b", count: 1_000) + "\n", in: repo)
        for engine in engines(gitRoot: true) {
            let many = try run(repo, engine, "hit")
            #expect(many.totalMatches == FileSearch.defaultMaxResults, "\(engine)")
            #expect(many.truncated, "\(engine)")
            let small = try run(repo, engine, "hit") { $0.maxResults = 10 }
            #expect(small.totalMatches == 10 && small.truncated, "\(engine)")
            let long = try #require(try run(repo, engine, "TARGET").files.first?.matches.first, "\(engine)")
            #expect(long.column == 1_001, "\(engine)")
            #expect(long.lineContent.utf16.count <= FileSearch.maxLineLength + 2, "\(engine)")
            let display = try #require(long.displayColumn)
            let snippet = Array(long.lineContent.utf16)
            #expect(String(decoding: snippet[(display - 1)..<(display - 1 + 6)], as: UTF16.self) == "TARGET", "\(engine)")
        }
    }

    @Test func cancellationAndEngineChain() throws {
        let f = try FilesFixture(); defer { f.stop(); f.remove() }
        let repo = try corpus(f)
        for engine in engines(gitRoot: true) {
            let control = GitProcessControl()
            control.cancel()
            #expect(throws: HostRPCError("cancelled"), "\(engine)") {
                try FileSearch.search(root: repo, options: .init(query: "needle"), engine: engine, control: control, isCancelled: { true })
            }
        }
        #expect(FileSearch.engine(for: repo, ripgrep: nil) == .gitGrep)
        #expect(FileSearch.engine(for: repo, ripgrep: "/x/rg") == .ripgrep("/x/rg"))
        let plain = f.directory.appendingPathComponent("plain", isDirectory: true)
        try f.write("a.txt", "needle\n", in: plain)
        #expect(FileSearch.engine(for: plain, ripgrep: nil) == .inProcess)
        #expect(try run(plain, .inProcess, "needle").totalMatches == 1)
        // Bundled rg sits in Contents/Resources next to Contents/MacOS/smthzd.
        let bundle = f.directory.appendingPathComponent("smthz.app/Contents", isDirectory: true)
        try f.write("MacOS/smthzd", "", in: bundle)
        #expect(FileSearch.bundledRipgrep(executable: bundle.appendingPathComponent("MacOS/smthzd")) == nil)
        try f.write("Resources/rg", "#!/bin/sh\n", in: bundle)
        chmod(bundle.appendingPathComponent("Resources/rg").path, 0o755)
        #expect(FileSearch.bundledRipgrep(executable: bundle.appendingPathComponent("MacOS/smthzd"))
                == bundle.appendingPathComponent("Resources/rg").path)
        #expect(FileSearch.ripgrepOnPath(environment: ["PATH": bundle.appendingPathComponent("Resources").path])
                == bundle.appendingPathComponent("Resources/rg").path)
    }

    @Test func searchJobOverRPCWithAndWithoutRipgrep() throws {
        for rg in [nil] + (testRipgrep.map { [$0] } ?? []) {
            let f = try FilesFixture(ripgrep: rg); defer { f.stop(); f.remove() }
            let repo = try corpus(f)
            let (state, items) = try f.job("fs.search", ["root": .string(repo.path), "query": "needle", "wholeWord": .bool(true)])
            #expect(state["state"] == .string("succeeded"), "\(state)")
            let summary = try #require(state["result"]?.object)
            #expect(summary["totalMatches"] == .number(4))
            #expect(summary["engine"] == .string(rg == nil ? "git-grep" : "ripgrep"))
            #expect(items.compactMap { $0.object?["path"]?.string } == [".hidden/conf", "src/main.swift", "src/util.ts"])
            #expect(try f.ok("fs.searchEngine", ["root": .string(repo.path)])["engine"] == .string(rg == nil ? "git-grep" : "ripgrep"))
            #expect(try f.error("fs.search", ["root": .string(repo.path), "query": "x", "scope": "../.."]) == "pathOutsideRoot")
        }
    }

    @Test func listFilesTrackedThenIgnoredWithPaging() throws {
        for rg in [nil] + (testRipgrep.map { [$0] } ?? []) {
            let f = try FilesFixture(ripgrep: rg); defer { f.stop(); f.remove() }
            let repo = try f.makeRepo()
            try f.write(".gitignore", "*.log\nbuild/\n", in: repo)
            try f.write("untracked.swift", "", in: repo)
            try f.write("debug.log", "", in: repo)
            try f.write("build/out.o", "", in: repo)
            try f.write("node_modules/pkg/index.js", "", in: repo)
            for i in 0..<6_000 { try f.write("gen/file\(i).txt", "", in: repo) }
            let (state, items) = try f.job("fs.listFiles", ["root": .string(repo.path)])
            #expect(state["state"] == .string("succeeded"), "\(state)")
            let summary = try #require(state["result"]?.object)
            let tracked = Int(summary["trackedCount"]?.number ?? 0)
            let all = items.compactMap(\.string)
            #expect(all.count == 6_000 + 5, "rg=\(rg ?? "none"): \(all.count)")
            #expect(Set(all[..<tracked]).isSuperset(of: [".gitignore", "README.md", "untracked.swift", "gen/file5999.txt"]))
            #expect(Set(all[tracked...]) == ["build/out.o", "debug.log"], "rg=\(rg ?? "none")")
            #expect(!all.contains { $0.hasPrefix("node_modules/") || $0.hasPrefix(".git/") })
            #expect(summary["truncated"] == .bool(false))
        }
        // Plain folders fall back to a bounded walk.
        let f = try FilesFixture(); defer { f.stop(); f.remove() }
        let plain = f.directory.appendingPathComponent("plain", isDirectory: true)
        try f.write("b/9.txt", "", in: plain); try f.write("a.txt", "", in: plain); try f.write("node_modules/x.js", "", in: plain)
        let walked = try FileListing.list(root: plain, ripgrep: nil, control: GitProcessControl())
        #expect(walked.engine == "walk")
        #expect(walked.tracked == ["a.txt", "b/9.txt"])
    }

    @Test func hostClientFileCallsOverSocket() throws {
        let f = try FilesFixture(); defer { f.stop(); f.remove() }
        let repo = try corpus(f)
        let server = try UnixSocketServer(path: f.directory.appendingPathComponent("s").path) { f.service.handle($0) }
        defer { server.stop() }
        let client = try HostClient(socketPath: f.directory.appendingPathComponent("s").path)
        defer { client.disconnect() }
        let root = repo.path
        try client.fsCreateDirectory(root: root, path: "new")
        try client.fsCreateFile(root: root, path: "new/file.txt")
        #expect(try client.fsList(root: root, path: "new").entries.map(\.name) == ["file.txt"])
        #expect(try client.fsList(root: root).entries.first?.isDirectory == true)
        #expect(try client.fsExists(root: root, path: "new/file.txt"))
        try client.fsRename(root: root, from: "new/file.txt", to: "new/renamed.txt")
        try client.fsCopy(root: root, from: "new/renamed.txt", to: "new/copy.txt")
        let trashed = try client.fsTrash(root: root, path: "new/copy.txt")
        defer { try? FileManager.default.removeItem(atPath: trashed) }
        try client.fsRestore(root: root, trashedPath: trashed, to: "new/copy.txt")
        #expect(try client.fsStat(root: root, path: "new/copy.txt").kind == "file")
        #expect(throws: HostClientError.detailedHostError(code: "pathOutsideRoot", detail: "../x")) {
            try client.fsCreateFile(root: root, path: "../x")
        }
        let changes = try client.fsChanges(root: root, cursor: nil)
        #expect(!changes.overflow)
        let listing = try client.fsListFiles(root: root)
        #expect(listing.tracked.contains("src/main.swift") && listing.tracked.contains("new/copy.txt"))
        var request = HostSearchRequest(root: root, query: "needle")
        request.wholeWord = true
        let result = try client.fsSearchResult(jobID: try client.fsStartSearch(request))
        #expect(result.totalMatches == 4)
        #expect(result.files.first { $0.path == "src/main.swift" }?.matches.first?.column == 5)
        #expect(try client.fsSearchEngine(root: root) == "git-grep")
    }
}
