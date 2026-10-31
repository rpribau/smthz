import Foundation
import SmthzCore

enum AgentCommands {
    static func run(arguments: [String], defaultSocket: String) throws {
        var args = arguments
        guard !args.isEmpty else { throw HostRPCError("badRequest", detail: "agent list|launch") }
        let verb = args.removeFirst()
        var socket = defaultSocket
        var json = false
        var draft = false
        var values: [String: String] = [:]
        var extra: [String] = []
        while !args.isEmpty {
            let flag = args.removeFirst()
            if flag == "--" { extra = args; break }
            if flag == "--draft" { draft = true; continue }
            if flag == "--json" { json = true; continue }
            guard ["--socket", "--agent", "--cwd", "--prompt", "--permission", "--account-id", "--request-id"].contains(flag),
                  !args.isEmpty else { throw HostRPCError("badRequest", detail: "Unknown option or missing value: \(flag)") }
            let value = args.removeFirst()
            if flag == "--socket" { socket = value }
            else { values[flag] = value }
        }
        guard ["list", "launch"].contains(verb) else { throw HostRPCError("badRequest", detail: "agent list|launch") }
        if verb == "list", !values.isEmpty || draft || !extra.isEmpty { throw HostRPCError("badRequest") }
        let client = try HostClient(socketPath: socket)
        defer { client.disconnect() }
        if verb == "list" {
            let agents = try client.listAgents()
            if json {
                try CLICommon.printResult(["agents": .array(agents.map {
                    .object(["id": .string($0.id.rawValue), "executable": .string($0.executable),
                             "version": $0.version.map(HostJSON.string) ?? .null])
                })])
            } else {
                for agent in agents { print("\(agent.id.rawValue)\t\(agent.version ?? "unknown")\t\(agent.executable)") }
            }
            return
        }
        guard let raw = values["--agent"], let agent = AgentID(rawValue: raw),
              let permission = AgentLaunchPermission(rawValue: values["--permission"] ?? "default")
        else { throw HostRPCError("badRequest", detail: "Pass --agent <id> and a valid --permission") }
        let cwd = URL(fileURLWithPath: values["--cwd"] ?? FileManager.default.currentDirectoryPath).standardizedFileURL.path
        let request = AgentLaunchRequest(agent: agent, cwd: cwd, prompt: values["--prompt"],
            mode: draft ? .draft : .submit, permission: permission, extraArgs: extra, accountId: values["--account-id"])
        let result = try client.launchAgent(request, requestID: values["--request-id"] ?? RequestID.generate().rawValue)
        if json {
            try CLICommon.printResult(try JSONDecoder().decode([String: HostJSON].self, from: JSONEncoder().encode(result)))
        } else { print(result.id) }
    }
}
