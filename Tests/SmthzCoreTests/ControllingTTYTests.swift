import Darwin
import Foundation
import Testing
@testable import SmthzCore

private final class TTYTestOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
}

private func ttyEventually(timeout: TimeInterval = 4, _ predicate: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeout)
    repeat {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    return predicate()
}

private func ttySession(_ command: String, rows: UInt16 = 24, cols: UInt16 = 80) throws -> (PTYSession, TTYTestOutput) {
    let child = try PTYSession(executable: "/bin/sh", arguments: ["-c", command],
                               environment: ProcessInfo.processInfo.environment, workingDirectory: nil,
                               size: PTYSize(rows: rows, cols: cols))
    let output = TTYTestOutput()
    child.setOutputHandler { output.append($0) }
    return (child, output)
}

@Suite(.serialized)
struct ControllingTTYTests {
    @Test func processHasControllingTTYAndForegroundPgrp() throws {
        let (child, output) = try ttySession("ps -o tty=,tpgid= -p $$; ps -o pgid= -p $$; echo READY; read answer")
        defer { child.close() }
        #expect(ttyEventually { output.text.contains("READY") })
        let lines = output.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let ttyAndTPGID = try #require(lines.first(where: { $0.contains("ttys") || $0.contains("??") }))
        let columns = ttyAndTPGID.split(whereSeparator: \.isWhitespace)
        #expect(columns.count == 2)
        #expect(columns.first?.hasPrefix("ttys") == true)
        let shellPgrp = try #require(lines.dropFirst().first.flatMap { Int32($0) })
        let terminalPgrp = try #require(columns.last.flatMap { Int32($0) })
        #expect(terminalPgrp == shellPgrp)
        try child.write(Data("done\n".utf8))
        #expect(child.waitForExit(timeout: 3) == .exited(0))
    }

    @Test func controlCInterruptsForegroundJobAndLeavesShellAlive() throws {
        let (child, output) = try ttySession("set -m; echo READY; sleep 100; echo SHELL-SURVIVED; sleep 100")
        defer { child.close() }
        #expect(ttyEventually { output.text.contains("READY") })
        try child.write(Data([0x03]))
        #expect(ttyEventually { output.text.contains("SHELL-SURVIVED") })
        #expect(child.waitForExit(timeout: 0.05) == nil)
    }

    @Test func resizeNotifiesForegroundProcessGroup() throws {
        let (child, output) = try ttySession("trap 'echo WINCH; stty size' WINCH; echo READY; while :; do sleep 0.05; done")
        defer { child.close() }
        #expect(ttyEventually { output.text.contains("READY") })
        try child.resize(PTYSize(rows: 41, cols: 123))
        #expect(ttyEventually { output.text.contains("WINCH") && output.text.contains("41 123") })
    }
}
