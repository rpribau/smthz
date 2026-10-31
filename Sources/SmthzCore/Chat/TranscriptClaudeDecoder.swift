import Foundation

// Claude Code JSONL line -> transcript row. Port of Orca
// `src/main/native-chat/transcript-line-decoders-claude.ts` (+ `transcript-record-blocks.ts`,
// `transcript-turn-markers.ts`, `shared/claude-bash-input.ts`), reference 1.4.238.
// Stateless: unknown or empty records yield nil, never throw (schema drift).
// Not ported yet: edit-patch hunks, pasted-content and image-companion unwrapping.

public enum TranscriptClaudeDecoder {
    /// Orca `NATIVE_CHAT_INTERRUPTED_STATUS_TEXT`.
    public static let interruptedText = "Conversation interrupted"

    public static func decode(line: String, fallbackID: String) -> TranscriptMessage? {
        guard let parsed = TranscriptJSON.object(line) else { return nil }
        let record = queuedPromptAsUserRecord(parsed) ?? parsed
        guard let type = record["type"] as? String, type == "user" || type == "assistant" else { return nil }
        let timestamp = TranscriptJSON.timestamp(record["timestamp"])
        let parentID = TranscriptJSON.string(record["parentUuid"])
        let recordID = TranscriptJSON.string(record["uuid"])

        // Claude's injected notice after Esc: a quiet status row, not a user bubble.
        if type == "user", TranscriptJSON.string(record["interruptedMessageId"]) != nil {
            return TranscriptMessage(id: recordID ?? fallbackID, role: .system, blocks: [.text(interruptedText)],
                                     timestamp: timestamp, parentID: parentID)
        }

        let message = TranscriptJSON.record(record["message"])
        let decoded = TranscriptJSON.contentBlocks(message?["content"])
        guard !decoded.blocks.isEmpty else { return nil }

        // Meta/synthetic/compact-summary user turns are injected context; tool results in them are
        // still genuine output.
        let injected = type == "user"
            && (TranscriptJSON.bool(record["isMeta"]) || TranscriptJSON.bool(record["isSynthetic"])
                || TranscriptJSON.bool(record["isCompactSummary"]))
        var blocks = injected ? decoded.blocks.filter { if case .toolResult = $0 { true } else { false } } : decoded.blocks
        guard !blocks.isEmpty else { return nil }
        if type == "user" { blocks = blocks.map(unwrapBashInput) }

        let id = recordID ?? TranscriptJSON.string(message?["id"]) ?? fallbackID
        return TranscriptMessage(id: id, role: role(type: type, blocks: blocks, reasoningOnly: decoded.reasoningOnly),
                                 blocks: blocks, timestamp: timestamp, parentID: parentID)
    }

    /// A user record holding only tool results is the tool's row; an assistant record made only of
    /// `thinking` blocks is reasoning (Claude writes one content block per line).
    static func role(type: String, blocks: [TranscriptBlock], reasoningOnly: Bool) -> TranscriptRole {
        if type == "user" {
            let onlyResults = blocks.allSatisfy { if case .toolResult = $0 { true } else { false } }
            return onlyResults ? .tool : .user
        }
        return reasoningOnly ? .reasoning : .assistant
    }

    /// A prompt typed mid-turn is recorded only as a `queued_command` attachment (Orca
    /// `claudeQueuedPromptAsUserRecord`); task notifications share the type but are not human.
    static func queuedPromptAsUserRecord(_ record: [String: Any]) -> [String: Any]? {
        guard record["type"] as? String == "attachment",
              let attachment = TranscriptJSON.record(record["attachment"]),
              attachment["type"] as? String == "queued_command",
              attachment["commandMode"] as? String == "prompt" else { return nil }
        if let kind = TranscriptJSON.record(attachment["origin"])?["kind"] as? String, kind != "human" { return nil }
        guard let prompt = attachment["prompt"], prompt is String || prompt is [Any] else { return nil }
        var copy = record
        copy["type"] = "user"
        copy["message"] = ["role": "user", "content": prompt]
        return copy
    }

    /// `<bash-input>cmd</bash-input>` is how Claude records a `!cmd` line.
    static func unwrapBashInput(_ block: TranscriptBlock) -> TranscriptBlock {
        guard case .text(let text) = block else { return block }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let open = "<bash-input>", close = "</bash-input>"
        guard trimmed.hasPrefix(open), trimmed.hasSuffix(close), trimmed.count >= open.count + close.count else {
            return block
        }
        let command = trimmed.dropFirst(open.count).dropLast(close.count)
        guard !command.contains(open) else { return block }
        return .text("!" + command)
    }
}
