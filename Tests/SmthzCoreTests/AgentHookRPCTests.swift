import Darwin
import Foundation
import Testing
@testable import SmthzCore

private final class HookRPCBundleMarker: NSObject {}

private final class HookRPCFixture {
    let directory: URL
    let socket: String
    let service: HostService
    let server: UnixSocketServer
    let client: HostClient
    init(script: String? = nil) throws {
        directory = URL(fileURLWithPath: "/tmp/smthz-ag3bt-\(UUID().uuidString.prefix(8))")
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let agent = bin.appendingPathComponent("claude")
        let content = """
        #!/bin/sh
        if [ "$1" = --version ]; then echo fake-1.2.3; exit 0; fi
        printf '%s\\n%s\\n%s\\n' "$SMTHZ_SESSION_ID" "$SMTHZ_LAUNCH_TOKEN" "$SMTHZ_HOOK_TOKEN" > "$PWD/meta"
        \(script ?? "/bin/cat")
        """
        try Data(content.utf8).write(to: agent)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
        socket = directory.appendingPathComponent("s").path
        let journal = try EventJournal(path: directory.appendingPathComponent("journal").path)
        service = HostService(journal: journal, hostIdentity: nil, hostEnvironment: ["PATH": bin.path], agentSocketPath: socket)
        let host = service
        server = try UnixSocketServer(path: socket, handler: { host.handle($0) },
            streamHandler: { bytes, send, cancelled in host.stream(bytes, send: send, cancelled: cancelled) })
        client = try HostClient(socketPath: socket)
    }
    func launch() throws -> (SessionInfo, [String]) {
        let session = try client.launchAgent(AgentLaunchRequest(agent: .claude, cwd: directory.path))
        let file = directory.appendingPathComponent("meta")
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            if let data = try? String(contentsOf: file, encoding: .utf8) {
                let fields = data.split(separator: "\n").map(String.init)
                if fields.count == 3 { return (session, fields) }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw HostRPCError("fakeAgentDidNotStart")
    }
    func hook(_ meta: [String], event: String = "UserPromptSubmit", token: String? = nil, launch: String? = nil) throws {
        let data = try JSONSerialization.data(withJSONObject: ["hook_event_name": event,
            "source": "startup", "session_id": "provider-1", "transcript_path": "/fake/transcript.jsonl", "prompt": "hello"])
        try HostClient.sendAgentHook(socketPath: socket, sessionID: meta[0], agent: "claude",
            launchToken: launch ?? meta[1], hookToken: token ?? meta[2], source: .claude, payload: data)
    }
    var cli: URL {
        var parent = Bundle(for: HookRPCBundleMarker.self).bundleURL.deletingLastPathComponent()
        while parent.path != "/", !FileManager.default.isExecutableFile(atPath: parent.appendingPathComponent("smthz").path) {
            parent.deleteLastPathComponent()
        }
        return parent.appendingPathComponent("smthz")
    }
    func runCLI(meta: [String], token: String?, payload: Data?, holdInput: Bool = false) throws -> (Int32, String, Double) {
        let process = Process()
        process.executableURL = cli
        process.arguments = ["hook", "--agent", "claude"]
        var env = ProcessInfo.processInfo.environment
        env["SMTHZ_SOCKET"] = socket; env["SMTHZ_SESSION_ID"] = meta[0]
        env["SMTHZ_AGENT_ID"] = "claude"; env["SMTHZ_LAUNCH_TOKEN"] = meta[1]
        env["SMTHZ_HOOK_TOKEN"] = token
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        let start = ProcessInfo.processInfo.systemUptime
        try process.run()
        if let payload { try input.fileHandleForWriting.write(contentsOf: payload) }
        if !holdInput { try input.fileHandleForWriting.close() }
        process.waitUntilExit()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        if holdInput { try input.fileHandleForWriting.close() }
        return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), elapsed)
    }
    deinit {
        client.disconnect(); service.stop(); server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite(.serialized)
struct AgentHookRPCTests {
    @Test func hookUpdatesStatusAndMetadataWithin200ms() throws {
        let f = try HookRPCFixture(); let (session, meta) = try f.launch()
        let start = ProcessInfo.processInfo.systemUptime
        try f.hook(meta, event: "SessionStart")
        let row = try #require(f.client.agentStatuses().first)
        #expect(ProcessInfo.processInfo.systemUptime - start < 0.2)
        #expect(row.sessionID == session.id && row.state == "idle" && row.source == .hook)
        #expect(row.providerSessionID == "provider-1" && row.transcriptPath == "/fake/transcript.jsonl")
        try f.hook(meta)
        #expect(try f.client.agentStatuses().first?.state == "working")
    }

    @Test func wrongMissingAndCrossLaunchCredentialsRejected() throws {
        let f = try HookRPCFixture(); let (_, meta) = try f.launch()
        for token in ["", "wrong"] {
            #expect(throws: HostClientError.hostError(code: "unauthorized")) { try f.hook(meta, token: token) }
        }
        #expect(throws: HostClientError.hostError(code: "unauthorized")) { try f.hook(meta, launch: "another-launch") }
        #expect(try f.client.agentStatuses().isEmpty)
        let socket = try UnixSocketClient(path: f.socket); defer { socket.close() }
        let request = RPCEnvelope(version: RPCEnvelope.currentVersion, requestID: UUID().uuidString,
            method: "agent.status.list", payload: Data("{}".utf8), authorization: meta[2])
        let reply = try JSONDecoder().decode(RPCEnvelope.self, from: socket.request(JSONEncoder().encode(request)))
        #expect(String(decoding: reply.payload, as: UTF8.self).contains("unauthorized"))
    }

    @Test func exitedSessionHookScopeIsRejected() throws {
        let f = try HookRPCFixture(); let (session, meta) = try f.launch()
        try f.client.close(id: session.id)
        #expect(throws: HostClientError.hostError(code: "unauthorized")) { try f.hook(meta) }
    }

    @Test func hookCLIAlwaysEmitsJSONObjectAndExitsZero() throws {
        let f = try HookRPCFixture(); let (_, meta) = try f.launch()
        let data = Data(#"{"hook_event_name":"UserPromptSubmit","prompt":"from cli"}"#.utf8)
        for token in [Optional(meta[2]), Optional("wrong"), nil] {
            let result = try f.runCLI(meta: meta, token: token, payload: data)
            #expect(result.0 == 0 && result.1 == "{}\n" && result.2 < 1.5)
        }
        #expect(try f.client.agentStatuses().first?.prompt == "from cli")
        let malformed = try f.runCLI(meta: meta, token: meta[2], payload: Data("oops".utf8))
        #expect(malformed.0 == 0 && malformed.1 == "{}\n")
    }

    @Test func hookCLIAbandonsUnclosedStdinBeforeDeadline() throws {
        let f = try HookRPCFixture(); let (_, meta) = try f.launch()
        let result = try f.runCLI(meta: meta, token: meta[2], payload: nil, holdInput: true)
        #expect(result.0 == 0 && result.1 == "{}\n" && result.2 < 1.5)
    }

    @Test func programStatusUpdatesWithoutAttachedAppAndReplayDoesNotReply() throws {
        let replyCount = ProgramStatusProtocol.queryReplyBytes.count
        let f = try HookRPCFixture(script: """
        /bin/stty raw -echo
        printf '\\033]7501;state=working:app=fake\\007'
        printf '\\033]7501;?\\007'
        /bin/dd bs=1 count=\(replyCount) of=reply 2>/dev/null
        /bin/dd bs=1 count=1 of=extra 2>/dev/null
        /bin/cat
        """)
        let (session, _) = try f.launch()
        let deadline = Date(timeIntervalSinceNow: 5)
        let replyFile = f.directory.appendingPathComponent("reply")
        while (try? Data(contentsOf: replyFile).count) != replyCount && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(try Data(contentsOf: replyFile) == Data(ProgramStatusProtocol.queryReplyBytes))
        #expect(try f.client.agentStatuses().first?.state == "working")
        for _ in 0..<3 { _ = try f.client.replay(id: session.id) }
        Thread.sleep(forTimeInterval: 0.1)
        #expect((try? Data(contentsOf: f.directory.appendingPathComponent("extra")).count) == 0)
    }

    @Test func statusSubscriptionDeliversChangeAfterInitialSnapshot() async throws {
        let f = try HookRPCFixture(); let (session, meta) = try f.launch()
        let stream = f.client.subscribeAgentStatuses()
        let consumer = Task { () throws -> [HostAgentStatusRow] in
            var iterator = stream.makeAsyncIterator()
            let initial = try await iterator.next()
            #expect(initial?.isEmpty == true)
            try f.hook(meta)
            guard let rows = try await iterator.next() else { throw HostRPCError("streamEnded") }
            return rows
        }
        defer { consumer.cancel() }
        let timeout = Task { try await Task.sleep(for: .seconds(5)); consumer.cancel() }
        defer { timeout.cancel() }
        let rows = try await consumer.value
        #expect(rows.first?.sessionID == session.id)
        #expect(rows.first?.state == "working")
    }

    @Test func largeToolPayloadIsBoundedBeforeFramedRPC() throws {
        let f = try HookRPCFixture(); let (_, meta) = try f.launch()
        let data = try JSONSerialization.data(withJSONObject: ["hook_event_name": "PreToolUse",
            "tool_name": "Bash", "tool_input": ["command": String(repeating: "x", count: 900_000)]])
        try HostClient.sendAgentHook(socketPath: f.socket, sessionID: meta[0], agent: "claude",
            launchToken: meta[1], hookToken: meta[2], source: .claude, payload: data)
        let row = try #require(f.client.agentStatuses().first)
        #expect(row.toolName == "Bash" && row.toolInputPreview?.count == AgentHookPayload.maxToolInputLength)
    }

    @Test func malformedHookDoesNotCreateStatus() throws {
        let f = try HookRPCFixture(); let (_, meta) = try f.launch()
        #expect(throws: HostClientError.hostError(code: "badRequest")) {
            try HostClient.sendAgentHook(socketPath: f.socket, sessionID: meta[0], agent: "claude",
                launchToken: meta[1], hookToken: meta[2], source: .claude, payload: Data("{}".utf8))
        }
        #expect(try f.client.agentStatuses().isEmpty)
    }
}
