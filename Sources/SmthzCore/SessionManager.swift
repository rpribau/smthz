import Darwin
import Foundation

public struct SessionInfo: Codable, Equatable, Sendable {
    public let id: String
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public var running: Bool
    public let executable: String?
    public let arguments: [String]?
    public let cwd: String?
    public let createdAt: Double?

    public init(id: String, pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64,
                running: Bool, executable: String? = nil, arguments: [String]? = nil,
                cwd: String? = nil, createdAt: Double? = nil) {
        self.id = id
        self.pid = pid
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.running = running
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
        self.createdAt = createdAt
    }
}

public struct SessionForeground: Codable, Equatable, Sendable {
    public let pgid: Int32
    public let pid: Int32
    public let executable: String?
    public let isShell: Bool
}

public enum SessionError: String, Error, Sendable {
    case badRequest, unknownSession, spawnFailed, notRunning, journalFailure, scrollbackFailure, cancelled
}

/// Owns children and bounded output independently of socket connections.
public final class SessionManager: @unchecked Sendable {
    public static let maximumTransferBytes = 1_048_576
    // HostService shares this lock: EventJournal uses one SQLite connection.
    // Always acquire it before the manager lock; RPC operations can reenter it.
    let journalLock = NSRecursiveLock()
    private let journal: EventJournal
    private let outputLimit: Int
    private let scrollbackDirectory: URL?
    private let scrollbackLimit: Int
    private let lock = NSLock()
    private var sessions: [String: Record] = [:]
    private var stopped = false
    private let exitMonitor: DispatchSourceTimer

