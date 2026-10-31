import Foundation

/// `orchestration.<verb>` host methods. Params use the CLI flag names in camelCase, values as strings.
/// Mutations are journaled by request id (Orca `--retry-request` replays the recorded result).
public enum OrchestrationRPC {
    /// Blocking reads (`wait`, `askWait`) return before the client's 30 s request ceiling; the CLI loops.
    public static let maximumWaitMilliseconds = 25_000

    public static func register(on router: HostRouter, store: WorkspaceStore) {
        let none: HostRouter.RepoKey = { _ in nil }
        func mutation(_ verb: String, _ handler: @escaping HostRouter.Handler) {
            router.register("orchestration." + verb, methodClass: .mutation, repository: none, handler: handler)
        }
        func read(_ verb: String, _ handler: @escaping HostRouter.Handler) {
            router.register("orchestration." + verb, methodClass: .read, repository: none, handler: handler)
        }
        let row = Orchestration.json
        @Sendable func rows(_ list: [[String: WorkspaceSQLValue]]) -> HostJSON { .array(list.map(row)) }
        /// Explicit `--run`, else the Run bound to `--from`.
        @Sendable func runID(_ p: [String: HostJSON], required: Bool = true) throws -> String? {
            if let run = p["run"]?.string { return try store.orchRun(run)["id"]?.string }
            if let from = p["from"]?.string, let bound = try store.orchBoundRun(from) { return bound["id"]?.string }
            if required { throw HostRPCError("badRequest", detail: "pass --run or bind a run with run-create/run-use --from") }
            return nil
        }

        // MARK: Runs
        mutation("run-create") { p, _ in
            ["run": row(try store.orchCreateRun(objective: try text(p, "objective"), coordinator: p["from"]?.string))]
        }
        mutation("run-use") { p, _ in
            ["run": row(try store.orchUseRun(try text(p, "id"), coordinator: try text(p, "from")))]
        }
        read("run-current") { p, _ in ["run": try store.orchBoundRun(try text(p, "from")).map(row) ?? .null] }
        read("run-list") { p, _ in
            ["runs": rows(try store.query("SELECT * FROM orch_runs ORDER BY created_at DESC, rowid DESC LIMIT ?", [.integer(Int64(try int(p, "limit") ?? 100))]))]
        }
        read("run-show") { p, _ in
            let run = try store.orchRun(try text(p, "id"))
            return ["run": row(run), "tasks": rows(try store.orchTasks(runID: run["id"]?.string, status: nil))]
        }

        // MARK: Tasks
        mutation("task-create") { p, _ in
            var deps: [String] = []
            if let raw = p["deps"]?.string {
                guard let decoded = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else {
                    throw HostRPCError("badRequest", detail: "--deps must be a JSON array of task ids")
                }
                deps = decoded
            }
            return ["task": row(try store.orchCreateTask(runID: try runID(p)!, spec: try text(p, "spec"), title: p["taskTitle"]?.string,
                                                         displayName: p["displayName"]?.string, deps: deps,
                                                         parent: p["parent"]?.string, createdBy: p["from"]?.string))]
        }
        read("task-list") { p, _ in
            let status = p["ready"] == .bool(true) ? "ready" : p["status"]?.string
            var list = try store.orchTasks(runID: try runID(p, required: false), status: status)
            if p["brief"] == .bool(true) {
                list = list.map { var r = $0
                    let spec = (r["spec"]?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    r["spec"] = .text(spec.count > 160 ? String(spec.prefix(159)) + "…" : spec); return r }
            }
            return ["tasks": rows(list)]
        }
        mutation("task-update") { p, _ in
            ["task": row(try store.orchUpdateTask(try text(p, "id"), status: try text(p, "status"), result: p["result"]?.string))]
        }

        // MARK: Dispatch
        mutation("dispatch") { p, _ in
            ["dispatch": row(try store.orchDispatchTask(try text(p, "task"), to: try text(p, "to"), from: p["from"]?.string))]
        }
        read("dispatch-show") { p, _ in
            let task = try store.orchTask(try text(p, "task"))
            let ctx = try store.query("SELECT * FROM orch_dispatches WHERE task_id=? ORDER BY rowid DESC LIMIT 1", [task["id"]!]).first
            return ["task": row(task), "dispatch": ctx.map(row) ?? .null]
        }

        // MARK: Mail
        mutation("send") { p, _ in
            var payload: [String: HostJSON] = [:]
            if let raw = p["payload"]?.string {
                guard let object = (try? JSONDecoder().decode(HostJSON.self, from: Data(raw.utf8)))?.object else {
                    throw HostRPCError("badRequest", detail: "--payload must be a JSON object")
                }
                payload = object
            }
            for key in ["taskId", "dispatchId", "outcome", "reportPath", "phase"] { if let v = p[key] { payload[key] = v } }
            if let files = p["filesModified"]?.string {
                payload["filesModified"] = .array(files.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) })
            }
            let message = try store.orchSend(from: p["from"]?.string ?? "cli", to: p["to"]?.string, runID: p["run"]?.string,
                                             subject: try text(p, "subject"), body: p["body"]?.string ?? "",
                                             type: p["type"]?.string ?? "status", priority: p["priority"]?.string ?? "normal",
                                             threadID: p["threadId"]?.string, payload: payload)
            return ["message": row(message)]
        }
        mutation("reply") { p, _ in
            ["message": row(try store.orchReply(to: try text(p, "id"), body: try text(p, "body"), from: p["from"]?.string))]
        }
        mutation("ask") { p, _ in
            var payload: [String: HostJSON] = [:]
            if let options = p["options"]?.string {
                payload["options"] = .array(options.split(separator: ",").map { .string(String($0)) })
            }
            let message = try store.orchSend(from: p["from"]?.string ?? "cli", to: p["to"]?.string, runID: p["run"]?.string,
                                             subject: try text(p, "question"), body: try text(p, "question"),
                                             type: "question", priority: "normal", threadID: nil, payload: payload)
            return ["message": row(message)]
        }
        read("ask-wait") { p, context in
            let id = try text(p, "id")
            let answer = try poll(p, context) { try store.orchAnswer(question: id) }
            return ["messageId": .string(id), "status": .string(answer == nil ? "pending" : "answered"),
                    "answer": answer.map(row) ?? .null]
        }
        @Sendable func mailboxes(_ p: [String: HostJSON]) throws -> (consumer: String, boxes: [String]) {
            if let run = p["run"]?.string { _ = try store.orchRun(run); return ("run:" + run, ["run:" + run]) }
            let handle = try text(p, "terminal")
            return (handle, try store.orchMailboxes(handle: handle))
        }
        @Sendable func types(_ p: [String: HostJSON]) -> Set<String>? {
            p["types"]?.string.map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        }
        mutation("check") { p, _ in
            let (consumer, boxes) = try mailboxes(p)
            if p["peek"] == .bool(true) || p["all"] == .bool(true) || p["unread"] == .bool(true) {
                let list = try store.orchMessages(mailboxes: boxes, unreadOnly: p["all"] != .bool(true),
                                                  types: p["unread"] == .bool(true) ? nil : types(p), limit: 500)
                if p["unread"] == .bool(true) { try store.orchMarkRead(list) }  // legacy consuming mode
                return ["messages": rows(list), "count": .number(Double(list.count)), "deliveryId": .null]
            }
            let batch = try store.orchCheck(consumer: consumer, mailboxes: boxes, ack: p["ack"]?.string)
            return ["deliveryId": batch.delivery?["id"]?.string.map(HostJSON.string) ?? .null, "messages": rows(batch.messages),
                    "count": .number(Double(batch.messages.count)), "acknowledged": p["ack"] ?? .null]
        }
        read("wait") { p, context in
            let (_, boxes) = try mailboxes(p)
            let filter = types(p)
            let found = try poll(p, context) { try store.orchMessages(mailboxes: boxes, unreadOnly: true, types: filter, limit: 1).first }
            return ["timedOut": .bool(found == nil)]
        }
        read("inbox") { p, _ in
            let boxes = try p["terminal"]?.string.map { try store.orchMailboxes(handle: $0) }
            var list = try store.orchMessages(mailboxes: boxes, unreadOnly: false, types: nil, limit: try int(p, "limit") ?? 50)
            if p["full"] != .bool(true) {
                list = list.map { var r = $0
                    if let body = r["body"]?.string, body.count > 200 { r["body"] = .text(String(body.prefix(199)) + "…") }
                    return r }
            }
            return ["messages": rows(list)]
        }

