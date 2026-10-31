import Foundation

/// Exact roster from reference/orca-1.4.238/src/shared/tui-agent.ts and
/// tui-agent-display-names.ts. Those files contain 45 entries (the WP says 47).
public enum AgentID: String, CaseIterable, Codable, Sendable {
    case claude
    case claudeAgentTeams = "claude-agent-teams"
    case codebuddy
    case openclaude
    case codex
    case autohand
    case opencode
    case opencode2
    case mimoCode = "mimo-code"
    case pi
    case omp
    case qoder
    case qoderCn = "qoder-cn"
    case gemini
    case antigravity
    case aider
    case goose
    case amp
    case kilo
    case kiro
    case crush
    case aug
    case cline
    case codebuff
    case freebuff
    case commandCode = "command-code"
    case `continue`
    case cursor
    case droid
    case kimi
    case mistralVibe = "mistral-vibe"
    case qwenCode = "qwen-code"
    case rovo
    case hermes
    case openclaw
    case copilot
    case grok
    case devin
    case ante
    case trae
    case muse
    case zcode
    case primeAgent = "prime-agent"
    case dsh
    case jcode

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .claudeAgentTeams: "Claude Agent Teams"
        case .codebuddy: "CodeBuddy"
        case .openclaude: "OpenClaude"
        case .codex: "Codex"
        case .autohand: "Autohand Code"
        case .opencode: "OpenCode"
        case .opencode2: "OpenCode 2"
        case .mimoCode: "MiMo Code"
        case .pi: "Pi"
        case .omp: "OMP"
        case .qoder: "Qoder CLI"
        case .qoderCn: "Qoder CLI China"
        case .gemini: "Gemini"
        case .antigravity: "Antigravity"
        case .aider: "Aider"
        case .goose: "Goose"
        case .amp: "Amp"
        case .kilo: "Kilocode"
        case .kiro: "Kiro"
        case .crush: "Charm"
        case .aug: "Auggie"
        case .cline: "Cline"
        case .codebuff: "Codebuff"
        case .freebuff: "Freebuff"
        case .commandCode: "Command Code"
        case .`continue`: "Continue"
        case .cursor: "Cursor"
        case .droid: "Droid"
        case .kimi: "Kimi"
        case .mistralVibe: "Mistral Vibe"
        case .qwenCode: "Qwen Code"
        case .rovo: "Rovo Dev"
        case .hermes: "Hermes"
        case .openclaw: "OpenClaw"
        case .copilot: "GitHub Copilot"
        case .grok: "Grok"
        case .devin: "Devin"
        case .ante: "Ante"
        case .trae: "Trae"
        case .muse: "Muse"
        case .zcode: "ZCode"
        case .primeAgent: "Prime Agent"
        case .dsh: "DeepSeek Harness"
        case .jcode: "Jcode"
        }
    }

    public var config: AgentConfig { AgentCatalog.config(for: self) }
}

public enum AgentPromptInjectionMode: String, Codable, Sendable {
    case argv
    case flagPrompt = "flag-prompt"
    case flagPromptInteractive = "flag-prompt-interactive"
    case flagInteractive = "flag-interactive"
    case hermesQuery = "hermes-query"
    case stdinAfterStart = "stdin-after-start"
}

/// Reference trust mechanism, retained as metadata only. U-B2 forbids global
/// configuration edits; this catalog never performs trust preflight.
public enum AgentTrustKind: String, Codable, Sendable {
    case claude, cursor, copilot, codex, antigravity, qoder
    case qoderCN = "qoder-cn"
}

public struct AgentPermissionArgs: Equatable, Sendable {
    public let auto: [String]
    public let bypass: [String]
    public let bypassEnvironment: [String: String]
}

