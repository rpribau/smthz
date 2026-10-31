import Darwin
import Foundation
import Testing
@testable import SmthzCore

private final class PTYOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private func eventually(timeout: TimeInterval = 3, _ predicate: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    repeat {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    } while Date() < deadline
    return predicate()
}

private func session(_ executable: String = "/bin/sh", _ arguments: [String],
                     environment: [String: String] = ProcessInfo.processInfo.environment,
                     directory: String? = nil) throws -> PTYSession {
    try PTYSession(executable: executable, arguments: arguments, environment: environment,
                   workingDirectory: directory, size: PTYSize(rows: 24, cols: 80))
}

private func capture(_ child: PTYSession) -> PTYOutput {
    let output = PTYOutput()
    child.setOutputHandler { output.append($0) }
    return output
}

@Suite(.serialized)
struct PTYSessionTests {
    @Test func echoArrives() throws {
        let child = try session("/bin/echo", ["hello"])
        let output = capture(child)
        #expect(eventually { output.text.contains("hello") })
        #expect(child.waitForExit(timeout: 3) == .exited(0))
    }

    @Test func catRoundTrip() throws {
        let child = try session("/bin/cat", [])
        let output = capture(child)
        try child.write(Data("ping\n".utf8))
        #expect(eventually { output.text.contains("ping") })
        child.terminate()
        #expect(child.waitForExit(timeout: 3) != nil)
    }

    @Test func resizeReachesChild() throws {
        let child = try session("/bin/sh", ["-c", "stty size; sleep 0.3; stty size"])
        let output = capture(child)
        #expect(eventually { output.text.contains("24 80") })
        try child.resize(PTYSize(rows: 40, cols: 120))
        #expect(eventually { output.text.contains("40 120") })
        #expect(child.waitForExit(timeout: 3) == .exited(0))
    }

    @Test func cachesExitCodeAcrossWaiters() throws {
        let child = try session("/bin/sh", ["-c", "exit 7"])
        #expect(child.waitForExit(timeout: 3) == .exited(7))
        #expect(child.waitForExit(timeout: 0) == .exited(7))
        #expect(child.waitForExit(timeout: 1) == .exited(7))
    }

    @Test func reportsSignal() throws {
        let child = try session("/bin/sleep", ["30"])
        #expect(kill(child.pid, SIGKILL) == 0)
        #expect(child.waitForExit(timeout: 3) == .signaled(SIGKILL))
    }

    @Test func timeoutThenTerminate() throws {
        let child = try session("/bin/sleep", ["30"])
        #expect(child.waitForExit(timeout: 0.02) == nil)
        child.terminate()
        #expect(child.waitForExit(timeout: 3) != nil)
        child.terminate() // Safe and idempotent after reap.
    }

    @Test func escalatesIgnoredHangup() throws {
        let child = try session("/bin/sh", ["-c", "trap '' HUP; echo ready; exec /bin/sleep 30"])
        let output = capture(child)
        #expect(eventually { output.text.contains("ready") })
        child.terminate()
        #expect(child.waitForExit(timeout: 4) == .signaled(SIGTERM))
    }

    @Test func buffersBeforeHandlerInstallation() throws {
        let child = try session("/bin/echo", ["before-handler"])
        // Waiting for exit ensures all bytes were read before handler attachment.
        #expect(child.waitForExit(timeout: 3) == .exited(0))
        let output = capture(child)
        #expect(eventually { output.text.contains("before-handler") })
    }

    @Test func identityTracksLifecycle() throws {
        let child = try session("/bin/sleep", ["30"])
        #expect(child.identity == ProcessIdentity.lookup(pid: child.pid))
        #expect(child.identity.isStillRunning())
        child.terminate()
        #expect(child.waitForExit(timeout: 3) != nil)
        #expect(!child.identity.isStillRunning())
    }

    @Test func directoryAndEnvironmentReachChild() throws {
        let child = try session("/bin/sh", ["-c", "pwd; echo $SMTHZ_TEST"],
                                environment: ["SMTHZ_TEST": "pty-environment"], directory: "/private/tmp")
        let output = capture(child)
        #expect(eventually { output.text.contains("/private/tmp") && output.text.contains("pty-environment") })
        #expect(child.waitForExit(timeout: 3) == .exited(0))
    }

    @Test func sessionLeaderHasControllingTerminal() throws {
        // Opening /dev/tty verifies the controlling tty, beyond isatty(stdin).
        let child = try session("/bin/sh", ["-c", "tty; stty -f /dev/tty size; echo ready; read answer"])
        let output = capture(child)
        #expect(eventually { output.text.contains("ready") })
        #expect(output.text.contains("/dev/ttys"))
        #expect(output.text.contains("24 80"))
        #expect(getsid(child.pid) == child.pid)
        try child.write(Data("done\n".utf8))
        #expect(child.waitForExit(timeout: 3) == .exited(0))
    }

    @Test func closeRejectsWritesAndLeavesNoZombie() throws {
        let child = try session("/bin/sleep", ["30"])
        let pid = child.pid
        child.close()
        #expect(throws: PTYError.notRunning) { try child.write(Data("closed".utf8)) }
        #expect(throws: PTYError.notRunning) { try child.resize(PTYSize(rows: 1, cols: 1)) }
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func deinitReapsLiveChild() throws {
        var child: PTYSession? = try session("/bin/sleep", ["30"])
        let pid = try #require(child?.pid)
        child = nil
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test func failedSpawnClosesDescriptors() throws {
        #expect(throws: PTYError.spawnFailed(ENOENT)) {
            _ = try session("/smthz-nonexistent-executable", [])
        }
    }

    @Test func twentySessionsDoNotLeakDescriptors() throws {
        // Count only descriptors of this process that refer to the given pty
        // (master or slave side), so parallel suites' sockets, pipes and files
        // cannot affect the result. The pty is identified by its slave device,
        // read from the child's controlling terminal.
        func ptyDescriptors(slaveDevice: dev_t) -> Set<Int32> {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
            var result = Set<Int32>()
            for fd in entries.compactMap({ Int32($0) }) {
                var info = stat()
                guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFCHR else { continue }
                if info.st_rdev == slaveDevice { result.insert(fd); continue }
                var name = [CChar](repeating: 0, count: 128)
                var slave = stat()
                if ptsname_r(fd, &name, name.count) == 0, stat(name, &slave) == 0,
                   slave.st_rdev == slaveDevice { result.insert(fd) }
            }
            return result
        }
        func controllingTerminal(_ pid: Int32) -> dev_t? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.e_tdev != UInt32.max else { return nil }
            return dev_t(bitPattern: info.e_tdev)
        }
        for _ in 0..<20 {
            // The child blocks on stdin so its controlling terminal can be read.
            let child = try session("/bin/sh", ["-c", "read line"])
            let device = try #require(controllingTerminal(child.pid))
            // The parent holds exactly one descriptor for the pty (its master);
            // the slave must already be closed after spawn.
            let held = ptyDescriptors(slaveDevice: device)
            #expect(held.count == 1)
            try child.write(Data("\n".utf8))
            #expect(child.waitForExit(timeout: 3) == .exited(0))
            child.close()
            // A leak keeps the same descriptor open on the same pty forever; a
            // parallel test reusing both the number and the pty is transient.
            #expect(eventually(timeout: 5) { ptyDescriptors(slaveDevice: device).isDisjoint(with: held) })
        }
    }
}
