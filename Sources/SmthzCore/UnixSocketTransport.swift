import Darwin
import Foundation

public enum UnixSocketError: Error, Equatable {
    case pathTooLong
    case listenFailed(Int32)
    case connectFailed(Int32)
    case peerNotAuthorized
    case closed
    case frame(String)
}

private func socketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path), !bytes.contains(0) else {
        throw UnixSocketError.pathTooLong
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: bytes)
    }
    return address
}

private func withAddress<T>(_ address: inout sockaddr_un,
                            _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func makeSocket() -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    if fd >= 0 {
        var enabled: Int32 = 1
        // PTY processes can spawn concurrently with socket setup. Never leave
        // listeners or client connections owned by an unrelated exec'd child.
        if fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 ||
           setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                      socklen_t(MemoryLayout.size(ofValue: enabled))) != 0 {
            let code = errno
            Darwin.close(fd)
            errno = code
            return -1
        }
    }
    return fd
}

private func authorize(_ fd: Int32) throws {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
        throw UnixSocketError.peerNotAuthorized
    }
}

private func writeFrame(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw UnixSocketError.closed }
            offset += count
        }
    }
}

private func readChunk(from fd: Int32) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = Darwin.read(fd, &bytes, bytes.count)
        if count < 0, errno == EINTR { continue }
        guard count != 0 else { throw UnixSocketError.closed }
        guard count > 0 else { throw UnixSocketError.frame("read failed: \(errno)") }
        return Data(bytes.prefix(count))
    }
}

public final class UnixSocketServer: @unchecked Sendable {
    /// A handler returns true after consuming a dedicated streaming connection.
    public typealias StreamHandler = @Sendable (Data, (Data) throws -> Void, () -> Bool) -> Bool
    // The state outlives the public server only until its background loops exit.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var listener: Int32
        var clients: Set<Int32> = []
        let path: String
        let inode: ino_t
        let handler: @Sendable (Data) -> Data
        let afterResponse: (@Sendable (Data) -> Void)?
        let streamHandler: StreamHandler?

        init(listener: Int32, path: String, inode: ino_t,
             handler: @escaping @Sendable (Data) -> Data,
             afterResponse: (@Sendable (Data) -> Void)?, streamHandler: StreamHandler?) {
            self.listener = listener
            self.path = path
            self.inode = inode
            self.handler = handler
            self.afterResponse = afterResponse
            self.streamHandler = streamHandler
        }

        func acceptConnections() {
            while true {
                lock.lock()
                let fd = listener
                lock.unlock()
                guard fd >= 0 else { return }
                var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&event, 1, 100)
                if ready < 0, errno == EINTR { continue }
                lock.lock()
                guard listener >= 0 else { lock.unlock(); return }
                guard ready > 0 else { lock.unlock(); continue }
                let client = Darwin.accept(listener, nil, nil)
                if client >= 0 {
                    var enabled: Int32 = 1
                    if fcntl(client, F_SETFD, FD_CLOEXEC) == 0,
                       fcntl(client, F_SETFL, 0) == 0,
                       setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled,
                                  socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 {
                        clients.insert(client)
                        Thread.detachNewThread { self.serve(client) }
                    } else {
                        Darwin.close(client)
                    }
                }
                lock.unlock()
            }
        }

        func serve(_ fd: Int32) {
            defer {
                lock.lock()
                clients.remove(fd)
                // shutdown affects every duplicate of this socket, including a
                // child spawned between accept() and setting FD_CLOEXEC. close()
                // alone cannot deliver EOF while such a duplicate remains open.
                Darwin.shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
                lock.unlock()
            }
            do {
                try authorize(fd)
                var decoder = RPCFrameDecoder()
                while true {
                    decoder.append(try readChunk(from: fd))
                    while let payload = try decoder.nextFrame() {
                        if let streamHandler {
                            let handled = streamHandler(payload, { data in
                                // A slow peer cannot retain a server thread indefinitely.
                                var timeout = timeval(tv_sec: 2, tv_usec: 0)
                                guard setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                                    socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else { throw UnixSocketError.closed }
                                try writeFrame(RPCFrameCodec.encode(data), to: fd)
                            }, {
                                if self.lock.withLock({ self.listener < 0 }) { return true }
                                var byte: UInt8 = 0
                                let count = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                                return count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR)
                            })
                            if handled { return }
                        }
                        let response = handler(payload)
                        try writeFrame(RPCFrameCodec.encode(response), to: fd)
                        afterResponse?(response)
                    }
                }
            } catch {
                // Framing has no resynchronization marker; terminate only this peer.
            }
        }

        func stop() {
            lock.lock()
            defer { lock.unlock() }
            guard listener >= 0 else { return }
            Darwin.close(listener)
            listener = -1
            for client in clients { Darwin.shutdown(client, SHUT_RDWR) }
            var info = stat()
            if lstat(path, &info) == 0, info.st_ino == inode {
                unlink(path)
            }
        }
    }

    private let state: State

    public init(path: String, handler: @escaping @Sendable (Data) -> Data,
                afterResponse: (@Sendable (Data) -> Void)? = nil,
                streamHandler: StreamHandler? = nil) throws {
        var address = try socketAddress(path)
        let parent = (path as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK else {
                throw UnixSocketError.listenFailed(EADDRINUSE)
            }
            let probe = makeSocket()
            guard probe >= 0 else { throw UnixSocketError.listenFailed(errno) }
            var result: Int32
            repeat { result = withAddress(&address) { Darwin.connect(probe, $0, $1) } }
            while result < 0 && errno == EINTR
            let code = errno
            Darwin.close(probe)
            guard result != 0 else { throw UnixSocketError.listenFailed(EADDRINUSE) }
            guard code == ECONNREFUSED else { throw UnixSocketError.listenFailed(code) }
            // Do not unlink a replacement installed while the probe was in flight.
            var current = stat()
            guard lstat(path, &current) == 0, current.st_ino == existing.st_ino,
                  unlink(path) == 0 else { throw UnixSocketError.listenFailed(errno) }
        }
        let fd = makeSocket()
        guard fd >= 0 else { throw UnixSocketError.listenFailed(errno) }
        guard withAddress(&address, { Darwin.bind(fd, $0, $1) }) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.listenFailed(code)
        }
        guard chmod(path, 0o600) == 0, Darwin.listen(fd, SOMAXCONN) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(path)
            throw UnixSocketError.listenFailed(code)
        }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(path)
            throw UnixSocketError.listenFailed(code)
        }
        state = State(listener: fd, path: path, inode: info.st_ino, handler: handler,
                      afterResponse: afterResponse, streamHandler: streamHandler)
        let backgroundState = state
        // Dedicated threads: these loops block, and a starved GCD pool would stall peers.
        Thread.detachNewThread { backgroundState.acceptConnections() }
    }

    public func stop() { state.stop() }
    deinit { state.stop() }
}