        // MARK: Gates
        mutation("gate-create") { p, _ in
            var options: [String] = []
            if let raw = p["options"]?.string {
                guard let decoded = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else {
                    throw HostRPCError("badRequest", detail: "--options must be a JSON array of strings")
                }
                options = decoded
            }
            return ["gate": row(try store.orchCreateGate(task: try text(p, "task"), question: try text(p, "question"), options: options))]
        }
        mutation("gate-resolve") { p, _ in
            ["gate": row(try store.orchResolveGate(try text(p, "id"), resolution: try text(p, "resolution")))]
        }
        read("gate-list") { p, _ in
            ["gates": rows(try store.orchGates(task: p["task"]?.string, status: p["status"]?.string, runID: try runID(p, required: false)))]
        }
        mutation("reset") { p, _ in
            let all = p["all"] == .bool(true), tasks = p["tasks"] == .bool(true), messages = p["messages"] == .bool(true)
            guard all || tasks || messages else { throw HostRPCError("badRequest", detail: "pass --all, --tasks or --messages") }
            try store.orchReset(tasks: tasks, messages: messages, runs: all)
            return [:]
        }
    }

    private static func text(_ p: [String: HostJSON], _ key: String) throws -> String {
        guard let value = p[key]?.string, !value.isEmpty else { throw HostRPCError("badRequest", detail: "missing \(key)") }
        return value
    }
    private static func int(_ p: [String: HostJSON], _ key: String) throws -> Int? {
        guard let value = p[key] else { return nil }
        guard let n = value.number.map(Int.init) ?? value.string.flatMap({ Int($0) }), n > 0 else { throw HostRPCError("badRequest", detail: key) }
        return n
    }
    /// Polls every 50 ms until `probe` yields a value, `timeoutMs` elapses, or the request is cancelled.
    private static func poll<T>(_ p: [String: HostJSON], _ context: HostRequestContext, _ probe: () throws -> T?) throws -> T? {
        let wait = min(try int(p, "timeoutMs") ?? maximumWaitMilliseconds, maximumWaitMilliseconds)
        let deadline = Date(timeIntervalSinceNow: Double(wait) / 1000)
        while true {
            if let value = try probe() { return value }
            try context.checkCancellation()
            if Date() >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

/// `smthz orchestration <verb> --flag value ...` parsed into an `orchestration.<verb>` call.
/// Verbs and flags mirror Orca `src/cli/specs/orchestration.ts` for the implemented families.
public struct OrchestrationCLIRequest: Equatable, Sendable {
    public var verb: String
    public var params: [String: HostJSON] = [:]
    public var json = false
    public var socket: String?
    public var retryRequest: String?
    public var method: String { "orchestration." + verb }

    static let booleans: Set<String> = ["json", "ready", "brief", "peek", "all", "unread", "wait", "full", "format",
                                        "tasks", "messages", "preamble"]
    static let verbs: [String: Set<String>] = [
        "run-create": ["objective", "from"], "run-use": ["id", "from"], "run-current": ["from"],
        "run-list": ["limit", "cursor"], "run-show": ["id"],
        "send": ["to", "run", "from", "subject", "body", "type", "priority", "thread-id", "payload", "task-id", "dispatch-id",
                 "outcome", "files-modified", "report-path", "phase"],
        "check": ["terminal", "run", "ack", "unread", "peek", "all", "types", "format", "wait", "timeout-ms"],
        "reply": ["id", "body", "run", "from"],
        "inbox": ["limit", "terminal", "full"],
        "task-create": ["spec", "task-title", "display-name", "deps", "parent", "run", "from"],
        "task-list": ["status", "ready", "brief", "run", "from"],
        "task-update": ["id", "status", "result", "run", "from"],
        "dispatch": ["task", "to", "from", "run"],
        "dispatch-show": ["task", "preamble", "from"],
        "ask": ["to", "run", "question", "resume", "options", "timeout-ms", "from"],
        "gate-create": ["task", "question", "options", "from"],
        "gate-resolve": ["id", "resolution", "from"],
        "gate-list": ["task", "status", "run", "from"],
        "reset": ["all", "tasks", "messages"],
    ]
    public static var usage: String {
        "usage: smthz orchestration " + verbs.keys.sorted().joined(separator: "|") + " [--flag value ...] [--json] [--socket <path>]"
    }

    public init(_ arguments: [String]) throws {
        guard let verb = arguments.first, !verb.hasPrefix("-") else { throw HostRPCError("badRequest", detail: Self.usage) }
        // shortcut: worker-*, request-show and federation need worker spawning (later M8 slices).
        guard let allowed = Self.verbs[verb] else { throw HostRPCError("notImplemented", detail: "orchestration \(verb)") }
        self.verb = verb
        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            guard arg.hasPrefix("--"), arg.count > 2 else { throw HostRPCError("badRequest", detail: "unexpected argument: \(arg)") }
            let name = String(arg.dropFirst(2))
            guard allowed.contains(name) || ["json", "socket", "retry-request"].contains(name) else {
                throw HostRPCError("badRequest", detail: "unknown flag for orchestration \(verb): \(arg)")
            }
            if Self.booleans.contains(name) {
                if name == "json" { json = true } else { params[Self.camel(name)] = .bool(true) }
            } else {
                guard i + 1 < arguments.count else { throw HostRPCError("badRequest", detail: "missing value for \(arg)") }
                i += 1
                switch name {
                case "socket": socket = arguments[i]
                case "retry-request": retryRequest = arguments[i]
                default: params[Self.camel(name)] = .string(arguments[i])
                }
            }
            i += 1
        }
        if verb == "ask", (params["question"] == nil) == (params["resume"] == nil) {
            throw HostRPCError("badRequest", detail: "pass exactly one of --question or --resume")
        }
        if verb == "send", case .string(let outcome)? = params["outcome"], !["succeeded", "failed"].contains(outcome) {
            throw HostRPCError("badRequest", detail: "--outcome must be succeeded or failed")
        }
    }
    static func camel(_ flag: String) -> String {
        let parts = flag.split(separator: "-")
        return parts.enumerated().map { $0.offset == 0 ? String($0.element) : $0.element.capitalized }.joined()
    }
}