    /// Disk retention is opt-in, bounded per session, and independent of the
    /// in-memory window. Files remain after close for explicit offline replay.
    public init(journal: EventJournal, outputLimit: Int = 4 * 1_048_576,
                scrollbackDirectory: URL? = nil, scrollbackLimit: Int = 64 * 1_048_576) {
        self.journal = journal
        self.outputLimit = max(1, outputLimit)
        self.scrollbackDirectory = scrollbackDirectory
        self.scrollbackLimit = min(1_073_741_824, max(1, scrollbackLimit))
        exitMonitor = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "SmthzCore.SessionManager.exits"))
        exitMonitor.schedule(deadline: .now(), repeating: .milliseconds(50))
        exitMonitor.setEventHandler { [weak self] in self?.recordExits() }
        exitMonitor.resume()
    }

    private final class Record: @unchecked Sendable {
        let child: PTYSession
        let info: SessionInfo
        let lock = NSLock()
        var output = Data()
        var end: UInt64 = 0
        let disk: Scrollback?
        var scrollbackFailed = false
        var closeJournaled = false // guarded by the manager lock
        init(child: PTYSession, id: String, disk: Scrollback?, executable: String,
             arguments: [String], cwd: String, createdAt: Double) {
            self.child = child
            self.disk = disk
            info = SessionInfo(id: id, pid: child.pid,
                               startSeconds: child.identity.startSeconds,
                               startMicroseconds: child.identity.startMicroseconds, running: true,
                               executable: executable, arguments: arguments, cwd: cwd, createdAt: createdAt)
        }
        func finishOutput() {
            child.flushOutput()
            lock.lock()
            defer { lock.unlock() }
            do { try disk?.finish() }
            catch { scrollbackFailed = true }
        }
        func append(_ bytes: Data, limit: Int) {
            lock.lock()
            defer { lock.unlock() }
            if let disk {
                do { try disk.append(bytes) }
                catch { scrollbackFailed = true }
            }
            end += UInt64(bytes.count)
            output.append(bytes)
            if output.count > limit { output = Data(output.suffix(limit)) }
        }
    }

    public func create(executable: String, arguments: [String],
                       environment: [String: String] = ProcessInfo.processInfo.environment,
                       workingDirectory: String? = nil, rows: Int = 24, cols: Int = 80) throws -> SessionInfo {
        journalLock.lock()
        defer { journalLock.unlock() }
        guard !stopped else { throw SessionError.notRunning }
        guard executable.hasPrefix("/"), !executable.utf8.contains(0),
              FileManager.default.isExecutableFile(atPath: executable),
              !arguments.contains(where: { $0.utf8.contains(0) }),
              !environment.contains(where: { $0.key.isEmpty || $0.key.contains("=") || $0.key.utf8.contains(0) || $0.value.utf8.contains(0) }),
              workingDirectory.map({ !$0.utf8.contains(0) }) ?? true else { throw SessionError.badRequest }
        var metadata = stat()
        guard stat(executable, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw SessionError.badRequest
        }
        let id = RequestID.generate().rawValue
        let disk: Scrollback?
        do {
            disk = try scrollbackDirectory.map { try Scrollback(directory: $0, id: id, capacity: scrollbackLimit) }
        } catch { throw SessionError.scrollbackFailure }
        let createdAt = Date().timeIntervalSince1970
        let cwd = workingDirectory ?? FileManager.default.currentDirectoryPath
        let child: PTYSession
        do {
            child = try PTYSession(executable: executable, arguments: arguments, environment: environment,
                                   workingDirectory: workingDirectory, size: Self.size(rows, cols))
        } catch {
            disk?.remove()
            throw SessionError.spawnFailed
        }
        let record = Record(child: child, id: id, disk: disk, executable: executable,
                            arguments: arguments, cwd: cwd, createdAt: createdAt)
        let limit = outputLimit
        child.setOutputHandler { [weak record] in record?.append($0, limit: limit) }
        lock.lock()
        do {
            try lifecycle("session.create", record: record)
            sessions[record.info.id] = record
            lock.unlock()
        } catch {
            lock.unlock()
            child.close()
            disk?.remove()
            throw SessionError.journalFailure
        }
        return record.info
    }

    /// Cancellation can leave a prefix written; callers must not blindly retry.
    public func write(id: String, data: Data, shouldCancel: (@Sendable () -> Bool)? = nil) throws {
        guard data.count <= Self.maximumTransferBytes else { throw SessionError.badRequest }
        let record = try lookup(id)
        do { try record.child.write(data, shouldCancel: shouldCancel) }
        catch PTYError.writeFailed(ECANCELED) { throw SessionError.cancelled }
        catch { throw SessionError.notRunning }
    }

    public func resize(id: String, rows: Int, cols: Int) throws {
        let record = try lookup(id)
        do { try record.child.resize(Self.size(rows, cols)) }
        catch { throw SessionError.notRunning }
    }

    public func read(id: String, from offset: UInt64, maxBytes: Int = maximumTransferBytes) throws
        -> (data: Data, nextOffset: UInt64, truncated: Bool, exit: PTYExit?) {
        guard maxBytes > 0 else { throw SessionError.badRequest }
        let record = try lookup(id)
        let exit = record.child.waitForExit(timeout: 0)
        if exit != nil { record.finishOutput() }
        record.lock.lock()
        defer { record.lock.unlock() }
        if record.scrollbackFailed { throw SessionError.scrollbackFailure }
        if let disk = record.disk {
            let replay = try disk.read(from: offset, maxBytes: min(maxBytes, Self.maximumTransferBytes))
            return (replay.data, replay.nextOffset, replay.truncated, exit)
        }
        let start = record.end - UInt64(record.output.count)
        let cursor = min(max(offset, start), record.end)
        let count = min(maxBytes, Self.maximumTransferBytes, Int(record.end - cursor))
        let data = Data(record.output.dropFirst(Int(cursor - start)).prefix(count))
        return (data, cursor + UInt64(count), offset < start, exit)
    }

    /// Replays a retained session without restoring a process or journal state.
    /// Offsets use the same absolute byte coordinates as live reads. Use only
    /// after close or manager teardown; it does not coordinate with a live writer.
    public static func readScrollback(id: String, directory: URL, from offset: UInt64,
                                      maxBytes: Int = maximumTransferBytes) throws
        -> (data: Data, nextOffset: UInt64, truncated: Bool) {
        guard maxBytes > 0 else { throw SessionError.badRequest }
        return try Scrollback(directory: directory, id: id)
            .read(from: offset, maxBytes: min(maxBytes, maximumTransferBytes))
    }

    public func close(id: String) throws {
        journalLock.lock()
        defer { journalLock.unlock() }
        let record = try lookup(id)
        record.child.close()
        record.finishOutput()
        record.lock.lock()
        let storageFailed = record.scrollbackFailed
        record.lock.unlock()
        lock.lock()
        defer { lock.unlock() }
        try journalClose(record)
        if storageFailed { throw SessionError.scrollbackFailure }
    }

    /// Stops accepting new sessions, then terminates every owned process group.
    /// All groups receive their initial signal before waiting begins so shutdown
    /// time does not grow with the number of sessions.
    public func stop(timeout: TimeInterval = 3) {
        journalLock.lock()
        defer { journalLock.unlock() }
        guard !stopped else { return }
        stopped = true
        lock.lock()
        let records = Array(sessions.values)
        lock.unlock()
        for record in records { record.child.terminate() }
        let deadline = Date(timeIntervalSinceNow: max(0, timeout))
        for record in records {
            _ = record.child.waitForExit(timeout: max(0, deadline.timeIntervalSinceNow))
        }
        for record in records {
            record.finishOutput()
            try? journalClose(record)
        }
    }

    public func foreground(id: String) throws -> SessionForeground {
        let record = try lookup(id)
        let pgid: Int32
        do { pgid = try record.child.foregroundProcessGroupID() }
        catch { throw SessionError.notRunning }
        // The foreground process group's leader is the representative process.
        // It may exit between tcgetpgrp and proc_pidpath; path lookup is optional.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = path.withUnsafeMutableBytes { proc_pidpath(pgid, $0.baseAddress, UInt32($0.count)) }
        let executable = count > 0 ? String(decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        return SessionForeground(pgid: pgid, pid: pgid, executable: executable,
                                 isShell: pgid == record.info.pid)
    }

    public func list() -> [SessionInfo] {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.map { record in
            var info = record.info
            info.running = record.child.waitForExit(timeout: 0) == nil
            return info
        }.sorted { $0.id < $1.id }
    }

    // Undo a create whose RPC response could not be committed. No unreported child survives.
    func discard(id: String) {
        journalLock.lock()
        defer { journalLock.unlock() }
        let record = try? lookup(id)
        record?.child.close()
        lock.lock()
        if let record { try? journalClose(record) }
        record?.disk?.remove()
        sessions.removeValue(forKey: id)
        lock.unlock()
    }

    private func lookup(_ id: String) throws -> Record {
        lock.lock()
        defer { lock.unlock() }
        guard let record = sessions[id] else { throw SessionError.unknownSession }
        return record
    }

    private static func size(_ rows: Int, _ cols: Int) -> PTYSize {
        PTYSize(rows: UInt16(min(2000, max(1, rows))), cols: UInt16(min(2000, max(1, cols))))
    }

    private struct Lifecycle: Encodable {
        let id: String
        let pid: Int32
        let identity: ProcessIdentity
    }

    private func lifecycle(_ kind: String, record: Record) throws {
        let payload = try JSONEncoder().encode(Lifecycle(id: record.info.id, pid: record.info.pid,
                                                       identity: record.child.identity))
        _ = try journal.append(requestID: "\(kind):\(record.info.id)", kind: kind, payload: payload)
    }

    private func journalClose(_ record: Record) throws {
        guard !record.closeJournaled else { return }
        do { try lifecycle("session.close", record: record); record.closeJournaled = true }
        catch { throw SessionError.journalFailure }
    }

    private func recordExits() {
        journalLock.lock()
        defer { journalLock.unlock() }
        lock.lock()
        defer { lock.unlock() }
        for record in sessions.values where !record.closeJournaled {
            if record.child.waitForExit(timeout: 0) != nil {
                record.finishOutput()
                try? journalClose(record) // Retry failed lifecycle appends on the next tick.
            }
        }
    }

    /// Fixed-size ring: magic, capacity, absolute end (all UInt64 big endian),
    /// followed by capacity bytes. Header commits follow data writes. This is
    /// bounded disk replay, not an atomic crash-recovery transaction.
    private final class Scrollback {
        var fd: Int32
        let url: URL
        let capacity: Int
        var end: UInt64
        private static let magic: UInt64 = 0x534d54485a534231
        private static let headerSize = 24

        init(directory: URL, id: String, capacity: Int) throws {
            guard Self.valid(id) else { throw SessionError.badRequest }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            url = directory.appendingPathComponent(id + ".scrollback")
            self.capacity = capacity
            end = 0
            fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw SessionError.scrollbackFailure }
            do {
                guard ftruncate(fd, off_t(capacity + Self.headerSize)) == 0 else { throw SessionError.scrollbackFailure }
                try commit()
            } catch {
                Darwin.close(fd)
                fd = -1
                unlink(url.path)
                throw SessionError.scrollbackFailure
            }
        }

        init(directory: URL, id: String) throws {
            guard Self.valid(id) else { throw SessionError.badRequest }
            url = directory.appendingPathComponent(id + ".scrollback")
            fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw SessionError.scrollbackFailure }
            do {
                var metadata = stat()
                guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                      metadata.st_uid == getuid() else { throw SessionError.scrollbackFailure }
                let header = try Self.load(fd, offset: 0, count: Self.headerSize)
                let words = stride(from: 0, to: Self.headerSize, by: 8).map { index in
                    header[index..<(index + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                }
                guard words[0] == Self.magic, words[1] > 0, words[1] <= 1_073_741_824,
                      metadata.st_size == off_t(words[1]) + off_t(Self.headerSize) else {
                    throw SessionError.scrollbackFailure
                }
                capacity = Int(words[1])
                end = words[2]
            } catch {
                Darwin.close(fd)
                fd = -1
                throw SessionError.scrollbackFailure
            }
        }

        private static func valid(_ id: String) -> Bool {
            UUID(uuidString: id)?.uuidString.lowercased() == id
        }

        func append(_ data: Data) throws {
            guard UInt64(data.count) <= UInt64.max - end else { throw SessionError.scrollbackFailure }
            let newEnd = end + UInt64(data.count)
            let kept = Data(data.suffix(capacity))
            let position = Int((newEnd - UInt64(kept.count)) % UInt64(capacity))
            let first = min(kept.count, capacity - position)
            try store(Data(kept.prefix(first)), offset: Self.headerSize + position)
            if first < kept.count { try store(Data(kept.dropFirst(first)), offset: Self.headerSize) }
            end = newEnd
            try commit()
        }

        func read(from offset: UInt64, maxBytes: Int) throws
            -> (data: Data, nextOffset: UInt64, truncated: Bool) {
            if fd < 0 {
                return try Scrollback(directory: url.deletingLastPathComponent(),
                                      id: url.deletingPathExtension().lastPathComponent)
                    .read(from: offset, maxBytes: maxBytes)
            }
            let start = end - min(end, UInt64(capacity))
            let cursor = min(max(offset, start), end)
            let count = min(maxBytes, Int(end - cursor))
            let position = Int(cursor % UInt64(capacity))
            let first = min(count, capacity - position)
            var data = try Self.load(fd, offset: Self.headerSize + position, count: first)
            if first < count { data.append(try Self.load(fd, offset: Self.headerSize, count: count - first)) }
            return (data, cursor + UInt64(count), offset < start)
        }

        func finish() throws {
            guard fd >= 0 else { return }
            defer { Darwin.close(fd); fd = -1 }
            guard fsync(fd) == 0 else { throw SessionError.scrollbackFailure }
        }

        func remove() { unlink(url.path) }

        private func commit() throws {
            var header = Data()
            for value in [Self.magic, UInt64(capacity), end] {
                var big = value.bigEndian
                withUnsafeBytes(of: &big) { header.append(contentsOf: $0) }
            }
            try store(header, offset: 0)
        }

        private func store(_ data: Data, offset: Int) throws {
            try data.withUnsafeBytes { bytes in
                var written = 0
                while written < bytes.count {
                    let count = pwrite(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written, off_t(offset + written))
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw SessionError.scrollbackFailure }
                    written += count
                }
            }
        }

        private static func load(_ fd: Int32, offset: Int, count: Int) throws -> Data {
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
                var received = 0
                while received < count {
                    let amount = pread(fd, bytes.baseAddress!.advanced(by: received), count - received, off_t(offset + received))
                    if amount < 0 && errno == EINTR { continue }
                    guard amount > 0 else { throw SessionError.scrollbackFailure }
                    received += amount
                }
            }
            return data
        }

        deinit { if fd >= 0 { Darwin.close(fd) } }
    }

    deinit {
        exitMonitor.cancel()
        stop()
    }
}
