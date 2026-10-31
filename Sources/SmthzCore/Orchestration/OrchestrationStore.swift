import Foundation

/// Runs, task DAG, dispatch contexts, mail and decision gates in the host workspace store.
/// Every multi-row change runs in one transaction so a settled task never leaves dependents unpromoted.
public extension WorkspaceStore {
    private var now: WorkspaceSQLValue { .real(Date().timeIntervalSince1970) }
    private func one(_ sql: String, _ bindings: [WorkspaceSQLValue], _ what: String) throws -> [String: WorkspaceSQLValue] {
        guard let row = try query(sql, bindings).first else { throw HostRPCError("notFound", detail: what) }
        return row
    }

    // MARK: Runs

    func orchCreateRun(objective: String, coordinator: String?) throws -> [String: WorkspaceSQLValue] {
        let id = Orchestration.newID("run")
        try execute("INSERT INTO orch_runs (id,objective,coordinator_handle,created_at,updated_at) VALUES (?,?,?,?,?)",
                    [.text(id), .text(objective), coordinator.map(WorkspaceSQLValue.text) ?? .null, now, now])
        return try orchRun(id)
    }
    func orchRun(_ id: String) throws -> [String: WorkspaceSQLValue] {
        try one("SELECT * FROM orch_runs WHERE id=?", [.text(id)], "run \(id)")
    }
    /// The Run a coordinator handle is bound to: the latest `run-create`/`run-use` wins.
    func orchBoundRun(_ handle: String) throws -> [String: WorkspaceSQLValue]? {
        try query("SELECT * FROM orch_runs WHERE coordinator_handle=? ORDER BY updated_at DESC, rowid DESC LIMIT 1", [.text(handle)]).first
    }
    func orchUseRun(_ id: String, coordinator: String) throws -> [String: WorkspaceSQLValue] {
        _ = try orchRun(id)
        try execute("UPDATE orch_runs SET coordinator_handle=?, updated_at=? WHERE id=?", [.text(coordinator), now, .text(id)])
        return try orchRun(id)
    }

    // MARK: Tasks

    func orchTask(_ id: String) throws -> [String: WorkspaceSQLValue] {
        try one("SELECT * FROM orch_tasks WHERE id=?", [.text(id)], "task \(id)")
    }
    /// Dependencies must already exist in the same Run, so the graph is acyclic by construction.
    func orchCreateTask(runID: String, spec: String, title: String?, displayName: String?, deps: [String],
                        parent: String?, createdBy: String?) throws -> [String: WorkspaceSQLValue] {
        try transaction {
            _ = try orchRun(runID)
            var ready = true
            for dep in deps {
                let row = try one("SELECT run_id, status FROM orch_tasks WHERE id=?", [.text(dep)], "dependency \(dep)")
                guard row["run_id"]?.string == runID else { throw HostRPCError("badRequest", detail: "dependency \(dep) must belong to run \(runID)") }
                if row["status"]?.string != "completed" { ready = false }
            }
            let id = Orchestration.newID("task")
            let depsJSON = String(decoding: try JSONEncoder().encode(deps), as: UTF8.self)
            try execute("INSERT INTO orch_tasks (id,run_id,parent_id,created_by,task_title,display_name,spec,status,deps,created_at) VALUES (?,?,?,?,?,?,?,?,?,?)", [
                .text(id), .text(runID), parent.map(WorkspaceSQLValue.text) ?? .null, createdBy.map(WorkspaceSQLValue.text) ?? .null,
                title.map(WorkspaceSQLValue.text) ?? .null, displayName.map(WorkspaceSQLValue.text) ?? .null,
                .text(spec), .text(ready ? "ready" : "pending"), .text(depsJSON), now])
            return try orchTask(id)
        }
    }
    func orchTasks(runID: String?, status: String?) throws -> [[String: WorkspaceSQLValue]] {
        var sql = "SELECT * FROM orch_tasks WHERE 1=1", bindings: [WorkspaceSQLValue] = []
        if let runID { sql += " AND run_id=?"; bindings.append(.text(runID)) }
        if let status { sql += " AND status=?"; bindings.append(.text(status)) }
        return try query(sql + " ORDER BY created_at, rowid", bindings)
    }
    /// Orca `taskUpdate` accepts every status; completing settles the active Dispatch and promotes dependents.
    func orchUpdateTask(_ id: String, status: String, result: String?) throws -> [String: WorkspaceSQLValue] {
        guard Orchestration.taskStatuses.contains(status) else { throw HostRPCError("badRequest", detail: "status") }
        return try transaction {
            _ = try orchTask(id)
            let done: WorkspaceSQLValue = ["completed", "failed"].contains(status) ? now : .null
            try execute("UPDATE orch_tasks SET status=?, result=COALESCE(?,result), completed_at=? WHERE id=?",
                        [.text(status), result.map(WorkspaceSQLValue.text) ?? .null, done, .text(id)])
            if ["completed", "failed", "blocked"].contains(status) {
                try execute("UPDATE orch_dispatches SET status=?, completed_at=? WHERE task_id=? AND status='dispatched'",
                            [.text(status == "failed" ? "failed" : "completed"), now, .text(id)])
            }
            if status == "completed" { try orchPromote(after: id) }
            return try orchTask(id)
        }
    }
    private func orchPromote(after completed: String) throws {
        for row in try query("SELECT id, deps FROM orch_tasks WHERE status='pending'") {
            let deps = (try? JSONDecoder().decode([String].self, from: Data((row["deps"]?.string ?? "[]").utf8))) ?? []
            guard deps.contains(completed) else { continue }
            let open = try query("SELECT COUNT(*) AS n FROM orch_tasks WHERE id IN (SELECT value FROM json_each(?)) AND status<>'completed'",
                                 [.text(row["deps"]?.string ?? "[]")]).first?["n"]?.integer ?? 1
            if open == 0 { try execute("UPDATE orch_tasks SET status='ready' WHERE id=? AND status='pending'", [row["id"]!]) }
        }
    }

