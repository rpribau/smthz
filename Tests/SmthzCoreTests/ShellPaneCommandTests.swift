import Foundation
import Testing
@testable import SmthzCore

private struct PaneIDs: ShellIDSource {
    var n = 0
    mutating func next() -> String { n += 1; return "c3-\(n)" }
}
private let paneHost = ProcessIdentity(pid: 100, startSeconds: 10, startMicroseconds: 1)
private let paneChild = ProcessIdentity(pid: 200, startSeconds: 20, startMicroseconds: 2)
private let paneBinding = SessionBinding(hostIncarnation: paneHost, sessionID: "session", process: paneChild)
private func facts(code: Int32? = 0, signal: Int32? = nil, local: Bool = true,
                   fresh: Bool = false, restored: Bool = false, input: Bool = true,
                   output: Bool = true, connected: Bool = false, absent: Bool = false) -> ProcessExitFacts {
    ProcessExitFacts(code: code, signal: signal, spawnedFresh: fresh, restored: restored,
                     inputWritten: input, outputReceived: output, tabHadPaneAtConnect: connected,
                     local: local, attachAbsent: absent)
}
private struct PaneHarness {
    var state = ShellState.empty
    var ids = PaneIDs()
    let now = Date(timeIntervalSince1970: 100)
    var w: WorkspaceLayout { state.workspaces[.home]! }
    var tab: TabID { w.groups[w.activeGroup!]!.activeTab! }
    var pane: PaneID { w.tabs[tab]!.activePane }
    @discardableResult mutating func apply(_ command: ShellCommand) throws -> ShellEffects {
        let applied = try state.applying(command, now: now, ids: &ids).get()
        state = applied.state
        #expect(state.violations().isEmpty)
        return applied.effects
    }
    mutating func create() throws { try apply(.createTab(.home, group: nil, cwd: "/tmp/c3", title: nil)) }
}

