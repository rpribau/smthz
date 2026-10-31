import Darwin
import Foundation
import SmthzCore

/// Hook helpers must never block or fail closed in the agent. In particular,
/// Claude permission hooks require a JSON object even on every failure path.
enum HookCommand {
    static func run(arguments: [String]) {
        // Install the deadline before reading stdin (which may itself never close).
        // _exit avoids waiting for stuck IO or background runtime shutdown.
        let deadline = DispatchSource.makeTimerSource(queue: .global())
        deadline.schedule(deadline: .now() + .milliseconds(1400))
        deadline.setEventHandler {
            let bytes: [UInt8] = [123, 125, 10]
            bytes.withUnsafeBytes { _ = Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            _exit(0)
        }
        deadline.resume()
        defer {
            deadline.cancel()
            print("{}")
        }
        guard arguments.count == 2, arguments[0] == "--agent",
              let source = AgentHookSource(rawValue: arguments[1]) else { return }
        let environment = ProcessInfo.processInfo.environment
        guard let socket = environment["SMTHZ_SOCKET"],
              let id = environment["SMTHZ_SESSION_ID"],
              let agent = environment["SMTHZ_AGENT_ID"],
              let launch = environment["SMTHZ_LAUNCH_TOKEN"],
              let token = environment["SMTHZ_HOOK_TOKEN"] else { return }
        var payload = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { return }
            if count == 0 { break }
            guard payload.count + count <= AgentHookPayload.maxBytes else { return }
            payload.append(contentsOf: buffer.prefix(count))
        }
        try? HostClient.sendAgentHook(socketPath: socket, sessionID: id, agent: agent,
            launchToken: launch, hookToken: token, source: source, payload: payload)
    }
}
