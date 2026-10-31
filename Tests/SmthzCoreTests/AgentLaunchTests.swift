import Darwin
import Foundation
import Testing
@testable import SmthzCore

private final class AgentLaunchFixture {
    let directory: URL
    let journal: EventJournal
    let service: HostService
    let server: UnixSocketServer
    let client: HostClient
    let bin: URL
    init() throws {
        directory = URL(fileURLWithPath: "/tmp/smthz-ag2-t-\(UUID().uuidString.prefix(8))")
        bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then printf 'fake-agent 1.2.3\\n'; exit 0; fi
        /bin/stty -echo -icanon min 1 time 0
        printf 'ARG:%s\\n' "$@"
        printf 'META:%s|%s|%s|%s|%s\\n' "$SMTHZ_SESSION_ID" "$SMTHZ_SOCKET" "$SMTHZ_AGENT_ID" "$SMTHZ_LAUNCH_TOKEN" "$SMTHZ_HOOK_TOKEN"
        printf 'READY\\n'
        /bin/cat
        """
        for id in ["claude", "codex", "aider", "openclaude"] {
            let file = bin.appendingPathComponent(id)
            try Data(script.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        journal = try EventJournal(path: directory.appendingPathComponent("journal").path)
        let socket = directory.appendingPathComponent("s").path
        service = HostService(journal: journal, hostIdentity: nil, hostEnvironment: ["PATH": bin.path], agentSocketPath: socket)
        let host = service
        server = try UnixSocketServer(path: socket) { host.handle($0) }
        client = try HostClient(socketPath: socket)
    }
    func request(_ agent: AgentID = .claude, prompt: String? = nil, mode: AgentLaunchMode = .submit) -> AgentLaunchRequest {
        AgentLaunchRequest(agent: agent, cwd: directory.path, prompt: prompt, mode: mode)
    }
    func output(_ id: String, contains text: String) throws -> String {
        let deadline = Date(timeIntervalSinceNow: 10)
        var result = ""
        repeat {
            result = String(decoding: try client.read(id: id).data, as: UTF8.self)
            if result.contains(text) { return result }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        Issue.record("Fake agent did not produce expected marker: \(text)")
        return result
    }
    deinit {
        client.disconnect(); service.stop(); server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite(.serialized)
struct AgentLaunchTests {
    @Test func draftClaudeGetsPrefillAndPrivateSettings() throws {
        let f = try AgentLaunchFixture()
        let info = try f.client.launchAgent(f.request(prompt: "hi", mode: .draft))
        #expect(info.arguments?.prefix(2) == ["--prefill", "hi"])
        let args = try #require(info.arguments)
        let index = try #require(args.firstIndex(of: "--settings"))
        let file = args[index + 1]
        #expect(file.hasPrefix(f.directory.path + "/hooks/claude-"))
        let attributes = try FileManager.default.attributesOfItem(atPath: file)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as? [String: Any]
        #expect((document?["hooks"] as? [String: Any])?.count == 13)
        #expect(try f.output(info.id, contains: "READY").contains("ARG:hi"))
    }

    @Test func argvPromptStaysOneLiteralArgument() throws {
        let f = try AgentLaunchFixture()
        let prompt = "hello ' $(touch never)\nnext"
        let info = try f.client.launchAgent(f.request(.codex, prompt: prompt))
        #expect(info.arguments == [prompt])
        #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("never").path))
    }

    @Test func childReceivesScopedEnvironmentAndCustomSocket() throws {
        let f = try AgentLaunchFixture()
        let info = try f.client.launchAgent(f.request())
        let output = try f.output(info.id, contains: "READY")
        let line = try #require(output.components(separatedBy: "\n").first { $0.hasPrefix("META:") })
        let parts = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
        #expect(parts.count == 5)
        #expect(parts[0] == info.id)
        #expect(parts[1] == f.directory.appendingPathComponent("s").path)
        #expect(parts[2] == "claude")
        let scope = try #require(f.service.agentLaunch.scope(sessionID: info.id, hookToken: parts[4]))
        #expect(scope.launchToken == parts[3])
        #expect(scope.agent == .claude)
        #expect(parts[4] != (try HostCapabilityToken.load(path: f.service.capabilityTokenPath)))
        #expect(f.service.agentLaunch.scope(sessionID: info.id, hookToken: "wrong") == nil)
        try f.client.close(id: info.id)
        #expect(f.service.agentLaunch.scope(sessionID: info.id, hookToken: parts[4]) == nil)
    }

    @Test func stdinPromptWaitsForQuietAndSubmits() throws {
        let f = try AgentLaunchFixture()
        let start = ProcessInfo.processInfo.systemUptime
        let info = try f.client.launchAgent(f.request(.aider, prompt: "quiet marker"))
        #expect(ProcessInfo.processInfo.systemUptime - start >= 0.5)
        #expect(info.arguments == [])
        let output = try f.output(info.id, contains: "quiet marker")
        #expect(output.contains("\u{1b}[200~quiet marker\u{1b}[201~"))
    }

    @Test func draftFallbackPastesWithoutSubmitting() throws {
        let f = try AgentLaunchFixture()
        let info = try f.client.launchAgent(f.request(.codex, prompt: "draft marker", mode: .draft))
        #expect(info.arguments == [])
        let output = try f.output(info.id, contains: "\u{1b}[201~")
        #expect(output.hasSuffix("\u{1b}[200~draft marker\u{1b}[201~"))
    }

    @Test func launchRetryOnNewConnectionReplaysOneSession() throws {
        let f = try AgentLaunchFixture()
        let id = RequestID.generate().rawValue
        let request = f.request(prompt: "hello", mode: .draft)
        let first = try f.client.launchAgent(request, requestID: id)
        let retry = try HostClient(socketPath: f.directory.appendingPathComponent("s").path)
        defer { retry.disconnect() }
        #expect(try retry.launchAgent(request, requestID: id) == first)
        #expect(try retry.list().sessions.count == 1)
        var changed = request; changed.prompt = "different"
        #expect(throws: HostClientError.detailedHostError(code: "idempotencyConflict", detail: nil)) {
            try retry.launchAgent(changed, requestID: id)
        }
    }

    @Test func detectedListIsReadAndLeavesJournalEmpty() throws {
        let f = try AgentLaunchFixture()
        let found = try f.client.listAgents()
        #expect(Set(found.map(\.id)) == Set([.claude, .codex, .aider, .openclaude]))
        #expect(found.allSatisfy { $0.version == "1.2.3" && $0.executable.hasPrefix(f.bin.path) })
        #expect(try f.journal.read(after: 0, limit: 100).isEmpty)
        #expect(f.service.router.route("agent.list")?.methodClass == .read)
        #expect(f.service.router.route("agent.launch")?.methodClass == .mutation)
    }

    @Test func launchPermissionsArePerLaunch() throws {
        let f = try AgentLaunchFixture()
        var request = f.request()
        request.permission = .auto
        #expect(try f.client.launchAgent(request).arguments?.prefix(2) == ["--permission-mode", "auto"])
        request.permission = .bypass
        #expect(try f.client.launchAgent(request).arguments?.first == "--dangerously-skip-permissions")
        #expect(try f.client.launchAgent(f.request()).arguments?.first == "--settings")
        #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent(".claude").path))
    }

    @Test func duplicateSessionIDIsRejectedBeforeSpawning() throws {
        let f = try AgentLaunchFixture()
        let id = RequestID.generate().rawValue
        let manager = f.service.sessionManager
        let info = try manager.create(executable: "/bin/cat", arguments: [], id: id)
        #expect(info.id == id)
        #expect(throws: SessionError.badRequest) { try manager.create(executable: "/bin/cat", arguments: [], id: id) }
        #expect(manager.list().count == 1)
        for invalid in ["bad", UUID().uuidString.uppercased(), "../../escape"] {
            #expect(throws: SessionError.badRequest) { try manager.create(executable: "/bin/cat", arguments: [], id: invalid) }
        }
    }

    @Test func unknownAgentMissingExecutableAndAccountsFailClosed() throws {
        let f = try AgentLaunchFixture()
        #expect(throws: HostClientError.detailedHostError(code: "agentNotInstalled", detail: "jcode")) {
            try f.client.launchAgent(f.request(.jcode))
        }
        var request = f.request(); request.accountId = "some-account"
        #expect(throws: HostClientError.detailedHostError(code: "unsupportedAccount", detail: "Account selection is not implemented")) {
            try f.client.launchAgent(request)
        }
        #expect(try f.client.list().sessions.isEmpty)
    }

    @Test func invalidDirectoryAndNulArgumentsNeverSpawn() throws {
        let f = try AgentLaunchFixture()
        for cwd in ["relative", f.directory.appendingPathComponent("absent").path] {
            var request = f.request(); request.cwd = cwd
            #expect(throws: HostRPCError("badRequest")) { try AgentLaunchPlan.build(request, environment: ["PATH": f.bin.path]) }
        }
        var request = f.request(); request.extraArgs = ["a\0b"]
        #expect(throws: HostRPCError("badRequest")) { try AgentLaunchPlan.build(request, environment: ["PATH": f.bin.path]) }
    }

    @Test func promptModeFlagsAndSeparatorsMatchCatalog() throws {
        let f = try AgentLaunchFixture()
        for (id, executable, expected) in [(AgentID.opencode, "opencode", ["--prompt", "hi"]),
            (.gemini, "gemini", ["--prompt-interactive", "hi"]), (.copilot, "copilot", ["-i", "hi"]),
            (.grok, "grok", ["--", "hi"]), (.hermes, "hermes", ["chat", "--query=hi", "--tui"])] {
            try FileManager.default.createSymbolicLink(atPath: f.bin.appendingPathComponent(executable).path, withDestinationPath: "/bin/cat")
            let plan = try AgentLaunchPlan.build(f.request(id, prompt: "hi"), environment: ["PATH": f.bin.path])
            #expect(plan.arguments == expected)
            #expect(plan.deferredPrompt == nil)
        }
    }

    @Test func nativeDraftEnvironmentAndBypassEnvironmentAreScoped() throws {
        let f = try AgentLaunchFixture()
        for name in ["pi", "goose"] {
            try FileManager.default.createSymbolicLink(atPath: f.bin.appendingPathComponent(name).path, withDestinationPath: "/bin/cat")
        }
        let draft = try AgentLaunchPlan.build(f.request(.pi, prompt: "draft", mode: .draft), environment: ["PATH": f.bin.path])
        #expect(draft.environment["ORCA_PI_PREFILL"] == "draft")
        #expect(draft.arguments.isEmpty)
        var request = f.request(.goose); request.permission = .bypass
        #expect(try AgentLaunchPlan.build(request, environment: ["PATH": f.bin.path]).environment["GOOSE_MODE"] == "auto")
    }

    @Test func cancelledQuietWaitClosesItsSession() throws {
        final class Cancellation: @unchecked Sendable {
            let lock = NSLock(); var checks = 0
            func check() throws { try lock.withLock { checks += 1; if checks >= 5 { throw HostRPCError("cancelled") } } }
        }
        let f = try AgentLaunchFixture()
        let cancellation = Cancellation()
        #expect(throws: HostRPCError("cancelled")) {
            try f.service.agentLaunch.launch(f.request(.aider, prompt: "never delivered"), checkCancellation: { try cancellation.check() })
        }
        #expect(f.service.sessionManager.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("hooks").path))
    }
}