@Test func paneExitVerdictPortsEveryOrcaTableRow() {
    let rows: [(ProcessExitFacts, Int, ExitVerdict)] = [
        (facts(), 1, .retire), (facts(local: false), 2, .retire),
        (facts(code: 1), 2, .keep),
        (facts(code: 1, local: false, fresh: true, input: false), 1, .keep),
        (facts(fresh: true, input: false), 1, .keep),
        (facts(local: false, fresh: true, input: false), 1, .keep),
        (facts(code: 1, local: false, fresh: true, input: false, output: false, connected: true), 2, .keep),
        (facts(local: false, fresh: true, input: false, output: false, connected: true), 2, .keep),
        (facts(code: 1, local: false, input: false, output: false, connected: true), 2, .keep),
        (facts(code: 1, local: false), 1, .retire),
        (facts(code: 1, local: false, fresh: true), 1, .retire),
        (facts(local: false, fresh: true), 1, .retire),
        (facts(fresh: true), 2, .retire),
        (facts(code: 1, local: false, fresh: true, input: false, output: false), 2, .retire),
        (facts(code: 1, local: false, restored: true, input: false, output: false, connected: true), 2, .retire),
        (facts(code: 1, local: false, input: false, connected: true), 2, .retire),
        (facts(code: -1, local: false), 1, .unbind),
        (facts(code: -1), 1, .unbind), (facts(absent: true), 1, .unbind)
    ]
    for (f, count, expected) in rows { #expect(exitVerdict(f, paneCount: count) == expected) }
}
@Test func paneMissingExitObservationNeverRetires() {
    for count in [1, 2] {
        for input in [false, true] {
            #expect(exitVerdict(facts(code: nil, input: input), paneCount: count) == .unbind)
            #expect(exitVerdict(facts(code: nil, signal: 0, input: input), paneCount: count) == .unbind)
        }
    }
    #expect(exitVerdict(facts(code: nil, signal: 15), paneCount: 1) == .keep)
    #expect(exitVerdict(facts(code: nil, signal: 15, local: false), paneCount: 1) == .retire)
    #expect(exitVerdict(facts(code: nil, signal: 15, absent: true), paneCount: 1) == .unbind)
}
@Test(arguments: PaneSide.allCases) func paneSplitInheritsCwdFocusesNewAndStarts(side: PaneSide) throws {
    var h = PaneHarness(); try h.create()
    let tab = h.tab, old = h.pane
    try h.apply(.bindSession(old, paneBinding))
    let effects = try h.apply(.splitPane(tab, pane: old, side: side))
    let new = h.pane
    #expect(new != old)
    #expect(h.w.panes[new]?.startupCwd == "/tmp/c3")
    #expect(h.w.panes[new]?.binding == nil)
    #expect(h.w.panes[new]?.state == .unstarted)
    #expect(effects == ShellEffects(startPanes: [new]))
    #expect(h.w.tabs[tab]?.panes == LayoutNode.leaf(old).inserting(new, beside: old, side: side))
}
@Test func paneLastCloseRefusesWithoutEffects() throws {
    var h = PaneHarness(); try h.create()
    let before = h.state
    #expect(h.state.applying(.closePane(h.tab, h.pane), ids: &h.ids) == .failure(.lastPane))
    #expect(h.state == before)
}
@Test func paneClosingExpandedPaneClearsExpansionAndStopsBoundSession() throws {
    var h = PaneHarness(); try h.create()
    let first = h.pane, tab = h.tab
    try h.apply(.splitPane(tab, pane: first, side: .right))
    let second = h.pane
    try h.apply(.bindSession(second, paneBinding))
    try h.apply(.toggleExpandPane(tab, second))
    #expect(h.w.tabs[tab]?.expandedPane == second)
    let effects = try h.apply(.closePane(tab, second))
    #expect(effects == ShellEffects(stopSessions: ["session"]))
    #expect(h.w.tabs[tab]?.expandedPane == nil)
    #expect(h.pane == first)
    #expect(h.w.tabs[tab]?.panes == .leaf(first))
}
@Test func paneFocusWrapsInVisualOrder() throws {
    var h = PaneHarness(); try h.create()
    let first = h.pane, tab = h.tab
    try h.apply(.splitPane(tab, pane: first, side: .right))
    let second = h.pane
    try h.apply(.focusNextPane(tab)); #expect(h.pane == first)
    try h.apply(.focusPreviousPane(tab)); #expect(h.pane == second)
    try h.apply(.focusPane(tab, first)); #expect(h.pane == first)
}
@Test func paneExpansionTogglesAndFollowsFocus() throws {
    var h = PaneHarness(); try h.create()
    let a = h.pane, tab = h.tab
    try h.apply(.splitPane(tab, pane: a, side: .bottom))
    let b = h.pane
    try h.apply(.toggleExpandPane(tab, a))
    try h.apply(.focusNextPane(tab))
    #expect(h.w.tabs[tab]?.expandedPane == b)
    try h.apply(.toggleExpandPane(tab, b))
    #expect(h.w.tabs[tab]?.expandedPane == nil)
}
@Test func paneRatiosValidatePathsClampAndEqualize() throws {
    var h = PaneHarness(); try h.create()
    let tab = h.tab, a = h.pane
    try h.apply(.splitPane(tab, pane: a, side: .right))
    let b = h.pane
    try h.apply(.splitPane(tab, pane: b, side: .right))
    try h.apply(.setPaneRatio(tab, path: [.second], ratio: 100))
    let tree = h.w.tabs[tab]!.panes
    #expect(tree == LayoutNode.leaf(a).inserting(b, beside: a, side: .right)!.inserting(h.pane, beside: b, side: .right)!.settingRatio(0.95, at: [.second]))
    for path: [SplitBranch] in [[.first], [.second, .first]] {
        guard case .failure(.invalid) = h.state.applying(.setPaneRatio(tab, path: path, ratio: 0.3), ids: &h.ids) else {
            Issue.record("expected invalid path"); continue
        }
    }
    guard case .failure(.invalid) = h.state.applying(.setPaneRatio(tab, path: [], ratio: .nan), ids: &h.ids) else {
        Issue.record("expected nonfinite refusal"); return
    }
    try h.apply(.equalizePanes(tab))
    #expect(h.w.tabs[tab]?.panes == tree.equalized())
}
@Test func paneRenameAndGridAreValidated() throws {
    var h = PaneHarness(); try h.create()
    let p = h.pane
    try h.apply(.renamePane(p, "  Shell \n")); #expect(h.w.panes[p]?.title == "Shell")
    try h.apply(.renamePane(p, " \n")); #expect(h.w.panes[p]?.title == nil)
    try h.apply(.setPaneGrid(p, cols: 120, rows: 40))
    #expect(h.w.panes[p]?.lastGrid == PaneGrid(cols: 120, rows: 40))
    for (cols, rows) in [(0, 40), (80, -1), (65536, 40)] {
        guard case .failure(.invalid) = h.state.applying(.setPaneGrid(p, cols: cols, rows: rows), ids: &h.ids) else {
            Issue.record("expected grid refusal"); continue
        }
    }
}
@Test func paneStartingAndBindingClearPendingRequest() throws {
    var h = PaneHarness(); try h.create()
    let p = h.pane, request = RequestID.generate()
    try h.apply(.paneStarting(p, requestID: request))
    #expect(h.w.panes[p]?.state == .starting)
    #expect(h.w.panes[p]?.pendingCreateRequestID == request)
    try h.apply(.paneStarting(p, requestID: request))
    try h.apply(.bindSession(p, paneBinding))
    #expect(h.w.panes[p]?.state == .live)
    #expect(h.w.panes[p]?.binding == paneBinding)
    #expect(h.w.panes[p]?.pendingCreateRequestID == nil)
    try h.apply(.bindSession(p, paneBinding))
}
@Test func paneStartingCannotReplaceLiveBinding() throws {
    var h = PaneHarness(); try h.create()
    try h.apply(.bindSession(h.pane, paneBinding))
    guard case .failure(.invalid) = h.state.applying(.paneStarting(h.pane, requestID: RequestID.generate()), ids: &h.ids) else {
        Issue.record("expected busy refusal"); return
    }
}
@Test func paneHostChangeTouchesOnlyMismatchedBindingsAcrossWorkspaces() throws {
    var h = PaneHarness(); try h.create()
    let old = h.pane
    try h.apply(.bindSession(old, paneBinding))
    let host = ProcessIdentity(pid: paneHost.pid, startSeconds: 11, startMicroseconds: 1)
    let folder = WorkspaceKey.folder("/tmp/project")
    try h.apply(.openWorkspace(folder, displayName: "Project", rootPath: "/tmp/project"))
    let live = try h.apply(.createTab(folder, group: nil, cwd: nil, title: nil)).startPanes[0]
    try h.apply(.bindSession(live, SessionBinding(hostIncarnation: host, sessionID: "new", process: paneChild)))
    try h.apply(.splitPane(h.tab, pane: old, side: .right))
    let unbound = h.pane, before = h.w.panes[unbound]
    let effects = try h.apply(.hostIncarnationChanged(host))
    #expect(effects == ShellEffects())
    #expect(h.w.panes[old]?.binding == nil)
    #expect(h.w.panes[old]?.state == .ended(reason: .hostRestarted))
    #expect(h.w.panes[unbound] == before)
    #expect(h.state.workspaces[folder]?.panes[live]?.state == .live)
}
@Test func paneAdoptionCreatesBoundTabWithoutSpawnAndIsIdempotent() throws {
    var h = PaneHarness()
    let info = SessionInfo(id: "adopt", pid: 77, startSeconds: 12, startMicroseconds: 2, running: true, cwd: "/tmp/adopt")
    let effects = try h.apply(.adoptSession(.home, info, host: paneHost))
    #expect(effects == ShellEffects())
    #expect(h.w.tabs.count == 1)
    #expect(h.w.panes[h.pane]?.binding?.sessionID == "adopt")
    #expect(h.w.panes[h.pane]?.binding?.process.pid == 77)
    #expect(h.w.panes[h.pane]?.state == .live)
    #expect(h.w.panes[h.pane]?.startupCwd == "/tmp/adopt")
    try h.apply(.adoptSession(.home, info, host: paneHost))
    #expect(h.w.tabs.count == 1)
}
@Test func paneRetiringLastPaneClosesEvenPinnedTabAndRecordsSnapshot() throws {
    var h = PaneHarness(); try h.create()
    let tab = h.tab, pane = h.pane
    try h.apply(.bindSession(pane, paneBinding))
    try h.apply(.setPinned(tab, true))
    let effects = try h.apply(.processExited(pane, facts()))
    #expect(h.w.tabs.isEmpty && h.w.panes.isEmpty)
    #expect(h.w.recentlyClosed.last?.tab.id == tab)
    #expect(effects == ShellEffects())
}
@Test func paneRetiringSplitPreservesSiblingAndClearsExpansion() throws {
    var h = PaneHarness(); try h.create()
    let first = h.pane, tab = h.tab
    try h.apply(.splitPane(tab, pane: first, side: .right))
    let second = h.pane
    try h.apply(.toggleExpandPane(tab, second))
    try h.apply(.processExited(second, facts()))
    #expect(h.w.tabs[tab]?.panes == .leaf(first))
    #expect(h.w.tabs[tab]?.expandedPane == nil)
    #expect(h.w.recentlyClosed.isEmpty)
}
@Test func paneKeptExitRetainsBindingAndRecordsStatus() throws {
    var h = PaneHarness(); try h.create()
    let p = h.pane
    try h.apply(.bindSession(p, paneBinding))
    let effects = try h.apply(.processExited(p, facts(code: 2)))
    #expect(h.w.panes[p]?.state == .exited(code: 2, signal: nil))
    #expect(h.w.panes[p]?.binding == paneBinding)
    #expect(effects == ShellEffects())
}
@Test func paneUnknownExitUnbindsWithoutClosingOrStopping() throws {
    var h = PaneHarness(); try h.create()
    let p = h.pane
    try h.apply(.bindSession(p, paneBinding))
    let effects = try h.apply(.processExited(p, facts(code: nil)))
    #expect(h.w.panes[p]?.state == .ended(reason: .sessionMissing))
    #expect(h.w.panes[p]?.binding == nil)
    #expect(h.w.tabs.count == 1)
    #expect(effects == ShellEffects())
}
@Test func paneRestartPreservesCwdAndClearsBindingAndStartToken() throws {
    var h = PaneHarness(); try h.create()
    let p = h.pane
    try h.apply(.bindSession(p, paneBinding))
    let effects = try h.apply(.restartPane(p))
    #expect(effects == ShellEffects(startPanes: [p], stopSessions: ["session"]))
    #expect(h.w.panes[p]?.state == .unstarted)
    #expect(h.w.panes[p]?.binding == nil)
    #expect(h.w.panes[p]?.startupCwd == "/tmp/c3")
    try h.apply(.paneStarting(p, requestID: RequestID.generate()))
    try h.apply(.restartPane(p))
    #expect(h.w.panes[p]?.pendingCreateRequestID == nil)
}
@Test func paneCommandsRejectMissingAndWrongTabPanes() throws {
    var h = PaneHarness(); try h.create()
    let a = h.tab, pane = h.pane
    try h.create()
    #expect(h.state.applying(.focusPane(h.tab, pane), ids: &h.ids) == .failure(.paneNotFound))
    #expect(h.state.applying(.closePane(a, h.pane), ids: &h.ids) == .failure(.paneNotFound))
    #expect(h.state.applying(.renamePane(PaneID(rawValue: "missing"), nil), ids: &h.ids) == .failure(.paneNotFound))
}
@Test func paneSeededThousandMixedCommandsPreserveInvariants() throws {
    var h = PaneHarness()
    var seed: UInt64 = 0xC3_5EED
    func random(_ bound: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 32) % UInt64(bound))
    }
    for _ in 0..<1000 {
        let tabs = h.w.tabs.keys.sorted { $0.rawValue < $1.rawValue }
        let command: ShellCommand
        if tabs.isEmpty { command = .createTab(.home, group: nil, cwd: nil, title: nil) }
        else {
            let tab = tabs[random(tabs.count)], leaves = h.w.tabs[tab]!.panes.leaves
            let pane = leaves[random(leaves.count)]
            switch random(24) {
            case 0: command = .createTab(.home, group: nil, cwd: nil, title: nil)
            case 1: command = .closeTab(tab, force: random(2) == 0)
            case 2: command = .closeOtherTabs(tab)
            case 3: command = .splitPane(tab, pane: pane, side: PaneSide.allCases[random(4)])
            case 4: command = .closePane(tab, pane)
            case 5: command = .focusPane(tab, pane)
            case 6: command = .focusNextPane(tab)
            case 7: command = .focusPreviousPane(tab)
            case 8: command = .toggleExpandPane(tab, pane)
            case 9: command = .equalizePanes(tab)
            case 10: command = .setPaneRatio(tab, path: [], ratio: Double(random(100)) / 100)
            case 11: command = .renamePane(pane, " Test ")
            case 12: command = .setPaneGrid(pane, cols: random(200), rows: random(100))
            case 13: command = .paneStarting(pane, requestID: RequestID.generate())
            case 14: command = .bindSession(pane, paneBinding)
            case 15: command = .processExited(pane, facts(code: Int32(random(3) - 1), fresh: random(2) == 0, input: random(2) == 0))
            case 16: command = .restartPane(pane)
            case 17: command = .reopenClosedTab(.home)
            case 18: command = .moveTabToSplit(tab, side: .right)
            case 19: command = .previousRecentTab(.home)
            case 20: command = .hostIncarnationChanged(paneHost)
            case 21: command = .duplicateTab(tab)
            case 22: command = .setPinned(tab, random(2) == 0)
            default: command = .closeAllTabs(.home)
            }
        }
        switch h.state.applying(command, now: h.now, ids: &h.ids) {
        case .success(let applied): h.state = applied.state
        case .failure(.invalid(let reason)):
            #expect(!reason.contains("mismatch") && !reason.contains("dangling") && !reason.contains("membership"))
        case .failure: break
        }
        #expect(h.state.violations().isEmpty)
    }
}
