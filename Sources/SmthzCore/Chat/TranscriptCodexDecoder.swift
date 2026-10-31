import Foundation

// Codex rollout JSONL line -> transcript row. Port of Orca
// `src/main/native-chat/transcript-line-decoders-codex.ts`, reference 1.4.238.
// Records are `{timestamp, type: response_item|event_msg|..., payload}`; older rollouts write the
// response item unwrapped. Codex records a turn twice (response_item message + event_msg
// user_message/agent_message): both decode here and `TranscriptLog` drops the repeat.

public enum TranscriptCodexDecoder {
    /// User-role blocks that are model context, not the typed prompt. Orca filters `<skill>`;
    /// smthz also hides the environment/instructions preamble Codex injects as a user message.
    static let contextPrefixes = ["<skill>", "<environment_context>", "<user_instructions>", "# agents.md instructions"]

    public static func decode(line: String, fallbackID: String) -> TranscriptMessage? {
        guard let record = TranscriptJSON.object(line) else { return nil }
        let timestamp = TranscriptJSON.timestamp(record["timestamp"])
        guard let payload = TranscriptJSON.record(record["payload"]) else {
            return responseItem(record, id: TranscriptJSON.string(record["id"]) ?? fallbackID, timestamp: timestamp)
        }
        let id = TranscriptJSON.string(payload["id"]) ?? fallbackID
        switch record["type"] as? String {
        case "response_item": return responseItem(payload, id: id, timestamp: timestamp)
        case "event_msg": return eventMessage(payload, id: id, timestamp: timestamp)
        default: return nil
        }
    }

    static func responseItem(_ payload: [String: Any], id: String, timestamp: Date?) -> TranscriptMessage? {
        switch payload["type"] as? String {
        case "message":
            guard let role = messageRole(payload["role"]) else { return nil }
            var blocks = TranscriptJSON.contentBlocks(payload["content"]).blocks
            if role == .user { blocks = blocks.filter { !isContext($0) } }
            return blocks.isEmpty ? nil : TranscriptMessage(id: id, role: role, blocks: blocks, timestamp: timestamp)
        case "reasoning":
            guard let text = TranscriptJSON.string(payload["text"]) ?? summaryText(payload["summary"]) else { return nil }
            return TranscriptMessage(id: id, role: .reasoning, blocks: [.text(text)], timestamp: timestamp)
        case "function_call", "local_shell_call", "custom_tool_call":
            let input = payload["arguments"] ?? payload["input"] ?? payload["action"]
            return TranscriptMessage(id: id, role: .assistant, blocks: [
                .toolCall(name: TranscriptJSON.string(payload["name"]) ?? "tool", input: TranscriptJSON.preview(input),
                          callID: TranscriptJSON.string(payload["call_id"])),
            ], timestamp: timestamp)
        case "function_call_output", "custom_tool_call_output":
            return TranscriptMessage(id: id, role: .tool, blocks: [
                toolResult(payload["output"], callID: TranscriptJSON.string(payload["call_id"])),
            ], timestamp: timestamp)
        default:
            return nil
        }
    }

    static func eventMessage(_ payload: [String: Any], id: String, timestamp: Date?) -> TranscriptMessage? {
        switch payload["type"] as? String {
        case "turn_aborted":
            return TranscriptMessage(id: id, role: .system, blocks: [.text(TranscriptClaudeDecoder.interruptedText)],
                                     timestamp: timestamp)
        case "user_message":
            guard let text = TranscriptJSON.string(payload["message"]) else { return nil }
            return TranscriptMessage(id: id, role: .user, blocks: [.text(text)], timestamp: timestamp)
        case "agent_message":
            guard let text = TranscriptJSON.string(payload["message"]) else { return nil }
            return TranscriptMessage(id: id, role: .assistant, blocks: [.text(text)], timestamp: timestamp)
        case "item_completed":
            guard let item = TranscriptJSON.record(payload["item"]) else { return nil }
            let blocks = turnItemBlocks(item["content"])
            guard !blocks.isEmpty else { return nil }
            let itemID = TranscriptJSON.string(item["id"]) ?? id
            switch item["type"] as? String {
            case "UserMessage", "user_message":
                let prompt = blocks.filter { !isContext($0) }
                return prompt.isEmpty ? nil : TranscriptMessage(id: itemID, role: .user, blocks: prompt, timestamp: timestamp)
            case "AgentMessage", "agent_message":
                return TranscriptMessage(id: itemID, role: .assistant, blocks: blocks, timestamp: timestamp)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    static func messageRole(_ value: Any?) -> TranscriptRole? {
        switch value as? String {
        case "assistant": .assistant
        case "user": .user
        default: nil
        }
    }

    static func isContext(_ block: TranscriptBlock) -> Bool {
        guard case .text(let text) = block else { return false }
        let head = text.drop(while: { $0.isWhitespace }).prefix(32).lowercased()
        return contextPrefixes.contains { head.hasPrefix($0) }
    }

    /// `item_completed` content uses Text/Image/LocalImage variants (Orca `codexTurnItemBlocks`).
    static func turnItemBlocks(_ content: Any?) -> [TranscriptBlock] {
        guard let items = content as? [Any] else { return [] }
        var blocks: [TranscriptBlock] = []
        for value in items {
            guard let item = TranscriptJSON.record(value) else { continue }
            switch item["type"] as? String {
            case "text", "Text", "input_text", "output_text":
                if let text = TranscriptJSON.string(item["text"]) { blocks.append(.text(text)) }
            case "image", "Image", "input_image":
                if let url = TranscriptJSON.string(item["image_url"]) ?? TranscriptJSON.string(item["url"]) {
                    blocks.append(.imageRef(url: url, path: nil))
                }
            case "local_image", "LocalImage":
                if let path = TranscriptJSON.string(item["path"]) { blocks.append(.imageRef(url: nil, path: path)) }
            default:
                continue
            }
        }
        return blocks
    }

    static func toolResult(_ output: Any?, callID: String?) -> TranscriptBlock {
        let record = TranscriptJSON.record(output)
        let isError = (record?["success"] as? Bool) == false || TranscriptJSON.bool(record?["is_error"])
        let body = record?["content"] ?? record?["output"] ?? output
        return .toolResult(output: TranscriptJSON.toolResultOutput(body), callID: callID, isError: isError)
    }

    static func summaryText(_ summary: Any?) -> String? {
        guard let items = summary as? [Any] else { return nil }
        let parts = items.compactMap { TranscriptJSON.string(TranscriptJSON.record($0)?["text"]) ?? TranscriptJSON.string($0) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
