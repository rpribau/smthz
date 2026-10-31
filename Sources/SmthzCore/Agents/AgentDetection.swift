import Darwin
import Foundation

public struct DetectedAgent: Equatable, Sendable {
    public let id: AgentID
    public let executable: String
    public let version: String?

    public init(id: AgentID, executable: String, version: String?) {
        self.id = id
        self.executable = executable
        self.version = version
    }
}

/// Resolves executables using the session PATH, without invoking a shell. Version
/// commands are untrusted: bounded output, a three-second deadline, a private
/// process group and waitpid are used even when the probe ignores SIGTERM.
public enum AgentDetector {
    public static let versionTimeout: TimeInterval = 3
    public static let maximumConcurrentProbes = 4

    // Shared across calls, so concurrent refreshes cannot exceed four children.
    private static let probeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "dev.smthz.agent-detection"
        queue.maxConcurrentOperationCount = maximumConcurrentProbes
        return queue
    }()

    public static func detect(path: String? = nil) async -> [DetectedAgent] {
        let sessionPath = path ?? SessionEnvironment.build(base: ProcessInfo.processInfo.environment)["PATH"] ?? ""
        return await withTaskGroup(of: DetectedAgent?.self) { group in
            for config in AgentCatalog.all {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return await withCheckedContinuation { continuation in
                        probeQueue.addOperation {
                            let result = detect(config, path: sessionPath)
                            continuation.resume(returning: result)
                        }
                    }
                }
            }
            var found: [AgentID: DetectedAgent] = [:]
            for await agent in group {
                if let agent { found[agent.id] = agent }
            }
            return AgentID.allCases.compactMap { found[$0] }
        }
    }

    private static func detect(_ config: AgentConfig, path: String) -> DetectedAgent? {
        guard config.detectRequiredCommands.allSatisfy({ resolve($0, path: path) != nil }),
              let executable = ([config.detectCmd] + config.detectCmdAliases).lazy.compactMap({ resolve($0, path: path) }).first
        else { return nil }
        return DetectedAgent(id: config.id, executable: executable, version: probe(executable, path: path))
    }

    private static func resolve(_ command: String, path: String) -> String? {
        // Ignore empty/relative PATH components: probing a workspace's executable
        // implicitly would run untrusted code merely by opening that workspace.
        for directory in path.split(separator: ":") where directory.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command).path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               !isDirectory.boolValue, access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }

    private static func probe(_ executable: String, path: String) -> String? {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { return nil }
        defer { close(descriptors[0]); close(descriptors[1]) }
        for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, descriptors[1]) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0
        else { return nil }
        var environment = SessionEnvironment.build(base: ProcessInfo.processInfo.environment)
        environment["PATH"] = path
        let args = [executable, "--version"].map { strdup($0) }
        let env = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { for pointer in args + env { free(pointer) } }
        var argv = args + [nil]
        var envp = env + [nil]
        var pid: pid_t = 0
        guard posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp) == 0 else { return nil }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + versionTimeout
        var status: Int32 = 0
        var timedOut = false
        func drain() {
            // Bound each pass as well as retained output, even for a noisy child.
            for _ in 0..<16 {
                let count = read(descriptors[0], &buffer, buffer.count)
                guard count > 0 else { break }
                let remaining = 65_536 - output.count
                if remaining > 0 { output.append(contentsOf: buffer.prefix(min(count, remaining))) }
            }
        }
        while true {
            drain()
            // Observe without reaping first: retain ownership of the pid/process
            // group until after the final group signal, avoiding PID-reuse races.
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid { break }
            if ProcessInfo.processInfo.systemUptime >= deadline { timedOut = true; break }
            usleep(5_000)
        }
        // Kill descendants retaining the output pipe, including on normal exit.
        _ = kill(-pid, SIGKILL)
        _ = kill(pid, SIGKILL)
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { return nil }
        }
        drain()
        guard !timedOut, status == 0 else { return nil }
        return parseVersion(String(decoding: output, as: UTF8.self))
    }

    static func parseVersion(_ output: String) -> String? {
        // Keep semver prerelease/build labels while rejecting dotted fragments.
        let pattern = #"(?<![0-9.])[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?(?![0-9.])"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        return String(output[range])
    }
}