/// Launch strings are reference data, not shell programs to execute. Consumers
/// must build argv and apply permission presets only to the individual launch.
/// Sources: tui-agent-config.ts, tui-agent-config-types.ts, tui-agent-permissions.ts.
public struct AgentConfig: Equatable, Sendable {
    public let id: AgentID
    public let detectCmd: String
    public let detectCmdAliases: [String]
    public let detectRequiredCommands: [String]
    public let launchCmd: String
    public let expectedProcess: String
    public let promptInjectionMode: AgentPromptInjectionMode
    public let draftPromptFlag: String?
    public let draftPromptEnvVar: String?
    public let argvPromptSeparator: String?
    public let permissionArgs: AgentPermissionArgs
    public let trustKind: AgentTrustKind?
    public let draftPasteReadySignal: String?
    public let submitPasteReadySignal: String?
    public let draftPasteReadyTimeoutMs: Int?
    public let submitRetryDelayMs: Int?
    public let submitLineSettleMsPerLine: Int?
    public let pasteNeedsTypedRequest: Bool

    fileprivate init(
        _ id: AgentID, detectCmd: String, launchCmd: String? = nil,
        expectedProcess: String? = nil, promptInjectionMode: AgentPromptInjectionMode,
        detectCmdAliases: [String] = [], detectRequiredCommands: [String] = [],
        draftPromptFlag: String? = nil, draftPromptEnvVar: String? = nil,
        argvPromptSeparator: String? = nil, auto: [String] = [], bypass: [String] = [],
        bypassEnvironment: [String: String] = [:], trustKind: AgentTrustKind? = nil,
        draftPasteReadySignal: String? = nil, submitPasteReadySignal: String? = nil,
        draftPasteReadyTimeoutMs: Int? = nil, submitRetryDelayMs: Int? = nil,
        submitLineSettleMsPerLine: Int? = nil, pasteNeedsTypedRequest: Bool = false
    ) {
        self.id = id
        self.detectCmd = detectCmd
        self.launchCmd = launchCmd ?? detectCmd
        self.expectedProcess = expectedProcess ?? detectCmd
        self.promptInjectionMode = promptInjectionMode
        self.detectCmdAliases = detectCmdAliases
        self.detectRequiredCommands = detectRequiredCommands
        self.draftPromptFlag = draftPromptFlag
        self.draftPromptEnvVar = draftPromptEnvVar
        self.argvPromptSeparator = argvPromptSeparator
        self.permissionArgs = AgentPermissionArgs(auto: auto, bypass: bypass, bypassEnvironment: bypassEnvironment)
        self.trustKind = trustKind
        self.draftPasteReadySignal = draftPasteReadySignal
        self.submitPasteReadySignal = submitPasteReadySignal
        self.draftPasteReadyTimeoutMs = draftPasteReadyTimeoutMs
        self.submitRetryDelayMs = submitRetryDelayMs
        self.submitLineSettleMsPerLine = submitLineSettleMsPerLine
        self.pasteNeedsTypedRequest = pasteNeedsTypedRequest
    }
}

public enum AgentCatalog {
    public static let all: [AgentConfig] = AgentID.allCases.map { config(for: $0) }

