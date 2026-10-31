import Foundation

// Chat-over-PTY transcript reading (docs/BROWSER-AGENTS-EXPERIMENT.md B.5, WP CHAT0).
// Mirrors Orca `src/main/native-chat/transcript-stream-lines.ts` (line framing),
// `transcript-fallback-id.ts` (offset ids) and `transcript-tail-reader.ts` (incremental tail),
// reference 1.4.238. The agent's JSONL file stays the source of truth; smthz only reads it.

/// Who a transcript row belongs to (Orca `NativeChatRole`, minus the structured-only roles).
public enum TranscriptRole: String, Codable, Sendable, CaseIterable {
    case user, assistant, reasoning, tool, system
}

/// One renderable piece of a transcript row (Orca `NativeChatBlock`, the transcript subset).
public enum TranscriptBlock: Equatable, Sendable {
    case text(String)
    /// `input` is a display preview: strings pass through, other JSON is serialized with sorted keys.
    case toolCall(name: String, input: String, callID: String?)
    case toolResult(output: String, callID: String?, isError: Bool)
    case imageRef(url: String?, path: String?)
}

public struct TranscriptMessage: Identifiable, Equatable, Sendable {
    /// The record's own id (Claude `uuid`, Codex payload `id`) or the offset fallback id.
    public var id: String
    public var role: TranscriptRole
    public var blocks: [TranscriptBlock]
    public var timestamp: Date?
    public var parentID: String?

    public init(id: String, role: TranscriptRole, blocks: [TranscriptBlock], timestamp: Date? = nil,
                parentID: String? = nil) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
        self.parentID = parentID
    }

    /// The row's text blocks joined, used for duplicate suppression and previews.
    public var plainText: String {
        blocks.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n")
    }
}

/// The CLI whose JSONL format a transcript uses.
public enum TranscriptFormat: String, Codable, Sendable, CaseIterable {
    case claude, codex

    public func decode(line: String, fallbackID: String) -> TranscriptMessage? {
        switch self {
        case .claude: TranscriptClaudeDecoder.decode(line: line, fallbackID: fallbackID)
        case .codex: TranscriptCodexDecoder.decode(line: line, fallbackID: fallbackID)
        }
    }
}

/// Stable id for a line without an intrinsic id: `<path>:<16-digit byte offset>` (Orca
/// `transcriptFallbackId`), so a full read and an incremental tail agree.
public func transcriptFallbackID(path: String, byteOffset: UInt64) -> String {
    let digits = String(byteOffset)
    return path + ":" + String(repeating: "0", count: max(0, 16 - digits.count)) + digits
}

public struct TranscriptReadResult: Equatable, Sendable {
    /// Decoded rows from the bytes read by this call, in file order.
    public var messages: [TranscriptMessage]
    /// The file shrank or was replaced: the reader started over at offset 0 and callers must
    /// drop what they showed before.
    public var didReset: Bool
}

/// Incremental reader of a growing JSONL transcript. Each call reads only bytes it has not read
/// before; a trailing line without `\n` is held in memory until its newline arrives. Not
/// thread-safe: own it from one actor or queue.
public final class TranscriptReader {
    /// Orca caps one record at a few MiB; larger lines are skipped, not buffered without bound.
    public static let defaultMaxRecordBytes = 8 * 1024 * 1024
    static let chunkSize = 256 * 1024

    public let url: URL
    public let format: TranscriptFormat
    public let maxRecordBytes: Int
    /// Bytes of the file already read (including a held partial line).
    public private(set) var readOffset: UInt64 = 0
    /// Total bytes read from disk over the reader's life (tests use it to prove no re-read).
    public private(set) var totalBytesRead: UInt64 = 0
    /// Lines skipped because they exceeded `maxRecordBytes`.
    public private(set) var oversizeLinesSkipped = 0

    private var pending = Data()
    private var skippingOversizeLine = false
    private var fileIdentity: (device: UInt64, inode: UInt64)?

    public init(url: URL, format: TranscriptFormat, maxRecordBytes: Int = TranscriptReader.defaultMaxRecordBytes) {
        self.url = url
        self.format = format
        self.maxRecordBytes = max(1, maxRecordBytes)
    }

