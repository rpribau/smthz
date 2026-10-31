import Foundation

/// Folder search (M4-PLAN §10.1, port of Orca `R/src/shared/text-search.ts`).
/// Engine chain (M4-D3): bundled `Contents/Resources/rg` → `rg` on PATH → `git grep` in Git roots
/// → in-process scan. No binary is downloaded or vendored here.
public enum FileSearch {
    public static let defaultMaxResults = 2_000
    public static let timeout: TimeInterval = 15
    public static let maxLineLength = 500
    public static let maxFileSize = 5 * 1_024 * 1_024

    public enum Engine: Equatable, Sendable {
        case ripgrep(String), gitGrep, inProcess
        public var name: String {
            switch self { case .ripgrep: "ripgrep"; case .gitGrep: "git-grep"; case .inProcess: "in-process" }
        }
    }

    public struct Options: Equatable, Sendable {
        public var query: String
        public var caseSensitive = false
        public var wholeWord = false
        public var useRegex = false
        public var includePattern = ""
        public var excludePattern = ""
        public var maxResults = FileSearch.defaultMaxResults
        /// Root-relative folder to search (Explorer "Find in Folder"); empty = whole root.
        public var scope = ""
        public init(query: String) { self.query = query }
    }

    public struct Match: Equatable, Sendable {
        /// 1-based line; columns are 1-based UTF-16 offsets into the full line.
        public let line: Int
        public let column: Int
        public let matchLength: Int
        public let lineContent: String
        /// Set when `lineContent` was clamped: position of the match inside the snippet.
        public let displayColumn: Int?
        public let displayMatchLength: Int?
    }

    public struct FileResult: Equatable, Sendable {
        public let path: String
        public var matches: [Match]
    }

    public struct Result: Equatable, Sendable {
        public var files: [FileResult] = []
        public var totalMatches = 0
        public var truncated = false
        public var engine = ""
    }

    // MARK: Engine detection

