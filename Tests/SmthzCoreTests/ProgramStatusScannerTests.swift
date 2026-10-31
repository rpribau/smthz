import Foundation
import Testing
@testable import SmthzCore

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private let sampleStream =
    "hello \u{1b}[1mbold\u{1b}[0m\r\n"
    + "\u{1b}]7501;?\u{1b}\\"
    + "\u{1b}]0;title\u{07}"
    + "\u{1b}]7501;state=working:app=claude-code:progress=40\u{07}"
    + "text in between"
    + "\u{1b}]7501;state=blocked:kind=permission:title=QmFzaA==\u{1b}\\"
    + "\u{1b}]7501;id=sub/a:state=done\u{1b}\\"
    + "\u{1b}]133;A\u{07}$ "
    + "\u{1b}c"
    + "\u{1b}]7501;state=clear\u{07}"

private let expectedSample: [ProgramStatusStreamEvent] = {
    var events: [ProgramStatusStreamEvent] = []
    events.append(.query(offset: 0))
    events.append(.report(ProgramStatusReport(state: .working, progress: 40, app: "claude-code"), offset: 0))
    events.append(.report(ProgramStatusReport(state: .blocked, kind: .permission, title: "Bash"), offset: 0))
    events.append(.report(ProgramStatusReport(id: "sub/a", state: .done), offset: 0))
    events.append(.promptStart(offset: 0))
    events.append(.fullReset(offset: 0))
    events.append(.report(ProgramStatusReport(state: nil), offset: 0))
    return events
}()

/// Offsets differ per split, so compare events with offsets zeroed.
private func normalized(_ events: [ProgramStatusStreamEvent]) -> [ProgramStatusStreamEvent] {
    events.map { event in
        switch event {
        case .query: .query(offset: 0)
        case let .report(report, _): .report(report, offset: 0)
        case .promptStart: .promptStart(offset: 0)
        case .fullReset: .fullReset(offset: 0)
        }
    }
}

@Test func scannerParsesSampleStreamInOneChunk() {
    var scanner = ProgramStatusScanner()
    let result = scanner.scan(bytes(sampleStream))
    #expect(normalized(result.events) == expectedSample)
    #expect(result.queryDetected)
    #expect(result.reply == ProgramStatusProtocol.queryReplyBytes)
    #expect(scanner.carriedByteCount == 0)
}

@Test func scannerHandlesSplitAtEveryByteOffset() {
    let data = bytes(sampleStream)
    for split in 0...data.count {
        var scanner = ProgramStatusScanner()
        let first = scanner.scan(data[0..<split])
        let second = scanner.scan(data[split...])
        #expect(normalized(first.events + second.events) == expectedSample, "split at \(split)")
        #expect(scanner.carriedByteCount == 0, "split at \(split)")
    }
}

@Test func scannerHandlesByteAtATimeFeed() {
    var scanner = ProgramStatusScanner()
    var events: [ProgramStatusStreamEvent] = []
    var replies = 0
    for byte in bytes(sampleStream) {
        let result = scanner.scan([byte])
        events += result.events
        if result.reply != nil { replies += 1 }
    }
    #expect(normalized(events) == expectedSample)
    #expect(replies == 1)
}

@Test func scannerOffsetsPointPastSequenceInChunk() {
    var scanner = ProgramStatusScanner()
    let prefix = "ab"
    let seq = "\u{1b}]7501;state=idle\u{07}"
    let result = scanner.scan(bytes(prefix + seq + "cd"))
    #expect(result.events == [.report(ProgramStatusReport(state: .idle), offset: prefix.utf8.count + seq.utf8.count)])
    // A sequence completed from carried bytes reports an offset inside the new chunk.
    _ = scanner.scan(bytes("\u{1b}]7501;state=do"))
    let tail = scanner.scan(bytes("ne\u{07}xyz"))
    #expect(tail.events == [.report(ProgramStatusReport(state: .done), offset: 3)])
}

@Test func replayModeSuppressesReply() {
    var scanner = ProgramStatusScanner()
    let replay = scanner.scan(bytes("\u{1b}]7501;?\u{07}"), replaying: true)
    #expect(replay.queryDetected)
    #expect(replay.reply == nil)
    let live = scanner.scan(bytes("\u{1b}]7501; ? \u{1b}\\"))
    #expect(live.queryDetected)
    #expect(live.reply == ProgramStatusProtocol.queryReplyBytes)
}

