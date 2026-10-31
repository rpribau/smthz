import Foundation

/// Converts app-server items into the existing transcript rows without changing file decoders.
struct CodexTranscriptAdapter {
    private var textByID: [String: String] = [:]

    mutating func delta(_ delta: CodexAgentMessageDeltaNotification, reasoning: Bool = false) -> TranscriptMessage {
        let id = delta.threadId + ":" + delta.itemId
        textByID[id, default: ""] += delta.delta
        return TranscriptMessage(id: id, role: reasoning ? .reasoning : .assistant,
                                 blocks: [.text(textByID[id]!)], parentID: delta.turnId)
    }

    mutating func item(_ item: [String: Any], threadID: String, turnID: String) -> TranscriptMessage? {
        guard let itemID = item["id"] as? String, let type = item["type"] as? String else { return nil }
        let id = threadID + ":" + itemID
        let role: TranscriptRole
        let blocks: [TranscriptBlock]
        switch type {
        case "agentMessage":
            guard let text = item["text"] as? String else { return nil }
            textByID[id] = text
            role = .assistant
            blocks = [.text(text)]
        case "userMessage":
            role = .user
            blocks = (item["content"] as? [[String: Any]] ?? []).compactMap {
                guard let text = $0["text"] as? String else { return nil }
                return .text(text)
            }
        case "reasoning":
            role = .reasoning
            let text = (item["summary"] as? [String] ?? []).joined(separator: "\n")
            blocks = [.text(text)]
        case "commandExecution":
            role = .tool
            var result: [TranscriptBlock] = [.toolCall(name: "shell", input: item["command"] as? String ?? "", callID: itemID)]
            if let output = item["aggregatedOutput"] as? String {
                result.append(.toolResult(output: output, callID: itemID, isError: (item["exitCode"] as? Int ?? 0) != 0))
            }
            blocks = result
        case "fileChange":
            role = .tool
            blocks = [.toolCall(name: "fileChange", input: TranscriptJSON.preview(item["changes"]), callID: itemID)]
        default: return nil
        }
        return TranscriptMessage(id: id, role: role, blocks: blocks, parentID: turnID)
    }
}
