import Foundation
import Testing
@testable import SmthzCore

private struct TestShellIDs: ShellIDSource {
    var value = 0
    mutating func next() -> String {
        value += 1
        return String(format: "00000000-0000-0000-0000-%012x", value)
    }
}
private struct TabHarness {
    var state = ShellState.empty
    var ids = TestShellIDs()
    let now = Date(timeIntervalSince1970: 1234)
    @discardableResult mutating func apply(_ command: ShellCommand) throws -> ShellEffects {
        let result = try state.applying(command, now: now, ids: &ids).get()
        state = result.state
        #expect(state.violations().isEmpty)
        return result.effects
    }
    var workspace: WorkspaceLayout { state.workspaces[.home]! }
    var group: GroupID { workspace.activeGroup! }
    var active: TabID { workspace.groups[group]!.activeTab! }
    var order: [TabID] { workspace.groups[group]!.tabOrder }
    @discardableResult mutating func create(cwd: String? = nil, title: String? = nil) throws -> TabID {
        try apply(.createTab(.home, group: nil, cwd: cwd, title: title))
        return active
    }
}
private let shellTabTestHostIdentity = ProcessIdentity(pid: 111, startSeconds: 100, startMicroseconds: 1)
private let shellTabTestChildIdentity = ProcessIdentity(pid: 222, startSeconds: 101, startMicroseconds: 2)

