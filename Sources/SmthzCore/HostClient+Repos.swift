import Foundation

/// Untyped registry calls for the app and CLI. Failures keep the host's code and detail.
public extension HostClient {
    func json(_ method: String, _ params: [String: HostJSON] = [:],
              timeoutMilliseconds: Int = 5_000) throws -> [String: HostJSON] {
        let payload = try rawCall(method: method, params: JSONEncoder().encode(params),
                                  timeoutMilliseconds: timeoutMilliseconds)
        var result = try JSONDecoder().decode([String: HostJSON].self, from: payload)
        guard result["ok"] == .bool(true) else {
            throw HostClientError.detailedHostError(code: result["error"]?.string ?? "unknownError",
                                                    detail: result["detail"]?.string)
        }
        result.removeValue(forKey: "ok")
        return result
    }

    /// Polls `job.get` every 250 ms until the job settles; `onEvent` receives new event texts.
    func waitForJob(_ jobID: String, isCancelled: @Sendable () -> Bool = { false },
                    onEvent: (String, String, (done: Int, total: Int)?) -> Void = { _, _, _ in }) throws -> HostJSON {
        var after = 0.0
        var cancelSent = false
        while true {
            if isCancelled(), !cancelSent {
                _ = try? json("job.cancel", ["jobId": .string(jobID)]); cancelSent = true
            }
            let state = try json("job.get", ["jobId": .string(jobID), "afterSeq": .number(after)])
            let progress = state["progress"]?.object.flatMap { p -> (Int, Int)? in
                guard let d = p["done"]?.number, let t = p["total"]?.number else { return nil }
                return (Int(d), Int(t))
            }
            if case .array(let events) = state["events"] ?? .null {
                for case .object(let event) in events {
                    after = max(after, event["seq"]?.number ?? 0)
                    onEvent(event["kind"]?.string ?? "log", event["text"]?.string ?? "", progress)
                }
            }
            switch state["state"]?.string {
            case "succeeded": return state["result"] ?? .null
            case "failed", "cancelled":
                throw HostClientError.detailedHostError(code: state["error"]?.string ?? "cancelled", detail: state["detail"]?.string)
            default: Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }
}
