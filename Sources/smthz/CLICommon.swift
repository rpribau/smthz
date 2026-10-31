import Foundation
import Darwin
import SmthzCore

struct CLIFlags {
    var positional: [String] = []
    var values: [String: String] = [:]
    var json = false
    init(_ arguments: [String]) throws {
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "--json" { json = true }
            else if arg.hasPrefix("--") {
                guard i + 1 < arguments.count else { throw HostRPCError("badRequest", detail: "missing value for \(arg)") }
                i += 1; values[String(arg.dropFirst(2))] = arguments[i]
            } else { positional.append(arg) }
            i += 1
        }
    }
}

struct CLIInterrupted: Error {}
// sig_atomic_t-sized storage; only the signal handler writes while waitJob runs.
nonisolated(unsafe) private var jobInterrupted: Int32 = 0

enum CLICommon {
    static func printJSON(_ value: [String: HostJSON]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try FileHandle.standardOutput.write(contentsOf: encoder.encode(value) + Data("\n".utf8))
    }
    static func printResult(_ result: [String: HostJSON]) throws {
        var result = result; result.removeValue(forKey: "ok")
        try printJSON(["ok": .bool(true), "result": .object(result)])
    }
    static func printError(_ error: any Error) {
        let code: String
        let detail: String?
        switch error {
        case let e as HostRPCError: code = e.code; detail = e.detail
        case HostClientError.detailedHostError(let c, let d): code = c; detail = d
        case HostClientError.hostError(let c): code = c; detail = nil
        case is CLIInterrupted: code = "cancelled"; detail = nil
        default: code = "badRequest"; detail = String(describing: error)
        }
        var failure: [String: HostJSON] = ["code": .string(code), "message": .string(code)]
        failure["detail"] = detail.map(HostJSON.string)
        try? printJSON(["ok": .bool(false), "error": .object(failure)])
    }
    static func call(_ client: HostClient, _ method: String, _ params: [String: HostJSON] = [:]) throws -> [String: HostJSON] {
        let payload = try client.rawCall(method: method, params: JSONEncoder().encode(params))
        let result = try JSONDecoder().decode([String: HostJSON].self, from: payload)
        guard result["ok"] == .bool(true) else {
            throw HostRPCError(result["error"]?.string ?? "unknownError", detail: result["detail"]?.string)
        }
        return result
    }
    static func waitJob(_ id: String, client: HostClient) throws -> [String: HostJSON] {
        jobInterrupted = 0
        let previous = signal(SIGINT) { _ in jobInterrupted = 1 }
        defer { signal(SIGINT, previous) }
        var after = 0.0
        while true {
            if jobInterrupted != 0 {
                _ = try? call(client, "job.cancel", ["jobId": .string(id)])
                throw CLIInterrupted()
            }
            let result = try call(client, "job.get", ["jobId": .string(id), "afterSeq": .number(after)])
            if case .array(let events) = result["events"] {
                for event in events {
                    guard let event = event.object else { continue }
                    after = max(after, event["seq"]?.number ?? 0)
                    if let text = event["text"]?.string {
                        try FileHandle.standardError.write(contentsOf: Data((text + "\n").utf8))
                    }
                }
            }
            switch result["state"]?.string {
            case "succeeded": return result["result"]?.object ?? ["value": result["result"] ?? .null]
            case "failed", "cancelled": throw HostRPCError(result["error"]?.string ?? "cancelled", detail: result["detail"]?.string)
            default: Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }
    static func dispatch(command: String, arguments: [String], defaultSocket: String) throws -> Bool {
        guard ["job", "job.list", "repo", "project", "worktree"].contains(command) else { return false }
        let flags = try CLIFlags(arguments)
        let client = try HostClient(socketPath: flags.values["socket"] ?? defaultSocket)
        defer { client.disconnect() }
        let result: [String: HostJSON]
        switch command {
        case "repo", "project": result = try RepoCommands.run(command: command, flags: flags, client: client)
        case "worktree": result = try WorktreeCommands.run(flags: flags, client: client)
        default:
            let verb = command == "job.list" ? "list" : flags.positional.first ?? "list"
            guard ["get", "list", "cancel", "wait"].contains(verb) else { throw HostRPCError("badRequest") }
            if verb == "list" { result = try call(client, "job.list") }
            else {
                guard let id = flags.values["job-id"] ?? flags.positional.dropFirst().first else { throw HostRPCError("badRequest", detail: "pass --job-id") }
                if verb == "wait" { result = try waitJob(id, client: client) }
                else { result = try call(client, "job." + verb, ["jobId": .string(id)]) }
            }
        }
        if flags.json { try printResult(result) }
        else {
            let bytes = try JSONEncoder().encode(result)
            print(String(decoding: bytes, as: UTF8.self))
        }
        return true
    }
}
