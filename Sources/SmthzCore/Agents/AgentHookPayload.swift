import Foundation

// Decoding of the JSON a Claude or Codex hook writes on stdin, and the status each event implies.
// Event names: Orca `src/main/claude/claude-managed-hook-events.ts` and
// `src/main/codex/codex-hook-definition.ts`; state rules: `src/shared/agent-hook-listener/providers/
// claude-events.ts` and `codex-state.ts` (reference 1.4.238).

/// The agent family whose hook produced a payload. Kept separate from the agent roster so the status
/// core does not depend on the catalog.
public enum AgentHookSource: String, Codable, Sendable, CaseIterable {
    case claude, codex
}

public enum AgentHookEvent: String, Codable, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case teammateIdle = "TeammateIdle"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case permissionRequest = "PermissionRequest"
    case postCompact = "PostCompact"
    case sessionEnd = "SessionEnd"
    /// Codex 0.150+: the only hook an Esc-cancelled turn fires.
    case interrupt = "Interrupt"

    /// The 13 events smthz registers for Claude (`CLAUDE_MANAGED_EVENTS`).
    public static let claudeEvents: [AgentHookEvent] = [
        .sessionStart, .userPromptSubmit, .stop, .stopFailure, .subagentStart, .subagentStop,
        .teammateIdle, .preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest,
        .postCompact, .sessionEnd,
    ]

    /// The 9 events Orca registers for Codex (`CODEX_EVENTS`).
    public static let codexEvents: [AgentHookEvent] = [
        .sessionStart, .userPromptSubmit, .preToolUse, .permissionRequest, .postToolUse,
        .subagentStart, .subagentStop, .stop, .interrupt,
    ]

    public static func events(for source: AgentHookSource) -> [AgentHookEvent] {
        source == .claude ? claudeEvents : codexEvents
    }

    /// Events that carry a tool and are registered with matcher `*`.
    public var isToolEvent: Bool {
        [.preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest].contains(self)
    }
}

public enum AgentHookPayloadError: Error, Equatable, Sendable {
    case tooLarge(Int)
    case notJSONObject
    case missingEventName
}

public struct AgentHookPayload: Equatable, Sendable {
    /// Stdin cap for one payload (BROWSER-AGENTS-EXPERIMENT B.4).
    public static let maxBytes = 1 << 20
    /// Orca `AGENT_STATUS_MAX_FIELD_LENGTH` / `AGENT_STATUS_TOOL_INPUT_MAX_LENGTH`.
    public static let maxPromptLength = 200
    public static let maxToolInputLength = 160

    public var source: AgentHookSource
    /// Raw `hook_event_name`, kept even when unknown.
    public var eventName: String
    public var event: AgentHookEvent?
    public var providerSessionID: String?
    public var transcriptPath: String?
    public var cwd: String?
    public var toolName: String?
    public var toolInputPreview: String?
    public var toolUseID: String?
    public var prompt: String?
    /// SessionStart `source` (startup/resume/clear/compact).
    public var sessionSource: String?
    /// Set when a child (subagent/teammate) produced the event.
    public var childAgentID: String?
    public var model: String?
    public var isInterrupt: Bool
    /// PostCompact `trigger` (manual/auto).
    public var trigger: String?

    public init(
        source: AgentHookSource, eventName: String, providerSessionID: String? = nil,
        transcriptPath: String? = nil, cwd: String? = nil, toolName: String? = nil,
        toolInputPreview: String? = nil, toolUseID: String? = nil, prompt: String? = nil,
        sessionSource: String? = nil, childAgentID: String? = nil, model: String? = nil,
        isInterrupt: Bool = false, trigger: String? = nil
    ) {
        self.source = source
        self.eventName = eventName
        self.event = AgentHookEvent(rawValue: eventName)
        self.providerSessionID = providerSessionID
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.toolName = toolName
        self.toolInputPreview = toolInputPreview
        self.toolUseID = toolUseID
        self.prompt = prompt
        self.sessionSource = sessionSource
        self.childAgentID = childAgentID
        self.model = model
        self.isInterrupt = isInterrupt
        self.trigger = trigger
    }

