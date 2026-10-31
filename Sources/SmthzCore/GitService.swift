import Foundation
import Darwin

public enum GitError: Error, Equatable, Sendable {
    case invalidInput(String)
    case notRepository
    case launchFailed(String)
    case commandFailed(code: Int32, stderr: String)
    case timedOut
    case cancelled
    case authenticationRequired(String)
    case malformedOutput
}

public struct GitRepository: Equatable, Sendable {
    public let root: URL
    public let isBare: Bool
}

public struct GitStatusEntry: Equatable, Sendable {
    public enum Kind: String, Sendable { case ordinary, renamed, unmerged, untracked, ignored }
    public let kind: Kind
    public let path: String
    public let originalPath: String?
    /// Porcelain v2 XY: index change followed by worktree change.
    public let indexStatus: Character
    public let worktreeStatus: Character
    public let submodule: String?
}

public struct GitStatus: Equatable, Sendable {
    public let branch: String?
    public let head: String?
    public let entries: [GitStatusEntry]
}

public struct GitBranch: Equatable, Sendable {
    public let name: String
    public let commit: String
    public let isCurrent: Bool
    public let upstream: String?
    public let isRemote: Bool
}

public struct GitWorktree: Equatable, Sendable {
    public let path: String
    public let head: String?
    public let branch: String?
    public let isBare: Bool
    public let isDetached: Bool
    public let lockedReason: String?
    public let prunableReason: String?
}

/// Executes /usr/bin/git without a pager or prompts. Read calls isolate config;
/// userContext writes preserve user identity, credential helpers, and hooks.
/// Each call runs off the caller's executor. Cancellation and timeout kill and reap Git.
/// Paths returned by Git must be UTF-8; undecodable output is a typed error.
public enum GitRunMode: Sendable { case isolatedRead, userContext }

public struct GitProgress: Equatable, Sendable {
    public let phase: String
    public let done: Int
    public let total: Int
    public static func parse(_ line: String) -> GitProgress? {
        guard let regex = try? NSRegularExpression(pattern: #"(Updating files|Receiving objects|Resolving deltas):\s*\d+%\s*\((\d+)/(\d+)\)"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let phase = Range(match.range(at: 1), in: line),
              let done = Range(match.range(at: 2), in: line), let total = Range(match.range(at: 3), in: line),
              let d = Int(line[done]), let t = Int(line[total]) else { return nil }
        return GitProgress(phase: String(line[phase]), done: d, total: t)
    }
}

public struct GitService: Sendable {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 30) { self.timeout = timeout }

    public func repository(at directory: URL) async throws -> GitRepository? {
        let probe = try await execute(["rev-parse", "--is-bare-repository"], at: directory, allowFailure: true)
        if probe.code != 0 {
            if probe.stderr.contains("not a git repository") { return nil }
            throw GitError.commandFailed(code: probe.code, stderr: probe.stderr)
        }
        let bare = probe.stdout.trimmingCharacters(in: .newlines) == "true"
        let root = try await execute(["rev-parse", bare ? "--absolute-git-dir" : "--show-toplevel"], at: directory)
        // Remove exactly Git's trailing newline, preserving whitespace in directory names.
        let path = root.stdout.hasSuffix("\n") ? String(root.stdout.dropLast()) : root.stdout
        return GitRepository(root: URL(fileURLWithPath: path, isDirectory: true), isBare: bare)
    }