    // MARK: Dispatch contexts

    func orchActiveDispatch(task: String) throws -> [String: WorkspaceSQLValue]? {
        try query("SELECT * FROM orch_dispatches WHERE task_id=? AND status='dispatched' ORDER BY rowid DESC LIMIT 1", [.text(task)]).first
    }
    func orchDispatch(_ id: String) throws -> [String: WorkspaceSQLValue] {
        try one("SELECT * FROM orch_dispatches WHERE id=?", [.text(id)], "dispatch \(id)")
    }
    /// Assigns a ready task to a terminal handle and mails it the spec (no worker is spawned in this slice).
    func orchDispatchTask(_ taskID: String, to handle: String, from creator: String?) throws -> [String: WorkspaceSQLValue] {
        try transaction {
            let task = try orchTask(taskID)
            guard task["status"]?.string == "ready" else {
                throw HostRPCError("taskNotReady", detail: "task \(taskID) is \(task["status"]?.string ?? "?")")
            }
            let failures = try query("SELECT COALESCE(MAX(failure_count),0) AS n FROM orch_dispatches WHERE task_id=?", [.text(taskID)]).first?["n"] ?? .integer(0)
            let id = Orchestration.newID("ctx"), runID = task["run_id"]!
            try execute("INSERT INTO orch_dispatches (id,run_id,task_id,assignee_handle,creator_handle,status,failure_count,created_at) VALUES (?,?,?,?,?,'dispatched',?,?)",
                        [.text(id), runID, .text(taskID), .text(handle), creator.map(WorkspaceSQLValue.text) ?? .null, failures, now])
            try execute("UPDATE orch_tasks SET status='dispatched' WHERE id=?", [.text(taskID)])
            let payload = String(decoding: try JSONEncoder().encode(["taskId": taskID, "dispatchId": id]), as: UTF8.self)
            _ = try orchInsertMessage(runID: runID.string, from: creator ?? "run:" + (runID.string ?? ""), to: handle,
                                      subject: task["task_title"]?.string ?? "Task \(taskID)", body: task["spec"]?.string ?? "",
                                      type: "dispatch", priority: "normal", threadID: nil, payload: payload)
            return try orchDispatch(id)
        }
    }
    /// Orca worker report settlement: success completes and promotes; failure reopens the task until the circuit breaks.
    private func orchSettle(dispatch dispatchID: String, task taskID: String, sender: String, outcome: String, result: String) throws {
        let ctx = try orchDispatch(dispatchID)
        guard ctx["task_id"]?.string == taskID else { throw HostRPCError("badRequest", detail: "dispatch \(dispatchID) is not for task \(taskID)") }
        guard ctx["status"]?.string == "dispatched" else { throw HostRPCError("dispatchSettled", detail: "dispatch \(dispatchID) is \(ctx["status"]?.string ?? "?")") }
        guard ctx["assignee_handle"]?.string == sender else { throw HostRPCError("consumerFenced", detail: "\(sender) is not the assignee of \(dispatchID)") }
        if outcome == "succeeded" {
            try execute("UPDATE orch_dispatches SET status='completed', completed_at=? WHERE id=?", [now, .text(dispatchID)])
            try execute("UPDATE orch_tasks SET status='completed', result=?, completed_at=? WHERE id=? AND status='dispatched'", [.text(result), now, .text(taskID)])
            try orchPromote(after: taskID)
        } else {
            let failures = (ctx["failure_count"]?.integer ?? 0) + 1
            let broken = failures >= Int64(Orchestration.circuitBreakFailures)
            try execute("UPDATE orch_dispatches SET status=?, failure_count=?, last_failure=?, completed_at=? WHERE id=?",
                        [.text(broken ? "circuit_broken" : "failed"), .integer(failures), .text(result), now, .text(dispatchID)])
            try execute("UPDATE orch_tasks SET status=?, result=?, completed_at=? WHERE id=? AND status='dispatched'",
                        [.text(broken ? "failed" : "ready"), .text(result), broken ? now : .null, .text(taskID)])
        }
    }