    public static func config(for id: AgentID) -> AgentConfig {
        switch id {
        case .claude:
            AgentConfig(.claude, detectCmd: "claude", promptInjectionMode: .argv, draftPromptFlag: "--prefill", auto: ["--permission-mode", "auto"], bypass: ["--dangerously-skip-permissions"], trustKind: .claude, pasteNeedsTypedRequest: true)
        case .claudeAgentTeams:
            AgentConfig(.claudeAgentTeams, detectCmd: "orca", launchCmd: "orca claude-teams", expectedProcess: "claude", promptInjectionMode: .stdinAfterStart, detectCmdAliases: ["orca-dev", "orca-ide"], detectRequiredCommands: ["claude"], auto: ["--permission-mode", "auto"], bypass: ["--dangerously-skip-permissions"], trustKind: .claude, pasteNeedsTypedRequest: true)
        case .codebuddy:
            AgentConfig(.codebuddy, detectCmd: "codebuddy", promptInjectionMode: .argv, detectCmdAliases: ["cbc"], bypass: ["--dangerously-skip-permissions"])
        case .openclaude:
            AgentConfig(.openclaude, detectCmd: "openclaude", promptInjectionMode: .argv, draftPromptFlag: "--prefill", bypass: ["--dangerously-skip-permissions"])
        case .codex:
            AgentConfig(.codex, detectCmd: "codex", promptInjectionMode: .argv, auto: ["--approve-for-me"], bypass: ["--dangerously-bypass-approvals-and-sandbox"], trustKind: .codex, draftPasteReadySignal: "codex-composer-prompt", draftPasteReadyTimeoutMs: 20_000, submitRetryDelayMs: 1200)
        case .autohand:
            AgentConfig(.autohand, detectCmd: "autohand", promptInjectionMode: .stdinAfterStart, bypass: ["--unrestricted"])
        case .opencode:
            AgentConfig(.opencode, detectCmd: "opencode", promptInjectionMode: .flagPrompt, draftPasteReadySignal: "render-cursor-after-bracketed-paste", submitPasteReadySignal: "opencode-agent-row", draftPasteReadyTimeoutMs: 20_000)
        case .opencode2:
            AgentConfig(.opencode2, detectCmd: "opencode2", launchCmd: "opencode2 --standalone", promptInjectionMode: .flagPrompt, draftPasteReadySignal: "render-cursor-after-bracketed-paste", submitPasteReadySignal: "opencode-agent-row", draftPasteReadyTimeoutMs: 20_000)
        case .mimoCode:
            AgentConfig(.mimoCode, detectCmd: "mimo", promptInjectionMode: .flagPrompt, draftPasteReadySignal: "render-cursor-after-bracketed-paste")
        case .pi:
            AgentConfig(.pi, detectCmd: "pi", promptInjectionMode: .argv, draftPromptEnvVar: "ORCA_PI_PREFILL")
        case .omp:
            AgentConfig(.omp, detectCmd: "omp", promptInjectionMode: .argv, draftPromptEnvVar: "ORCA_OMP_PREFILL")
        case .qoder:
            AgentConfig(.qoder, detectCmd: "qodercli", promptInjectionMode: .flagPromptInteractive, detectCmdAliases: ["qoder"], bypass: ["--dangerously-skip-permissions"], trustKind: .qoder)
        case .qoderCn:
            AgentConfig(.qoderCn, detectCmd: "qoderclicn", promptInjectionMode: .flagPromptInteractive, detectCmdAliases: ["qodercn"], bypass: ["--dangerously-skip-permissions"], trustKind: .qoderCN)
        case .gemini:
            AgentConfig(.gemini, detectCmd: "gemini", promptInjectionMode: .flagPromptInteractive, bypass: ["--yolo"])
        case .antigravity:
            AgentConfig(.antigravity, detectCmd: "agy", promptInjectionMode: .flagPromptInteractive, bypass: ["--dangerously-skip-permissions"], trustKind: .antigravity, submitLineSettleMsPerLine: 45)
        case .aider:
            AgentConfig(.aider, detectCmd: "aider", promptInjectionMode: .stdinAfterStart, bypass: ["--yes-always"])
        case .goose:
            AgentConfig(.goose, detectCmd: "goose", promptInjectionMode: .stdinAfterStart, bypassEnvironment: ["GOOSE_MODE": "auto"])
        case .amp:
            AgentConfig(.amp, detectCmd: "amp", promptInjectionMode: .stdinAfterStart, bypass: ["--dangerously-allow-all"])
        case .kilo:
            AgentConfig(.kilo, detectCmd: "kilo", promptInjectionMode: .stdinAfterStart)
        case .kiro:
            AgentConfig(.kiro, detectCmd: "kiro-cli", launchCmd: "kiro-cli chat --tui", promptInjectionMode: .stdinAfterStart, bypass: ["--trust-all-tools"])
        case .crush:
            AgentConfig(.crush, detectCmd: "crush", promptInjectionMode: .stdinAfterStart, bypass: ["--yolo"])
        case .aug:
            AgentConfig(.aug, detectCmd: "auggie", promptInjectionMode: .stdinAfterStart)
        case .cline:
            AgentConfig(.cline, detectCmd: "cline", promptInjectionMode: .stdinAfterStart, bypass: ["--auto-approve", "true"])
        case .codebuff:
            AgentConfig(.codebuff, detectCmd: "codebuff", promptInjectionMode: .stdinAfterStart)
        case .freebuff:
            AgentConfig(.freebuff, detectCmd: "freebuff", promptInjectionMode: .stdinAfterStart)
        case .commandCode:
            AgentConfig(.commandCode, detectCmd: "command-code", launchCmd: "command-code --trust", promptInjectionMode: .argv, bypass: ["--yolo"])
        case .`continue`:
            AgentConfig(.`continue`, detectCmd: "cn", promptInjectionMode: .stdinAfterStart, bypass: ["--allow", "*"])
        case .cursor:
            AgentConfig(.cursor, detectCmd: "cursor-agent", promptInjectionMode: .argv, bypass: ["--yolo"], trustKind: .cursor)
        case .droid:
            AgentConfig(.droid, detectCmd: "droid", promptInjectionMode: .argv, bypass: ["--auto", "high"])
        case .kimi:
            AgentConfig(.kimi, detectCmd: "kimi", promptInjectionMode: .stdinAfterStart, detectCmdAliases: ["kimi-code"], bypass: ["--yolo"])
        case .mistralVibe:
            AgentConfig(.mistralVibe, detectCmd: "vibe", promptInjectionMode: .stdinAfterStart, detectCmdAliases: ["mistral-vibe"], bypass: ["--agent", "auto-approve"])
        case .qwenCode:
            AgentConfig(.qwenCode, detectCmd: "qwen", promptInjectionMode: .stdinAfterStart, bypass: ["--approval-mode", "yolo"], submitRetryDelayMs: 1200)
        case .rovo:
            AgentConfig(.rovo, detectCmd: "acli", launchCmd: "acli rovodev run", promptInjectionMode: .stdinAfterStart, bypass: ["--yolo"])
        case .hermes:
            AgentConfig(.hermes, detectCmd: "hermes", launchCmd: "hermes --tui", promptInjectionMode: .hermesQuery, bypass: ["--yolo"])
        case .openclaw:
            AgentConfig(.openclaw, detectCmd: "openclaw", promptInjectionMode: .stdinAfterStart)
        case .copilot:
            AgentConfig(.copilot, detectCmd: "copilot", promptInjectionMode: .flagInteractive, bypass: ["--yolo"], trustKind: .copilot)
        case .grok:
            AgentConfig(.grok, detectCmd: "grok", promptInjectionMode: .argv, argvPromptSeparator: "--", bypass: ["--permission-mode", "bypassPermissions"], draftPasteReadySignal: "grok-composer-prompt")
        case .devin:
            AgentConfig(.devin, detectCmd: "devin", promptInjectionMode: .stdinAfterStart, bypass: ["--permission-mode", "bypass", "--respect-workspace-trust", "false"])
        case .ante:
            AgentConfig(.ante, detectCmd: "ante", promptInjectionMode: .stdinAfterStart, bypass: ["--yolo"])
        case .trae:
            AgentConfig(.trae, detectCmd: "traecli", promptInjectionMode: .argv, argvPromptSeparator: "--", bypass: ["--yolo"])
        case .muse:
            AgentConfig(.muse, detectCmd: "muse", launchCmd: "muse --trust-workspace", promptInjectionMode: .stdinAfterStart, bypass: ["--yolo"])
        case .zcode:
            AgentConfig(.zcode, detectCmd: "zcode", expectedProcess: "zcode-cli", promptInjectionMode: .stdinAfterStart, bypass: ["--mode", "yolo"], draftPasteReadySignal: "zcode-composer-prompt")
        case .primeAgent:
            AgentConfig(.primeAgent, detectCmd: "prime-agent", promptInjectionMode: .argv, argvPromptSeparator: "--")
        case .dsh:
            AgentConfig(.dsh, detectCmd: "dsh-tui", launchCmd: "dsh-tui .", expectedProcess: "dsh", promptInjectionMode: .stdinAfterStart, detectCmdAliases: ["dst"], detectRequiredCommands: ["dsh"], draftPasteReadySignal: "dsh-composer-prompt")
        case .jcode:
            AgentConfig(.jcode, detectCmd: "jcode", launchCmd: "jcode", expectedProcess: "jcode", promptInjectionMode: .stdinAfterStart)
        }
    }
}
