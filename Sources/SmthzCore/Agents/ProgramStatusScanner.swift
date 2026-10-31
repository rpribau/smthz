import Foundation

// Program Status Protocol (OSC 7501): a program reports idle/working/blocked/done/error for itself
// (root record) or for ids beneath it. Port of Orca `src/shared/program-status/protocol.ts`,
// `osc-scanner.ts` and `query-responder.ts` (reference 1.4.238).

public enum ProgramStatusState: String, Codable, Sendable, CaseIterable {
    case idle, working, done, blocked, error
}

public enum ProgramStatusKind: String, Codable, Sendable, CaseIterable {
    case permission, question, auth
}

public struct ProgramStatusReport: Equatable, Sendable {
    /// Nil addresses the root record.
    public var id: String?
    /// Nil means `state=clear`.
    public var state: ProgramStatusState?
    public var kind: ProgramStatusKind?
    public var progress: Int?
    public var app: String?
    public var title: String?
    public var msg: String?

    public init(
        id: String? = nil, state: ProgramStatusState?, kind: ProgramStatusKind? = nil,
        progress: Int? = nil, app: String? = nil, title: String? = nil, msg: String? = nil
    ) {
        self.id = id
        self.state = state
        self.kind = kind
        self.progress = progress
        self.app = app
        self.title = title
        self.msg = msg
    }

    public var isClear: Bool { state == nil }
}

public enum ProgramStatusMessage: Equatable, Sendable {
    case query
    case report(ProgramStatusReport)
}

/// Everything in a PTY stream that touches OSC 7501 records, in byte order. `offset` is the index in
/// the chunk just past the sequence (0 when it ended inside carried bytes).
public enum ProgramStatusStreamEvent: Equatable, Sendable {
    case query(offset: Int)
    case report(ProgramStatusReport, offset: Int)
    /// OSC 133;A: a new shell prompt ends the program's live records.
    case promptStart(offset: Int)
    /// RIS (`ESC c`): every record goes.
    case fullReset(offset: Int)
}

public enum ProgramStatusProtocol {
    public static let oscPrefix: [UInt8] = Array("\u{1b}]7501;".utf8)
    /// The only bytes a supporting terminal ever writes back (`protocol.ts` PROGRAM_STATUS_QUERY_REPLY).
    public static let queryReply =
        "\u{1b}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{1b}\\"
    public static var queryReplyBytes: [UInt8] { Array(queryReply.utf8) }
    /// Whole sequence cap, OSC through ST.
    public static let maxSequenceBytes = 4096

    static let maxKeyBytes = 16
    static let maxMsgEncoded = 2732
    static let maxMsgDecoded = 2048
    static let maxTitleEncoded = 256
    static let maxTitleDecoded = 192
    static let maxIDLength = 128
    static let maxIDDepth = 8
    static let maxAppBytes = 32