    // MARK: Messages

    private func orchInsertMessage(runID: String?, from: String, to: String, subject: String, body: String, type: String,
                                   priority: String, threadID: String?, payload: String?) throws -> [String: WorkspaceSQLValue] {
        let id = Orchestration.newID("msg")
        try execute("INSERT INTO orch_messages (id,run_id,from_handle,to_handle,subject,body,type,priority,thread_id,payload,created_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)", [
            .text(id), runID.map(WorkspaceSQLValue.text) ?? .null, .text(from), .text(to), .text(subject), .text(body),
            .text(type), .text(priority), threadID.map(WorkspaceSQLValue.text) ?? .null, payload.map(WorkspaceSQLValue.text) ?? .null, now])
        return try orchMessage(id)
    }
    func orchMessage(_ id: String) throws -> [String: WorkspaceSQLValue] {
        try one("SELECT * FROM orch_messages WHERE id=?", [.text(id)], "message \(id)")
    }
    /// Resolves the recipient (explicit, else the dispatch's or sender's Run mailbox), applies
    /// worker_done/heartbeat lifecycle effects, and records the message in one transaction.
    func orchSend(from: String, to explicitTo: String?, runID explicitRun: String?, subject: String, body: String,
                  type: String, priority: String, threadID: String?, payload: [String: HostJSON]) throws -> [String: WorkspaceSQLValue] {
        guard Orchestration.messageTypes.contains(type) else { throw HostRPCError("badRequest", detail: "type") }
        guard Orchestration.priorities.contains(priority) else { throw HostRPCError("badRequest", detail: "priority") }
        return try transaction {
            let dispatchID = payload["dispatchId"]?.string
            let ctx = try dispatchID.map(orchDispatch)
            var to = explicitTo
            var runID = explicitRun ?? ctx?["run_id"]?.string
            if to == nil {
                if runID == nil {
                    runID = try query("SELECT run_id FROM orch_dispatches WHERE assignee_handle=? AND status='dispatched' ORDER BY rowid DESC LIMIT 1",
                                      [.text(from)]).first?["run_id"]?.string
                }
                guard let runID else { throw HostRPCError("badRequest", detail: "pass --to or --run") }
                to = "run:" + runID
            }
            guard let to, !to.isEmpty else { throw HostRPCError("badRequest", detail: "to") }
            // shortcut: group addresses (@all, @idle, @worktree:...) need the worker roster, add with worker-start.
            guard !to.hasPrefix("@") else { throw HostRPCError("notImplemented", detail: "group addresses") }
            if to.hasPrefix("run:") { runID = try orchRun(String(to.dropFirst(4)))["id"]?.string }
            if to.hasPrefix("dispatch:") { runID = try orchDispatch(String(to.dropFirst(9)))["run_id"]?.string }
            if ["worker_done", "heartbeat"].contains(type) {
                guard let dispatchID else { throw HostRPCError("badRequest", detail: "\(type) requires --dispatch-id") }
                if type == "heartbeat" {
                    try execute("UPDATE orch_dispatches SET last_heartbeat_at=? WHERE id=? AND status='dispatched'", [now, .text(dispatchID)])
                } else {
                    guard let task = payload["taskId"]?.string else { throw HostRPCError("badRequest", detail: "worker_done requires --task-id") }
                    guard let outcome = payload["outcome"]?.string, ["succeeded", "failed"].contains(outcome) else {
                        throw HostRPCError("badRequest", detail: "worker_done requires --outcome succeeded or --outcome failed")
                    }
                    try orchSettle(dispatch: dispatchID, task: task, sender: from, outcome: outcome, result: body.isEmpty ? subject : body)
                }
            }
            let payloadText = payload.isEmpty ? nil : String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
            return try orchInsertMessage(runID: runID, from: from, to: to, subject: subject, body: body, type: type,
                                         priority: priority, threadID: threadID, payload: payloadText)
        }
    }
    /// Replies go back to the original sender in the original thread.
    func orchReply(to id: String, body: String, from: String?) throws -> [String: WorkspaceSQLValue] {
        try transaction {
            let original = try orchMessage(id)
            let subject = original["subject"]?.string ?? ""
            return try orchInsertMessage(runID: original["run_id"]?.string, from: from ?? original["to_handle"]?.string ?? "",
                                         to: original["from_handle"]?.string ?? "", subject: subject.hasPrefix("Re: ") ? subject : "Re: " + subject,
                                         body: body, type: "status", priority: "normal",
                                         threadID: original["thread_id"]?.string ?? id, payload: nil)
        }
    }
    /// The first reply in the question's thread, marked read because `ask` consumed it.
    func orchAnswer(question id: String) throws -> [String: WorkspaceSQLValue]? {
        let question = try orchMessage(id)
        guard let answer = try query("SELECT * FROM orch_messages WHERE thread_id=? AND id<>? AND to_handle=? ORDER BY sequence LIMIT 1",
                                     [.text(id), .text(id), question["from_handle"]!]).first else { return nil }
        try execute("UPDATE orch_messages SET read=1 WHERE id=?", [answer["id"]!])
        return try orchMessage(answer["id"]!.string!)
    }