@Test func shellEmptyContainsHomeAndNoTabs() {
    let state = ShellState.empty
    #expect(state.workspaceOrder == [.home])
    #expect(state.workspaces[.home]?.tabs.isEmpty == true)
    #expect(state.violations().isEmpty)
}
@Test func shellCreatePlacesAfterActiveAndEmitsFreshPane() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create()
    try h.apply(.activateTab(a))
    let effects = try h.apply(.createTab(.home, group: nil, cwd: "/tmp", title: "new"))
    let c = h.active
    #expect(h.order == [a, c, b])
    #expect(effects.startPanes == [h.workspace.tabs[c]!.activePane])
    #expect(effects.stopSessions.isEmpty)
    #expect(h.workspace.panes[effects.startPanes[0]]?.startupCwd == "/tmp")
    #expect(h.workspace.tabs[c]?.createdAt == h.now)
}
@Test func shellDefaultTitlesRemainStableAfterRename() throws {
    var h = TabHarness()
    let a = try h.create()
    try h.apply(.renameTab(a, "Renamed"))
    let b = try h.create()
    #expect(h.workspace.tabs[a]?.defaultTitle == "Terminal 1")
    #expect(h.workspace.tabs[a]?.title == "Renamed")
    #expect(h.workspace.tabs[b]?.defaultTitle == "Terminal 2")
    try h.apply(.renameTab(a, " \n "))
    #expect(h.workspace.tabs[a]?.title == "Terminal 1")
}
@Test func shellCloseActiveChoosesMostRecentSurvivor() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create(), c = try h.create()
    try h.apply(.activateTab(a)); try h.apply(.activateTab(c))
    try h.apply(.closeTab(c, force: false))
    #expect(h.active == a)
    #expect(h.order == [a, b])
}
@Test func shellCloseActiveFallsBackToRightThenLast() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create(), c = try h.create()
    try h.apply(.activateTab(b))
    h.state.workspaces[.home]!.groups[h.group]!.recentTabIDs = []
    try h.apply(.closeTab(b, force: false))
    #expect(h.active == c)
    h.state.workspaces[.home]!.groups[h.group]!.recentTabIDs = []
    try h.apply(.closeTab(c, force: false))
    #expect(h.active == a)
}
@Test func shellClosingInactiveDoesNotChangeActive() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create()
    try h.apply(.closeTab(a, force: false))
    #expect(h.active == b)
}
@Test func shellCloseOthersPreservesPinnedAndTarget() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create(), c = try h.create()
    try h.apply(.setPinned(a, true))
    try h.apply(.closeOtherTabs(b))
    #expect(h.order == [a, b])
    #expect(h.workspace.tabs[c] == nil)
}
@Test func shellPinnedCloseRefusesUnlessForced() throws {
    var h = TabHarness()
    let a = try h.create()
    try h.apply(.setPinned(a, true))
    let prior = h.state
    #expect(h.state.applying(.closeTab(a, force: false), ids: &h.ids) == .failure(.pinnedTab))
    #expect(h.state == prior)
    try h.apply(.closeTab(a, force: true))
    #expect(h.workspace.tabs.isEmpty)
    #expect(h.workspace.groupLayout == nil)
}
@Test func shellLastTabCollapsesGroupAndActivatesSibling() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create()
    let original = h.group
    try h.apply(.moveTabToSplit(b, side: .right))
    let split = h.group
    try h.apply(.closeTab(b, force: false))
    #expect(h.workspace.groups[split] == nil)
    #expect(h.workspace.groupLayout == .leaf(original))
    #expect(h.group == original)
    #expect(h.active == a)
}
@Test func shellNestedGroupCollapseChoosesSiblingFirstLeaf() throws {
    var h = TabHarness()
    _ = try h.create()
    let b = try h.create(), c = try h.create()
    try h.apply(.moveTabToSplit(c, side: .right))
    let right = h.group
    try h.apply(.activateTab(b))
    try h.apply(.moveTabToSplit(b, side: .bottom))
    let nested = h.group
    try h.apply(.closeTab(c, force: false))
    #expect(h.workspace.groups[right] == nil)
    #expect(h.group == nested) // Closing an inactive group preserves the active group.
}
@Test(arguments: PaneSide.allCases) func shellMoveTabToSplitOnEverySide(side: PaneSide) throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create()
    let original = h.group
    let oldPane = h.workspace.tabs[b]!.activePane
    let effects = try h.apply(.moveTabToSplit(b, side: side))
    let new = h.group
    #expect(new != original)
    #expect(h.workspace.groups[original]?.tabOrder == [a])
    #expect(h.workspace.tabs[b]?.activePane == oldPane)
    let axis: SplitAxis = side == .left || side == .right ? .horizontal : .vertical
    let first = side == .left || side == .top
    #expect(h.workspace.groupLayout == .split(axis: axis, ratio: 0.5,
                                             first: .leaf(first ? new : original), second: .leaf(first ? original : new)))
    #expect(effects == ShellEffects())
}
@Test func shellSplitOnlyTabRefuses() throws {
    var h = TabHarness()
    let a = try h.create()
    guard case .failure(.invalid) = h.state.applying(.moveTabToSplit(a, side: .right), ids: &h.ids) else {
        Issue.record("expected refusal"); return
    }
}
@Test func shellMoveAcrossGroupsCollapsesEmptySource() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create()
    let original = h.group
    try h.apply(.moveTabToSplit(b, side: .right))
    let split = h.group
    let effects = try h.apply(.moveTab(b, toGroup: original, index: 0))
    #expect(h.order == [b, a])
    #expect(h.workspace.groups[split] == nil)
    #expect(h.workspace.groupLayout == .leaf(original))
    #expect(effects == ShellEffects())
}
@Test func shellMoveWithinGroupAndClampIndex() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create(), c = try h.create()
    try h.apply(.moveTab(a, toGroup: h.group, index: 999))
    #expect(h.order == [b, c, a])
    try h.apply(.moveTab(a, toGroup: h.group, index: -1))
    #expect(h.order == [a, b, c])
}
@Test func shellReopenRestoresAppearanceCwdAndPositionWithNewPane() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create(cwd: "/tmp/saved", title: "Saved"), c = try h.create()
    try h.apply(.setTabColor(b, .purple))
    let oldPane = h.workspace.tabs[b]!.activePane
    h.state.workspaces[.home]!.panes[oldPane]!.binding = SessionBinding(hostIncarnation: shellTabTestHostIdentity, sessionID: "old", process: shellTabTestChildIdentity)
    let closed = try h.apply(.closeTab(b, force: true))
    #expect(closed.stopSessions == ["old"])
    let effects = try h.apply(.reopenClosedTab(.home))
    let reopened = h.active
    let pane = h.workspace.tabs[reopened]!.activePane
    #expect(h.order == [a, reopened, c])
    #expect(reopened != b && pane != oldPane)
    #expect(h.workspace.tabs[reopened]?.title == "Saved")
    #expect(h.workspace.tabs[reopened]?.defaultTitle == "Terminal 2")
    #expect(h.workspace.tabs[reopened]?.color == .purple)
    #expect(h.workspace.panes[pane]?.startupCwd == "/tmp/saved")
    #expect(h.workspace.panes[pane]?.binding == nil)
    #expect(h.workspace.panes[pane]?.pendingCreateRequestID == nil)
    #expect(h.workspace.panes[pane]?.state == .unstarted)
    #expect(effects.startPanes == [pane])
    #expect(effects.stopSessions.isEmpty)
}
@Test func shellReopenLastTabCreatesNewGroupAndKeepsTitleCounter() throws {
    var h = TabHarness()
    let a = try h.create()
    try h.apply(.closeTab(a, force: false))
    try h.apply(.reopenClosedTab(.home))
    #expect(h.workspace.tabs[h.active]?.defaultTitle == "Terminal 1")
    let b = try h.create()
    #expect(h.workspace.tabs[b]?.defaultTitle == "Terminal 2")
}
@Test func shellCloseEmitsStopsOnlyForBoundPanes() throws {
    var h = TabHarness()
    let a = try h.create()
    let first = h.workspace.tabs[a]!.activePane
    let second = PaneID(rawValue: "extra")
    h.state.workspaces[.home]!.tabs[a]!.panes = .split(axis: .horizontal, ratio: 0.5, first: .leaf(first), second: .leaf(second))
    h.state.workspaces[.home]!.panes[second] = PaneRecord(id: second)
    h.state.workspaces[.home]!.panes[first]!.binding = SessionBinding(hostIncarnation: shellTabTestHostIdentity, sessionID: "bound", process: shellTabTestChildIdentity)
    let effects = try h.apply(.closeTab(a, force: false))
    #expect(effects.stopSessions == ["bound"])
    #expect(effects.startPanes.isEmpty)
    #expect(h.workspace.panes.isEmpty)
}
@Test func shellPreviousRecentTabFollowsMRUAndToggles() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create()
    _ = try h.create()
    try h.apply(.activateTab(a)); try h.apply(.activateTab(b))
    try h.apply(.previousRecentTab(.home))
    #expect(h.active == a)
    try h.apply(.previousRecentTab(.home))
    #expect(h.active == b)
}
@Test func shellTabNavigationWrapsAndSelectsIndex() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create()
    try h.apply(.nextTab(.home)); #expect(h.active == a)
    try h.apply(.previousTab(.home)); #expect(h.active == b)
    try h.apply(.selectTab(.home, index: 0)); #expect(h.active == a)
    guard case .failure(.invalid) = h.state.applying(.selectTab(.home, index: -1), ids: &h.ids) else {
        Issue.record("expected invalid index"); return
    }
}
@Test func shellBulkSideClosesPreservePinsAndStayWithinGroup() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create(), c = try h.create(), d = try h.create()
    try h.apply(.setPinned(a, true))
    try h.apply(.closeTabsToLeft(c))
    #expect(h.order == [a, c, d])
    #expect(h.workspace.tabs[b] == nil)
    try h.apply(.closeTabsToRight(c))
    #expect(h.order == [a, c])
    try h.apply(.closeAllTabs(.home))
    #expect(h.order == [a])
}
@Test func shellDuplicateUsesFreshShellInSameCwd() throws {
    var h = TabHarness()
    let a = try h.create(cwd: "/tmp/duplicate", title: "Original")
    let pane = h.workspace.tabs[a]!.activePane
    h.state.workspaces[.home]!.panes[pane]!.binding = SessionBinding(hostIncarnation: shellTabTestHostIdentity, sessionID: "existing", process: shellTabTestChildIdentity)
    let effects = try h.apply(.duplicateTab(a))
    let b = h.active, new = h.workspace.tabs[b]!.activePane
    #expect(h.order == [a, b])
    #expect(h.workspace.tabs[b]?.defaultTitle == "Terminal 2")
    #expect(h.workspace.panes[new]?.startupCwd == "/tmp/duplicate")
    #expect(h.workspace.panes[new]?.binding == nil)
    #expect(effects.startPanes == [new])
    #expect(effects.stopSessions.isEmpty)
}
@Test func shellClosedStackBoundedAtTen() throws {
    var h = TabHarness()
    for _ in 0..<14 { let a = try h.create(); try h.apply(.closeTab(a, force: false)) }
    #expect(h.workspace.recentlyClosed.count == 10)
    #expect(h.workspace.recentlyClosed.first?.tab.defaultTitle == "Terminal 5")
}
@Test func shellWorkspaceCommandsAndRefusals() throws {
    var h = TabHarness()
    let key = WorkspaceKey.folder("/tmp/project")
    try h.apply(.openWorkspace(key, displayName: "Project", rootPath: "/tmp/project"))
    let effects = try h.apply(.createTab(key, group: nil, cwd: nil, title: nil))
    let p = effects.startPanes[0]
    #expect(h.state.workspaces[key]?.panes[p]?.startupCwd == "/tmp/project")
    h.state.workspaces[key]!.panes[p]!.binding = SessionBinding(hostIncarnation: shellTabTestHostIdentity, sessionID: "project", process: shellTabTestChildIdentity)
    let stopped = try h.apply(.closeWorkspace(key))
    #expect(stopped.stopSessions == ["project"])
    #expect(h.state.workspaceOrder == [.home])
    #expect(h.state.applying(.closeWorkspace(key), ids: &h.ids) == .failure(.workspaceNotFound))
    #expect(h.state.applying(.activateTab(TabID(rawValue: "missing")), ids: &h.ids) == .failure(.tabNotFound))
    #expect(h.state.applying(.activateGroup(GroupID(rawValue: "missing")), ids: &h.ids) == .failure(.groupNotFound))
}
@Test func shellRatioAndActiveGroupCommands() throws {
    var h = TabHarness()
    _ = try h.create(); let b = try h.create()
    let original = h.group
    try h.apply(.moveTabToSplit(b, side: .bottom))
    try h.apply(.setGroupRatio(.home, path: [], ratio: 2))
    guard case .split(_, let ratio, _, _) = h.workspace.groupLayout else { Issue.record("expected split"); return }
    #expect(ratio == 0.95)
    try h.apply(.activateGroup(original))
    #expect(h.group == original)
}
@Test func shellCodableRoundTripAndStringIDs() throws {
    var h = TabHarness()
    let a = try h.create(cwd: "/tmp", title: "One")
    try h.apply(.setPinned(a, true))
    try h.apply(.closeTab(a, force: true))
    let data = try JSONEncoder().encode(h.state)
    #expect(try JSONDecoder().decode(ShellState.self, from: data) == h.state)
    #expect(String(data: try JSONEncoder().encode(TabID(rawValue: "ABC")), encoding: .utf8) == "\"abc\"")
}
@Test func shellRepairsDanglingMembershipAndActiveIDs() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create()
    let group = h.group
    let missing = TabID(rawValue: "missing")
    h.state.workspaces[.home]!.groups[group]!.tabOrder = [a, a, missing]
    h.state.workspaces[.home]!.groups[group]!.recentTabIDs = [missing, a, a]
    h.state.workspaces[.home]!.groups[group]!.activeTab = missing
    h.state.workspaces[.home]!.activeGroup = GroupID(rawValue: "missing")
    h.state.workspaces[.home]!.tabs[a]!.activePane = PaneID(rawValue: "missing")
    h.state.workspaces[.home]!.panes[PaneID(rawValue: "stray")] = PaneRecord(id: PaneID(rawValue: "stray"))
    #expect(!h.state.violations().isEmpty)
    let repaired = h.state.repaired()
    #expect(repaired.violations().isEmpty)
    #expect(repaired.workspaces[.home]?.tabs[b] != nil)
    #expect(repaired.repaired() == repaired)
}
@Test func shellRestartMissingPaneRefusesWithPaneNotFound() {
    var h = TabHarness()
    #expect(h.state.applying(.restartPane(PaneID(rawValue: "missing")), ids: &h.ids) == .failure(.paneNotFound))
}
@Test func shellSeededThousandRandomCommandsPreserveInvariants() throws {
    var h = TabHarness()
    var seed: UInt64 = 0xC2_5EED
    func random(_ bound: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 32) % UInt64(bound))
    }
    for _ in 0..<1_000 {
        let tabs = h.workspace.tabs.keys.sorted { $0.rawValue < $1.rawValue }
        let groups = h.workspace.groups.keys.sorted { $0.rawValue < $1.rawValue }
        let command: ShellCommand
        if tabs.isEmpty { command = .createTab(.home, group: nil, cwd: nil, title: nil) }
        else {
            let tab = tabs[random(tabs.count)]
            switch random(19) {
            case 0: command = .createTab(.home, group: nil, cwd: "/tmp", title: nil)
            case 1: command = .closeTab(tab, force: random(2) == 0)
            case 2: command = .activateTab(tab)
            case 3: command = .closeOtherTabs(tab)
            case 4: command = .setPinned(tab, random(2) == 0)
            case 5: command = .moveTabToSplit(tab, side: PaneSide.allCases[random(4)])
            case 6: command = .moveTab(tab, toGroup: groups[random(groups.count)], index: random(10) - 2)
            case 7: command = .reopenClosedTab(.home)
            case 8: command = .previousRecentTab(.home)
            case 9: command = .closeTabsToLeft(tab)
            case 10: command = .closeTabsToRight(tab)
            case 11: command = .duplicateTab(tab)
            case 12: command = .renameTab(tab, "Name")
            case 13: command = .setTabColor(tab, TabColor.allCases[random(9)])
            case 14: command = .nextTab(.home)
            case 15: command = .previousTab(.home)
            case 16: command = .selectTab(.home, index: random(5))
            case 17: command = .activateGroup(groups[random(groups.count)])
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

@Test func shellActiveGroupCollapseChoosesFirstLeafOfSiblingSubtree() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create(), c = try h.create()
    let first = h.group
    try h.apply(.moveTabToSplit(c, side: .right))
    try h.apply(.activateTab(b))
    try h.apply(.moveTabToSplit(b, side: .bottom))
    try h.apply(.activateTab(c))
    try h.apply(.closeTab(c, force: false))
    #expect(h.group == first)
    #expect(h.active == a)
}
@Test func shellRepairPrunesRepeatedLayoutAndPaneLeaves() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create()
    let group = h.group
    let pane = h.workspace.tabs[a]!.activePane
    h.state.workspaces[.home]!.groupLayout = .split(axis: .horizontal, ratio: 0.5, first: .leaf(group), second: .leaf(group))
    h.state.workspaces[.home]!.tabs[b]!.panes = .leaf(pane)
    h.state.workspaces[.home]!.tabs[a]!.expandedPane = PaneID(rawValue: "missing")
    let repaired = h.state.repaired()
    #expect(repaired.violations().isEmpty)
    #expect(repaired.workspaces[.home]?.tabs[b] == nil)
    #expect(repaired.workspaces[.home]?.tabs[a]?.expandedPane == nil)
    #expect(repaired.workspaces[.home]?.groupLayout == .leaf(group))
    #expect(repaired.repaired() == repaired)
}
@Test func shellRepairRecoversOrphanTabsAndPrunesWindowMetadata() throws {
    var h = TabHarness()
    let a = try h.create()
    h.state.workspaces[.home]!.groups = [:]
    h.state.workspaces[.home]!.groupLayout = nil
    h.state.workspaceOrder = [.floating, .home, .home]
    h.state.lastVisited[.floating] = h.now
    let win = WindowID(rawValue: "win")
    h.state.windows = [WindowState(id: win, workspace: .floating), WindowState(id: win, workspace: .home), WindowState(id: win, workspace: .home)]
    let repaired = h.state.repaired()
    #expect(repaired.violations().isEmpty)
    #expect(repaired.workspaces[.home]?.tabs[a] != nil)
    #expect(repaired.workspaceOrder == [.home])
    #expect(repaired.windows.count == 1)
    #expect(repaired.lastVisited[.floating] == nil)
    #expect(repaired.repaired() == repaired)
}

@Test func shellGroupMetadataPersistsAndUngroupPreservesSessions() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create()
    try h.apply(.createGroup(b, name: "Build"))
    let group = h.group
    try h.apply(.renameGroup(group, " Review "))
    try h.apply(.setGroupColor(group, .blue))
    try h.apply(.setGroupCollapsed(group, true))
    let directory = URL(fileURLWithPath: "/tmp/sz-gr-" + UUID().uuidString.prefix(8))
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("shell-state.json")
    try ShellStateStore.save(h.state, to: url)
    let (restored, report) = ShellStateStore.load(from: url)
    #expect(report.salvaged.isEmpty && report.backupPath == nil)
    #expect(restored.workspaces[.home]?.groups[group]?.name == "Review")
    #expect(restored.workspaces[.home]?.groups[group]?.color == .blue)
    #expect(restored.workspaces[.home]?.groups[group]?.collapsed == true)
    let effects = try h.apply(.ungroup(group))
    #expect(h.workspace.groups.count == 1)
    #expect(Set(h.order) == Set([a, b]))
    #expect(effects.stopSessions.isEmpty && effects.startPanes.isEmpty)
}
@Test func shellPinnedBoundarySurvivesMoveAndCreate() throws {
    var h = TabHarness()
    let a = try h.create(), b = try h.create(), c = try h.create()
    try h.apply(.setPinned(c, true))
    #expect(h.order == [c, a, b])
    try h.apply(.moveTab(a, toGroup: h.group, index: 0))
    #expect(h.order == [c, a, b])
    try h.apply(.moveTab(c, toGroup: h.group, index: 99))
    #expect(h.order.first == c)
    try h.apply(.activateTab(c))
    let d = try h.create()
    #expect(h.order == [c, d, a, b])
}
@Test func shellOldGroupMetadataDecodes() throws {
    let id = GroupID(rawValue: "old")
    let data = try JSONEncoder().encode(TabGroup(id: id))
    var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    json.removeValue(forKey: "name"); json.removeValue(forKey: "color"); json.removeValue(forKey: "collapsed")
    let group = try JSONDecoder().decode(TabGroup.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(group.name == nil && group.color == nil && group.collapsed == nil)
}
