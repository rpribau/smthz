import Darwin
import Foundation

public enum AgentLaunchMode: String, Codable, Sendable { case draft, submit }
public enum AgentLaunchPermission: String, Codable, Sendable { case `default`, auto, bypass }

public struct AgentLaunchRequest: Codable, Sendable, Equatable {
    public var agent: AgentID
    public var cwd: String
    public var prompt: String?
    public var mode: AgentLaunchMode
    public var permission: AgentLaunchPermission
    public var extraArgs: [String]
    public var accountId: String?

    public init(agent: AgentID, cwd: String, prompt: String? = nil, mode: AgentLaunchMode = .submit,
                permission: AgentLaunchPermission = .default, extraArgs: [String] = [], accountId: String? = nil) {
        self.agent = agent; self.cwd = cwd; self.prompt = prompt; self.mode = mode
        self.permission = permission; self.extraArgs = extraArgs; self.accountId = accountId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try c.decode(AgentID.self, forKey: .agent)
        cwd = try c.decode(String.self, forKey: .cwd)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
        mode = try c.decodeIfPresent(AgentLaunchMode.self, forKey: .mode) ?? .submit
        permission = try c.decodeIfPresent(AgentLaunchPermission.self, forKey: .permission) ?? .default
        extraArgs = try c.decodeIfPresent([String].self, forKey: .extraArgs) ?? []
        accountId = try c.decodeIfPresent(String.self, forKey: .accountId)
    }
}

public struct AgentLaunchPlan: Sendable {
    public let executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public let deferredPrompt: Data?

    /// Catalog launchCmd strings contain only fixed executable/argument words. No shell is invoked.
    /// Prompt flags mirror reference src/shared/tui-agent-startup.ts; trust preflight stays off (U-B2).
    public static func build(_ request: AgentLaunchRequest, environment: [String: String]) throws -> Self {
        guard request.accountId == nil else { throw HostRPCError("unsupportedAccount", detail: "Account selection is not implemented") }
        var directory: ObjCBool = false
        guard request.cwd.hasPrefix("/"), !request.cwd.utf8.contains(0),
              FileManager.default.fileExists(atPath: request.cwd, isDirectory: &directory), directory.boolValue,
              !(request.extraArgs + [request.prompt ?? ""]).contains(where: { $0.utf8.contains(0) })
        else { throw HostRPCError("badRequest") }
        let config = request.agent.config
        let path = environment["PATH"] ?? ""
        func resolve(_ name: String) -> String? {
            for dir in path.split(separator: ":") where dir.hasPrefix("/") {
                let file = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory),
                   !isDirectory.boolValue, access(file, X_OK) == 0 { return file }
            }
            return nil
        }
        guard config.detectRequiredCommands.allSatisfy({ resolve($0) != nil }),
              let executable = ([config.detectCmd] + config.detectCmdAliases).lazy.compactMap({ resolve($0) }).first
        else { throw HostRPCError("agentNotInstalled", detail: request.agent.rawValue) }
        var args = config.launchCmd.split(separator: " ").dropFirst().map(String.init)
        var env = environment
        switch request.permission {
        case .default: break
        case .auto: args += config.permissionArgs.auto
        case .bypass:
            args += config.permissionArgs.bypass
            env.merge(config.permissionArgs.bypassEnvironment) { _, new in new }
        }
        args += request.extraArgs
        var deferred: Data?
        if let prompt = request.prompt, !prompt.isEmpty {
            if request.mode == .draft {
                if let flag = config.draftPromptFlag { args += [flag, prompt] }
                else if let key = config.draftPromptEnvVar { env[key] = prompt }
                else { deferred = Data(("\u{1b}[200~" + prompt + "\u{1b}[201~").utf8) }
            } else {
                switch config.promptInjectionMode {
                case .argv:
                    if let separator = config.argvPromptSeparator { args.append(separator) }
                    args.append(prompt)
                case .flagPrompt: args += ["--prompt", prompt]
                case .flagPromptInteractive: args += ["--prompt-interactive", prompt]
                case .flagInteractive: args += ["-i", prompt]
                case .hermesQuery:
                    args.removeAll { $0 == "--tui" }
                    args = ["chat", "--query=" + prompt] + args + ["--tui"]
                case .stdinAfterStart: deferred = Data(("\u{1b}[200~" + prompt + "\u{1b}[201~\r").utf8)
                }
            }
        }
        return Self(executable: executable, arguments: args, environment: env, deferredPrompt: deferred)
    }
}

/// Scoped credentials live only here and in the launched child's environment. They are never
/// returned in RPC responses, stored in the journal, or substituted for the host capability.
public final class AgentLaunchService: @unchecked Sendable {
    public struct Scope: Sendable, Equatable {
        public let sessionID: String
        public let agent: AgentID
        public let launchToken: String
        public let hookToken: String
    }
    private let lock = NSLock()
    private var scopes: [String: Scope] = [:]
    private let sessions: SessionManager
    private let stateDirectory: URL
    private let socketPath: String
    private let environment: [String: String]
    private let hookExecutable: String