    /// Mailboxes a terminal handle consumes: its own, the Runs it coordinates, and its live Dispatches.
    func orchMailboxes(handle: String) throws -> [String] {
        let runs = try query("SELECT id FROM orch_runs WHERE coordinator_handle=?", [.text(handle)]).compactMap { $0["id"]?.string }.map { "run:" + $0 }
        let ctxs = try query("SELECT id FROM orch_dispatches WHERE assignee_handle=? AND status='dispatched'", [.text(handle)])
            .compactMap { $0["id"]?.string }.map { "dispatch:" + $0 }
        return [handle] + runs + ctxs
    }
    func orchMessages(mailboxes: [String]?, unreadOnly: Bool, types: Set<String>?, limit: Int) throws -> [[String: WorkspaceSQLValue]] {
        var sql = "SELECT * FROM orch_messages WHERE 1=1", bindings: [WorkspaceSQLValue] = []
        if let mailboxes {
            let list = String(decoding: try JSONEncoder().encode(mailboxes), as: UTF8.self)
            sql += " AND to_handle IN (SELECT value FROM json_each(?))"; bindings.append(.text(list))
        }
        if unreadOnly { sql += " AND read=0" }
        if let types {
            sql += " AND type IN (SELECT value FROM json_each(?))"
            bindings.append(.text(String(decoding: try JSONEncoder().encode(types.sorted()), as: UTF8.self)))
        }
        return try query(sql + " ORDER BY sequence LIMIT ?", bindings + [.integer(Int64(limit))])
    }
    /// Orca FIFO Delivery: the oldest unread batch is replayed until acknowledged; `ack` marks it read first.
    func orchCheck(consumer: String, mailboxes: [String], ack: String?) throws -> (delivery: [String: WorkspaceSQLValue]?, messages: [[String: WorkspaceSQLValue]]) {
        try transaction {
            if let ack {
                let delivery = try one("SELECT * FROM orch_deliveries WHERE id=? AND consumer=?", [.text(ack), .text(consumer)], "delivery \(ack)")
                try execute("UPDATE orch_messages SET read=1 WHERE id IN (SELECT value FROM json_each(?))", [delivery["message_ids"]!])
                try execute("UPDATE orch_deliveries SET status='acknowledged', acknowledged_at=COALESCE(acknowledged_at,?) WHERE id=?", [now, .text(ack)])
            }
            if let open = try query("SELECT * FROM orch_deliveries WHERE consumer=? AND status='outstanding' ORDER BY rowid LIMIT 1", [.text(consumer)]).first {
                let messages = try query("SELECT * FROM orch_messages WHERE id IN (SELECT value FROM json_each(?)) ORDER BY sequence", [open["message_ids"]!])
                if messages.contains(where: { $0["read"]?.integer == 0 }) { return (open, messages) }
                try execute("UPDATE orch_deliveries SET status='acknowledged', acknowledged_at=? WHERE id=?", [now, open["id"]!])
            }
            let messages = try orchMessages(mailboxes: mailboxes, unreadOnly: true, types: nil, limit: 100)
            guard !messages.isEmpty else { return (nil, []) }
            let id = Orchestration.newID("dlv")
            let ids = String(decoding: try JSONEncoder().encode(messages.compactMap { $0["id"]?.string }), as: UTF8.self)
            try execute("INSERT INTO orch_deliveries (id,consumer,message_ids,status,created_at) VALUES (?,?,?,'outstanding',?)",
                        [.text(id), .text(consumer), .text(ids), now])
            return (try one("SELECT * FROM orch_deliveries WHERE id=?", [.text(id)], "delivery"), messages)
        }
    }
    func orchMarkRead(_ messages: [[String: WorkspaceSQLValue]]) throws {
        let ids = String(decoding: try JSONEncoder().encode(messages.compactMap { $0["id"]?.string }), as: UTF8.self)
        try execute("UPDATE orch_messages SET read=1 WHERE id IN (SELECT value FROM json_each(?))", [.text(ids)])
    }

