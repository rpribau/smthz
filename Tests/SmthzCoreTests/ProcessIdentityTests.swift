import Testing
import Foundation
@testable import SmthzCore

@Test
func currentProcessIsRunning() throws {
    let id = try #require(ProcessIdentity.current())
    #expect(id.pid == getpid())
    #expect(id.isStillRunning())
}

@Test
func unknownPidIsNil() {
    #expect(ProcessIdentity.lookup(pid: Int32.max) == nil)
}

@Test
func childProcessLifecycle() throws {
    let p = Process()
    p.executableURL = URL(filePath: "/bin/sleep")
    p.arguments = ["30"]
    try p.run()
    let id = try #require(ProcessIdentity.lookup(pid: p.processIdentifier))
    #expect(id.isStillRunning())
    p.terminate()
    p.waitUntilExit()
    #expect(!id.isStillRunning())
}
