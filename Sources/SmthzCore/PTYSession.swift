import Darwin
import Foundation

@_silgen_name("fork") private func smthzFork() -> pid_t

public struct PTYSize: Equatable, Sendable {
    public var rows: UInt16
    public var cols: UInt16

    public init(rows: UInt16, cols: UInt16) {
        self.rows = rows
        self.cols = cols
    }
}

public enum PTYError: Error, Equatable {
    case openFailed(Int32)
    case spawnFailed(Int32)
    case writeFailed(Int32)
    case notRunning
}

public enum PTYExit: Equatable, Sendable {
    case exited(Int32)
    case signaled(Int32)
}

/// Owns the child and its master terminal independently of any UI attachment.
public final class PTYSession: @unchecked Sendable {
    public let identity: ProcessIdentity
    public var pid: Int32 { identity.pid }
    private let state: State

    public init(executable: String, arguments: [String], environment: [String: String],
                workingDirectory: String?, size: PTYSize) throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var window = winsize(ws_row: size.rows, ws_col: size.cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &window) == 0 else {
            throw PTYError.openFailed(errno)
        }
        var transferred = false
        defer {
            Darwin.close(slave)
            if !transferred { Darwin.close(master) }
        }
        guard fcntl(master, F_SETFD, FD_CLOEXEC) != -1,
              fcntl(slave, F_SETFD, FD_CLOEXEC) != -1,
              fcntl(master, F_SETFL, O_NONBLOCK) != -1 else { throw PTYError.openFailed(errno) }
        // Use a close-on-exec error pipe to report setup/exec failures to the
        // parent. The child path after fork is deliberately syscall-only: a
        // multithreaded process must not call Swift/Foundation there.
        var errorPipe: [Int32] = [0, 0]
        guard pipe(&errorPipe) == 0 else { throw PTYError.spawnFailed(errno) }
        for fd in errorPipe {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 else {
                let code = errno
                Darwin.close(errorPipe[0]); Darwin.close(errorPipe[1])
                throw PTYError.spawnFailed(code)
            }
        }
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let executablePath = strdup(executable)
        let directoryPath = workingDirectory.map { strdup($0) }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            free(executablePath)
            if let directoryPath { free(directoryPath) }
        }
        var child: pid_t = -1
        argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                child = smthzFork()
                if child == 0 {
                    Darwin.close(master)
                    Darwin.close(errorPipe[0])
                    var failure: Int32 = 0
                    // The host installs ignored dispositions for its own
                    // shutdown signals and may have a non-empty thread mask.
                    // Restore ordinary child semantics before entering exec.
                    var signalMask = sigset_t()
                    sigemptyset(&signalMask)
                    sigprocmask(SIG_SETMASK, &signalMask, nil)
                    for number in 1..<NSIG where number != SIGKILL && number != SIGSTOP {
                        _ = signal(number, SIG_DFL)
                    }
                    if setsid() == -1 { failure = errno }
                    else if ioctl(slave, TIOCSCTTY, 0) == -1 { failure = errno }
                    else if dup2(slave, STDIN_FILENO) == -1 ||
                                dup2(slave, STDOUT_FILENO) == -1 ||
                                dup2(slave, STDERR_FILENO) == -1 { failure = errno }
                    else if let directoryPath, chdir(directoryPath) == -1 { failure = errno }
                    if failure == 0 {
                        execve(executablePath!, args.baseAddress!, env.baseAddress!)
                        failure = errno
                    }
                    _ = Darwin.write(errorPipe[1], &failure, MemoryLayout<Int32>.size)
                    _exit(127)
                }
            }
        }
        guard child > 0 else {
            let code = errno
            Darwin.close(errorPipe[0]); Darwin.close(errorPipe[1])
            throw PTYError.spawnFailed(code)
        }
        Darwin.close(errorPipe[1])
        var childError: Int32 = 0
        let errorBytes = withUnsafeMutableBytes(of: &childError) { buffer -> Int in
            var total = 0
            while total < buffer.count {
                let count = Darwin.read(errorPipe[0], buffer.baseAddress!.advanced(by: total), buffer.count - total)
                if count > 0 { total += count }
                else if count < 0 && errno == EINTR { continue }
                else { break }
            }
            return total
        }
        Darwin.close(errorPipe[0])
        if errorBytes > 0 {
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            throw PTYError.spawnFailed(errorBytes == MemoryLayout<Int32>.size ? childError : EIO)
        }
        // A child that exits immediately can be unavailable to proc_pidinfo.
        // Zero start time is a sentinel identity in that case, never used to signal.
        identity = ProcessIdentity.lookup(pid: child)
            ?? ProcessIdentity(pid: child, startSeconds: 0, startMicroseconds: 0)
        state = State(fd: master, pid: child)
        transferred = true
        let monitor = state
        // A long-lived blocking monitor must not occupy a shared dispatch
        // worker needed by socket handlers and other sessions under load.
        let monitorThread = Thread { monitor.run() }
        monitorThread.name = "SmthzCore.PTYSession.\(child)"
        monitorThread.qualityOfService = .utility
        monitorThread.start()
    }

    public func setOutputHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        state.condition.lock()
        defer { state.condition.unlock() }
        state.handler = handler
        if !state.buffer.isEmpty {
            let bytes = state.buffer
            state.buffer.removeAll(keepingCapacity: false)
            state.delivery.async { handler(bytes) }
        }
    }

    /// Cancellation may interrupt after writing a prefix of data.
    public func write(_ data: Data, shouldCancel: (@Sendable () -> Bool)? = nil) throws {
        // Serialize whole writes, but release the lifecycle lock while waiting
        // for space so the reader and termination monitor can make progress.
        if let shouldCancel {
            while !state.writer.try() {
                if shouldCancel() { throw PTYError.writeFailed(ECANCELED) }
                Thread.sleep(forTimeInterval: 0.002)
            }
        } else { state.writer.lock() }
        defer { state.writer.unlock() }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            repeat {
                if shouldCancel?() == true { throw PTYError.writeFailed(ECANCELED) }
                state.condition.lock()
                guard state.fd >= 0, state.result == nil, !state.closing else {
                    state.condition.unlock()
                    throw PTYError.notRunning
                }
                if offset == bytes.count { state.condition.unlock(); return }
                let count = Darwin.write(state.fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                let code = errno
                state.condition.unlock()
                if count > 0 { offset += count }
                else if count < 0 && code == EINTR { continue }
                else if count < 0 && (code == EAGAIN || code == EWOULDBLOCK) {
                    Thread.sleep(forTimeInterval: 0.002)
                } else { throw PTYError.writeFailed(count == 0 ? EIO : code) }
            } while true
        }
    }

    public func resize(_ size: PTYSize) throws {
        state.condition.lock()
        defer { state.condition.unlock() }
        guard state.fd >= 0, state.result == nil, !state.closing else { throw PTYError.notRunning }
        var window = winsize(ws_row: size.rows, ws_col: size.cols, ws_xpixel: 0, ws_ypixel: 0)
        // The kernel sends SIGWINCH to the terminal's foreground process group.
        guard ioctl(state.fd, TIOCSWINSZ, &window) == 0 else { throw PTYError.writeFailed(errno) }
    }

    /// Reads the controlling terminal while holding the descriptor lifecycle lock.
    public func foregroundProcessGroupID() throws -> Int32 {
        state.condition.lock()
        defer { state.condition.unlock() }
        guard state.fd >= 0, state.result == nil, !state.closing else { throw PTYError.notRunning }
        let pgid = tcgetpgrp(state.fd)
        guard pgid > 0 else { throw PTYError.notRunning }
        return pgid
    }

    public func waitForExit(timeout: TimeInterval) -> PTYExit? {
        state.condition.lock()
        defer { state.condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: max(0, timeout))
        while state.result == nil {
            if !state.condition.wait(until: deadline) { break }
        }
        return state.result
    }

    public func terminate() { state.terminate() }

    // Call outside SessionManager's record lock: delivery handlers acquire it.
    func flushOutput() { state.delivery.sync {} }

    /// Closes the session, terminates its process group, and waits for the child reap.
    public func close() {
        state.terminate()
        state.condition.lock()
        while state.result == nil { state.condition.wait() }
        state.condition.unlock()
    }

    deinit { close() }

    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        let writer = NSLock()
        let delivery = DispatchQueue(label: "SmthzCore.PTYSession.output")
        let pid: Int32
        var fd: Int32
        var result: PTYExit?
        var closing = false
        var termDeadline: UInt64?
        var killDeadline: UInt64?
        var escalationFinished = false
        var handler: (@Sendable (Data) -> Void)?
        var buffer = Data()

        init(fd: Int32, pid: Int32) { self.fd = fd; self.pid = pid }

        func terminate() {
            condition.lock()
            defer { condition.unlock() }
            guard result == nil, !closing else { return }
            closing = true
            // Only this monitor reaps, under this same lock. Even an exited
            // child retains its pid until reap, so it cannot be recycled here.
            Darwin.kill(-pid, SIGHUP)
            let now = DispatchTime.now().uptimeNanoseconds
            termDeadline = now + 250_000_000
            condition.broadcast()
        }

        func emit(_ data: Data) {
            if let handler { delivery.async { handler(data) } }
            else {
                // Keep the earliest output up to the documented 1 MiB limit.
                buffer.append(data.prefix(max(0, 1_048_576 - buffer.count)))
            }
        }

        func run() {
            var bytes = [UInt8](repeating: 0, count: 16384)
            condition.lock()
            while true {
                if fd >= 0 {
                    // Bound each drain so a continuously writing child cannot
                    // starve waitpid, writes, resize, or shutdown.
                    for _ in 0..<64 {
                        let count = Darwin.read(fd, &bytes, bytes.count)
                        if count > 0 { emit(Data(bytes.prefix(count))) }
                        else if count < 0 && errno == EINTR { continue }
                        else { break }
                    }
                }
                let now = DispatchTime.now().uptimeNanoseconds
                if let termDeadline, now >= termDeadline {
                    Darwin.kill(-pid, SIGTERM)
                    self.termDeadline = nil
                    // Start this grace period at actual signal delivery, even
                    // if the monitor was delayed by unrelated system load.
                    killDeadline = now + 500_000_000
                }
                if let killDeadline, now >= killDeadline {
                    Darwin.kill(-pid, SIGKILL)
                    self.killDeadline = nil
                    escalationFinished = true
                }
                // Peek without reaping: retaining the leader's pid prevents a
                // recycled pid/pgid from receiving a delayed group signal, even
                // when the leader exits before a stubborn grandchild does.
                var childInfo = siginfo_t()
                let peek = waitid(P_PID, id_t(pid), &childInfo, WEXITED | WNOHANG | WNOWAIT)
                let exited = peek == 0 && childInfo.si_pid == pid
                let unavailable = peek == -1 && errno == ECHILD
                if (exited && (!closing || escalationFinished)) || unavailable {
                    if exited && !closing {
                        // The leader ended naturally. Clean up its remaining
                        // background group before releasing ownership of pgid.
                        Darwin.kill(-pid, SIGHUP)
                        Darwin.kill(-pid, SIGTERM)
                        Darwin.kill(-pid, SIGKILL)
                    }
                    var status: Int32 = 0
                    var waited: pid_t
                    repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
                    // Drain bytes written just before exit before publishing the
                    // cached result and closing the descriptor.
                    if fd >= 0 {
                        while true {
                            let count = Darwin.read(fd, &bytes, bytes.count)
                            if count > 0 { emit(Data(bytes.prefix(count))) }
                            else if count < 0 && errno == EINTR { continue }
                            else { break }
                        }
                        Darwin.close(fd)
                        fd = -1
                    }
                    // Darwin's wait status encoding (the C WIF*/W* macros are
                    // unavailable in Swift). Never expose stop statuses as exits.
                    let signal = status & 0x7f
                    result = signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
                    condition.broadcast()
                    condition.unlock()
                    return
                }
                // Wait for readiness outside the lifecycle lock. A fixed sleep
                // after every drain throttles sustained output when a writer
                // refills the tty just after read returns EAGAIN.
                var readiness = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                condition.unlock()
                _ = Darwin.poll(&readiness, 1, 10)
                // A hung-up tty remains readable; avoid spinning while waiting
                // for the group escalation deadline or the leader's reap.
                if readiness.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    Thread.sleep(forTimeInterval: 0.002)
                }
                condition.lock()
            }
        }
    }
}
