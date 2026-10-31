import Foundation
import Testing
@testable import SmthzCore

@Test func claudeHookSettingsListsEveryEvent() throws {
    let command = ClaudeHookSettings.hookCommand(executablePath: "/Applications/smthz.app/Contents/MacOS/smthz-cli")
    let data = try ClaudeHookSettings.json(command: command)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let hooks = try #require(root["hooks"] as? [String: Any])
    let expected: Set<String> = [
        "SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "SubagentStart", "SubagentStop",
        "TeammateIdle", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
        "PostCompact", "SessionEnd",
    ]
    #expect(Set(hooks.keys) == expected)
    #expect(hooks.count == 13)
    let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]
    for (event, value) in hooks {
        let definitions = try #require(value as? [[String: Any]], "\(event)")
        #expect(definitions.count == 1)
        let definition = definitions[0]
        if toolEvents.contains(event) {
            #expect(definition["matcher"] as? String == "*", "\(event)")
        } else {
            #expect(definition["matcher"] == nil, "\(event)")
        }
        let entries = try #require(definition["hooks"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries[0]["type"] as? String == "command")
        #expect(entries[0]["command"] as? String == command)
        #expect(entries[0]["timeout"] as? Int == ClaudeHookSettings.defaultTimeoutSeconds)
    }
}

@Test func claudeHookSettingsIsDeterministic() throws {
    let a = try ClaudeHookSettings.json(command: "smthz hook --agent claude", timeoutSeconds: 5)
    let b = try ClaudeHookSettings.json(command: "smthz hook --agent claude", timeoutSeconds: 5)
    #expect(a == b)
    let text = String(decoding: a, as: UTF8.self)
    #expect(text.contains("\"timeout\" : 5"))
}

@Test func claudeHookCommandQuotesPath() {
    #expect(ClaudeHookSettings.hookCommand(executablePath: "/a b/smthz") == "'/a b/smthz' hook --agent claude")
    #expect(ClaudeHookSettings.hookCommand(executablePath: "/it's/smthz", agent: .codex)
        == "'/it'\\''s/smthz' hook --agent codex")
}