    public static func isQueryBody(_ body: String) -> Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines) == "?"
    }

    /// Parse the body between `OSC 7501;` and ST. Nil means ignore (no state, bad id, over a limit).
    public static func parseBody(_ body: String) -> ProgramStatusMessage? {
        if body.utf8.count > maxSequenceBytes { return nil }
        if isQueryBody(body) { return .query }
        var pairs: [String: String] = [:]
        var msg: String?
        var title: String?
        for pair in body.split(separator: ":", omittingEmptySubsequences: false) {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = pair[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            // A hard cap broken anywhere voids the report, even if a duplicate follows.
            if key.utf8.count > maxKeyBytes
                || (key == "app" && value.utf8.count > maxAppBytes)
                || (key == "id" && !isValidID(value)) {
                return nil
            }
            // Malformed pairs are skipped; the rest of the report still applies.
            guard isKey(key), isValue(value) else { continue }
            if key == "msg" || key == "title" {
                let limits = key == "msg" ? (maxMsgEncoded, maxMsgDecoded) : (maxTitleEncoded, maxTitleDecoded)
                guard let text = decodeText(value, maxEncoded: limits.0, maxDecoded: limits.1) else { return nil }
                if key == "msg" { msg = text } else { title = text }
                continue
            }
            pairs[key] = value
        }
        guard let rawState = pairs["state"] else { return nil }
        let state: ProgramStatusState?
        if rawState == "clear" {
            state = nil
        } else if let parsed = ProgramStatusState(rawValue: rawState) {
            state = parsed
        } else {
            return nil
        }
        var report = ProgramStatusReport(id: pairs["id"], state: state)
        if state == .blocked, let raw = pairs["kind"], let kind = ProgramStatusKind(rawValue: raw) {
            report.kind = kind
        }
        if state == .working || state == .blocked, let raw = pairs["progress"],
           (1...3).contains(raw.count), raw.allSatisfy({ $0.isASCII && $0.isNumber }),
           let value = Int(raw), value <= 100 {
            report.progress = value
        }
        if let app = pairs["app"], !app.isEmpty, app.allSatisfy(isSegmentCharacter) {
            report.app = app
        }
        if let msg, !msg.isEmpty { report.msg = msg }
        if let title, !title.isEmpty { report.title = title }
        return .report(report)
    }

    private static func isKey(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { $0.value >= 0x61 && $0.value <= 0x7a }
    }

    private static func isValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            guard scalar.isASCII else { return false }
            let c = Character(scalar)
            return c.isLetter || c.isNumber || "_.,+/=-".contains(c)
        }
    }

    private static func isSegmentCharacter(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber || "_.+-".contains(c))
    }

    private static func isValidID(_ id: String) -> Bool {
        if id.count > maxIDLength { return false }
        let segments = id.split(separator: "/", omittingEmptySubsequences: false)
        return segments.count <= maxIDDepth
            && segments.allSatisfy { (1...32).contains($0.count) && $0.allSatisfy(isSegmentCharacter) }
    }

    /// Decoded single-line text, or nil when the report must be discarded whole.
    private static func decodeText(_ encoded: String, maxEncoded: Int, maxDecoded: Int) -> String? {
        // The encoded cap bounds the work a hostile program can cause.
        guard encoded.utf8.count <= maxEncoded, isBase64(encoded) else { return nil }
        var unpadded = Substring(encoded)
        while unpadded.hasSuffix("=") { unpadded = unpadded.dropLast() }
        if unpadded.count % 4 == 1 { return nil }
        let padded = String(unpadded) + String(repeating: "=", count: (4 - unpadded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), data.count <= maxDecoded,
              let text = String(validating: data, as: UTF8.self) else { return nil }
        let hasControl = text.unicodeScalars.contains { $0.value <= 0x1f || (0x7f...0x9f).contains($0.value) }
        return hasControl ? nil : text
    }

    private static func isBase64(_ value: String) -> Bool {
        var seenPadding = 0
        for scalar in value.unicodeScalars {
            if scalar == "=" {
                seenPadding += 1
                if seenPadding > 2 { return false }
                continue
            }
            if seenPadding > 0 { return false }
            guard scalar.isASCII else { return false }
            let c = Character(scalar)
            guard c.isLetter || c.isNumber || c == "+" || c == "/" else { return false }
        }
        return true
    }
}

/// Result of scanning one PTY output chunk.
public struct ProgramStatusScanResult: Equatable, Sendable {
    public var events: [ProgramStatusStreamEvent]
    /// Bytes to write into the PTY's input (the query reply), or nil. Always nil while replaying.
    public var reply: [UInt8]?

    public var queryDetected: Bool {
        events.contains { if case .query = $0 { true } else { false } }
    }

    public var reports: [ProgramStatusReport] {
        events.compactMap { if case let .report(report, _) = $0 { report } else { nil } }
    }
}

/// Stateful OSC 7501 scanner for one PTY stream. It never strips anything from the stream; sequences
/// split across chunks are carried (bounded by the 4096-byte sequence cap).
public struct ProgramStatusScanner: Sendable {
    private static let esc: UInt8 = 0x1b
    private static let promptStartMarker: [UInt8] = Array("\u{1b}]133;A".utf8)
    private static let fullResetMarker: [UInt8] = [0x1b, 0x63]
    private static let markers: [[UInt8]] = [ProgramStatusProtocol.oscPrefix, promptStartMarker, fullResetMarker]
    /// Carry window for a partial marker. Orca uses the 7-byte 7501 prefix, which drops an
    /// `ESC]133;A` split right before the `A`; the longest marker (8 bytes) keeps it.
    private static let carryWindow = markers.map(\.count).max()!
    private static let maxBodyLength =
        ProgramStatusProtocol.maxSequenceBytes - ProgramStatusProtocol.oscPrefix.count - 1
    /// Bounds the `;key=value` options a prompt-start mark may carry before its terminator.
    private static let maxPromptStartOptionsLength = 512

    private var pending: [UInt8] = []

    public init() {}

    /// Bytes currently carried from an unterminated sequence (for tests and diagnostics).
    public var carriedByteCount: Int { pending.count }

    /// Scans one chunk. `replaying` is true while feeding restored bytes (`session.replay`): queries
    /// are still reported but answer no one, so no reply is produced (Orca `shouldReply`).
    public mutating func scan<C: Collection>(_ chunk: C, replaying: Bool = false) -> ProgramStatusScanResult
    where C.Element == UInt8 {
        let events = scanEvents(Array(chunk))
        let query = events.contains { if case .query = $0 { true } else { false } }
        return ProgramStatusScanResult(
            events: events,
            reply: query && !replaying ? ProgramStatusProtocol.queryReplyBytes : nil)
    }