    public func status(at directory: URL, includeIgnored: Bool = false) async throws -> GitStatus {
        var args = ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]
        if includeIgnored { args.append("--ignored") }
        let result = try await execute(args, at: directory)
        return try Self.parseStatus(result.stdout)
    }

    public func branches(at directory: URL, includeRemote: Bool = false) async throws -> [GitBranch] {
        var args = ["for-each-ref", "--format=%(refname)%00%(objectname)%00%(HEAD)%00%(upstream:short)", "refs/heads/"]
        if includeRemote { args.append("refs/remotes/") }
        return try await execute(args, at: directory).stdout.split(separator: "\n").map { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 4 else { throw GitError.malformedOutput }
            let remote = fields[0].hasPrefix("refs/remotes/")
            let prefix = remote ? "refs/remotes/" : "refs/heads/"
            return GitBranch(name: String(fields[0].dropFirst(prefix.count)), commit: String(fields[1]),
                             isCurrent: fields[2] == "*", upstream: fields[3].isEmpty ? nil : String(fields[3]),
                             isRemote: remote)
        }
    }

    public func worktrees(at directory: URL) async throws -> [GitWorktree] {
        let output = try await execute(["worktree", "list", "--porcelain", "-z"], at: directory).stdout
        var result: [GitWorktree] = []
        var fields: [String: String] = [:]
        for record in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if record.isEmpty {
                if !fields.isEmpty {
                    guard let path = fields["worktree"] else { throw GitError.malformedOutput }
                    result.append(GitWorktree(path: path, head: fields["HEAD"], branch: fields["branch"],
                        isBare: fields["bare"] != nil, isDetached: fields["detached"] != nil,
                        lockedReason: fields["locked"], prunableReason: fields["prunable"]))
                    fields.removeAll()
                }
            } else {
                let parts = record.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
                fields[String(parts[0])] = parts.count == 2 ? String(parts[1]) : ""
            }
        }
        guard fields.isEmpty else { throw GitError.malformedOutput }
        return result
    }

    public func addWorktree(at directory: URL, path: URL, branch: String? = nil,
                            newBranch: String? = nil, detached: Bool = false) async throws {
        try Self.validatePath(path)
        guard !(detached && newBranch != nil) else { throw GitError.invalidInput("detached new branch") }
        var args = ["worktree", "add"]
        if let newBranch { try Self.validateRef(newBranch); args += ["-b", newBranch] }
        if detached { args.append("--detach") }
        args += ["--", path.path]
        if let branch { try Self.validateRef(branch); args.append(branch) }
        _ = try await run(args, at: directory)
    }

    public func removeWorktree(at directory: URL, path: URL, force: Bool = false) async throws {
        try Self.validatePath(path)
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        _ = try await run(args + ["--", path.path], at: directory)
    }

    /// Tracked working-tree changes by default, or staged changes when `staged` is true.
    /// Untracked files have no Git diff. The path is literal, never a Git pathspec pattern.
    public func diff(at directory: URL, path: String, staged: Bool = false) async throws -> String {
        guard !path.isEmpty, !path.utf8.contains(0) else { throw GitError.invalidInput("path") }
        var args = ["diff", "--no-ext-diff", "--no-textconv", "--no-color"]
        if staged { args.append("--cached") }
        return try await execute(args + ["--", path], at: directory).stdout
    }

    static func parseStatus(_ output: String) throws -> GitStatus {
        let records = output.split(separator: "\0", omittingEmptySubsequences: false)
        var branch: String?, head: String?, entries: [GitStatusEntry] = []
        var index = 0
        while index < records.count {
            let record = records[index]; index += 1
            if record.isEmpty { continue }
            if record.hasPrefix("# branch.head ") { branch = String(record.dropFirst(14)); continue }
            if record.hasPrefix("# branch.oid ") { head = String(record.dropFirst(13)); continue }
            if record.hasPrefix("# ") { continue }
            let tag = record.first!
            if tag == "?" || tag == "!" {
                guard record.hasPrefix("\(tag) ") else { throw GitError.malformedOutput }
                entries.append(GitStatusEntry(kind: tag == "?" ? .untracked : .ignored,
                    path: String(record.dropFirst(2)), originalPath: nil,
                    indexStatus: tag, worktreeStatus: tag, submodule: nil))
                continue
            }
            let count: Int
            let kind: GitStatusEntry.Kind
            switch tag {
            case "1": count = 8; kind = .ordinary
            case "2": count = 9; kind = .renamed
            case "u": count = 10; kind = .unmerged
            default: throw GitError.malformedOutput
            }
            let parts = record.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false)
            guard parts.count == count + 1, parts[1].count == 2 else { throw GitError.malformedOutput }
            var original: String?
            if tag == "2" {
                guard index < records.count, !records[index].isEmpty else { throw GitError.malformedOutput }
                original = String(records[index]); index += 1
            }
            entries.append(GitStatusEntry(kind: kind, path: String(parts[count]), originalPath: original,
                indexStatus: parts[1].first!, worktreeStatus: parts[1].last!, submodule: String(parts[2])))
        }
        return GitStatus(branch: branch, head: head, entries: entries)
    }

    private static func validateRef(_ ref: String) throws {
        guard !ref.isEmpty, !ref.hasPrefix("-"), !ref.utf8.contains(0) else { throw GitError.invalidInput("ref") }
    }

    private static func validatePath(_ path: URL) throws {
        guard path.isFileURL, !path.path.utf8.contains(0) else { throw GitError.invalidInput("directory") }
    }

    public struct Output: Sendable { public let stdout: String; public let stderr: String; public let code: Int32 }

    /// Writes have no deadline unless the caller explicitly supplies one.
    public func run(_ arguments: [String], at directory: URL, mode: GitRunMode = .userContext,
                    timeout: TimeInterval? = nil, stdin: Data? = nil,
                    environment: [String: String]? = nil, control: GitProcessControl = GitProcessControl(),
                    stderr: (@Sendable (String) -> Void)? = nil,
                    progress: (@Sendable (GitProgress) -> Void)? = nil,
                    allowFailure: Bool = false) async throws -> Output {
        try Self.validatePath(directory)
        if let timeout { guard timeout.isFinite, timeout > 0, timeout <= 86_400 else { throw GitError.invalidInput("timeout") } }
        guard arguments.allSatisfy({ !$0.utf8.contains(0) }) else { throw GitError.invalidInput("arguments") }
        return try await withTaskCancellationHandler {
            if Task.isCancelled { throw GitError.cancelled }
            return try await Task.detached {
                try Self.runBlocking(arguments, at: directory, timeout: timeout, control: control,
                    allowFailure: allowFailure, mode: mode, input: stdin, environment: environment,
                    onStderr: stderr, progress: progress)
            }.value
        } onCancel: { control.cancel() }
    }

    private func execute(_ arguments: [String], at directory: URL, allowFailure: Bool = false) async throws -> Output {
        try Self.validatePath(directory)
        guard timeout.isFinite, timeout > 0, timeout <= 86_400 else { throw GitError.invalidInput("timeout") }
        let control = GitProcessControl()
        return try await withTaskCancellationHandler {
            if Task.isCancelled { throw GitError.cancelled }
            return try await Task.detached {
                try Self.runBlocking(arguments, at: directory, timeout: timeout, control: control, allowFailure: allowFailure)
            }.value
        } onCancel: { control.cancel() }
    }

    private static func runBlocking(_ arguments: [String], at directory: URL, timeout: TimeInterval?,
                                    control: GitProcessControl, allowFailure: Bool, mode: GitRunMode = .isolatedRead,
                                    input: Data? = nil, environment suppliedEnvironment: [String: String]? = nil,
                                    onStderr: (@Sendable (String) -> Void)? = nil,
                                    progress: (@Sendable (GitProgress) -> Void)? = nil) throws -> Output {
        // Regular files avoid pipe capacity deadlocks and inherited-pipe EOF hangs.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("smthz-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outURL = temporary.appendingPathComponent("out"), errURL = temporary.appendingPathComponent("err")
        _ = FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        _ = FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: outURL)
        defer { try? out.close() }
        let err = try FileHandle(forWritingTo: errURL)
        defer { try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = directory
        process.arguments = ["--no-pager", "--literal-pathspecs", "-c", "core.fsmonitor=false"]
            + (mode == .isolatedRead ? ["-c", "core.hooksPath=/dev/null"] : []) + arguments
        var environment = suppliedEnvironment ?? ProcessInfo.processInfo.environment
        if mode == .isolatedRead {
            environment = environment.filter { !$0.key.hasPrefix("GIT_") }
            environment["GIT_CONFIG_NOSYSTEM"] = "1"; environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        } else {
            environment.removeValue(forKey: "GIT_ASKPASS"); environment.removeValue(forKey: "SSH_ASKPASS")
            if environment["GIT_SSH_COMMAND"] == nil { environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        }
        environment["LC_ALL"] = "C"; environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        var inputHandle: FileHandle?
        if let input {
            let inputURL = temporary.appendingPathComponent("stdin")
            try input.write(to: inputURL)
            inputHandle = try FileHandle(forReadingFrom: inputURL)
        }
        defer { try? inputHandle?.close() }
        process.standardInput = inputHandle ?? FileHandle.nullDevice
        process.standardOutput = out; process.standardError = err
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try control.start(process)
        defer {
            if process.isRunning { control.stop() }
            process.waitUntilExit()
        }
        let reader = try FileHandle(forReadingFrom: errURL)
        defer { try? reader.close() }
        var pending = Data()
        func drain(final: Bool = false) throws {
            pending.append(try reader.readToEnd() ?? Data())
            while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                let line = String(decoding: pending[..<end], as: UTF8.self)
                pending.removeSubrange(...end)
                if !line.isEmpty { onStderr?(line); if let p = GitProgress.parse(line) { progress?(p) } }
            }
            if final || pending.count > 16_384 {
                if !pending.isEmpty { onStderr?(String(decoding: pending, as: UTF8.self)) }
                pending.removeAll(keepingCapacity: true)
            }
        }
        let deadline = timeout.map { Date(timeIntervalSinceNow: $0) }
        while ended.wait(timeout: .now() + min(timeout ?? 0.01, 0.01)) == .timedOut {
            try drain()
            if let deadline, Date() >= deadline {
                control.stop(); process.waitUntilExit()
                if control.wasCancelled { throw GitError.cancelled }
                throw GitError.timedOut
            }
        }
        try drain(final: true)
        process.waitUntilExit()
        if control.wasCancelled { throw GitError.cancelled }
        guard let stdout = String(data: try Data(contentsOf: outURL), encoding: .utf8),
              let stderr = String(data: try Data(contentsOf: errURL), encoding: .utf8) else { throw GitError.malformedOutput }
        if process.terminationStatus != 0 && !allowFailure {
            if ["could not read Username", "Permission denied (publickey)", "terminal prompts disabled", "Authentication failed"].contains(where: stderr.contains) {
                throw GitError.authenticationRequired(stderr)
            }
            if stderr.contains("not a git repository") { throw GitError.notRepository }
            throw GitError.commandFailed(code: process.terminationStatus, stderr: stderr)
        }
        return Output(stdout: stdout, stderr: stderr, code: process.terminationStatus)
    }

}

/// Lock serializes launch with cancellation, including cancellation before launch.
public final class GitProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    public init() {}
    public var wasCancelled: Bool { lock.withLock { cancelled } }
    func start(_ process: Process) throws {
        try lock.withLock {
            guard !cancelled else { throw GitError.cancelled }
            do { try process.run() } catch { throw GitError.launchFailed(String(describing: error)) }
            self.process = process
        }
    }
    func stop() { lock.withLock { killRunning() } }
    public func cancel() { lock.withLock { cancelled = true; killRunning() } }
    private func killRunning() {
        if let process, process.isRunning {
            let pid = process.processIdentifier
            // Foundation Process starts a new process group. Verify ownership
            // before signalling it, then kill Git as a fallback on other runtimes.
            if getpgid(pid) == pid { Darwin.kill(-pid, SIGKILL) }
            else { Darwin.kill(pid, SIGKILL) }
        }
    }
}
