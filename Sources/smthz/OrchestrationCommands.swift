import Foundation
import SmthzCore

/// `smthz orchestration <verb> ...` (WP-M8-ORCH-1). Blocking `ask` and `check --wait` loop over
/// bounded host waits so no single request exceeds the host's request ceiling.
enum OrchestrationCommands {
    static func run(arguments: [String], defaultSocket: String) throws {
        let request = try OrchestrationCLIRequest(arguments)
        let client = try HostClient(socketPath: request.socket ?? defaultSocket)
        defer { client.disconnect() }
        func call(_ method: String, _ params: [String: HostJSON], requestID: String? = nil) throws -> [String: HostJSON] {
            let payload = try client.rawCall(method: method, params: JSONEncoder().encode(params),
                                             requestID: requestID ?? RequestID.generate().rawValue, timeoutMilliseconds: 30_000)
            var result = try JSONDecoder().decode([String: HostJSON].self, from: payload)
            guard result["ok"] == .bool(true) else {
                throw HostRPCError(result["error"]?.string ?? "unknownError", detail: result["detail"]?.string)
            }
            result.removeValue(forKey: "ok")
            return result
        }
        /// Repeats a bounded wait until it reports something or the caller's total timeout expires.
        func waitLoop(_ method: String, _ params: [String: HostJSON], done: ([String: HostJSON]) -> Bool) throws -> [String: HostJSON] {
            let total = Double(params["timeoutMs"]?.string.flatMap(Int.init) ?? 600_000) / 1000
            let deadline = Date(timeIntervalSinceNow: total)
            while true {
                let remaining = max(1, Int(deadline.timeIntervalSinceNow * 1000))
                var bounded = params; bounded["timeoutMs"] = .number(Double(min(remaining, OrchestrationRPC.maximumWaitMilliseconds)))
                let result = try call(method, bounded)
                if done(result) || Date() >= deadline { return result }
            }
        }

        var result: [String: HostJSON]
        switch request.verb {
        case "ask":
            let id = try request.params["resume"]?.string
                ?? call(request.method, request.params, requestID: request.retryRequest)["message"]?.object?["id"]?.string ?? ""
            var waitParams: [String: HostJSON] = ["id": .string(id)]
            waitParams["timeoutMs"] = request.params["timeoutMs"]
            result = try waitLoop("orchestration.ask-wait", waitParams) { $0["status"] == .string("answered") }
            guard result["status"] == .string("answered") else {
                throw HostRPCError("timeout", detail: "question \(id) is still pending; resume with --resume \(id)")
            }
            if !request.json { print(result["answer"]?.object?["body"]?.string ?? ""); return }
        case "check" where request.params["wait"] == .bool(true):
            var params = request.params
            if params["ack"] != nil {
                // Acknowledge the prior batch first so the wait does not wake on its own unread rows.
                result = try call(request.method, params, requestID: request.retryRequest)
                params["ack"] = nil
                if result["count"] != .number(0) { break }
            }
            let waited = try waitLoop("orchestration.wait", params) { $0["timedOut"] == .bool(false) }
            result = try call(request.method, params)
            result["timedOut"] = waited["timedOut"]
        default:
            result = try call(request.method, request.params, requestID: request.retryRequest)
        }
        if request.json { try CLICommon.printResult(result) }
        else { print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self)) }
    }
}