    private mutating func scanEvents(_ data: [UInt8]) -> [ProgramStatusStreamEvent] {
        if pending.isEmpty && !data.contains(Self.esc) { return [] }
        if pending.isEmpty && !Self.markers.contains(where: { Self.contains(data, $0) }) {
            pending = Self.markerPrefixCarry(data[...])
            return []
        }
        let carried = pending.count
        let combined = pending + data
        pending = []
        var events: [ProgramStatusStreamEvent] = []
        func offsetOf(_ end: Int) -> Int { max(0, end - carried) }
        var cursor = 0
        while cursor < combined.count {
            guard let esc = combined[cursor...].firstIndex(of: Self.esc) else { break }
            if Self.hasPrefix(combined, Self.fullResetMarker, at: esc) {
                cursor = esc + Self.fullResetMarker.count
                events.append(.fullReset(offset: offsetOf(cursor)))
                continue
            }
            if Self.hasPrefix(combined, Self.promptStartMarker, at: esc) {
                let afterMark = esc + Self.promptStartMarker.count
                let next: UInt8? = afterMark < combined.count ? combined[afterMark] : nil
                // The whole frame: `133;AB` is another mark, and a split frame must not end the program early.
                let isPromptStart = next == 0x07 || next == 0x1b || next == 0x3b
                let terminator = isPromptStart
                    ? Self.findTerminator(combined, from: afterMark, limit: afterMark + Self.maxPromptStartOptionsLength)
                    : nil
                if let terminator {
                    cursor = terminator.index + terminator.length
                    if !terminator.aborted { events.append(.promptStart(offset: offsetOf(cursor))) }
                    continue
                }
                if (next == nil || isPromptStart)
                    && combined.count - afterMark < Self.maxPromptStartOptionsLength {
                    pending = Array(combined[esc...])
                    break
                }
                cursor = afterMark
                continue
            }
            if !Self.hasPrefix(combined, ProgramStatusProtocol.oscPrefix, at: esc) {
                if combined.count - esc < Self.carryWindow {
                    pending = Self.markerPrefixCarry(combined[esc...])
                    if !pending.isEmpty { break }
                }
                cursor = esc + 1
                continue
            }
            let bodyStart = esc + ProgramStatusProtocol.oscPrefix.count
            guard let terminator = Self.findTerminator(
                combined, from: bodyStart, limit: bodyStart + Self.maxBodyLength + 1)
            else {
                if combined.count - bodyStart <= Self.maxBodyLength {
                    pending = Array(combined[esc...])
                    break
                }
                // Over the sequence cap: discard whole and resume after the introducer.
                cursor = bodyStart
                continue
            }
            cursor = terminator.index + terminator.length
            guard !terminator.aborted else { continue }
            let body = String(decoding: combined[bodyStart..<terminator.index], as: UTF8.self)
            switch ProgramStatusProtocol.parseBody(body) {
            case .query: events.append(.query(offset: offsetOf(cursor)))
            case let .report(report): events.append(.report(report, offset: offsetOf(cursor)))
            case nil: break
            }
        }
        return events
    }

    private struct FrameEnd {
        var index: Int
        var length: Int
        var aborted = false
    }

    /// BEL, ST or (as xterm does) an unconsumed non-ST ESC; `aborted` by CAN/SUB; nil while completable.
    private static func findTerminator(_ data: [UInt8], from: Int, limit: Int) -> FrameEnd? {
        let end = min(limit, data.count)
        var index = from
        while index < end {
            switch data[index] {
            case 0x07: return FrameEnd(index: index, length: 1)
            case 0x18, 0x1a: return FrameEnd(index: index, length: 1, aborted: true)
            case 0x1b where index + 1 < data.count:
                return FrameEnd(index: index, length: data[index + 1] == 0x5c ? 2 : 0)
            default: index += 1
            }
        }
        return nil
    }

    /// Longest suffix of `data` that could still grow into a marker.
    private static func markerPrefixCarry(_ data: ArraySlice<UInt8>) -> [UInt8] {
        guard let lastEsc = data.lastIndex(of: esc),
              data.endIndex - lastEsc < carryWindow else { return [] }
        let suffix = Array(data[lastEsc...])
        return markers.contains { $0.count > suffix.count && $0.starts(with: suffix) } ? suffix : []
    }

    private static func hasPrefix(_ data: [UInt8], _ marker: [UInt8], at index: Int) -> Bool {
        guard index + marker.count <= data.count else { return false }
        for offset in 0..<marker.count where data[index + offset] != marker[offset] { return false }
        return true
    }

    private static func contains(_ data: [UInt8], _ marker: [UInt8]) -> Bool {
        guard data.count >= marker.count else { return false }
        var index = 0
        while let esc = data[index...].firstIndex(of: marker[0]) {
            if hasPrefix(data, marker, at: esc) { return true }
            index = esc + 1
            if index >= data.count { break }
        }
        return false
    }
}
