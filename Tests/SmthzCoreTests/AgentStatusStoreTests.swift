import Foundation
import Testing
@testable import SmthzCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func hook(_ event: String, _ source: AgentHookSource = .claude, tool: String? = nil,
                  prompt: String? = nil, sessionSource: String? = "startup",
                  transcript: String? = nil) -> AgentHookPayload {
    AgentHookPayload(
        source: source, eventName: event, providerSessionID: "p1", transcriptPath: transcript,
        toolName: tool, toolInputPreview: tool.map { "\($0) input" }, prompt: prompt,
        sessionSource: sessionSource)
}

private func osc(_ state: ProgramStatusState?, kind: ProgramStatusKind? = nil, app: String? = nil,
                 id: String? = nil) -> [ProgramStatusStreamEvent] {
    [.report(ProgramStatusReport(id: id, state: state, kind: kind, app: app), offset: 0)]
}

private enum Step {
    case hook(AgentHookPayload, at: TimeInterval)
    case osc([ProgramStatusStreamEvent], at: TimeInterval)
    case exited(at: TimeInterval)
}

private func run(_ steps: [Step], expectAt now: TimeInterval) -> AgentStatusRow? {
    var store = AgentStatusStore()
    for step in steps {
        switch step {
        case let .hook(p, at): store.applyHook(p, sessionID: "s", at: t0 + at)
        case let .osc(events, at): store.applyProgramStatus(events, sessionID: "s", at: t0 + at)
        case let .exited(at): store.sessionExited("s", at: t0 + at)
        }
    }
    return store.status("s", now: t0 + now)
}

@Test func statusStoreTransitionTable() {
    typealias Row = (name: String, steps: [Step], now: TimeInterval, state: AgentStatusState?, source: AgentStatusSource?)
    let rows: [Row] = [
        ("empty", [], 0, nil, nil),
        ("hook start", [.hook(hook("SessionStart"), at: 0)], 0, .idle, .hook),
        ("hook prompt", [.hook(hook("SessionStart"), at: 0), .hook(hook("UserPromptSubmit"), at: 1)], 1, .working, .hook),
        ("hook permission", [.hook(hook("UserPromptSubmit"), at: 0), .hook(hook("PermissionRequest", tool: "Bash"), at: 1)],
         1, .blocked(.permission), .hook),
        ("hook stop", [.hook(hook("UserPromptSubmit"), at: 0), .hook(hook("Stop"), at: 5)], 5, .done, .hook),
        ("hook failure", [.hook(hook("UserPromptSubmit"), at: 0), .hook(hook("StopFailure"), at: 5)], 5, .error, .hook),
        ("metadata-only event keeps state",
         [.hook(hook("UserPromptSubmit"), at: 0), .hook(hook("SubagentStart"), at: 1)], 1, .working, .hook),
        ("metadata-only first event has no row", [.hook(hook("SubagentStart"), at: 0)], 0, nil, nil),
        ("osc only", [.osc(osc(.working), at: 0)], 0, .working, .programStatus),
        ("osc blocked kind", [.osc(osc(.blocked, kind: .auth), at: 0)], 0, .blocked(.auth), .programStatus),
        ("osc blocked without kind", [.osc(osc(.blocked), at: 0)], 0, .blocked(nil), .programStatus),
        ("osc clear", [.osc(osc(.working), at: 0), .osc(osc(nil), at: 1)], 1, nil, nil),
        ("osc child record does not set root", [.osc(osc(.working, id: "a"), at: 0)], 0, nil, nil),
        ("hook beats disagreeing fresh osc",
         [.hook(hook("UserPromptSubmit"), at: 0), .osc(osc(.done), at: 10)], 10, .working, .hook),
        ("hook beats osc just under 2 minutes",
         [.hook(hook("UserPromptSubmit"), at: 0), .osc(osc(.done), at: 100)], 119.9, .working, .hook),
        ("osc takes over after 2 minutes of hook silence",
         [.hook(hook("UserPromptSubmit"), at: 0), .osc(osc(.done), at: 100)], 120, .done, .programStatus),
        ("agreeing osc never displaces hook",
         [.hook(hook("UserPromptSubmit"), at: 0), .osc(osc(.working), at: 1)], 600, .working, .hook),
        ("later hook takes the row back",
         [.hook(hook("UserPromptSubmit"), at: 0), .osc(osc(.done), at: 100), .hook(hook("PreToolUse", tool: "Bash"), at: 200)],
         200, .working, .hook),
        ("metadata hook refreshes liveness",
         [.hook(hook("UserPromptSubmit"), at: 0), .osc(osc(.done), at: 100), .hook(hook("SubagentStop"), at: 110)],
         200, .working, .hook),
        ("other app after done takes the row",
         [.hook(hook("Stop"), at: 0), .osc(osc(.working, app: "pi"), at: 1)], 1, .working, .programStatus),
        ("other app mid-turn does not",
         [.hook(hook("UserPromptSubmit"), at: 0), .osc(osc(.done, app: "pi"), at: 1)], 1, .working, .hook),
        ("same app after done yields to hook",
         [.hook(hook("Stop"), at: 0), .osc(osc(.working, app: "claude-code"), at: 1)], 1, .done, .hook),
        ("prompt start ends live osc",
         [.osc(osc(.working), at: 0), .osc([.promptStart(offset: 0)], at: 1)], 1, nil, nil),
        ("prompt start keeps done osc",
         [.osc(osc(.done), at: 0), .osc([.promptStart(offset: 0)], at: 1)], 1, .done, .programStatus),
        ("full reset clears done osc",
         [.osc(osc(.done), at: 0), .osc([.fullReset(offset: 0)], at: 1)], 1, nil, nil),
        ("exit turns working hook idle",
         [.hook(hook("UserPromptSubmit"), at: 0), .exited(at: 1)], 1, .idle, .hook),
        ("exit keeps done hook",
         [.hook(hook("Stop"), at: 0), .exited(at: 1)], 1, .done, .hook),
        ("codex permission then interrupt",
         [.hook(hook("PermissionRequest", .codex), at: 0), .hook(hook("Interrupt", .codex), at: 1)], 1, .done, .hook),
    ]
    for row in rows {
        let status = run(row.steps, expectAt: row.now)
        #expect(status?.state == row.state, "\(row.name)")
        #expect(status?.source == row.source, "\(row.name)")
    }
}

