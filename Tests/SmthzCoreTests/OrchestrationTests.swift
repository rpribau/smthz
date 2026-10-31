import Foundation
import Testing
@testable import SmthzCore

private final class OrchFixture: @unchecked Sendable {
    let core: HostCoreFixture
    let store: WorkspaceStore
    init() throws {
        core = try HostCoreFixture()
        store = try WorkspaceStore(path: core.directory.appendingPathComponent("workspace.sqlite").path)
        OrchestrationRPC.register(on: core.router, store: store)
    }
    func call(_ verb: String, _ params: [String: HostJSON] = [:], id: String = UUID().uuidString, timeout: Int? = nil) throws -> [String: HostJSON] {
        try core.call("orchestration." + verb, params, id: id, timeout: timeout)
    }
    func ok(_ verb: String, _ params: [String: HostJSON] = [:]) throws -> [String: HostJSON] {
        let result = try call(verb, params)
        try #require(result["ok"] == .bool(true), "\(verb) failed: \(result)")
        return result
    }
    func id(_ result: [String: HostJSON], _ key: String) throws -> String { try #require(result[key]?.object?["id"]?.string) }
    func status(_ task: String) throws -> String? { try store.orchTask(task)["status"]?.string }
}

struct OrchestrationTests {
    @Test func v1StoreMigratesToV2AndKeepsRows() throws {
        let f = try HostCoreFixture(), path = f.directory.appendingPathComponent("w").path
        do {
            let store = try WorkspaceStore(path: path)
            for table in ["orch_gates", "orch_deliveries", "orch_messages", "orch_dispatches", "orch_tasks", "orch_runs"] {
                try store.execute("DROP TABLE \(table)")
            }
            try store.execute("PRAGMA user_version=1")
            try store.execute("INSERT INTO host_settings VALUES ('k','true',1)")
        }
        let store = try WorkspaceStore(path: path)
        #expect(try store.query("PRAGMA user_version").first?["user_version"] == .integer(2))
        #expect(try store.query("SELECT value_json FROM host_settings").first?["value_json"] == .text("true"))
        #expect(try store.query("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'orch_%'").count == 6)
        _ = try store.orchCreateRun(objective: "o", coordinator: nil)
    }