    // MARK: Decision gates

    /// Opening a gate settles the active Dispatch and blocks the task until the gate resolves.
    func orchCreateGate(task taskID: String, question: String, options: [String]) throws -> [String: WorkspaceSQLValue] {
        try transaction {
            let task = try orchTask(taskID)
            let id = Orchestration.newID("gate")
            try execute("INSERT INTO orch_gates (id,run_id,task_id,question,options,status,created_at) VALUES (?,?,?,?,?,'pending',?)",
                        [.text(id), task["run_id"]!, .text(taskID), .text(question),
                         .text(String(decoding: try JSONEncoder().encode(options), as: UTF8.self)), now])
            try execute("UPDATE orch_dispatches SET status='completed', completed_at=? WHERE task_id=? AND status='dispatched'", [now, .text(taskID)])
            try execute("UPDATE orch_tasks SET status='blocked' WHERE id=?", [.text(taskID)])
            return try one("SELECT * FROM orch_gates WHERE id=?", [.text(id)], "gate")
        }
    }
    func orchResolveGate(_ id: String, resolution: String) throws -> [String: WorkspaceSQLValue] {
        try transaction {
            let gate = try one("SELECT * FROM orch_gates WHERE id=?", [.text(id)], "gate \(id)")
            guard gate["status"]?.string == "pending" else { throw HostRPCError("gateResolved", detail: id) }
            try execute("UPDATE orch_gates SET status='resolved', resolution=?, resolved_at=? WHERE id=?", [.text(resolution), now, .text(id)])
            try execute("UPDATE orch_tasks SET status='ready' WHERE id=?", [gate["task_id"]!])
            return try one("SELECT * FROM orch_gates WHERE id=?", [.text(id)], "gate")
        }
    }
    func orchGates(task: String?, status: String?, runID: String?) throws -> [[String: WorkspaceSQLValue]] {
        var sql = "SELECT * FROM orch_gates WHERE 1=1", bindings: [WorkspaceSQLValue] = []
        for (column, value) in [("task_id", task), ("status", status), ("run_id", runID)] {
            if let value { sql += " AND \(column)=?"; bindings.append(.text(value)) }
        }
        return try query(sql + " ORDER BY created_at, rowid", bindings)
    }

    func orchReset(tasks: Bool, messages: Bool, runs: Bool) throws {
        try transaction {
            if tasks || runs { try execute("DELETE FROM orch_gates; DELETE FROM orch_dispatches; DELETE FROM orch_tasks;") }
            if messages || runs { try execute("DELETE FROM orch_deliveries; DELETE FROM orch_messages;") }
            if runs { try execute("DELETE FROM orch_runs") }
        }
    }
}