@Test func statusStoreKeepsToolPromptAndTranscript() {
    var store = AgentStatusStore()
    store.applyHook(hook("SessionStart", transcript: "/t/abc.jsonl"), sessionID: "s", at: t0)
    store.applyHook(hook("UserPromptSubmit", prompt: "fix the bug"), sessionID: "s", at: t0 + 1)
    store.applyHook(hook("PreToolUse", tool: "Bash"), sessionID: "s", at: t0 + 2)
    store.applyHook(hook("Stop"), sessionID: "s", at: t0 + 3)
    let row = store.status("s", now: t0 + 3)
    #expect(row?.state == .done)
    #expect(row?.agent == .claude)
    #expect(row?.lastEventName == "Stop")
    #expect(row?.prompt == "fix the bug")
    #expect(row?.toolName == "Bash")
    #expect(row?.toolInputPreview == "Bash input")
    #expect(row?.transcriptPath == "/t/abc.jsonl")
    #expect(row?.providerSessionID == "p1")
    #expect(row?.updatedAt == t0 + 3)

    // A new prompt clears the previous tool.
    store.applyHook(hook("UserPromptSubmit", prompt: "next"), sessionID: "s", at: t0 + 4)
    #expect(store.status("s", now: t0 + 4)?.toolName == nil)
    #expect(store.status("s", now: t0 + 4)?.prompt == "next")
}

@Test func statusStoreOscRowCarriesProgressAndText() {
    var store = AgentStatusStore()
    store.applyProgramStatus(
        [.report(ProgramStatusReport(state: .working, progress: 30, app: "pi", title: "Build", msg: "step 2"), offset: 0)],
        sessionID: "a", at: t0)
    store.applyProgramStatus(osc(.idle), sessionID: "b", at: t0)
    let row = store.status("a", now: t0)
    #expect(row?.progress == 30)
    #expect(row?.app == "pi")
    #expect(row?.title == "Build")
    #expect(row?.message == "step 2")
    #expect(store.rows(now: t0).map(\.sessionID) == ["a", "b"])
    store.remove("a")
    #expect(store.status("a") == nil)
    #expect(store.sessionIDs == ["b"])
}

@Test func programStatusRecordSetCapsAndClearsSubtrees() {
    var set = ProgramStatusRecordSet()
    for index in 0..<(ProgramStatusRecordSet.maxRecords + 10) {
        set.apply(ProgramStatusReport(id: "r\(index)", state: .working), at: t0)
    }
    set.apply(ProgramStatusReport(state: .working), at: t0)
    #expect(set.root?.state == .working)
    set.apply(ProgramStatusReport(id: "a", state: .working), at: t0)
    set.apply(ProgramStatusReport(id: "a/b", state: .done), at: t0)
    set.apply(ProgramStatusReport(id: "a", state: nil), at: t0)
    #expect(set.root?.state == .working)
    set.apply(ProgramStatusReport(state: nil), at: t0)
    #expect(set.isEmpty)
}

@Test func agentStatusStateNames() {
    #expect(AgentStatusState.blocked(.question).name == "blocked")
    #expect(AgentStatusState.blocked(.question).blockKind == .question)
    #expect(AgentStatusState(.blocked, kind: .permission) == .blocked(.permission))
    #expect(AgentStatusState.done.outlivesProgram && AgentStatusState.error.outlivesProgram)
    #expect(!AgentStatusState.working.outlivesProgram)
    let encoded = try? JSONEncoder().encode(AgentStatusState.blocked(.auth))
    let decoded = encoded.flatMap { try? JSONDecoder().decode(AgentStatusState.self, from: $0) }
    #expect(decoded == .blocked(.auth))
}
