import Foundation

/// The per-launch `claude --settings <file>` document that routes Claude's 13 managed hook events to
/// `smthz hook --agent claude`. Claude merges it with the user's own hooks, so no global file is edited
/// (BROWSER-AGENTS-EXPERIMENT B.2/B.4). Shape: Orca `src/main/claude/claude-managed-hook-events.ts` and
/// `buildManagedCommandHook` in `src/main/agent-hooks/installer-utils.ts` (reference 1.4.238).
public enum ClaudeHookSettings {
    /// Orca `MANAGED_HOOK_TIMEOUT_SECONDS`.
    public static let defaultTimeoutSeconds = 10

    public static var events: [AgentHookEvent] { AgentHookEvent.claudeEvents }

    /// Settings JSON (sorted keys) for every managed event; tool events get matcher `*`.
    public static func json(command: String, timeoutSeconds: Int = defaultTimeoutSeconds) throws -> Data {
        var hooks: [String: Any] = [:]
        for event in events {
            var definition: [String: Any] = [
                "hooks": [["type": "command", "command": command, "timeout": timeoutSeconds]],
            ]
            if event.isToolEvent { definition["matcher"] = "*" }
            hooks[event.rawValue] = [definition]
        }
        return try JSONSerialization.data(
            withJSONObject: ["hooks": hooks], options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
    }

    /// `'<executable>' hook --agent claude`, single-quoted for `/bin/sh`.
    public static func hookCommand(executablePath: String, agent: AgentHookSource = .claude) -> String {
        "\(shellQuote(executablePath)) hook --agent \(agent.rawValue)"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
