import Foundation
import Testing
@testable import SmthzCore

// Hand-written records shaped like Claude Code's `~/.claude/projects/<slug>/<id>.jsonl` lines.

private func decode(_ line: String, fallback: String = "f:0") -> TranscriptMessage? {
    TranscriptClaudeDecoder.decode(line: line, fallbackID: fallback)
}

@Test func claudeDecodesStringUserPrompt() throws {
    let m = try #require(decode("""
        {"type":"user","uuid":"u1","parentUuid":null,"timestamp":"2026-10-31T10:00:00.250Z","sessionId":"s",\
        "message":{"role":"user","content":"Fix the login bug"}}
        """))
    #expect(m.id == "u1")
    #expect(m.role == .user)
    #expect(m.blocks == [.text("Fix the login bug")])
    #expect(m.parentID == nil)
    #expect(m.timestamp == Date(timeIntervalSince1970: 1_793_440_800.25))
}

@Test func claudeDecodesAssistantTextToolUseAndThinking() throws {
    let text = try #require(decode("""
        {"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"id":"msg_1","role":"assistant",\
        "content":[{"type":"text","text":"Looking at it."}]}}
        """))
    #expect(text.role == .assistant)
    #expect(text.parentID == "u1")
    #expect(text.blocks == [.text("Looking at it.")])

    let tool = try #require(decode("""
        {"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"tool_use",\
        "id":"toolu_1","name":"Bash","input":{"description":"list","command":"ls"}}]}}
        """))
    #expect(tool.role == .assistant)
    #expect(tool.blocks == [.toolCall(name: "Bash", input: #"{"command":"ls","description":"list"}"#, callID: "toolu_1")])

    let thinking = try #require(decode("""
        {"type":"assistant","uuid":"a3","message":{"role":"assistant","content":[{"type":"thinking",\
        "thinking":"The bug is in the session check.","signature":"x"}]}}
        """))
    #expect(thinking.role == .reasoning)
    #expect(thinking.blocks == [.text("The bug is in the session check.")])
}

@Test func claudeToolResultRecordIsToolRow() throws {
    let m = try #require(decode("""
        {"type":"user","uuid":"r1","toolUseResult":{"stdout":"a\\nb"},"message":{"role":"user","content":[\
        {"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"a"},{"type":"text","text":"b"}]}]}}
        """))
    #expect(m.role == .tool)
    #expect(m.blocks == [.toolResult(output: "a\nb", callID: "toolu_1", isError: false)])

    let failed = try #require(decode("""
        {"type":"user","uuid":"r2","message":{"content":[{"type":"tool_result","tool_use_id":"t2",\
        "content":"command not found","is_error":true}]}}
        """))
    #expect(failed.blocks == [.toolResult(output: "command not found", callID: "t2", isError: true)])
}

@Test func claudeSkipsMetaAndNonMessageRecords() {
    #expect(decode(#"{"type":"user","uuid":"m1","isMeta":true,"message":{"content":"<command-name>/clear</command-name>"}}"#) == nil)
    #expect(decode(#"{"type":"file-history-snapshot","messageId":"x","snapshot":{}}"#) == nil)
    #expect(decode(#"{"type":"ai-title","aiTitle":"Login","sessionId":"s"}"#) == nil)
    #expect(decode(#"{"type":"assistant","uuid":"e","message":{"content":[]}}"#) == nil)
    #expect(decode("not json") == nil)
    #expect(decode("") == nil)
    #expect(decode("[1,2]") == nil)
}

@Test func claudeMetaTurnKeepsToolResults() throws {
    let m = try #require(decode("""
        {"type":"user","uuid":"m2","isMeta":true,"message":{"content":[{"type":"text","text":"injected"},\
        {"type":"tool_result","tool_use_id":"t9","content":"ok"}]}}
        """))
    #expect(m.role == .tool)
    #expect(m.blocks == [.toolResult(output: "ok", callID: "t9", isError: false)])
}

@Test func claudeInterruptAndQueuedPromptAndBashInput() throws {
    let interrupted = try #require(decode("""
        {"type":"user","uuid":"i1","interruptedMessageId":"a2","message":{"content":[{"type":"text",\
        "text":"[Request interrupted by user]"}]}}
        """))
    #expect(interrupted.role == .system)
    #expect(interrupted.blocks == [.text(TranscriptClaudeDecoder.interruptedText)])

    let queued = try #require(decode("""
        {"type":"attachment","uuid":"q1","attachment":{"type":"queued_command","commandMode":"prompt",\
        "prompt":"also update the docs","origin":{"kind":"human"}}}
        """))
    #expect(queued.role == .user)
    #expect(queued.blocks == [.text("also update the docs")])
    #expect(decode("""
        {"type":"attachment","uuid":"q2","attachment":{"type":"queued_command","commandMode":"prompt",\
        "prompt":"task done","origin":{"kind":"task-notification"}}}
        """) == nil)

    let bash = try #require(decode(#"{"type":"user","uuid":"b1","message":{"content":"<bash-input>git status</bash-input>"}}"#))
    #expect(bash.blocks == [.text("!git status")])
}

@Test func claudeFallbackIDWhenRecordHasNoUUID() throws {
    let m = try #require(decode(#"{"type":"assistant","message":{"content":"hi"}}"#, fallback: "/p:0000000000000042"))
    #expect(m.id == "/p:0000000000000042")
    let withMessageID = try #require(decode(#"{"type":"assistant","message":{"id":"msg_7","content":"hi"}}"#))
    #expect(withMessageID.id == "msg_7")
}
