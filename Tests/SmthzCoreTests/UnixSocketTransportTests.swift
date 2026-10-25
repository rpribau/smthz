import Darwin
import Foundation
import Testing
@testable import SmthzCore

private struct SocketFixture {
    let directory = "/tmp/smthz-test-\(UUID().uuidString.prefix(8))"
    var path: String { directory + "/s.sock" }
    func cleanup() { try? FileManager.default.removeItem(atPath: directory) }
}

private func rawSocket(_ path: String, bindSocket: Bool = false) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(fd >= 0)
    #expect(fcntl(fd, F_SETFD, FD_CLOEXEC) == 0)
    var enabled: Int32 = 1
    #expect(setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, 4) == 0)
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    #expect(setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                      socklen_t(MemoryLayout.size(ofValue: timeout))) == 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            if bindSocket { return Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            return Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        let code = errno
        Darwin.close(fd)
        throw UnixSocketError.connectFailed(code)
    }
    return fd
}

@Test func unixSocketEchoRoundtrip() throws {
    let fixture = SocketFixture()
    defer { fixture.cleanup() }
    let server = try UnixSocketServer(path: fixture.path) { $0 }
    defer { server.stop() }
    let client = try UnixSocketClient(path: fixture.path)
    defer { client.close() }
    let payload = Data(repeating: 0xAB, count: 200_000)
    #expect(try client.request(payload) == payload)
}

@Test func unixSocketSequentialRequests() throws {
    let fixture = SocketFixture()
    defer { fixture.cleanup() }
    let server = try UnixSocketServer(path: fixture.path) { $0 }
    defer { server.stop() }
    let client = try UnixSocketClient(path: fixture.path)
    defer { client.close() }
    #expect(try client.request(Data("first".utf8)) == Data("first".utf8))
    #expect(try client.request(Data("second".utf8)) == Data("second".utf8))
}

@Test func unixSocketConcurrentClients() async throws {
    let fixture = SocketFixture()
    defer { fixture.cleanup() }
    let server = try UnixSocketServer(path: fixture.path) { $0 }
    defer { server.stop() }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for byte: UInt8 in [42, 43] {
            group.addTask {
                let client = try UnixSocketClient(path: fixture.path)
                defer { client.close() }
                let payload = Data(repeating: byte, count: 100_000)
                #expect(try client.request(payload) == payload)
            }
        }
        try await group.waitForAll()
    }
}

@Test func unixSocketPermissions() throws {
    let fixture = SocketFixture()
    defer { fixture.cleanup() }
    let server = try UnixSocketServer(path: fixture.path) { $0 }
    defer { server.stop() }
    var info = stat()
    #expect(lstat(fixture.path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)
    #expect(lstat(fixture.directory, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o700)
}

@Test func unixSocketRejectsLongPath() {
    let path = "/tmp/" + String(repeating: "x", count: 104)
    #expect(throws: UnixSocketError.pathTooLong) {
        try UnixSocketServer(path: path) { $0 }
    }
    #expect(throws: UnixSocketError.pathTooLong) { try UnixSocketClient(path: path) }
}

@Test func unixSocketMissingPath() {
    let fixture = SocketFixture()
    defer { fixture.cleanup() }
    #expect(throws: UnixSocketError.connectFailed(ENOENT)) {
        try UnixSocketClient(path: fixture.path)
    }
}

@Test func unixSocketReplacesStaleSocket() throws {
    let fixture = SocketFixture()
    defer { fixture.cleanup() }
    try FileManager.default.createDirectory(atPath: fixture.directory, withIntermediateDirectories: true)
    // Closing a bound descriptor without unlinking models a terminated server.
    let abandoned = try rawSocket(fixture.path, bindSocket: true)
    Darwin.close(abandoned)
    let server = try UnixSocketServer(path: fixture.path) { $0 }
    defer { server.stop() }
    let client = try UnixSocketClient(path: fixture.path)
    defer { client.close() }
    #expect(try client.request(Data([1, 2, 3])) == Data([1, 2, 3]))
}

@Test func unixSocketPreservesLiveServer() throws {
    let fixture = SocketFixture()
    defer { fixture.cleanup() }
    let server = try UnixSocketServer(path: fixture.path) { $0 }
    defer { server.stop() }
    #expect(throws: UnixSocketError.listenFailed(EADDRINUSE)) {
        try UnixSocketServer(path: fixture.path) { $0 }
    }
    let client = try UnixSocketClient(path: fixture.path)
    defer { client.close() }
    #expect(try client.request(Data([99])) == Data([99]))
}

@Test func unixSocketStopRemovesSocket() throws {
    let fixture = SocketFixture()
    defer { fixture.cleanup() }
    let server = try UnixSocketServer(path: fixture.path) { $0 }
    #expect(FileManager.default.fileExists(atPath: fixture.path))
    server.stop()
    server.stop()
    #expect(!FileManager.default.fileExists(atPath: fixture.path))
}

@Test func unixSocketSurvivesOversizeFrame() throws {
    let fixture = SocketFixture()
    defer { fixture.cleanup() }
    let server = try UnixSocketServer(path: fixture.path) { $0 }
    defer { server.stop() }
    let badClient = try rawSocket(fixture.path)
    defer { Darwin.close(badClient) }
    // Complete a request so the server has accepted this peer before spawning.
    let request = try RPCFrameCodec.encode(Data([42]))
    #expect(request.withUnsafeBytes { Darwin.write(badClient, $0.baseAddress, $0.count) } == request.count)
    var response = [UInt8](repeating: 0, count: request.count)
    var received = 0
    while received < response.count {
        let count = response.withUnsafeMutableBytes {
            Darwin.read(badClient, $0.baseAddress!.advanced(by: received), $0.count - received)
        }
        try #require(count > 0)
        received += count
    }
    #expect(Data(response) == request)
    // A live PTY child used to inherit the server's accepted descriptor. Closing
    // it in the server then left the peer open until that unrelated child exited.
    let child = try PTYSession(executable: "/bin/cat", arguments: [],
                               environment: ProcessInfo.processInfo.environment,
                               workingDirectory: nil,
                               size: PTYSize(rows: 24, cols: 80))
    defer { child.close() }
    let prefix: [UInt8] = [0, 0x10, 0, 1]
    #expect(prefix.withUnsafeBytes { Darwin.write(badClient, $0.baseAddress, $0.count) } == 4)
    var byte: UInt8 = 0
    let count = Darwin.read(badClient, &byte, 1)
    let readError = count < 0 ? errno : 0
    #expect(count == 0, "Expected EOF; read returned \(count), errno \(readError)")
    #expect(child.waitForExit(timeout: 0) == nil)
    let client = try UnixSocketClient(path: fixture.path)
    defer { client.close() }
    #expect(try client.request(Data([7])) == Data([7]))
}
