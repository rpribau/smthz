import Testing
import Foundation
@testable import SmthzCore

@Test
func sessionExitDescribesExitCode() {
    #expect(HostSessionExit(code: 0, signal: nil).displayDescription == "exit 0")
    #expect(HostSessionExit(code: 2, signal: nil).displayDescription == "exit 2")
}

@Test
func sessionExitDescribesSignalWithName() {
    #expect(HostSessionExit(code: nil, signal: 9).displayDescription == "signal 9 (SIGKILL)")
    #expect(HostSessionExit(code: nil, signal: 15).displayDescription == "signal 15 (SIGTERM)")
    #expect(HostSessionExit(code: nil, signal: 99).displayDescription == "signal 99")
}

@Test
func sessionExitWireFormatUnchanged() throws {
    let exit = try JSONDecoder().decode(HostSessionExit.self, from: Data(#"{"signal":9}"#.utf8))
    #expect(exit == HostSessionExit(code: nil, signal: 9))
    #expect(HostSessionExit(code: nil, signal: nil).displayDescription == "running")
}