    /// Byte offset of the first line not yet fully decoded.
    public var consumedOffset: UInt64 { readOffset - UInt64(pending.count) }

    /// Reads what was appended since the last call. A missing file yields no rows (the agent may
    /// not have created it yet). With `includeTrailingLine`, a complete-looking final line without
    /// `\n` is decoded too but stays held, so it is decoded again (same id) once terminated.
    public func readAvailable(includeTrailingLine: Bool = false) throws -> TranscriptReadResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return TranscriptReadResult(messages: [], didReset: false)
        }
        defer { try? handle.close() }

        var didReset = false
        var info = stat()
        if fstat(handle.fileDescriptor, &info) == 0 {
            let identity = (device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
            let size = UInt64(info.st_size)
            let replaced = fileIdentity.map { $0.device != identity.device || $0.inode != identity.inode } ?? false
            if replaced || size < readOffset {
                reset()
                didReset = true
            }
            fileIdentity = identity
        }

        try handle.seek(toOffset: readOffset)
        var messages: [TranscriptMessage] = []
        while true {
            guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
            totalBytesRead += UInt64(chunk.count)
            consume(chunk, into: &messages)
        }
        if includeTrailingLine, !skippingOversizeLine, !pending.isEmpty {
            decodeLine(pending, at: consumedOffset, into: &messages)
        }
        return TranscriptReadResult(messages: messages, didReset: didReset)
    }

    /// Forgets everything read; the next call starts at offset 0.
    public func reset() {
        readOffset = 0
        pending = Data()
        skippingOversizeLine = false
        fileIdentity = nil
    }

    private func consume(_ chunk: Data, into messages: inout [TranscriptMessage]) {
        var lineStart = chunk.startIndex
        while let newline = chunk[lineStart...].firstIndex(of: 0x0A) {
            let piece = chunk[lineStart..<newline]
            let pieceLength = UInt64(newline - lineStart + 1)
            if skippingOversizeLine {
                skippingOversizeLine = false
            } else if pending.count + piece.count > maxRecordBytes {
                oversizeLinesSkipped += 1
                pending = Data()
            } else {
                let lineOffset = readOffset - UInt64(pending.count)
                var line = pending
                line.append(piece)
                pending = Data()
                decodeLine(line, at: lineOffset, into: &messages)
            }
            readOffset += pieceLength
            lineStart = chunk.index(after: newline)
        }
        let tail = chunk[lineStart...]
        readOffset += UInt64(tail.count)
        if skippingOversizeLine { return }
        if pending.count + tail.count > maxRecordBytes {
            oversizeLinesSkipped += 1
            pending = Data()
            skippingOversizeLine = true
            return
        }
        pending.append(tail)
    }

    private func decodeLine(_ raw: Data, at offset: UInt64, into messages: inout [TranscriptMessage]) {
        var bytes = raw
        if bytes.last == 0x0D { bytes.removeLast() }
        guard !bytes.isEmpty, let line = String(data: bytes, encoding: .utf8) else { return }
        let fallback = transcriptFallbackID(path: url.path, byteOffset: offset)
        if let message = format.decode(line: line, fallbackID: fallback) {
            messages.append(message)
        }
    }

    /// Reads a whole transcript from offset 0 (Orca `readTranscript`).
    public static func readAll(url: URL, format: TranscriptFormat) throws -> [TranscriptMessage] {
        try TranscriptReader(url: url, format: format).readAvailable(includeTrailingLine: true).messages
    }
}

/// The ordered rows a transcript view shows. Upserts by id (a re-decoded trailing line replaces
/// itself) and drops a text row that repeats one of the last few rows of the same role, which is
/// how Codex records the same prompt as both a `response_item` and an `event_msg`.
public struct TranscriptLog: Equatable, Sendable {
    public static let duplicateWindow = 6
    public private(set) var messages: [TranscriptMessage] = []
    private var indexByID: [String: Int] = [:]

    public init(_ messages: [TranscriptMessage] = []) {
        apply(messages)
    }

    public mutating func apply(_ result: TranscriptReadResult) {
        if result.didReset { removeAll() }
        apply(result.messages)
    }

