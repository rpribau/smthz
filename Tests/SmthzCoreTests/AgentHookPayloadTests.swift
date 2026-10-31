import Foundation
import Testing
@testable import SmthzCore

private func payload(_ source: AgentHookSource, _ json: String) throws -> AgentHookPayload {
    try AgentHookPayload(source: source, json: Data(json.utf8))
}

@Test func hookPayloadDecodesClaudeSessionStart() throws {
    let p = try payload(.claude, """
        {"session_id":"abc","transcript_path":"/Users/u/.claude/projects/x/abc.jsonl","cwd":"/tmp/w",
         "hook_event_name":"SessionStart","source":"startup"}
        """)
    #expect(p.event == .sessionStart)
    #expect(p.providerSessionID == "abc")
    #expect(p.transcriptPath == "/Users/u/.claude/projects/x/abc.jsonl")
    #expect(p.cwd == "/tmp/w")
    #expect(p.sessionSource == "startup")
    #expect(p.impliedState == .idle)
}

@Test func hookPayloadDecodesToolFieldsAndPrompt() throws {
    let tool = try payload(.claude, """
        {"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"tu1",
         "tool_input":{"command":"ls -la\\n  /tmp","description":"list"}}
        """)
    #expect(tool.toolName == "Bash")
    #expect(tool.toolUseID == "tu1")
    #expect(tool.toolInputPreview == "ls -la /tmp")

    let fallback = try payload(.codex, #"{"hook_event_name":"PreToolUse","tool_name":"mystery","tool_input":{"url":"https://x"}}"#)
    #expect(fallback.toolInputPreview == "https://x")

    let long = String(repeating: "p", count: 500)
    let prompt = try payload(.claude, #"{"hook_event_name":"UserPromptSubmit","prompt":"\#(long)"}"#)
    #expect(prompt.prompt?.count == AgentHookPayload.maxPromptLength)
}

@Test func hookPayloadRejectsBadInput() {
    #expect(throws: AgentHookPayloadError.notJSONObject) { try payload(.claude, "[1,2]") }
    #expect(throws: AgentHookPayloadError.notJSONObject) { try payload(.claude, "not json") }
    #expect(throws: AgentHookPayloadError.missingEventName) { try payload(.claude, #"{"session_id":"x"}"#) }
    let huge = Data(count: AgentHookPayload.maxBytes + 1)
    #expect(throws: AgentHookPayloadError.tooLarge(huge.count)) {
        try AgentHookPayload(source: .claude, json: huge)
    }
    // Unknown events decode but imply nothing.
    let unknown = try? payload(.claude, #"{"hook_event_name":"Notification"}"#)
    #expect(unknown?.event == nil)
    #expect(unknown?.impliedState == nil)
}

@Test func claudeEventStateTable() {
    let rows: [(String, [String: String], AgentStatusState?)] = [
        ("SessionStart", ["source": "startup"], .idle),
        ("SessionStart", ["source": "resume"], .idle),
        ("SessionStart", ["source": "clear"], .idle),
        ("SessionStart", ["source": "compact"], nil),
        ("SessionStart", ["source": "startup", "agent_id": "c1"], nil),
        ("UserPromptSubmit", [:], .working),
        ("PreToolUse", ["tool_name": "Bash"], .working),
        ("PreToolUse", ["tool_name": "AskUserQuestion"], .blocked(.question)),
        ("PostToolUse", ["tool_name": "Bash"], .working),
        ("PostToolUseFailure", [:], .working),
        ("PermissionRequest", ["tool_name": "Bash"], .blocked(.permission)),
        ("PermissionRequest", ["tool_name": "AskUserQuestion"], .blocked(.question)),
        ("Stop", [:], .done),
        ("StopFailure", [:], .error),
        ("StopFailure", ["agent_id": "c1"], nil),
        ("SubagentStart", [:], nil),
        ("SubagentStop", [:], nil),
        ("TeammateIdle", [:], nil),
        ("PostCompact", ["trigger": "manual"], .done),
        ("PostCompact", ["trigger": "auto"], nil),
        ("SessionEnd", [:], .idle),
    ]
    for (event, fields, expected) in rows {
        let p = AgentHookPayload(
            source: .claude, eventName: event, toolName: fields["tool_name"],
            sessionSource: fields["source"], childAgentID: fields["agent_id"], trigger: fields["trigger"])
        #expect(p.impliedState == expected, "\(event) \(fields)")
    }
}

@Test func codexEventStateTable() {
    let rows: [(String, String?, AgentStatusState?)] = [
        ("SessionStart", nil, .working),
        ("UserPromptSubmit", nil, .working),
        ("PreToolUse", nil, .working),
        ("PostToolUse", nil, .working),
        ("PermissionRequest", nil, .blocked(.permission)),
        ("Stop", nil, .done),
        ("Interrupt", nil, .done),
        ("SubagentStart", nil, nil),
        ("SubagentStop", nil, nil),
        ("Stop", "child", nil),
    ]
    for (event, child, expected) in rows {
        let p = AgentHookPayload(source: .codex, eventName: event, childAgentID: child)
        #expect(p.impliedState == expected, "\(event) child=\(child ?? "-")")
    }
    #expect(AgentHookEvent.codexEvents.count == 9)
    #expect(AgentHookEvent.claudeEvents.count == 13)
}

@Test func askUserQuestionToolNames() {
    #expect(AgentHookPayload.isAskUserQuestionTool("AskUserQuestion"))
    #expect(AgentHookPayload.isAskUserQuestionTool("ask_user_question"))
    #expect(AgentHookPayload.isAskUserQuestionTool("request_user_input"))
    #expect(!AgentHookPayload.isAskUserQuestionTool("Bash"))
    #expect(!AgentHookPayload.isAskUserQuestionTool(nil))
}
