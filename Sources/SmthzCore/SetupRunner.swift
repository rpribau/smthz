import Foundation

public enum SetupRunner {
    static func sharedCommandsEnabled(_ repo: [String: WorkspaceSQLValue]) -> Bool {
        let policy = repo["command_source_policy"]?.string
        return policy != "local-only" && (policy != nil || (repo["local_setup_script"]?.string ?? "").isEmpty)
    }
    public static func script(store: WorkspaceStore, repo: [String: WorkspaceSQLValue], kind: String,
                              root: String) throws -> (String, SmthzConfigFile.Source) {
        let file = SmthzConfigLoader.load(repoRoot: root)
        return try selectedScript(store: store, repo: repo, kind: kind, file: file)
    }
    static func requireTrust(store: WorkspaceStore, repoID: String, kind: String, script: String) throws {
        guard !script.isEmpty else { return }
        let trusted = try store.query("SELECT content_hash FROM hook_trust WHERE repo_id=? AND kind=?", [.text(repoID), .text(kind)]).first?["content_hash"]?.string
        guard trusted == SmthzConfigTrust.contentHash(script) else { throw HostRPCError("untrustedCommand", detail: "\(kind): \(SmthzConfigTrust.contentHash(script))") }
    }
    static func selectedScript(store: WorkspaceStore, repo: [String: WorkspaceSQLValue], kind: String,
                               file: SmthzConfigFile?) throws -> (String, SmthzConfigFile.Source) {
        let shared = (kind == "setup" ? file?.config?.setupScript : file?.config?.archiveScript) ?? ""
        let local = repo["local_\(kind)_script"]?.string ?? ""
        let policy = repo["command_source_policy"]?.string
        let useShared = policy != "local-only" && (policy == "run-both" || local.isEmpty || policy == "shared-only")
        if useShared, !shared.isEmpty {
            try requireTrust(store: store, repoID: repo["id"]!.string!, kind: kind, script: shared)
        }
        let scripts = [useShared ? shared : "", policy == "shared-only" ? "" : local].filter { !$0.isEmpty }
        return (scripts.joined(separator: "\n"), file?.source ?? .smthz)
    }
    public static func start(script: String, source: SmthzConfigFile.Source, root: String, path: String,
                             sessions: SessionManager, kind: String = "setup") throws -> SessionInfo {
        let git = GitService()
        let raw = try git.worktreeGit(["rev-parse", "--git-path", "smthz/\(kind)-runner.sh"], at: path).stdout.trimmingCharacters(in: .newlines)
        let url = URL(fileURLWithPath: raw, relativeTo: URL(fileURLWithPath: path, isDirectory: true)).standardizedFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var body = script
        var options = ""
        if body.hasPrefix("#!"), let line = body.firstIndex(of: "\n") {
            let words = body[..<line].split(separator: " ").dropFirst()
            options = words.filter { $0.hasPrefix("-") && !$0.contains(where: { !$0.isLetter && $0 != "-" }) }.joined(separator: " ")
            body = String(body[body.index(after: line)...])
        }
        try Data(("#!/usr/bin/env bash\nset -e\n" + (options.isEmpty ? "" : "set \(options)\n") + body + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        var env = ProcessInfo.processInfo.environment
        env.merge(SmthzConfigLoader.setupEnvironment(rootPath: root, worktreePath: path, source: source)) { _, new in new }
        return try sessions.create(executable: "/bin/bash", arguments: [url.path], environment: env, workingDirectory: path)
    }
    static func archive(store: WorkspaceStore, repo: [String: WorkspaceSQLValue], path: String,
                        sessions: SessionManager?, allowFailure: Bool, context: HostJobContext? = nil,
                        cancellation: @Sendable () -> String? = { nil }) throws -> Bool {
        let root = repo["path"]!.string!
        let (script, source) = try script(store: store, repo: repo, kind: "archive", root: root)
        guard !script.isEmpty else { return false }
        guard let sessions else { throw HostRPCError("badRequest", detail: "session manager unavailable") }
        let session = try start(script: script, source: source, root: root, path: path, sessions: sessions, kind: "archive")
        let deadline = Date(timeIntervalSinceNow: 600)
        while sessions.list().contains(where: { $0.id == session.id && $0.running }) {
            if let code = cancellation() { try? sessions.close(id: session.id); throw HostRPCError(code) }
            if context?.isCancelled == true || Date() >= deadline {
                try? sessions.close(id: session.id)
                try context?.checkCancellation()
                if allowFailure { return true }
                throw HostRPCError("archiveHookFailed", detail: "archive hook timed out")
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let result = try sessions.read(id: session.id, from: 0, maxBytes: 1)
        guard result.exit == .exited(0) else {
            if allowFailure { return true }
            throw HostRPCError("archiveHookFailed")
        }
        return false
    }
}