    /// Decodes a hook's stdin. `eventNameOverride` covers hosts that pass the event out of band.
    public init(source: AgentHookSource, json data: Data, eventNameOverride: String? = nil) throws {
        guard data.count <= Self.maxBytes else { throw AgentHookPayloadError.tooLarge(data.count) }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let record = object as? [String: Any] else { throw AgentHookPayloadError.notJSONObject }
        func string(_ key: String) -> String? {
            guard let value = record[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        guard let eventName = eventNameOverride ?? string("hook_event_name") ?? string("hookEventName")
        else { throw AgentHookPayloadError.missingEventName }
        let toolName = string("tool_name")
        self.init(
            source: source,
            eventName: eventName,
            providerSessionID: string("session_id"),
            transcriptPath: string("transcript_path"),
            cwd: string("cwd"),
            toolName: toolName,
            toolInputPreview: Self.toolInputPreview(toolName: toolName, input: record["tool_input"])
                .map { Self.singleLine($0, max: Self.maxToolInputLength) },
            toolUseID: string("tool_use_id"),
            prompt: (string("prompt") ?? string("user_prompt")).map { Self.singleLine($0, max: Self.maxPromptLength) },
            sessionSource: string("source"),
            childAgentID: string("agent_id"),
            model: string("model"),
            isInterrupt: (record["is_interrupt"] as? Bool) == true,
            trigger: string("trigger"))
    }

    /// Orca `isAskUserQuestionTool`.
    public static func isAskUserQuestionTool(_ name: String?) -> Bool {
        guard let name else { return false }
        let normalized = String(name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        return normalized == "askuserquestion" || normalized == "requestuserinput"
    }

    /// The status this event implies, or nil when the event carries metadata only (child lifecycle,
    /// compact restarts, unknown events).
    public var impliedState: AgentStatusState? {
        guard let event else { return nil }
        switch source {
        case .claude: return claudeState(event)
        case .codex: return codexState(event)
        }
    }

    private func claudeState(_ event: AgentHookEvent) -> AgentStatusState? {
        let asksQuestion = Self.isAskUserQuestionTool(toolName)
        switch event {
        case .sessionStart:
            // Allowlist idle boundaries: a compact restart fires mid-turn, and a child-attributed
            // SessionStart must not flip the lead's live turn.
            guard childAgentID == nil, ["startup", "resume", "clear"].contains(sessionSource ?? "") else { return nil }
            return .idle
        case .userPromptSubmit, .postToolUse, .postToolUseFailure:
            return .working
        case .preToolUse:
            return asksQuestion ? .blocked(.question) : .working
        case .permissionRequest:
            return .blocked(asksQuestion ? .question : .permission)
        case .stop:
            return .done
        case .stopFailure:
            // A child's StopFailure ends that child's turn, not the lead's.
            return childAgentID == nil ? .error : nil
        case .postCompact:
            // A manual /compact ends at an idle prompt without a Stop; an auto compact runs inside a turn.
            return trigger == "manual" ? .done : nil
        case .sessionEnd:
            return .idle
        case .subagentStart, .subagentStop, .teammateIdle, .interrupt:
            return nil
        }
    }

    private func codexState(_ event: AgentHookEvent) -> AgentStatusState? {
        guard childAgentID == nil else { return nil }
        switch event {
        case .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse:
            return .working
        case .permissionRequest:
            return .blocked(Self.isAskUserQuestionTool(toolName) ? .question : .permission)
        case .stop, .interrupt:
            return .done
        default:
            return nil
        }
    }

    // MARK: Tool input preview (Orca `tool-input-preview.ts`, subset of the per-tool keys)

    private static let toolInputKeys: [String: [String]] = [
        "Read": ["file_path", "filePath", "path"], "Write": ["file_path", "filePath", "path"],
        "Edit": ["file_path", "filePath", "path"], "MultiEdit": ["file_path", "filePath", "path"],
        "NotebookEdit": ["file_path", "filePath", "path"], "Bash": ["command"], "Glob": ["pattern"],
        "Grep": ["pattern"], "WebFetch": ["url"], "WebSearch": ["query"],
        "AskUserQuestion": ["questions", "question", "prompt", "message"],
        "exec_command": ["cmd", "command"], "shell_command": ["cmd", "command"],
        "apply_patch": ["path", "file_path"], "view_image": ["path", "file_path"],
    ]

    private static let fallbackToolInputKeys = [
        "command", "cmd", "code", "query", "pattern", "url", "path", "file_path", "filePath",
        "target", "selector", "text", "action", "name", "description",
    ]

    static func toolInputPreview(toolName: String?, input: Any?) -> String? {
        if let text = input as? String { return text.isEmpty ? nil : text }
        guard let record = input as? [String: Any] else { return nil }
        let keys = toolName.flatMap { toolInputKeys[$0] } ?? fallbackToolInputKeys
        for key in keys {
            if let value = record[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    /// Trim, fold to one line, truncate on a character boundary.
    static func singleLine(_ value: String, max: Int) -> String {
        let folded = value.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return folded.count > max ? String(folded.prefix(max)) : folded
    }
}
