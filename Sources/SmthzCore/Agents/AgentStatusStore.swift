import Foundation

// Agent status per host session from two channels: managed hooks and OSC 7501 reports. Hooks win;
// OSC 7501 fills in when hooks are absent, or silent for 2 minutes on a state the program has left.
// Ports Orca `src/main/agent-hooks/server/program-status/hook-precedence.ts` and
// `src/shared/program-status/records.ts` (reference 1.4.238).

public enum AgentBlockKind: String, Codable, Sendable, CaseIterable {
    case permission, question, auth
}

public enum AgentStatusState: Hashable, Codable, Sendable {
    case idle
    case working
    /// Nil kind: the program reported `blocked` without saying why.
    case blocked(AgentBlockKind?)
    case done
    case error

    public init(_ state: ProgramStatusState, kind: ProgramStatusKind? = nil) {
        switch state {
        case .idle: self = .idle
        case .working: self = .working
        case .done: self = .done
        case .error: self = .error
        case .blocked: self = .blocked(kind.flatMap { AgentBlockKind(rawValue: $0.rawValue) })
        }
    }

    /// Stable wire name (`blocked` drops the kind; see `blockKind`).
    public var name: String {
        switch self {
        case .idle: "idle"
        case .working: "working"
        case .blocked: "blocked"
        case .done: "done"
        case .error: "error"
        }
    }

    public var blockKind: AgentBlockKind? {
        if case let .blocked(kind) = self { kind } else { nil }
    }

    /// done/error outlive the program that reported them, so the user still finds the result.
    public var outlivesProgram: Bool { self == .done || self == .error }

    /// Compared without the blocked kind, as Orca compares OSC and hook states.
    func sameState(as other: AgentStatusState) -> Bool { name == other.name }
}

public enum AgentStatusSource: String, Codable, Sendable {
    case hook
    case programStatus
}

public struct AgentStatusRow: Equatable, Sendable {
    public var sessionID: String
    public var state: AgentStatusState
    public var source: AgentStatusSource
    public var updatedAt: Date
    /// Hook family, when a hook ever reported for the session.
    public var agent: AgentHookSource?
    /// OSC 7501 `app`, when the program reported one.
    public var app: String?
    public var lastEventName: String?
    public var toolName: String?
    public var toolInputPreview: String?
    public var prompt: String?
    public var providerSessionID: String?
    public var transcriptPath: String?
    public var title: String?
    public var message: String?
    public var progress: Int?
}

/// One session's OSC 7501 records (Orca `ProgramStatusRecordSet`), LRU-capped.
struct ProgramStatusRecordSet: Sendable {
    static let maxRecords = 256
    private static let rootKey = ""

    private var records: [String: ProgramStatusReport] = [:]
    /// Least recently updated first.
    private var order: [String] = []
    private(set) var updatedAt: Date?

    var isEmpty: Bool { records.isEmpty }
    var root: ProgramStatusReport? { records[Self.rootKey] }

    mutating func apply(_ report: ProgramStatusReport, at date: Date) {
        let key = report.id ?? Self.rootKey
        updatedAt = date
        guard report.state != nil else {
            if report.id == nil { reset(at: date); return }
            for existing in order where existing != Self.rootKey
                && (existing == key || existing.hasPrefix(key + "/")) {
                remove(existing)
            }
            return
        }
        // Each report replaces its record whole.
        remove(key)
        if records.count >= Self.maxRecords, let oldest = order.first { remove(oldest) }
        records[key] = report
        order.append(key)
    }

    /// The program ended (OSC 133;A or process exit): only done/error records stay.
    mutating func endProgram(at date: Date) {
        for key in order {
            if let state = records[key]?.state, state != .done, state != .error {
                remove(key)
                updatedAt = date
            }
        }
    }

    mutating func reset(at date: Date) {
        if !records.isEmpty { updatedAt = date }
        records.removeAll()
        order.removeAll()
    }

    private mutating func remove(_ key: String) {
        if records.removeValue(forKey: key) != nil { order.removeAll { $0 == key } }
    }
}

public struct AgentStatusStore: Sendable {
    /// Hook silence, while OSC 7501 disagrees, before OSC 7501 takes the row. Minutes because a long
    /// tool call sends no hooks but leaves the program's state unchanged.
    public static let hookSilenceBeforeProgramStatusFallback: TimeInterval = 2 * 60

    struct HookRecord: Sendable {
        var agent: AgentHookSource
        var state: AgentStatusState?
        var receivedAt: Date
        var stateAt: Date
        var lastEventName: String
        var toolName: String?
        var toolInputPreview: String?
        var prompt: String?
        var providerSessionID: String?
        var transcriptPath: String?
    }

    struct SessionEntry: Sendable {
        var hook: HookRecord?
        var programStatus = ProgramStatusRecordSet()
    }

    private var sessions: [String: SessionEntry] = [:]

    public init() {}

    public var sessionIDs: [String] { sessions.keys.sorted() }