    @Test func dagReadinessPromotionAndRetry() throws {
        let f = try OrchFixture()
        let run = try f.id(try f.ok("run-create", ["objective": .string("ship"), "from": .string("coord")]), "run")
        let a = try f.id(try f.ok("task-create", ["spec": .string("A"), "from": .string("coord")]), "task")
        let b = try f.id(try f.ok("task-create", ["spec": .string("B"), "run": .string(run), "deps": .string("[\"\(a)\"]")]), "task")
        #expect(try f.status(a) == "ready")
        #expect(try f.status(b) == "pending")
        #expect(try f.call("dispatch", ["task": .string(b), "to": .string("w1")])["error"] == .string("taskNotReady"))
        #expect(try f.call("task-create", ["spec": .string("C"), "run": .string(run), "deps": .string("[\"task_missing\"]")])["error"] == .string("notFound"))
        let ready = try f.ok("task-list", ["run": .string(run), "ready": .bool(true)])["tasks"]
        #expect(ready == .array([try #require(Orchestration.json(try f.store.orchTask(a)) as HostJSON?)]))

        // Two failed attempts reopen the task; worker_done must come from the assignee.
        for attempt in 1...2 {
            let ctx = try f.id(try f.ok("dispatch", ["task": .string(a), "to": .string("w1"), "from": .string("coord")]), "dispatch")
            #expect(try f.status(a) == "dispatched")
            #expect(try f.call("send", ["from": .string("intruder"), "subject": .string("x"), "type": .string("worker_done"),
                                        "taskId": .string(a), "dispatchId": .string(ctx), "outcome": .string("succeeded")])["error"] == .string("consumerFenced"))
            _ = try f.ok("send", ["from": .string("w1"), "subject": .string("nope"), "type": .string("worker_done"),
                                  "taskId": .string(a), "dispatchId": .string(ctx), "outcome": .string("failed")])
            #expect(try f.status(a) == "ready")
            #expect(try f.store.orchDispatch(ctx)["failure_count"] == .integer(Int64(attempt)))
        }
        let ctx = try f.id(try f.ok("dispatch", ["task": .string(a), "to": .string("w1")]), "dispatch")
        let done = try f.ok("send", ["from": .string("w1"), "subject": .string("done"), "type": .string("worker_done"),
                                     "taskId": .string(a), "dispatchId": .string(ctx), "outcome": .string("succeeded")])
        #expect(done["message"]?.object?["toHandle"] == .string("run:" + run))
        #expect(try f.status(a) == "completed")
        #expect(try f.status(b) == "ready")
        #expect(try f.call("send", ["from": .string("w1"), "subject": .string("again"), "type": .string("worker_done"),
                                    "taskId": .string(a), "dispatchId": .string(ctx), "outcome": .string("succeeded")])["error"] == .string("dispatchSettled"))

        // Third failure breaks the circuit and fails the task.
        let c = try f.id(try f.ok("task-create", ["spec": .string("C"), "run": .string(run)]), "task")
        for _ in 1...3 {
            let ctx = try f.id(try f.ok("dispatch", ["task": .string(c), "to": .string("w2")]), "dispatch")
            _ = try f.ok("send", ["from": .string("w2"), "subject": .string("x"), "type": .string("worker_done"),
                                  "taskId": .string(c), "dispatchId": .string(ctx), "outcome": .string("failed")])
        }
        #expect(try f.status(c) == "failed")
    }

    @Test func gatesBlockAndReopenTasks() throws {
        let f = try OrchFixture()
        let run = try f.id(try f.ok("run-create", ["objective": .string("o")]), "run")
        let t = try f.id(try f.ok("task-create", ["spec": .string("T"), "run": .string(run)]), "task")
        let gate = try f.id(try f.ok("gate-create", ["task": .string(t), "question": .string("Which?"), "options": .string("[\"a\",\"b\"]")]), "gate")
        #expect(try f.status(t) == "blocked")
        #expect(try f.ok("gate-list", ["status": .string("pending")])["gates"] == .array([Orchestration.json(try f.store.orchGates(task: t, status: nil, runID: nil)[0])]))
        #expect(try f.store.orchGates(task: t, status: nil, runID: nil).first?["id"] == .text(gate))
        _ = try f.ok("gate-resolve", ["id": .string(gate), "resolution": .string("a")])
        #expect(try f.status(t) == "ready")
        #expect(try f.call("gate-resolve", ["id": .string(gate), "resolution": .string("b")])["error"] == .string("gateResolved"))
        _ = try f.ok("task-update", ["id": .string(t), "status": .string("completed"), "result": .string("ok")])
        #expect(try f.store.orchTask(t)["result"] == .text("ok"))
    }

    @Test func checkReplaysBatchUntilAck() throws {
        let f = try OrchFixture()
        let run = try f.id(try f.ok("run-create", ["objective": .string("o"), "from": .string("coord")]), "run")
        for n in 1...2 { _ = try f.ok("send", ["from": .string("w1"), "to": .string("run:" + run), "subject": .string("s\(n)")]) }
        let first = try f.ok("check", ["terminal": .string("coord")])
        #expect(first["count"] == .number(2))
        let delivery = try #require(first["deliveryId"]?.string)
        _ = try f.ok("send", ["from": .string("w1"), "to": .string("coord"), "subject": .string("s3")])
        let replay = try f.ok("check", ["terminal": .string("coord")])
        #expect(replay["deliveryId"] == .string(delivery))
        #expect(replay["count"] == .number(2))
        #expect(try f.ok("check", ["terminal": .string("coord"), "peek": .bool(true)])["count"] == .number(3))
        let next = try f.ok("check", ["terminal": .string("coord"), "ack": .string(delivery)])
        #expect(next["count"] == .number(1))
        #expect(next["deliveryId"] != .string(delivery))
        let ack2 = try #require(next["deliveryId"]?.string)
        #expect(try f.ok("check", ["terminal": .string("coord"), "ack": .string(ack2)])["count"] == .number(0))
        #expect(try f.call("check", ["terminal": .string("other"), "ack": .string(ack2)])["error"] == .string("notFound"))
        #expect(try f.ok("check", ["terminal": .string("coord"), "all": .bool(true)])["count"] == .number(3))
        #expect(try f.ok("wait", ["terminal": .string("coord"), "timeoutMs": .string("100")])["timedOut"] == .bool(true))
    }

    @Test func askBlocksUntilReplyOrTimeout() async throws {
        let f = try OrchFixture()
        let run = try f.id(try f.ok("run-create", ["objective": .string("o"), "from": .string("coord")]), "run")
        let task = try f.id(try f.ok("task-create", ["spec": .string("T"), "run": .string(run)]), "task")
        _ = try f.ok("dispatch", ["task": .string(task), "to": .string("w1")])
        // From an active Dispatch, a question defaults to the owning Run mailbox.
        let question = try f.ok("ask", ["from": .string("w1"), "question": .string("Proceed?")])
        #expect(question["message"]?.object?["toHandle"] == .string("run:" + run))
        let qid = try f.id(question, "message")
        let pending = try f.ok("ask-wait", ["id": .string(qid), "timeoutMs": .string("150")])
        #expect(pending["status"] == .string("pending"))

        let waiter = Task.detached { try f.ok("ask-wait", ["id": .string(qid), "timeoutMs": .string("10000")]) }
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try f.ok("reply", ["id": .string(qid), "body": .string("yes"), "from": .string("coord")])
        let answered = try await waiter.value
        #expect(answered["status"] == .string("answered"))
        #expect(answered["answer"]?.object?["body"] == .string("yes"))
        #expect(answered["answer"]?.object?["threadId"] == .string(qid))
        // The reply was consumed by ask, so it is not delivered again to the worker.
        #expect(try f.ok("check", ["terminal": .string("w1"), "peek": .bool(true), "types": .string("status")])["count"] == .number(0))
    }

    @Test func mutationsReplayByRequestID() throws {
        let f = try OrchFixture()
        let params: [String: HostJSON] = ["objective": .string("once")]
        let id = UUID().uuidString.lowercased()
        let first = try f.call("run-create", params, id: id), second = try f.call("run-create", params, id: id)
        #expect(first == second)
        #expect(try f.store.query("SELECT * FROM orch_runs").count == 1)
        #expect(try f.call("run-create", ["objective": .string("other")], id: id)["error"] == .string("idempotencyConflict"))
        _ = try f.ok("reset", ["all": .bool(true)])
        #expect(try f.store.query("SELECT * FROM orch_runs").isEmpty)
    }

    @Test func cliParsesOrcaFlags() throws {
        let send = try OrchestrationCLIRequest(["send", "--from", "h", "--type", "worker_done", "--subject", "s", "--task-id", "t",
                                                "--dispatch-id", "d", "--outcome", "succeeded", "--retry-request", "r1", "--json"])
        #expect(send.method == "orchestration.send")
        #expect(send.params == ["from": .string("h"), "type": .string("worker_done"), "subject": .string("s"), "taskId": .string("t"),
                                "dispatchId": .string("d"), "outcome": .string("succeeded")])
        #expect(send.retryRequest == "r1")
        #expect(send.json)
        let check = try OrchestrationCLIRequest(["check", "--terminal", "h", "--wait", "--types", "worker_done,question", "--timeout-ms", "5"])
        #expect(check.params == ["terminal": .string("h"), "wait": .bool(true), "types": .string("worker_done,question"), "timeoutMs": .string("5")])
        #expect(try OrchestrationCLIRequest(["task-list", "--ready", "--socket", "/tmp/s"]).socket == "/tmp/s")
        #expect(throws: HostRPCError.self) { try OrchestrationCLIRequest(["send", "--bogus", "x"]) }
        #expect(throws: HostRPCError.self) { try OrchestrationCLIRequest(["send", "--subject"]) }
        #expect(throws: HostRPCError.self) { try OrchestrationCLIRequest(["send", "--subject", "s", "--outcome", "maybe"]) }
        #expect(throws: HostRPCError.self) { try OrchestrationCLIRequest(["ask", "--question", "q", "--resume", "m"]) }
        #expect(throws: HostRPCError("notImplemented", detail: "orchestration worker-start")) { try OrchestrationCLIRequest(["worker-start"]) }
    }
}
