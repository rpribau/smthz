import Foundation
import Darwin

/// Pipe transport seam: callers may inject a fake executable or an in-memory process.
public protocol CodexAppServerProcess: Sendable {
    func launch() throws -> AsyncThrowingStream<Data, Error>
    func write(_ data: Data) async throws
    /// Must close the pipes and reap the child before returning; safe more than once.
    func stop()
}

/// Owns a private process group. Retains the leader until the final group signal, like AgentDetector.
public final class CodexStdioProcess: CodexAppServerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let executable: URL
    private let arguments: [String]
    private let directory: URL?
    private let environment: [String: String]
    private let writes = DispatchQueue(label: "dev.smthz.codex.stdin")
    private var pid: pid_t = 0
    private var exitStatus: Int32?
    private var inputFD: Int32 = -1
    private var started = false
    private var stopped = false

    public init(executable: URL, arguments: [String] = ["app-server"],
                directory: URL? = nil, environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.environment = environment ?? ProcessInfo.processInfo.environment
    }

    public func launch() throws -> AsyncThrowingStream<Data, Error> {
        let outputFD = try lock.withLock {
            guard !started, !stopped else { throw CodexAppServerError.invalidState }
            let values = [executable.path] + arguments + environment.map { "\($0.key)=\($0.value)" } + [directory?.path ?? ""]
            guard !values.contains(where: { $0.utf8.contains(0) }) else { throw CodexAppServerError.invalidState }
            var input: [Int32] = [-1, -1], output: [Int32] = [-1, -1]
            guard pipe(&input) == 0 else { throw posixError() }
            guard pipe(&output) == 0 else { close(input[0]); close(input[1]); throw posixError() }
            var keepParentEnds = false
            defer {
                close(input[0]); close(output[1])
                if !keepParentEnds { close(input[1]); close(output[0]) }
            }
            for fd in input + output {
                guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw posixError() }
            }
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            try check(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }
            try check(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }
            try check(posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO))
            try check(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO))
            try check(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))
            for fd in input + output { try check(posix_spawn_file_actions_addclose(&actions, fd)) }
            if let directory { try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path)) }
            try check(posix_spawnattr_setpgroup(&attributes, 0))
            try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
            let args = ([executable.path] + arguments).map { strdup($0) }
            let env = environment.map { strdup("\($0.key)=\($0.value)") }
            defer { for pointer in args + env { free(pointer) } }
            var argv = args + [nil], envp = env + [nil]
            try check(posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp))
            started = true
            inputFD = input[1]
            keepParentEnds = true
            return output[0]
        }
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let leader = lock.withLock { pid }
        Thread { [self] in
            // A descendant can retain stdout after the leader exits; observe exit independently of EOF.
            var info = siginfo_t()
            while waitid(P_PID, id_t(leader), &info, WEXITED | WNOWAIT) < 0 {
                if errno != EINTR { break }
            }
            lock.withLock {
                if pid == leader, pid > 0 { exitStatus = reap() }
            }
        }.start()
        Thread { [self] in
            defer { close(outputFD) }
            var bytes = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = Darwin.read(outputFD, &bytes, bytes.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    pair.continuation.finish(throwing: posixError())
                    stop()
                    return
                }
                if case .dropped = pair.continuation.yield(Data(bytes.prefix(count))) {
                    pair.continuation.finish(throwing: CodexAppServerError.overloaded)
                    stop()
                    return
                }
            }
            // EOF can precede process exit. Poll without holding the lock so close/timeout can stop it.
            while true {
                if let error = lock.withLock({ () -> CodexAppServerError? in
                    if stopped { return .closed }
                    return exitStatus.map { .processExited($0) }
                }) {
                    pair.continuation.finish(throwing: error)
                    return
                }
                usleep(5_000)
            }
        }.start()
        return pair.stream
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writes.async { [self] in
                do {
                    // A private duplicate prevents descriptor reuse if stop closes stdin concurrently.
                    let fd = try lock.withLock {
                        guard inputFD >= 0, !stopped else { throw CodexAppServerError.closed }
                        let fd = dup(inputFD)
                        guard fd >= 0 else { throw posixError() }
                        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
                            let error = posixError(); close(fd); throw error
                        }
                        return fd
                    }
                    defer { close(fd) }
                    try data.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                            if count < 0 && errno == EINTR { continue }
                            guard count > 0 else { throw posixError() }
                            offset += count
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            if pid > 0 {
                _ = kill(-pid, SIGTERM)
                let deadline = ProcessInfo.processInfo.systemUptime + 0.2
                while !exited(), ProcessInfo.processInfo.systemUptime < deadline { usleep(5_000) }
                exitStatus = reap()
            }
            if inputFD >= 0 { close(inputFD); inputFD = -1 }
        }
    }

    private func exited() -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }

    private func reap() -> Int32 {
        // Do this before waitpid relinquishes ownership of the leader's PID/group identity.
        _ = kill(-pid, SIGKILL)
        _ = kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 { if errno != EINTR { break } }
        pid = 0
        if inputFD >= 0 { close(inputFD); inputFD = -1 }
        return status & 0x7F == 0 ? (status >> 8) & 0xFF : -(status & 0x7F)
    }

    private func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    private func check(_ code: Int32) throws { if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) } }
    deinit { stop() }
}