    /// Records a hook event. Events that imply no state still refresh metadata and liveness.
    public mutating func applyHook(_ payload: AgentHookPayload, sessionID: String, at date: Date = Date()) {
        var entry = sessions[sessionID] ?? SessionEntry()
        var record = entry.hook ?? HookRecord(
            agent: payload.source, state: nil, receivedAt: date, stateAt: date, lastEventName: payload.eventName)
        if record.agent != payload.source {
            // Another agent family took the pane: drop the previous one's details.
            record = HookRecord(
                agent: payload.source, state: nil, receivedAt: date, stateAt: date, lastEventName: payload.eventName)
        }
        record.receivedAt = date
        record.lastEventName = payload.eventName
        if let state = payload.impliedState {
            record.state = state
            record.stateAt = date
        }
        if payload.childAgentID == nil {
            if payload.event == .userPromptSubmit {
                record.prompt = payload.prompt
                record.toolName = nil
                record.toolInputPreview = nil
            } else if payload.event == .sessionStart, payload.impliedState != nil {
                record.prompt = nil
                record.toolName = nil
                record.toolInputPreview = nil
            }
            if payload.event?.isToolEvent == true, let tool = payload.toolName {
                record.toolName = tool
                record.toolInputPreview = payload.toolInputPreview
            }
        }
        if let id = payload.providerSessionID { record.providerSessionID = id }
        if let path = payload.transcriptPath { record.transcriptPath = path }
        entry.hook = record
        sessions[sessionID] = entry
    }

    /// Applies scanner events for a session in stream order.
    public mutating func applyProgramStatus(
        _ events: [ProgramStatusStreamEvent], sessionID: String, at date: Date = Date()
    ) {
        var entry = sessions[sessionID] ?? SessionEntry()
        for event in events {
            switch event {
            case let .report(report, _): entry.programStatus.apply(report, at: date)
            case .promptStart: entry.programStatus.endProgram(at: date)
            case .fullReset: entry.programStatus.reset(at: date)
            case .query: break
            }
        }
        if entry.hook == nil && entry.programStatus.isEmpty {
            sessions.removeValue(forKey: sessionID)
        } else {
            sessions[sessionID] = entry
        }
    }

    /// The session's process exited: live states end; done/error stay so the user finds the result.
    public mutating func sessionExited(_ sessionID: String, at date: Date = Date()) {
        guard var entry = sessions[sessionID] else { return }
        entry.programStatus.endProgram(at: date)
        if var hook = entry.hook, let state = hook.state, !state.outlivesProgram {
            hook.state = .idle
            hook.stateAt = date
            entry.hook = hook
        }
        sessions[sessionID] = entry
    }

    public mutating func remove(_ sessionID: String) {
        sessions.removeValue(forKey: sessionID)
    }

    public func status(_ sessionID: String, now: Date = Date()) -> AgentStatusRow? {
        guard let entry = sessions[sessionID] else { return nil }
        let hookRow = entry.hook.flatMap { hook in hook.state.map { (hook, $0) } }
        let osc = entry.programStatus.root.flatMap { report in report.state.map { (report, $0) } }
        if let (hook, state) = hookRow {
            if let (report, oscState) = osc,
               !Self.programStatusYields(hook: hook, hookState: state, report: report,
                                         oscState: AgentStatusState(oscState, kind: report.kind), now: now) {
                return row(sessionID, entry: entry, oscReport: report, oscState: oscState)
            }
            return AgentStatusRow(
                sessionID: sessionID, state: state, source: .hook, updatedAt: hook.stateAt,
                agent: hook.agent, app: entry.programStatus.root?.app, lastEventName: hook.lastEventName,
                toolName: hook.toolName, toolInputPreview: hook.toolInputPreview, prompt: hook.prompt,
                providerSessionID: hook.providerSessionID, transcriptPath: hook.transcriptPath)
        }
        if let (report, oscState) = osc {
            return row(sessionID, entry: entry, oscReport: report, oscState: oscState)
        }
        return nil
    }

    public func rows(now: Date = Date()) -> [AgentStatusRow] {
        sessionIDs.compactMap { status($0, now: now) }
    }

    private func row(
        _ sessionID: String, entry: SessionEntry, oscReport: ProgramStatusReport, oscState: ProgramStatusState
    ) -> AgentStatusRow {
        let hook = entry.hook
        return AgentStatusRow(
            sessionID: sessionID, state: AgentStatusState(oscState, kind: oscReport.kind),
            source: .programStatus, updatedAt: entry.programStatus.updatedAt ?? Date.distantPast,
            agent: hook?.agent, app: oscReport.app, lastEventName: hook?.lastEventName,
            toolName: hook?.toolName, toolInputPreview: hook?.toolInputPreview, prompt: hook?.prompt,
            providerSessionID: hook?.providerSessionID, transcriptPath: hook?.transcriptPath,
            title: oscReport.title, message: oscReport.msg, progress: oscReport.progress)
    }

    /// Whether an OSC 7501 report must leave the hook row alone (Orca `programStatusYieldsToHookRow`).
    static func programStatusYields(
        hook: HookRecord, hookState: AgentStatusState, report: ProgramStatusReport,
        oscState: AgentStatusState, now: Date
    ) -> Bool {
        // A different app after the hook agent finished is a new program in the pane. Mid-turn the
        // hook row still wins over another app id (forks report upstream's app).
        if let app = report.app, !appMatches(app, agent: hook.agent), hookState == .done {
            return false
        }
        return oscState.sameState(as: hookState)
            || now.timeIntervalSince(hook.receivedAt) < hookSilenceBeforeProgramStatusFallback
    }

    static func appMatches(_ app: String, agent: AgentHookSource) -> Bool {
        let normalized = app.lowercased()
        switch agent {
        case .claude: return normalized == "claude" || normalized == "claude-code" || normalized.hasPrefix("claude")
        case .codex: return normalized.hasPrefix("codex")
        }
    }
}