@Test func queryReplyMatchesReferenceProtocol() {
    #expect(ProgramStatusProtocol.queryReply
        == "\u{1b}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{1b}\\")
}

@Test func scannerEnforcesSequenceCap() {
    // Body that fits exactly: 4096 - prefix(7) - terminator(1) bytes.
    let maxBody = ProgramStatusProtocol.maxSequenceBytes - ProgramStatusProtocol.oscPrefix.count - 1
    let fill = String(repeating: "x", count: maxBody - "state=working:".utf8.count)
    var scanner = ProgramStatusScanner()
    let fits = scanner.scan(bytes("\u{1b}]7501;state=working:\(fill)\u{07}"))
    #expect(fits.reports == [ProgramStatusReport(state: .working)])

    // One byte over: discarded whole, and the scanner resumes after the introducer.
    var over = ProgramStatusScanner()
    let tooLong = over.scan(bytes("\u{1b}]7501;state=working:\(fill)x\u{07}\u{1b}]7501;state=done\u{07}"))
    #expect(tooLong.reports == [ProgramStatusReport(state: .done)])

    // An unterminated sequence never carries more than the cap.
    var unterminated = ProgramStatusScanner()
    _ = unterminated.scan(bytes("\u{1b}]7501;state=working"))
    for _ in 0..<10 { _ = unterminated.scan([UInt8](repeating: 0x61, count: 1000)) }
    #expect(unterminated.carriedByteCount <= ProgramStatusProtocol.maxSequenceBytes)
    let after = unterminated.scan(bytes("\u{1b}]7501;state=idle\u{07}"))
    #expect(after.reports == [ProgramStatusReport(state: .idle)])
}

@Test func scannerAbortsOnCancelAndIgnoresOtherOSC() {
    var scanner = ProgramStatusScanner()
    let result = scanner.scan(bytes(
        "\u{1b}]7501;state=working\u{18}\u{1b}]7502;state=done\u{07}\u{1b}]133;AB\u{07}\u{1b}]7501;state=error\u{07}"))
    #expect(result.events.count == 1)
    #expect(result.reports == [ProgramStatusReport(state: .error)])
    #expect(scanner.scan(bytes("plain text, no escapes")).events.isEmpty)
}

@Test func parseBodyTable() {
    let rows: [(String, ProgramStatusMessage?)] = [
        ("?", .query),
        (" ? ", .query),
        ("state=idle", .report(ProgramStatusReport(state: .idle))),
        ("state=clear", .report(ProgramStatusReport(state: nil))),
        ("state=bogus", nil),
        ("app=x", nil),
        ("state=blocked:kind=question", .report(ProgramStatusReport(state: .blocked, kind: .question))),
        ("state=working:kind=question", .report(ProgramStatusReport(state: .working))),
        ("state=blocked:kind=nope", .report(ProgramStatusReport(state: .blocked))),
        ("state=working:progress=101", .report(ProgramStatusReport(state: .working))),
        ("state=working:progress=100", .report(ProgramStatusReport(state: .working, progress: 100))),
        ("state=done:progress=50", .report(ProgramStatusReport(state: .done))),
        ("state=idle:id=a/b.c", .report(ProgramStatusReport(id: "a/b.c", state: .idle))),
        ("state=idle:id=a//b", nil),
        ("state=idle:id=" + String(repeating: "a/", count: 8) + "a", nil),
        ("state=idle:app=" + String(repeating: "a", count: 33), nil),
        ("state=idle:Bad=1", .report(ProgramStatusReport(state: .idle))),
        ("state=idle:msg=aGVsbG8gd29ybGQ=", .report(ProgramStatusReport(state: .idle, msg: "hello world"))),
        // Decoded control characters void the report.
        ("state=idle:msg=YQph", nil),
        ("state=idle:msg=!!!", .report(ProgramStatusReport(state: .idle))),
        ("state=idle:title=a", nil),
    ]
    for (body, expected) in rows {
        #expect(ProgramStatusProtocol.parseBody(body) == expected, "body: \(body)")
    }
}
