import Darwin
import Foundation
import Testing
@testable import SmthzCore

private struct SizeFixture {
    let directory = URL(fileURLWithPath: "/tmp/smthz-size-\(UUID().uuidString)")
    var output: URL { directory.appendingPathComponent("output") }

    func manager(capacity: Int = 16 * 1_048_576) throws -> SessionManager {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SessionManager(journal: try EventJournal(path: directory.appendingPathComponent("journal").path),
                              scrollbackDirectory: output, scrollbackLimit: capacity)
    }

    func attributes(_ id: String) throws -> (size: Int, mode: Int) {
        let values = try FileManager.default.attributesOfItem(atPath: output.appendingPathComponent(id + ".scrollback").path)
        return (try #require(values[.size] as? NSNumber).intValue,
                try #require(values[.posixPermissions] as? NSNumber).intValue)
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private func sizeEventually(_ predicate: () throws -> Bool) rethrows -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    repeat {
        if try predicate() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    } while clock.now < deadline
    return try predicate()
}

@Suite(.serialized)
struct ScrollbackSizeTests {
    @Test func shortSessionStoresOnlyHeaderAndOutput() throws {
        let fixture = SizeFixture()
        defer { fixture.cleanup() }
        let manager = try fixture.manager()
        defer { manager.stop() }
        let info = try manager.create(executable: "/bin/echo", arguments: ["small"])
        try #require(try sizeEventually { try manager.read(id: info.id, from: 0).exit == .exited(0) })
        try manager.close(id: info.id)
        let live = try manager.read(id: info.id, from: 0)
        #expect(live.data == Data("small\r\n".utf8))
        let attributes = try fixture.attributes(info.id)
        #expect(attributes.size == 24 + live.data.count)
        #expect(attributes.size < 4096)
        #expect(attributes.mode == 0o600)
        let archived = try SessionManager.readScrollback(id: info.id, directory: fixture.output, from: 0)
        #expect(archived.data == live.data)
        #expect(archived.nextOffset == live.nextOffset)
        #expect(!archived.truncated)
    }

    @Test func silentSessionStoresOnlyHeader() throws {
        let fixture = SizeFixture()
        defer { fixture.cleanup() }
        let manager = try fixture.manager()
        defer { manager.stop() }
        let info = try manager.create(executable: "/bin/sleep", arguments: ["60"])
        #expect(try fixture.attributes(info.id).size == 24)
        try manager.close(id: info.id)
        #expect(try fixture.attributes(info.id).size == 24)
        let archived = try SessionManager.readScrollback(id: info.id, directory: fixture.output, from: 0)
        #expect(archived.data.isEmpty)
        #expect(archived.nextOffset == 0)
        #expect(!archived.truncated)
    }

    @Test func fileGrowsWithLiveOutput() throws {
        let fixture = SizeFixture()
        defer { fixture.cleanup() }
        let manager = try fixture.manager()
        defer { manager.stop() }
        let info = try manager.create(executable: "/bin/sh", arguments: ["-c", "stty -echo -opost; printf abc; read first; printf def; read second; printf ghi"])
        try #require(try sizeEventually { try manager.read(id: info.id, from: 0).nextOffset == 3 })
        #expect(try fixture.attributes(info.id).size == 27)
        try manager.write(id: info.id, data: Data("\n".utf8))
        try #require(try sizeEventually { try manager.read(id: info.id, from: 0).nextOffset == 6 })
        #expect(try fixture.attributes(info.id).size == 30)
        try manager.write(id: info.id, data: Data("\n".utf8))
        try #require(try sizeEventually { try manager.read(id: info.id, from: 0).exit == .exited(0) })
        try manager.close(id: info.id)
        #expect(try fixture.attributes(info.id).size == 33)
        let archived = try SessionManager.readScrollback(id: info.id, directory: fixture.output, from: 3, maxBytes: 3)
        #expect(archived.data == Data("def".utf8))
        #expect(archived.nextOffset == 6)
        #expect(!archived.truncated)
    }

    @Test func outputLargerThanCapacityRemainsBoundedAndReplayable() throws {
        let fixture = SizeFixture()
        defer { fixture.cleanup() }
        let manager = try fixture.manager(capacity: 32)
        defer { manager.stop() }
        let payload = String(repeating: "0123456789", count: 20) + "END"
        let info = try manager.create(executable: "/bin/sh", arguments: ["-c", "stty -opost; printf '%s' '\(payload)'"])
        try #require(try sizeEventually { try manager.read(id: info.id, from: 0).exit == .exited(0) })
        try manager.close(id: info.id)
        #expect(try fixture.attributes(info.id).size == 56)
        let archived = try SessionManager.readScrollback(id: info.id, directory: fixture.output, from: 0)
        #expect(archived.data == Data(payload.utf8.suffix(32)))
        #expect(archived.nextOffset == UInt64(payload.utf8.count))
        #expect(archived.truncated)
    }

    @Test func legacyPreSizedArchivesStillReplay() throws {
        let fixture = SizeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.output, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        var bytes = archiveHeader(capacity: 64, end: 5)
        bytes.append(Data("hello".utf8))
        bytes.append(Data(repeating: 0, count: 59))
        try bytes.write(to: fixture.output.appendingPathComponent(id + ".scrollback"))
        let archived = try SessionManager.readScrollback(id: id, directory: fixture.output, from: 1)
        #expect(archived.data == Data("ello".utf8))
        #expect(archived.nextOffset == 5)
        #expect(!archived.truncated)
    }

    @Test func lazyArchivesRejectMissingOrExtraData() throws {
        let fixture = SizeFixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.output, withIntermediateDirectories: true)
        for count in [0, 4, 6, 65] {
            let id = UUID().uuidString.lowercased()
            var bytes = archiveHeader(capacity: 64, end: 5)
            bytes.append(Data(repeating: 120, count: count))
            try bytes.write(to: fixture.output.appendingPathComponent(id + ".scrollback"))
            #expect(throws: SessionError.scrollbackFailure) {
                try SessionManager.readScrollback(id: id, directory: fixture.output, from: 0)
            }
        }
    }
}

private func archiveHeader(capacity: UInt64, end: UInt64) -> Data {
    var bytes = Data()
    for value in [0x534d54485a534231, capacity, end] {
        var word = value.bigEndian
        withUnsafeBytes(of: &word) { bytes.append(contentsOf: $0) }
    }
    return bytes
}