    public init(sessions: SessionManager, stateDirectory: URL, socketPath: String,
                environment: [String: String], hookExecutable: String? = nil) {
        self.sessions = sessions; self.stateDirectory = stateDirectory; self.socketPath = socketPath
        // An explicitly supplied host PATH is a session override. In particular a
        // private host with a fake-agent PATH must never resolve a real paid CLI.
        self.environment = SessionEnvironment.build(base: environment,
            override: environment["PATH"].map { ["PATH": $0] })
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("smthz").path
        self.hookExecutable = hookExecutable ?? sibling
    }

    /// Only agent.hook may consume this scope; callers must also compare the agent and launch token.
    public func scope(sessionID: String, hookToken: String) -> Scope? {
        guard sessions.list().contains(where: { $0.id == sessionID && $0.running }) else { return nil }
        return lock.withLock {
            guard let scope = scopes[sessionID], scope.hookToken.utf8.count == hookToken.utf8.count else { return nil }
            var difference: UInt8 = 0
            for (a, b) in zip(scope.hookToken.utf8, hookToken.utf8) { difference |= a ^ b }
            return difference == 0 ? scope : nil
        }
    }

    public func list(checkCancellation: @Sendable () throws -> Void = {}) throws -> [DetectedAgent] {
        // Detector probes have their own process deadlines; do not occupy the main thread.
        final class ResultBox: @unchecked Sendable { let lock = NSLock(); var value: [DetectedAgent]? }
        let box = ResultBox()
        let path = environment["PATH"] ?? ""
        let task = Task.detached {
            let result = await AgentDetector.detect(path: path)
            box.lock.withLock { box.value = result }
        }
        defer { task.cancel() }
        while true {
            try checkCancellation()
            if let result = box.lock.withLock({ box.value }) { return result }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    public func launch(_ request: AgentLaunchRequest, checkCancellation: @Sendable () throws -> Void = {}) throws -> SessionInfo {
        try checkCancellation()
        var plan = try AgentLaunchPlan.build(request, environment: environment)
        let id = RequestID.generate().rawValue
        let launchToken = RequestID.generate().rawValue
        let scope = Scope(sessionID: id, agent: request.agent, launchToken: launchToken, hookToken: HostCapabilityToken.random())
        plan.environment.merge(["SMTHZ_SESSION_ID": id, "SMTHZ_SOCKET": socketPath,
            "SMTHZ_AGENT_ID": request.agent.rawValue, "SMTHZ_LAUNCH_TOKEN": launchToken,
            "SMTHZ_HOOK_TOKEN": scope.hookToken]) { _, new in new }
        // Never pass credentials inherited from an enclosing smthz-launched terminal.
        plan.environment["SMTHZ_CAPABILITY_TOKEN"] = nil
        var settings: URL?
        if [.claude, .claudeAgentTeams, .openclaude, .qoder, .qoderCn, .qwenCode, .codebuddy].contains(request.agent) {
            let directory = stateDirectory.appendingPathComponent("hooks", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("claude-\(launchToken).json")
            let data = try ClaudeHookSettings.json(command: ClaudeHookSettings.hookCommand(executablePath: hookExecutable))
            let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw HostRPCError("hookSettingsFailure") }
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            let synced = fsync(fd) == 0
            Darwin.close(fd)
            guard written == data.count, synced else { unlink(file.path); throw HostRPCError("hookSettingsFailure") }
            settings = file
            plan.arguments += ["--settings", file.path]
        }
        let info: SessionInfo
        do {
            try checkCancellation()
            info = try sessions.create(executable: plan.executable, arguments: plan.arguments,
                environment: plan.environment, workingDirectory: request.cwd, id: id)
        } catch {
            if let settings { try? FileManager.default.removeItem(at: settings) }
            if let error = error as? SessionError { throw HostRPCError(error.rawValue) }
            throw error
        }
        let live = Set(sessions.list().filter(\.running).map(\.id))
        lock.withLock { scopes = scopes.filter { live.contains($0.key) }; scopes[id] = scope }
        if let prompt = plan.deferredPrompt {
            do {
                var cursor: UInt64 = 0
                let began = ProcessInfo.processInfo.systemUptime
                var quietSince = began
                while ProcessInfo.processInfo.systemUptime - began < 20 {
                    try checkCancellation()
                    let output = try sessions.read(id: id, from: cursor, maxBytes: 65_536)
                    cursor = output.nextOffset
                    guard output.exit == nil else { throw HostRPCError("agentExited") }
                    if !output.data.isEmpty { quietSince = ProcessInfo.processInfo.systemUptime }
                    if ProcessInfo.processInfo.systemUptime - quietSince >= 0.5 { break }
                    Thread.sleep(forTimeInterval: 0.02)
                }
                try checkCancellation()
                try sessions.write(id: id, data: prompt)
            } catch {
                sessions.discard(id: id)
                _ = lock.withLock { scopes.removeValue(forKey: id) }
                if let settings { try? FileManager.default.removeItem(at: settings) }
                throw error
            }
        }
        return info
    }
}