    public mutating func apply(_ incoming: [TranscriptMessage]) {
        for message in incoming {
            if let index = indexByID[message.id] {
                messages[index] = message
                continue
            }
            if isRepeat(message) { continue }
            indexByID[message.id] = messages.count
            messages.append(message)
        }
    }

    public mutating func removeAll() {
        messages = []
        indexByID = [:]
    }

    private func isRepeat(_ message: TranscriptMessage) -> Bool {
        guard message.role == .user || message.role == .assistant,
              message.blocks.allSatisfy({ if case .text = $0 { true } else { false } }) else { return false }
        let text = message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return messages.suffix(Self.duplicateWindow).contains {
            $0.role == message.role && $0.plainText.trimmingCharacters(in: .whitespacesAndNewlines) == text
        }
    }
}

// MARK: - JSON helpers shared by the decoders (Orca `ai-vault/session-scanner-values.ts`)

enum TranscriptJSON {
    static func object(_ line: String) -> [String: Any]? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty, let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
    }

    static func record(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    /// A non-empty string, else nil (Orca `extractString`).
    static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    static func bool(_ value: Any?) -> Bool { (value as? Bool) == true }

    /// ISO-8601 string or epoch seconds/milliseconds (Orca `timestampMs`).
    static func timestamp(_ value: Any?) -> Date? {
        if let text = value as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            return ISO8601DateFormatter().date(from: text)
        }
        if let number = value as? NSNumber, !(value is Bool) {
            let raw = number.doubleValue
            guard raw.isFinite, raw > 0 else { return nil }
            return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000 : raw)
        }
        return nil
    }

    /// Display text for a tool input: strings as they are, anything else as sorted-key JSON.
    static func preview(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let text = value as? String { return text }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    /// Coerce a tool-result payload into one string (Orca `toolResultOutput`).
    static func toolResultOutput(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let items = value as? [Any] {
            return items.compactMap { item -> String? in
                if let text = item as? String { return text }
                let entry = record(item)
                return string(entry?["text"]) ?? string(entry?["content"])
            }.joined(separator: "\n")
        }
        if let entry = record(value), let text = string(entry["text"]) ?? string(entry["content"]) {
            return text
        }
        guard let value, !(value is NSNull) else { return "" }
        return preview(value)
    }

    /// Claude-style content: a string or an array of typed blocks (Orca `claudeContentBlocks`).
    /// `reasoning` reports whether every block came from a `thinking` block.
    static func contentBlocks(_ content: Any?) -> (blocks: [TranscriptBlock], reasoningOnly: Bool) {
        if let text = content as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty ? [] : [.text(text)], false)
        }
        guard let items = content as? [Any] else { return ([], false) }
        var blocks: [TranscriptBlock] = []
        var sawThinking = false
        var sawOther = false
        for item in items {
            if let text = item as? String {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(.text(text))
                    sawOther = true
                }
                continue
            }
            guard let entry = record(item) else { continue }
            switch entry["type"] as? String {
            case "text", "input_text", "output_text":
                if let text = string(entry["text"]) { blocks.append(.text(text)); sawOther = true }
            case "thinking":
                if let text = string(entry["thinking"]) ?? string(entry["text"]) {
                    blocks.append(.text(text))
                    sawThinking = true
                }
            case "tool_use":
                blocks.append(.toolCall(name: string(entry["name"]) ?? "tool", input: preview(entry["input"]),
                                        callID: string(entry["id"])))
                sawOther = true
            case "tool_result":
                blocks.append(.toolResult(output: toolResultOutput(entry["content"]),
                                          callID: string(entry["tool_use_id"]), isError: bool(entry["is_error"])))
                sawOther = true
            case "image", "input_image":
                let source = record(entry["source"])
                let url = string(source?["url"]) ?? string(entry["url"]) ?? string(entry["image_url"])
                let path = string(entry["path"])
                if url != nil || path != nil { blocks.append(.imageRef(url: url, path: path)); sawOther = true }
            default:
                continue
            }
        }
        return (blocks, sawThinking && !sawOther)
    }
}
