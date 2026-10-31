import Foundation
import Testing
@testable import SmthzCore

/// Signals the moment a request is written, so cancellation tests need no timing sleep.
private struct CodexSilentProcess: CodexAppServerProcess {
    let output = AsyncThrowingStream<Data, Error>.makeStream()
    let written = AsyncStream<Void>.makeStream()
    func launch() -> AsyncThrowingStream<Data, Error> { output.stream }
    func write(_ data: Data) async throws { written.continuation.yield(()) }
    func stop() { output.continuation.finish(); written.continuation.finish() }
}

/// Compile a Swift fake once for overlapping fixtures, deleting it when the last owner exits.
private final class CodexFakeExecutable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static weak var cached: CodexFakeExecutable?
    let directory: URL
    let executable: URL

    static func get() throws -> CodexFakeExecutable {
        try lock.withLock {
            if let cached { return cached }
            let fake = try CodexFakeExecutable()
            cached = fake
            return fake
        }
    }

    private init() throws {
        directory = URL(fileURLWithPath: "/tmp/smthz-chat1-fake-" + UUID().uuidString)
        executable = directory.appendingPathComponent("fake-app-server")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let source = directory.appendingPathComponent("main.swift")
            try Self.script.write(to: source, atomically: true, encoding: .utf8)
            let compiler = Process()
            compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            compiler.arguments = ["swiftc", source.path, "-o", executable.path]
            try compiler.run()
            compiler.waitUntilExit()
            guard compiler.terminationStatus == 0 else { throw CodexAppServerError.invalidState }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static let script = #"""
    import Foundation
    import Darwin
    let mode = CommandLine.arguments[1]
    func raw(_ text: String) { try! FileHandle.standardOutput.write(contentsOf: Data(text.utf8)) }
    func send(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try! FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
    func reply(_ id: Any, _ result: [String: Any]) { send(["id": id, "result": result]) }
    func notify(_ method: String, _ params: [String: Any]) { send(["method": method, "params": params]) }
    func check(_ condition: Bool) { if !condition { exit(7) } }
    var initialized = false
    while let line = readLine() {
        guard !line.isEmpty else { continue }
        let r = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        let p = r["params"] as? [String: Any] ?? [:]
        let id = r["id"] ?? NSNull()
        switch r["method"] as? String {
        case "initialize":
            let info = p["clientInfo"] as? [String: String] ?? [:]
            check(info["name"] == "smthz" && info["version"] != nil)
            if mode == "hang" { continue }
            if mode == "malformed" { raw("{broken\n"); continue }
            if mode == "oversize" { raw(String(repeating: "x", count: 8 * 1024 * 1024 + 1)); continue }
            if mode == "serverError" { send(["id": id, "error": ["code": 42, "message": "fixture error"]]); continue }
            reply(id, ["userAgent": mode == "version" ? "codex/9.0.0" :
                mode == "minor" ? "codex/0.165.0" : "codex/0.164.0 (Mac OS) smthz/0.1.0"])
        case "initialized":
            initialized = true
            notify("remoteControl/status/changed", ["status": "disabled"])
        case "thread/start":
            check(initialized && p["cwd"] as? String == "/tmp" && p["approvalPolicy"] as? String == "on-request"
                && p["sandbox"] as? String == "workspace-write")
            if mode == "badResponse" { reply(id, ["unexpected": true]); continue }
            reply(id, ["thread": ["id": "thread-1", "turns": []]])
        case "thread/resume":
            check(initialized && p["threadId"] as? String == "thread-1")
            reply(id, ["thread": ["id": "thread-1", "turns": [["id": "old-turn", "items": [
                ["id": "old-user", "type": "userMessage", "content": [["type": "text", "text": "Earlier prompt"]]],
                ["id": "old-answer", "type": "agentMessage", "text": "Earlier answer"]]]]]])
        case "turn/start":
            let input = p["input"] as? [[String: Any]] ?? []
            check(initialized && p["threadId"] as? String == "thread-1" && input.first?["type"] as? String == "text"
                && input.first?["text"] as? String == "Hello")
            if mode == "exit" { exit(0) }
            if mode == "descendant" || mode == "orphanExit" {
                var child: pid_t = 0
                let args = ["/bin/sleep", "60"].map { $0.withCString { strdup($0) } }
                var argv = args + [nil]
                check(posix_spawn(&child, "/bin/sleep", nil, nil, &argv, environ) == 0)
                for arg in args { free(arg) }
                reply(id, ["turn": ["id": "turn-1"]])
                notify("item/agentMessage/delta", ["threadId": "thread-1", "turnId": "turn-1", "itemId": "child",
                    "delta": String(child)])
                if mode == "orphanExit" { exit(0) }
                continue
            }
            reply(id, ["turn": ["id": "turn-1", "status": "inProgress"]])
            notify("turn/started", ["threadId": "thread-1", "turn": ["id": "turn-1", "status": "inProgress"]])
            var delta = ["threadId": "thread-1", "turnId": "turn-1", "itemId": "answer", "delta": "Hello "]
            let encoded = String(data: try! JSONSerialization.data(withJSONObject: ["method": "item/agentMessage/delta",
                "params": delta]), encoding: .utf8)!
            raw("\n" + String(encoded.prefix(12))); raw(String(encoded.dropFirst(12)) + "\r\n")
            delta["delta"] = "world"; notify("item/agentMessage/delta", delta)
            if mode == "exitAfterDelta" { exit(23) }
            if ["approval", "fileApproval", "autoDecline"].contains(mode) {
                send(["id": mode == "fileApproval" ? 99 : "approval-1",
                    "method": mode == "fileApproval" ? "item/fileChange/requestApproval" : "item/commandExecution/requestApproval",
                    "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "tool-1", "command": "pwd",
                               "cwd": "/tmp", "reason": "fixture"]])
            } else if mode == "permissionsApproval" {
                send(["id": "permissions-1", "method": "item/permissions/requestApproval",
                    "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "tool-1", "cwd": "/tmp",
                        "permissions": ["network": ["enabled": true]]]])
            } else if mode == "unsupported" {
                send(["id": "unsupported-1", "method": "item/tool/call", "params": [:]])
            } else if mode != "interrupt" {
                notify("item/completed", ["threadId": "thread-1", "turnId": "turn-1", "item": ["id": "answer",
                    "type": "agentMessage", "text": "Hello world"]])
                notify("turn/completed", ["threadId": "thread-1", "turn": ["id": "turn-1", "status": "completed"]])
            }
        case "turn/interrupt":
            check(p["threadId"] as? String == "thread-1" && p["turnId"] as? String == "turn-1")
            reply(id, [:])
            notify("turn/completed", ["threadId": "thread-1", "turn": ["id": "turn-1", "status": "interrupted"]])
        default:
            if id as? String == "approval-1" || id as? Int == 99 {
                let result = r["result"] as? [String: String] ?? [:]
                let decision = result["decision"] ?? ""
                check(["accept", "decline"].contains(decision))
                notify("turn/completed", ["threadId": "thread-1", "turn": ["id": "turn-1", "status": decision]])
            } else if id as? String == "permissions-1" {
                let result = r["result"] as? [String: Any] ?? [:]
                let profile = result["permissions"] as? [String: Any] ?? [:]
                check(result["scope"] as? String == "turn")
                if !profile.isEmpty { check((profile["network"] as? [String: Bool])?["enabled"] == true) }
                notify("turn/completed", ["threadId": "thread-1", "turn": ["id": "turn-1",
                    "status": profile.isEmpty ? "decline" : "accept"]])
            } else if id as? String == "unsupported-1" {
                check((r["error"] as? [String: Any])?["code"] as? Int == -32601)
                notify("turn/completed", ["threadId": "thread-1", "turn": ["id": "turn-1", "status": "declined"]])
            } else { exit(8) }
        }
    }
    """#
}

/// Real stdio pipes and a fake Swift executable: no Codex invocation or paid turns.
private final class CodexFixture {
    let fake: CodexFakeExecutable
    let process: CodexStdioProcess
    let client: CodexAppServerClient
    let watchdog: Task<Void, Never>

    init(_ mode: String = "normal", timeout: Duration = .seconds(30), approvalTimeout: Duration = .seconds(30)) throws {
        fake = try CodexFakeExecutable.get()
        process = CodexStdioProcess(executable: fake.executable, arguments: [mode])
        client = CodexAppServerClient(process: process, requestTimeout: timeout, approvalTimeout: approvalTimeout)
        watchdog = Task { [client] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            await client.close()
        }
    }

    deinit { watchdog.cancel(); process.stop() }
}

@Suite("Codex app-server (fake stdio executable)")
struct CodexAppServerTests {
    @Test func handshakeAndStreamingDeltas() async throws {
        let fixture = try CodexFixture()
        defer { fixture.process.stop() }
        let client = fixture.client
        try await client.initialize()
        #expect(try await client.startThread(directory: "/tmp") == "thread-1")
        #expect(try await client.startTurn(threadID: "thread-1", text: "Hello") == "turn-1")
        var log = TranscriptLog()
        var texts: [String] = []
        for try await event in client.events {
            if case .message(let message) = event { log.apply([message]); texts.append(message.plainText) }
            if case .turnCompleted(_, _, let status) = event { #expect(status == "completed"); break }
        }
        #expect(texts == ["Hello ", "Hello world", "Hello world"])
        #expect(log.messages.count == 1)
        #expect(log.messages.first?.plainText == "Hello world")
        await client.close()
    }

    @Test(arguments: ["approval", "fileApproval", "permissionsApproval"], [CodexApprovalDecision.accept, .decline])
    func approvalRoundTrip(mode: String, decision: CodexApprovalDecision) async throws {
        let fixture = try CodexFixture(mode)
        defer { fixture.process.stop() }
        let client = fixture.client
        try await client.initialize()
        _ = try await client.startThread(directory: "/tmp")
        _ = try await client.startTurn(threadID: "thread-1", text: "Hello")
        var approved = false
        for try await event in client.events {
            if case .approval(let request) = event {
                #expect(request.kind == (mode == "approval" ? .commandExecution : mode == "fileApproval" ? .fileChange : .permissions))
                if mode == "permissionsApproval" {
                    #expect(request.permissions == ["network": .object(["enabled": .bool(true)])])
                }
                #expect(request.threadID == "thread-1")
                #expect(request.turnID == "turn-1")
                #expect(request.itemID == "tool-1")
                try await client.respond(to: request.id, decision: decision)
                approved = true
            }
            if case .turnCompleted(_, _, let status) = event { #expect(status == decision.rawValue); break }
        }
        #expect(approved)
        await client.close()
    }

    @Test func approvalTimeoutDefaultsToDecline() async throws {
        let fixture = try CodexFixture("autoDecline", approvalTimeout: .milliseconds(100))
        defer { fixture.process.stop() }
        let client = fixture.client
        try await client.initialize()
        _ = try await client.startTurn(threadID: "thread-1", text: "Hello")
        for try await event in client.events {
            if case .turnCompleted(_, _, let status) = event { #expect(status == "decline"); break }
        }
        await client.close()
    }

    @Test func interrupt() async throws {
        let fixture = try CodexFixture("interrupt")
        defer { fixture.process.stop() }
        let client = fixture.client
        try await client.initialize()
        _ = try await client.startTurn(threadID: "thread-1", text: "Hello")
        try await client.interrupt(threadID: "thread-1", turnID: "turn-1")
        for try await event in client.events {
            if case .turnCompleted(_, _, let status) = event { #expect(status == "interrupted"); break }
        }
        await client.close()
    }

    @Test func resumeRestoresTranscript() async throws {
        let fixture = try CodexFixture()
        defer { fixture.process.stop() }
        let client = fixture.client
        try await client.initialize()
        #expect(try await client.resume(threadID: "thread-1") == "thread-1")
        var messages: [TranscriptMessage] = []
        for try await event in client.events {
            if case .message(let message) = event { messages.append(message) }
            if messages.count == 2 { break }
        }
        #expect(messages.map(\.role) == [.user, .assistant])
        #expect(messages.map(\.plainText) == ["Earlier prompt", "Earlier answer"])
        await client.close()
    }

    @Test(arguments: ["version", "minor"])
    func unknownVersionRefused(mode: String) async throws {
        let fixture = try CodexFixture(mode)
        defer { fixture.process.stop() }
        do { try await fixture.client.initialize(); Issue.record("Unknown server version accepted") }
        catch CodexAppServerError.unsupportedVersion { }
        await fixture.client.close()
    }

    @Test func malformedLineFailsPendingRequest() async throws {
        let fixture = try CodexFixture("malformed")
        defer { fixture.process.stop() }
        await #expect(throws: (any Error).self) { try await fixture.client.initialize() }
        await #expect(throws: CodexAppServerError.malformedMessage) {
            _ = try await fixture.client.startTurn(threadID: "thread-1", text: "Hello")
        }
    }

    @Test func processExitMidTurn() async throws {
        let fixture = try CodexFixture("exit")
        defer { fixture.process.stop() }
        let client = fixture.client
        try await client.initialize()
        await #expect(throws: CodexAppServerError.processExited(0)) {
            _ = try await client.startTurn(threadID: "thread-1", text: "Hello")
        }
        do {
            for try await _ in client.events { }
            Issue.record("Exit must finish events with an error")
        } catch { #expect(error as? CodexAppServerError == .processExited(0)) }
    }

    @Test func unsupportedServerRequestFailsClosed() async throws {
        let fixture = try CodexFixture("unsupported")
        defer { fixture.process.stop() }
        let client = fixture.client
        try await client.initialize()
        _ = try await client.startTurn(threadID: "thread-1", text: "Hello")
        for try await event in client.events {
            if case .turnCompleted(_, _, let status) = event { #expect(status == "declined"); break }
        }
        await client.close()
    }

    @Test func serverErrorPreservesCode() async throws {
        let fixture = try CodexFixture("serverError")
        defer { fixture.process.stop() }
        await #expect(throws: CodexAppServerError.server(code: 42, message: "fixture error")) {
            try await fixture.client.initialize()
        }
    }

    @Test func requestTimeoutReapsChild() async throws {
        let fixture = try CodexFixture("hang", timeout: .milliseconds(200))
        defer { fixture.process.stop() }
        await #expect(throws: CodexAppServerError.timedOut) { try await fixture.client.initialize() }
        await fixture.client.close()
    }

    @Test func malformedResponseRejected() async throws {
        let fixture = try CodexFixture("badResponse")
        defer { fixture.process.stop() }
        try await fixture.client.initialize()
        await #expect(throws: CodexAppServerError.malformedMessage) {
            _ = try await fixture.client.startThread(directory: "/tmp")
        }
        await fixture.client.close()
    }

    @Test func oversizedLineFailsBoundedly() async throws {
        let fixture = try CodexFixture("oversize")
        defer { fixture.process.stop() }
        await #expect(throws: CodexAppServerError.overloaded) { try await fixture.client.initialize() }
    }

    @Test func lifecycleGuards() async throws {
        let fixture = try CodexFixture()
        defer { fixture.process.stop() }
        await #expect(throws: CodexAppServerError.invalidState) {
            _ = try await fixture.client.startThread(directory: "/tmp")
        }
        try await fixture.client.initialize()
        await #expect(throws: CodexAppServerError.invalidState) { try await fixture.client.initialize() }
        await #expect(throws: CodexAppServerError.invalidState) {
            try await fixture.client.respond(to: .integer(123), decision: .accept)
        }
        await fixture.client.close()
        await fixture.client.close()
        await #expect(throws: CodexAppServerError.closed) {
            _ = try await fixture.client.resume(threadID: "thread-1")
        }
    }
    @Test func finalDeltasSurviveProcessExit() async throws {
        let fixture = try CodexFixture("exitAfterDelta")
        defer { fixture.process.stop() }
        try await fixture.client.initialize()
        _ = try await fixture.client.startTurn(threadID: "thread-1", text: "Hello")
        var lastText = ""
        do {
            for try await event in fixture.client.events {
                if case .message(let message) = event { lastText = message.plainText }
            }
            Issue.record("Expected process exit")
        } catch { #expect(error as? CodexAppServerError == .processExited(23)) }
        #expect(lastText == "Hello world")
    }

    @Test func closeKillsOwnedProcessGroup() async throws {
        let fixture = try CodexFixture("descendant")
        defer { fixture.process.stop() }
        try await fixture.client.initialize()
        _ = try await fixture.client.startTurn(threadID: "thread-1", text: "Hello")
        var child: ProcessIdentity?
        for try await event in fixture.client.events {
            if case .message(let message) = event, let pid = Int32(message.plainText) {
                child = ProcessIdentity.lookup(pid: pid)
                break
            }
        }
        let identity = try #require(child)
        await fixture.client.close()
        let deadline = ContinuousClock.now + .seconds(10)
        while identity.isStillRunning(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!identity.isStillRunning())
    }

    @Test func cancellationUnblocksPendingRequest() async throws {
        let process = CodexSilentProcess()
        let client = CodexAppServerClient(process: process)
        let task = Task { try await client.initialize() }
        var writes = process.written.stream.makeAsyncIterator()
        _ = await writes.next()
        task.cancel()
        do { try await task.value; Issue.record("Cancelled initialize succeeded") }
        catch { #expect(error as? CodexAppServerError == .cancelled) }
        await client.close()
    }

    @Test func exitedLeaderCannotLeaveDescendantHoldingStdout() async throws {
        let fixture = try CodexFixture("orphanExit")
        defer { fixture.process.stop() }
        try await fixture.client.initialize()
        _ = try await fixture.client.startTurn(threadID: "thread-1", text: "Hello")
        var sawChild = false
        do {
            for try await event in fixture.client.events {
                if case .message = event { sawChild = true }
            }
            Issue.record("Expected exit despite descendant retaining stdout")
        } catch { #expect(error as? CodexAppServerError == .processExited(0)) }
        #expect(sawChild)
    }

}