public final class UnixSocketClient {
    private var fd: Int32
    private let lifecycleLock = NSLock()
    private var decoder = RPCFrameDecoder()

    public init(path: String) throws {
        var address = try socketAddress(path)
        fd = makeSocket()
        guard fd >= 0 else { throw UnixSocketError.connectFailed(errno) }
        var result: Int32
        repeat { result = withAddress(&address) { Darwin.connect(fd, $0, $1) } }
        while result < 0 && errno == EINTR
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            fd = -1
            throw UnixSocketError.connectFailed(code)
        }
        do { try authorize(fd) } catch { close(); throw error }
    }

    public func request(_ payload: Data, timeout: TimeInterval = 5) throws -> Data {
        guard fd >= 0 else { throw UnixSocketError.closed }
        guard timeout.isFinite, timeout > 0, timeout < Double(Int.max) else {
            throw UnixSocketError.frame("invalid receive timeout")
        }
        var interval = timeval(tv_sec: Int(timeout),
                               tv_usec: Int32(max(1, (timeout - floor(timeout)) * 1_000_000)))
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval,
                         socklen_t(MemoryLayout.size(ofValue: interval))) == 0 else {
            throw UnixSocketError.frame("receive timeout failed: \(errno)")
        }
        let frame: Data
        do { frame = try RPCFrameCodec.encode(payload) }
        catch { throw UnixSocketError.frame(String(describing: error)) }
        do {
            try writeFrame(frame, to: fd)
            while true {
                if let response = try decoder.nextFrame() { return response }
                decoder.append(try readChunk(from: fd))
            }
        } catch {
            close()
            if let error = error as? UnixSocketError { throw error }
            throw UnixSocketError.frame(String(describing: error))
        }
    }

    /// Owner-thread receive after a subscription acknowledgement. No idle
    /// timeout; interrupt() wakes it promptly when its consumer goes away.
    public func receive() throws -> Data {
        guard fd >= 0 else { throw UnixSocketError.closed }
        var timeout = timeval(tv_sec: 0, tv_usec: 0)
        // Darwin fails setsockopt with EINVAL once the peer has closed, yet the
        // frames it sent first (e.g. a stream's exit) are still readable.
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 || errno == EINVAL else { throw UnixSocketError.closed }
        while true {
            if let response = try decoder.nextFrame() { return response }
            decoder.append(try readChunk(from: fd))
        }
    }

    /// Safe from a cancellation thread: shuts down but never closes/recycles
    /// the descriptor while the owner is inside a blocking receive.
    public func interrupt() {
        lifecycleLock.withLock { if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) } }
    }

    public func close() {
        lifecycleLock.withLock { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    }

    deinit { close() }
}
