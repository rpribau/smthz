import Foundation
import Testing
@testable import SmthzCore

struct AgentCatalogTests {
    // Independently enumerated from tui-agent.ts: 45, despite the spec's 47.
    @Test func exactReferenceRoster() {
        let expected: Set<String> = [
            "claude", "claude-agent-teams", "codebuddy", "openclaude", "codex",
            "autohand", "opencode", "opencode2", "mimo-code", "pi", "omp", "qoder",
            "qoder-cn", "gemini", "antigravity", "aider", "goose", "amp", "kilo", "kiro",
            "crush", "aug", "cline", "codebuff", "freebuff", "command-code", "continue",
            "cursor", "droid", "kimi", "mistral-vibe", "qwen-code", "rovo", "hermes",
            "openclaw", "copilot", "grok", "devin", "ante", "trae", "muse", "zcode",
            "prime-agent", "dsh", "jcode"
        ]
        #expect(AgentID.allCases.count == 45)
        #expect(Set(AgentID.allCases.map(\.rawValue)) == expected)
        #expect(AgentCatalog.all.count == 45)
        #expect(AgentCatalog.all.allSatisfy { !$0.detectCmd.isEmpty && !$0.launchCmd.isEmpty && !$0.expectedProcess.isEmpty })
    }

    @Test func referenceDisplayNames() {
        #expect(AgentID.claude.displayName == "Claude")
        #expect(AgentID.claudeAgentTeams.displayName == "Claude Agent Teams")
        #expect(AgentID.crush.displayName == "Charm")
        #expect(AgentID.aug.displayName == "Auggie")
        #expect(AgentID.dsh.displayName == "DeepSeek Harness")
        #expect(AgentID.qoderCn.displayName == "Qoder CLI China")
        #expect(AgentID.allCases.allSatisfy { !$0.displayName.isEmpty })
    }

    @Test func claudeReferenceConfig() {
        let c = AgentID.claude.config
        #expect(c.detectCmd == "claude" && c.launchCmd == "claude" && c.expectedProcess == "claude")
        #expect(c.promptInjectionMode == .argv && c.draftPromptFlag == "--prefill")
        #expect(c.permissionArgs.auto == ["--permission-mode", "auto"])
        #expect(c.permissionArgs.bypass == ["--dangerously-skip-permissions"])
        #expect(c.trustKind == .claude && c.pasteNeedsTypedRequest)
    }

    @Test func codexReferenceConfig() {
        let c = AgentID.codex.config
        #expect(c.detectCmd == "codex" && c.launchCmd == "codex" && c.expectedProcess == "codex")
        #expect(c.promptInjectionMode == .argv && c.draftPromptFlag == nil)
        #expect(c.permissionArgs.auto == ["--approve-for-me"])
        #expect(c.permissionArgs.bypass == ["--dangerously-bypass-approvals-and-sandbox"])
        #expect(c.trustKind == .codex)
        #expect(c.draftPasteReadySignal == "codex-composer-prompt")
        #expect(c.draftPasteReadyTimeoutMs == 20_000 && c.submitRetryDelayMs == 1200)
    }

    @Test func referenceLaunchExceptions() {
        #expect(AgentID.kiro.config.launchCmd == "kiro-cli chat --tui")
        #expect(AgentID.rovo.config.launchCmd == "acli rovodev run")
        #expect(AgentID.hermes.config.launchCmd == "hermes --tui")
        #expect(AgentID.opencode2.config.launchCmd == "opencode2 --standalone")
        #expect(AgentID.dsh.config.expectedProcess == "dsh")
        #expect(AgentID.zcode.config.expectedProcess == "zcode-cli")
        #expect(AgentID.continue.config.detectCmd == "cn")
        #expect(AgentID.qwenCode.config.detectCmd == "qwen")
    }

    @Test func permissionPresetsAreArgumentArrays() {
        #expect(AgentID.continue.config.permissionArgs.bypass == ["--allow", "*"])
        #expect(AgentID.cline.config.permissionArgs.bypass == ["--auto-approve", "true"])
        #expect(AgentID.devin.config.permissionArgs.bypass == ["--permission-mode", "bypass", "--respect-workspace-trust", "false"])
        #expect(AgentID.goose.config.permissionArgs.bypassEnvironment == ["GOOSE_MODE": "auto"])
        #expect(AgentID.pi.config.permissionArgs.bypass.isEmpty)
    }

    @Test func specialPromptContracts() {
        #expect(AgentID.hermes.config.promptInjectionMode == .hermesQuery)
        #expect(AgentID.gemini.config.promptInjectionMode == .flagPromptInteractive)
        #expect(AgentID.copilot.config.promptInjectionMode == .flagInteractive)
        #expect(AgentID.opencode.config.promptInjectionMode == .flagPrompt)
        #expect(AgentID.pi.config.draftPromptEnvVar == "ORCA_PI_PREFILL")
        #expect(AgentID.omp.config.draftPromptEnvVar == "ORCA_OMP_PREFILL")
        #expect(AgentID.primeAgent.config.argvPromptSeparator == "--")
        #expect(AgentID.grok.config.argvPromptSeparator == "--")
    }

    @Test func idCodableUsesReferenceSpelling() throws {
        let data = try JSONEncoder().encode(AgentID.qwenCode)
        #expect(String(decoding: data, as: UTF8.self) == "\"qwen-code\"")
        #expect(try JSONDecoder().decode(AgentID.self, from: data) == .qwenCode)
        #expect(AgentID(rawValue: "unknown") == nil)
    }
}
