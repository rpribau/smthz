import Foundation
import Testing
@testable import SmthzCore

// Hand-written records shaped like Codex rollout lines (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`).

private func decode(_ line: String, fallback: String = "f:0") -> TranscriptMessage? {
    TranscriptCodexDecoder.decode(line: line, fallbackID: fallback)
}

@Test func codexDecodesResponseItemMessages() throws {
    let user = try #require(decode("""
        {"timestamp":"2026-10-31T10:00:00.000Z","type":"response_item","payload":{"type":"message","id":"m1",\
        "role":"user","content":[{"type":"input_text","text":"Add a test"}]}}
        """))
    #expect(user.id == "m1")
    #expect(user.role == .user)
    #expect(user.blocks == [.text("Add a test")])
    #expect(user.timestamp == Date(timeIntervalSince1970: 1_793_440_800))

    let assistant = try #require(decode("""
        {"type":"response_item","payload":{"type":"message","role":"assistant",\
        "content":[{"type":"output_text","text":"Done."}]}}
        """, fallback: "x:1"))
    #expect(assistant.id == "x:1")
    #expect(assistant.role == .assistant)
    #expect(decode(#"{"type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"rules"}]}}"#) == nil)
}

@Test func codexHidesInjectedContextInUserMessages() {
    #expect(decode("""
        {"type":"response_item","payload":{"type":"message","role":"user","content":[\
        {"type":"input_text","text":"<environment_context>\\n<cwd>/w</cwd>\\n</environment_context>"}]}}
        """) == nil)
    #expect(decode("""
        {"type":"response_item","payload":{"type":"message","role":"user","content":[\
        {"type":"input_text","text":"  <skill>\\nname: x\\n</skill>"},{"type":"input_text","text":"go"}]}}
        """)?.blocks == [.text("go")])
}

@Test func codexDecodesToolCallsAndOutputs() throws {
    let call = try #require(decode("""
        {"type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"c1",\
        "arguments":"{\\"command\\":[\\"ls\\"]}"}}
        """))
    #expect(call.role == .assistant)
    #expect(call.blocks == [.toolCall(name: "shell", input: #"{"command":["ls"]}"#, callID: "c1")])

    let custom = try #require(decode("""
        {"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"c2",\
        "input":"*** Begin Patch","status":"completed"}}
        """))
    #expect(custom.blocks == [.toolCall(name: "apply_patch", input: "*** Begin Patch", callID: "c2")])

    let output = try #require(decode(#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"a.txt"}}"#))
    #expect(output.role == .tool)
    #expect(output.blocks == [.toolResult(output: "a.txt", callID: "c1", isError: false)])

    let failed = try #require(decode(#"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c2","output":{"success":false,"output":"patch failed"}}}"#))
    #expect(failed.blocks == [.toolResult(output: "patch failed", callID: "c2", isError: true)])
}

@Test func codexDecodesReasoningAndEvents() throws {
    let reasoning = try #require(decode("""
        {"type":"response_item","payload":{"type":"reasoning","id":"r1","encrypted_content":"zz",\
        "summary":[{"type":"summary_text","text":"Plan the change"}]}}
        """))
    #expect(reasoning.role == .reasoning)
    #expect(reasoning.blocks == [.text("Plan the change")])
    #expect(decode(#"{"type":"response_item","payload":{"type":"reasoning","summary":[]}}"#) == nil)

    #expect(decode(#"{"type":"event_msg","payload":{"type":"user_message","message":"Add a test"}}"#)?.role == .user)
    #expect(decode(#"{"type":"event_msg","payload":{"type":"agent_message","message":"Done."}}"#)?.role == .assistant)
    let aborted = try #require(decode(#"{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#))
    #expect(aborted.role == .system)
    #expect(aborted.blocks == [.text(TranscriptClaudeDecoder.interruptedText)])

    let completed = try #require(decode("""
        {"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"it1",\
        "content":[{"type":"Text","text":"All green"}]}}}
        """))
    #expect(completed.id == "it1")
    #expect(completed.role == .assistant)
}

@Test func codexSkipsBookkeepingRecords() {
    #expect(decode(#"{"type":"session_meta","payload":{"id":"s","cwd":"/w","cli_version":"0.1"}}"#) == nil)
    #expect(decode(#"{"type":"turn_context","payload":{"cwd":"/w","model":"m"}}"#) == nil)
    #expect(decode(#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#) == nil)
    #expect(decode(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t"}}"#) == nil)
    #expect(decode("{") == nil)
}

@Test func codexUnwrappedLegacyRecords() throws {
    let m = try #require(decode(#"{"type":"message","id":"old1","role":"assistant","content":[{"type":"output_text","text":"legacy"}]}"#))
    #expect(m.id == "old1")
    #expect(m.blocks == [.text("legacy")])
    #expect(decode(#"{"type":"function_call","name":"shell","call_id":"c","arguments":"{}"}"#)?.role == .assistant)
}