    /// `Contents/Resources/rg` next to the running binary (`Contents/MacOS/smthzd`).
    public static func bundledRipgrep(executable: URL? = Bundle.main.executableURL) -> String? {
        guard let executable else { return nil }
        let candidate = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/rg").path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    /// PATH entries, then the Homebrew prefixes (an app-launched host inherits a minimal PATH).
    public static func ripgrepOnPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let entries = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
        for directory in entries where directory.hasPrefix("/") {
            let candidate = (directory as NSString).appendingPathComponent("rg")
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func detectRipgrep() -> String? { bundledRipgrep() ?? ripgrepOnPath() }

    public static func isGitWorkTree(_ root: URL) -> Bool {
        let result = try? runCollecting("/usr/bin/git", ["rev-parse", "--is-inside-work-tree"], cwd: root,
                                         environment: gitEnvironment(), control: GitProcessControl())
        return result?.code == 0 && String(decoding: result?.stdout ?? Data(), as: UTF8.self).hasPrefix("true")
    }

    public static func engine(for root: URL, ripgrep: String?) -> Engine {
        if let ripgrep { return .ripgrep(ripgrep) }
        return isGitWorkTree(root) ? .gitGrep : .inProcess
    }

    // MARK: Arguments

    /// Splits comma-separated globs, keeping commas inside `{…}` and `[…]` (Orca `splitSearchGlobPatterns`).
    public static func splitGlobs(_ patterns: String) -> [String] {
        var out: [String] = [], current = "", braces = 0, inClass = false, escaping = false
        for ch in patterns {
            if escaping { current.append("\\"); current.append(ch); escaping = false; continue }
            if ch == "\\" && !inClass { escaping = true; continue }
            if inClass { if ch == "]" { inClass = false } }
            else if ch == "[" { inClass = true }
            else if ch == "{" { braces += 1 }
            else if ch == "}" { braces = max(0, braces - 1) }
            if ch == ",", braces == 0, !inClass {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                current = ""; continue
            }
            current.append(ch)
        }
        if escaping { current.append("\\") }
        let t = current.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        return out
    }

    /// `{a,b}` alternatives for engines without brace support (git pathspecs, fnmatch); capped at 64.
    public static func expandBraces(_ glob: String) -> [String] {
        let chars = Array(glob)
        var depth = 0, open: Int?
        for (i, ch) in chars.enumerated() {
            if ch == "{" { if depth == 0 { open = i }; depth += 1 }
            else if ch == "}", depth > 0 {
                depth -= 1
                guard depth == 0, let start = open else { continue }
                var options: [String] = [], current = "", nested = 0
                for c in chars[(start + 1)..<i] {
                    if c == "{" { nested += 1 } else if c == "}" { nested -= 1 }
                    if c == ",", nested == 0 { options.append(current); current = "" } else { current.append(c) }
                }
                options.append(current)
                guard options.count > 1 else { return [glob] }
                let prefix = String(chars[..<start]), suffix = String(chars[(i + 1)...])
                return Array(options.flatMap { expandBraces(prefix + $0 + suffix) }.prefix(64))
            }
        }
        return [glob]
    }

    public static func ripgrepArguments(_ o: Options) -> [String] {
        var args = ["--no-config", "--json", "--hidden", "--glob", "!.git", "--max-filesize", "\(maxFileSize / 1_048_576)M"]
        if !o.caseSensitive { args.append("--ignore-case") }
        if o.wholeWord { args.append("--word-regexp") }
        if !o.useRegex { args.append("--fixed-strings") }
        for g in splitGlobs(o.includePattern) { args += ["--glob", g] }
        for g in splitGlobs(o.excludePattern) { args += ["--glob", "!" + g] }
        return args + ["--", o.query, o.scope.isEmpty ? "." : o.scope]
    }

    static func gitPathspecs(_ glob: String, exclude: Bool) -> [String] {
        let directoryOnly = glob.hasSuffix("/")
        let trimmed = String(glob.reversed().drop { $0 == "/" }.reversed())
        guard !trimmed.isEmpty else { return [] }
        let pattern = trimmed.contains("/") ? trimmed : "**/" + trimmed
        let spec = (exclude ? ":(exclude,glob)" : ":(glob)") + pattern
        return directoryOnly ? [spec + "/**"] : [spec, spec + "/**"]
    }

    public static func gitGrepArguments(_ o: Options) -> [String] {
        var args = ["-c", "submodule.recurse=false", "-c", "grep.column=false", "grep", "-n", "-I", "--null", "--no-color",
                    "--untracked", "--no-recurse-submodules"]
        if !o.caseSensitive { args.append("-i") }
        if o.wholeWord { args.append("-w") }
        args.append(o.useRegex ? "--extended-regexp" : "--fixed-strings")
        args += ["-e", o.query, "--"]
        let scopePrefix = o.scope.isEmpty ? "" : o.scope + "/"
        var includes: [String] = [], excludes: [String] = []
        for g in splitGlobs(o.includePattern).flatMap(expandBraces) { includes += gitPathspecs(scopePrefix.isEmpty ? g : scopePrefix + (g.contains("/") ? g : "**/" + g), exclude: false) }
        for g in splitGlobs(o.excludePattern).flatMap(expandBraces) { excludes += gitPathspecs(g, exclude: true) }
        if includes.isEmpty { includes = o.scope.isEmpty ? ["."] : [":(literal)" + o.scope] }
        return args + includes + excludes
    }

    // MARK: Running

    /// Runs the chosen engine. Stops at `maxResults` (truncated), on `timeout` (truncated) or when
    /// `control` is cancelled (throws `cancelled`). `onFile` sees each file as it completes.
    public static func search(root: URL, options: Options, engine: Engine, control: GitProcessControl,
                              isCancelled: @escaping @Sendable () -> Bool = { false },
                              timeout: TimeInterval = FileSearch.timeout) throws -> Result {
        guard !options.query.isEmpty else { throw HostRPCError("badRequest", detail: "query") }
        if options.useRegex {
            guard (try? NSRegularExpression(pattern: options.query)) != nil || engine != .inProcess else {
                throw HostRPCError("invalidPattern", detail: options.query)
            }
        }
        if !options.scope.isEmpty { _ = try FileOperations.components(options.scope) }
        var accumulator = Accumulator(maxResults: max(1, min(options.maxResults, 10_000)))
        let deadline = Date(timeIntervalSinceNow: timeout)
        switch engine {
        case .ripgrep(let path):
            let timedOut = try streamLines(path, ripgrepArguments(options), cwd: root, environment: nil, control: control,
                                           deadline: deadline, separator: 10) { line in
                ingestRipgrep(line, into: &accumulator)
            }
            if timedOut { accumulator.result.truncated = true }
        case .gitGrep:
            let regex = submatchRegex(options)
            let timedOut = try streamLines("/usr/bin/git", gitGrepArguments(options), cwd: root, environment: gitEnvironment(),
                                           control: control, deadline: deadline, separator: 10) { line in
                ingestGitGrep(line, regex: regex, into: &accumulator)
            }
            if timedOut { accumulator.result.truncated = true }
        case .inProcess:
            try searchInProcess(root: root, options: options, deadline: deadline, isCancelled: isCancelled, into: &accumulator)
        }
        if control.wasCancelled || isCancelled() { throw HostRPCError("cancelled") }
        var result = accumulator.finish()
        result.engine = engine.name
        return result
    }

    struct Accumulator {
        let maxResults: Int
        var result = Result()
        var index: [String: Int] = [:]
        var full: Bool { result.totalMatches >= maxResults }

        mutating func add(path: String, line: Int, text: String, start: Int, length: Int) -> Bool {
            guard !full else { result.truncated = true; return false }
            let i: Int
            if let existing = index[path] { i = existing } else {
                i = result.files.count; index[path] = i
                result.files.append(FileResult(path: path, matches: []))
            }
            result.files[i].matches.append(FileSearch.clamp(line: line, text: text, start: start, length: length))
            result.totalMatches += 1
            if full { result.truncated = true; return false }
            return true
        }

        func finish() -> Result {
            var r = result
            r.files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            return r
        }
    }

    /// Port of Orca `clampLineContext`: lines over 500 UTF-16 units become a window around the match.
    static func clamp(line: Int, text: String, start: Int, length: Int) -> Match {
        let units = Array(text.utf16)
        guard units.count > maxLineLength else {
            return Match(line: line, column: start + 1, matchLength: length, lineContent: text, displayColumn: nil, displayMatchLength: nil)
        }
        let clampedLength = min(length, maxLineLength)
        var windowStart = max(0, start - (maxLineLength - clampedLength) / 2)
        var windowEnd = min(units.count, windowStart + maxLineLength)
        windowStart = max(0, windowEnd - maxLineLength)
        if windowStart > 0, UTF16.isTrailSurrogate(units[windowStart]) { windowStart += 1 }
        if windowEnd < units.count, windowEnd > 0, UTF16.isLeadSurrogate(units[windowEnd - 1]) { windowEnd -= 1 }
        var snippet = String(decoding: units[windowStart..<windowEnd], as: UTF16.self)
        let displayStart = max(windowStart, min(start, windowEnd))
        let displayLength = max(0, min(start + length, windowEnd) - displayStart)
        var column = displayStart - windowStart + 1
        if windowStart > 0 { snippet = "…" + snippet; column += 1 }
        if windowEnd < units.count { snippet += "…" }
        return Match(line: line, column: start + 1, matchLength: length, lineContent: snippet,
                     displayColumn: column, displayMatchLength: displayLength)
    }

    static func relative(_ path: String) -> String {
        var p = path
        while p.hasPrefix("./") { p.removeFirst(2) }
        return p
    }

    /// rg `--json`: `match` messages carry byte offsets into `lines.text`; converted to UTF-16.
    static func ingestRipgrep(_ line: Data, into acc: inout Accumulator) -> Bool {
        guard !acc.full else { acc.result.truncated = true; return false }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "match", let data = object["data"] as? [String: Any] else { return true }
        guard let path = (data["path"] as? [String: Any])?["text"] as? String,
              let lines = data["lines"] as? [String: Any], let text = lines["text"] as? String else {
            acc.result.truncated = true; return true  // byte-only paths/lines cannot be opened losslessly
        }
        let content = text.hasSuffix("\r\n") ? String(text.dropLast(2)) : text.hasSuffix("\n") ? String(text.dropLast()) : text
        let bytes = Array(content.utf8)
        let number = data["line_number"] as? Int ?? 0
        for sub in data["submatches"] as? [[String: Any]] ?? [] {
            guard let s = sub["start"] as? Int, let e = sub["end"] as? Int, s <= e else { continue }
            let start = utf16Offset(bytes, min(s, bytes.count)), end = utf16Offset(bytes, min(e, bytes.count))
            if !acc.add(path: relative(path), line: number, text: content, start: start, length: end - start) { return false }
        }
        return true
    }

    static func utf16Offset(_ bytes: [UInt8], _ byteOffset: Int) -> Int {
        var end = byteOffset
        while end > 0, end < bytes.count, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        return String(decoding: bytes[..<end], as: UTF8.self).utf16.count
    }

    static func submatchRegex(_ o: Options) -> NSRegularExpression? {
        var pattern = o.useRegex ? o.query : NSRegularExpression.escapedPattern(for: o.query)
        if o.wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        return try? NSRegularExpression(pattern: pattern, options: o.caseSensitive ? [] : [.caseInsensitive])
    }

    /// `file\0line\0content`; every submatch is located again with the regex (git reports lines only).
    static func ingestGitGrep(_ line: Data, regex: NSRegularExpression?, into acc: inout Accumulator) -> Bool {
        guard !acc.full else { acc.result.truncated = true; return false }
        let parts = line.split(separator: 0, maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let number = Int(String(decoding: parts[1], as: UTF8.self)) else { return true }
        let path = String(decoding: parts[0], as: UTF8.self)
        var content = String(decoding: parts[2], as: UTF8.self)
        if content.hasSuffix("\r") { content.removeLast() }
        return addRegexMatches(path: path, line: number, content: content, regex: regex, into: &acc)
    }

    static func addRegexMatches(path: String, line: Int, content: String, regex: NSRegularExpression?,
                                into acc: inout Accumulator) -> Bool {
        let ns = content as NSString
        let found = regex?.matches(in: content, range: NSRange(location: 0, length: ns.length)).filter { $0.range.length > 0 } ?? []
        if found.isEmpty { return acc.add(path: relative(path), line: line, text: content, start: 0, length: ns.length) }
        for m in found where !acc.add(path: relative(path), line: line, text: content, start: m.range.location, length: m.range.length) {
            return false
        }
        return true
    }

    /// Non-Git folders without rg: walks the scope (no ignore rules), skips `.git`, files over 5 MiB
    /// and binary files (NUL in the first 8 KiB), same caps as the other engines.
    static func searchInProcess(root: URL, options o: Options, deadline: Date, isCancelled: () -> Bool,
                                into acc: inout Accumulator) throws {
        guard let regex = submatchRegex(o) else { throw HostRPCError("invalidPattern", detail: o.query) }
        let start = o.scope.isEmpty ? root : root.appendingPathComponent(o.scope)
        let includes = splitGlobs(o.includePattern).flatMap(expandBraces), excludes = splitGlobs(o.excludePattern).flatMap(expandBraces)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: start, includingPropertiesForKeys: keys) else { return }
        var paths: [String] = []
        for case let url as URL in walker {
            if isCancelled() { throw HostRPCError("cancelled") }
            if Date() > deadline { acc.result.truncated = true; break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let rel = FileOperations.relativePath(of: url, in: FileRoot(url: root, key: ""))
            if values.isDirectory == true {
                if url.lastPathComponent == ".git" || excludes.contains(where: { globMatches($0, rel) }) { walker.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= maxFileSize else { continue }
            if !includes.isEmpty, !includes.contains(where: { globMatches($0, rel) }) { continue }
            if excludes.contains(where: { globMatches($0, rel) }) { continue }
            paths.append(rel)
        }
        for rel in paths.sorted() {
            if isCancelled() { throw HostRPCError("cancelled") }
            if Date() > deadline { acc.result.truncated = true; return }
            guard let data = FileManager.default.contents(atPath: root.appendingPathComponent(rel).path),
                  !data.prefix(8_192).contains(0) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for (offset, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
                let line = String(line), ns = line as NSString
                for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                    if !acc.add(path: rel, line: offset + 1, text: line, start: m.range.location, length: m.range.length) { return }
                }
            }
        }
    }

    /// Glob test for the in-process engine: a pattern without `/` matches any path component
    /// (like rg/git `**/<glob>`), otherwise the whole relative path or a directory prefix of it.
    public static func globMatches(_ glob: String, _ path: String) -> Bool {
        let pattern = String(glob.reversed().drop { $0 == "/" }.reversed())
        guard !pattern.isEmpty else { return false }
        if !pattern.contains("/") {
            return path.split(separator: "/").contains { fnmatch(pattern, String($0), 0) == 0 }
        }
        let parts = path.split(separator: "/").map(String.init)
        for count in stride(from: parts.count, through: 1, by: -1) where fnmatch(pattern, parts.prefix(count).joined(separator: "/"), FNM_PATHNAME) == 0 {
            return true
        }
        return pattern.hasPrefix("**/") && globMatches(String(pattern.dropFirst(3)), path)
    }

    // MARK: Process plumbing

    static func gitEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"; environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["LC_ALL"] = "C"
        return environment
    }

    /// Streams stdout split on `separator`; `onLine` returning false stops the child. Returns true on timeout.
    @discardableResult
    static func streamLines(_ executable: String, _ arguments: [String], cwd: URL, environment: [String: String]?,
                            control: GitProcessControl, deadline: Date, separator: UInt8,
                            onLine: (Data) -> Bool) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = executable == "/usr/bin/git"
            ? ["--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"] + arguments : arguments
        process.currentDirectoryURL = cwd
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try control.start(process) } catch GitError.cancelled { throw HostRPCError("cancelled") }
        catch { throw HostRPCError("searchFailed", detail: String(describing: error)) }
        let reader = pipe.fileHandleForReading
        let timer = DispatchSource.makeTimerSource(queue: .global())
        let timedOut = TimeoutFlag()
        timer.schedule(deadline: .now() + max(0, deadline.timeIntervalSinceNow))
        timer.setEventHandler { timedOut.set(); control.stop() }
        timer.resume()
        defer {
            timer.cancel()
            if process.isRunning { control.stop() }
            process.waitUntilExit()
            try? reader.close()
        }
        var pending = Data()
        var stopped = false
        while !stopped {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let end = pending.firstIndex(of: separator) {
                let line = pending[pending.startIndex..<end]
                if !line.isEmpty, !onLine(Data(line)) { stopped = true; break }
                pending.removeSubrange(pending.startIndex...end)
            }
            if stopped { control.stop() }
        }
        if !stopped, !pending.isEmpty, !timedOut.value { _ = onLine(pending) }
        if control.wasCancelled { throw HostRPCError("cancelled") }
        return timedOut.value
    }

    static func runCollecting(_ executable: String, _ arguments: [String], cwd: URL, environment: [String: String]?,
                              control: GitProcessControl, deadline: Date = Date(timeIntervalSinceNow: 30)) throws -> (code: Int32, stdout: Data) {
        var out = Data()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try control.start(process) } catch GitError.cancelled { throw HostRPCError("cancelled") }
        out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? pipe.fileHandleForReading.close()
        if control.wasCancelled { throw HostRPCError("cancelled") }
        return (process.terminationStatus, out)
    }

    final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func set() { lock.withLock { fired = true } }
        var value: Bool { lock.withLock { fired } }
    }
}
