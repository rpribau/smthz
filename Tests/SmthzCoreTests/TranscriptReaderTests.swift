import Foundation
import Testing
@testable import SmthzCore

private final class TranscriptFile {
    let directory: URL
    let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("smthz-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("session.jsonl")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func append(_ text: String) throws {
        let data = Data(text.utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

private let claudeUser = #"{"type":"user","uuid":"u1","message":{"role":"user","content":"hello"}}"#
private let claudeAssistant = #"{"type":"assistant","uuid":"a1","parentUuid":"u1","message":{"content":[{"type":"text","text":"hi there"}]}}"#
private let claudeTool = #"{"type":"assistant","uuid":"a2","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/w/a.swift"}}]}}"#
private let claudeResult = #"{"type":"user","uuid":"r1","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"let a = 1"}]}}"#

@Test func readerReadsWholeFileInOrder() throws {
    let file = try TranscriptFile()
    try file.append([claudeUser, #"{"type":"ai-title","aiTitle":"x"}"#, claudeAssistant, claudeTool, claudeResult].joined(separator: "\n") + "\n")
    let messages = try TranscriptReader.readAll(url: file.url, format: .claude)
    #expect(messages.map(\.id) == ["u1", "a1", "a2", "r1"])
    #expect(messages.map(\.role) == [.user, .assistant, .assistant, .tool])
}

@Test func readerTailsGrowingFileWithoutRereading() throws {
    let file = try TranscriptFile()
    let reader = TranscriptReader(url: file.url, format: .claude)
    #expect(try reader.readAvailable().messages.isEmpty)  // file not created yet

    try file.append(claudeUser + "\n")
    #expect(try reader.readAvailable().messages.map(\.id) == ["u1"])
    let afterFirst = reader.totalBytesRead
    #expect(afterFirst == UInt64(claudeUser.utf8.count + 1))

    #expect(try reader.readAvailable().messages.isEmpty)
    #expect(reader.totalBytesRead == afterFirst)

    try file.append(claudeAssistant + "\n" + claudeTool + "\n")
    #expect(try reader.readAvailable().messages.map(\.id) == ["a1", "a2"])
    let size = try #require(try FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber).uint64Value
    #expect(reader.totalBytesRead == size)
    #expect(reader.readOffset == size)
    #expect(reader.consumedOffset == size)
}

@Test func readerHoldsPartialLastLineUntilNewline() throws {
    let file = try TranscriptFile()
    let reader = TranscriptReader(url: file.url, format: .claude)
    let cut = claudeAssistant.index(claudeAssistant.startIndex, offsetBy: 37)
    try file.append(claudeUser + "\n" + String(claudeAssistant[..<cut]))
    #expect(try reader.readAvailable().messages.map(\.id) == ["u1"])
    #expect(reader.consumedOffset == UInt64(claudeUser.utf8.count + 1))
    #expect(reader.readOffset > reader.consumedOffset)

    try file.append(String(claudeAssistant[cut...]))
    #expect(try reader.readAvailable().messages.isEmpty)  // still no newline

    try file.append("\n")
    let messages = try reader.readAvailable().messages
    #expect(messages.map(\.id) == ["a1"])
    #expect(messages.first?.blocks == [.text("hi there")])
    #expect(reader.totalBytesRead == UInt64(claudeUser.utf8.count + claudeAssistant.utf8.count + 2))
}

@Test func readerSplitsAtEveryByteOffsetIdentically() throws {
    let content = [claudeUser, claudeAssistant, claudeTool, claudeResult].joined(separator: "\n") + "\n"
    let bytes = Array(content.utf8)
    let expected = try {
        let file = try TranscriptFile()
        try file.append(content)
        return try TranscriptReader.readAll(url: file.url, format: .claude)
    }()
    for split in stride(from: 1, to: bytes.count, by: 7) {
        let file = try TranscriptFile()
        let reader = TranscriptReader(url: file.url, format: .claude)
        try Data(bytes[..<split]).write(to: file.url)
        var got = try reader.readAvailable().messages
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(bytes[split...]))
        try handle.close()
        got += try reader.readAvailable().messages
        #expect(got == expected, "split at \(split)")
    }
}

@Test func readerFallbackIDsUseByteOffsetsAndMatchFullRead() throws {
    let file = try TranscriptFile()
    let first = #"{"type":"assistant","message":{"content":"one"}}"#
    let second = #"{"type":"assistant","message":{"content":"two – ü"}}"#
    try file.append(first + "\n")
    let reader = TranscriptReader(url: file.url, format: .claude)
    let a = try reader.readAvailable().messages
    try file.append(second + "\r\n")
    let b = try reader.readAvailable().messages
    #expect(a.first?.id == transcriptFallbackID(path: file.url.path, byteOffset: 0))
    #expect(b.first?.id == transcriptFallbackID(path: file.url.path, byteOffset: UInt64(first.utf8.count + 1)))
    #expect(b.first?.blocks == [.text("two – ü")])
    #expect(try TranscriptReader.readAll(url: file.url, format: .claude) == a + b)
    #expect(transcriptFallbackID(path: "/p", byteOffset: 42) == "/p:0000000000000042")
}

@Test func readerTrailingLineIsDecodedButStillHeld() throws {
    let file = try TranscriptFile()
    try file.append(claudeUser)
    let reader = TranscriptReader(url: file.url, format: .claude)
    #expect(try reader.readAvailable().messages.isEmpty)
    #expect(try reader.readAvailable(includeTrailingLine: true).messages.map(\.id) == ["u1"])
    try file.append("\n")
    #expect(try reader.readAvailable().messages.map(\.id) == ["u1"])
    var log = TranscriptLog()
    log.apply([TranscriptMessage(id: "u1", role: .user, blocks: [.text("hello")])])
    log.apply(try TranscriptReader.readAll(url: file.url, format: .claude))
    #expect(log.messages.count == 1)
}

@Test func readerResetsWhenFileIsTruncatedOrReplaced() throws {
    let file = try TranscriptFile()
    try file.append(claudeUser + "\n" + claudeAssistant + "\n")
    let reader = TranscriptReader(url: file.url, format: .claude)
    #expect(try reader.readAvailable().messages.count == 2)

    try Data((claudeTool + "\n").utf8).write(to: file.url, options: .atomic)  // new inode
    let replaced = try reader.readAvailable()
    #expect(replaced.didReset)
    #expect(replaced.messages.map(\.id) == ["a2"])

    let handle = try FileHandle(forWritingTo: file.url)
    try handle.truncate(atOffset: 0)
    try handle.close()
    try file.append(String(claudeResult.prefix(10)))
    let truncated = try reader.readAvailable()
    #expect(truncated.didReset)
    #expect(truncated.messages.isEmpty)
}

@Test func readerSkipsOversizeLinesAndKeepsGoing() throws {
    let file = try TranscriptFile()
    let big = #"{"type":"assistant","uuid":"big","message":{"content":""# + String(repeating: "x", count: 4000) + #""}}"#
    let reader = TranscriptReader(url: file.url, format: .claude, maxRecordBytes: 1024)
    try file.append(claudeUser + "\n" + String(big.prefix(2000)))
    #expect(try reader.readAvailable().messages.map(\.id) == ["u1"])
    try file.append(String(big.dropFirst(2000)) + "\n" + claudeAssistant + "\n")
    #expect(try reader.readAvailable().messages.map(\.id) == ["a1"])
    #expect(reader.oversizeLinesSkipped == 1)
}

@Test func readerToleratesGarbageAndInvalidUTF8Lines() throws {
    let file = try TranscriptFile()
    var data = Data((claudeUser + "\n{broken\n").utf8)
    data.append(contentsOf: [0xFF, 0xFE, 0x0A])
    data.append(Data((claudeAssistant + "\n").utf8))
    try data.write(to: file.url)
    #expect(try TranscriptReader.readAll(url: file.url, format: .claude).map(\.id) == ["u1", "a1"])
}

@Test func logDropsCodexDoubleRecordingAndUpsertsByID() throws {
    let file = try TranscriptFile()
    try file.append([
        #"{"type":"session_meta","payload":{"id":"s"}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add a test"}]}}"#,
        #"{"type":"event_msg","payload":{"type":"user_message","message":"Add a test"}}"#,
        #"{"type":"response_item","payload":{"type":"function_call","name":"shell","call_id":"c1","arguments":"{}"}}"#,
        #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"ok"}}"#,
        #"{"type":"event_msg","payload":{"type":"agent_message","message":"Done."}}"#,
        #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done."}]}}"#,
    ].joined(separator: "\n") + "\n")
    let log = TranscriptLog(try TranscriptReader.readAll(url: file.url, format: .codex))
    #expect(log.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
    #expect(log.messages.last?.plainText == "Done.")

    var replay = log
    replay.apply(TranscriptReadResult(messages: [], didReset: true))
    #expect(replay.messages.isEmpty)
}
