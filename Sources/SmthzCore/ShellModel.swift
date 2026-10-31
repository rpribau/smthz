import Foundation
import CoreGraphics

/// IDs encode as strings, rather than objects containing a rawValue field.
public protocol ShellStringID: RawRepresentable, Hashable, Codable, Sendable where RawValue == String {
    init(rawValue: String)
}
public extension ShellStringID {
    init(from decoder: any Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
public struct WorkspaceKey: ShellStringID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let home = Self(rawValue: "home")
    public static let floating = Self(rawValue: "floating")
    public static func folder(_ absolutePath: String) -> Self { .init(rawValue: "folder:" + absolutePath) }
}
public struct WindowID: ShellStringID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue.lowercased() }
}
public struct GroupID: ShellStringID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue.lowercased() }
}
public struct TabID: ShellStringID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue.lowercased() }
}
public struct PaneID: ShellStringID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue.lowercased() }
}
public protocol ShellIDSource { mutating func next() -> String }
public struct UUIDShellIDSource: ShellIDSource, Sendable {
    public init() {}
    public mutating func next() -> String { UUID().uuidString.lowercased() }
}
public enum TabColor: String, Codable, Sendable, CaseIterable {
    case gray, red, orange, yellow, green, teal, blue, purple, pink
}
public enum ShellTabKind: String, Codable, Sendable { case terminal }
public enum PaneEndReason: String, Codable, Sendable { case hostRestarted, sessionMissing }
public enum PaneState: Equatable, Codable, Sendable {
    case unstarted, starting, live
    case exited(code: Int32?, signal: Int32?)
    case ended(reason: PaneEndReason)
}
public struct PaneGrid: Equatable, Codable, Sendable {
    public var cols: Int
    public var rows: Int
    public init(cols: Int, rows: Int) { self.cols = cols; self.rows = rows }
}
public struct SessionBinding: Equatable, Codable, Sendable {
    public var hostIncarnation: ProcessIdentity
    public var sessionID: String
    public var process: ProcessIdentity
    public init(hostIncarnation: ProcessIdentity, sessionID: String, process: ProcessIdentity) {
        self.hostIncarnation = hostIncarnation; self.sessionID = sessionID; self.process = process
    }
}
public struct PaneRecord: Equatable, Codable, Sendable {
    public var id: PaneID
    public var title: String?
    public var lastGrid: PaneGrid?
    public var startupCwd: String?
    public var binding: SessionBinding?
    public var pendingCreateRequestID: RequestID?
    public var state: PaneState
    public init(id: PaneID, title: String? = nil, lastGrid: PaneGrid? = nil, startupCwd: String? = nil,
                binding: SessionBinding? = nil, pendingCreateRequestID: RequestID? = nil, state: PaneState = .unstarted) {
        self.id = id; self.title = title; self.lastGrid = lastGrid; self.startupCwd = startupCwd
        self.binding = binding; self.pendingCreateRequestID = pendingCreateRequestID; self.state = state
    }
}
public struct TerminalTabRecord: Equatable, Codable, Sendable {
    public var id: TabID
    public var kind: ShellTabKind = .terminal
    public var createdAt: Date
    public var defaultTitle: String
    public var customTitle: String?
    public var color: TabColor?
    public var isPinned: Bool
    public var panes: LayoutNode<PaneID>
    public var activePane: PaneID
    public var expandedPane: PaneID?
    public var startupCwd: String?
    public var title: String { customTitle ?? defaultTitle }
    public init(id: TabID, createdAt: Date, defaultTitle: String, customTitle: String? = nil,
                color: TabColor? = nil, isPinned: Bool = false, panes: LayoutNode<PaneID>,
                activePane: PaneID, expandedPane: PaneID? = nil, startupCwd: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.defaultTitle = defaultTitle; self.customTitle = customTitle
        self.color = color; self.isPinned = isPinned; self.panes = panes; self.activePane = activePane
        self.expandedPane = expandedPane; self.startupCwd = startupCwd
    }
}
public struct TabGroup: Equatable, Codable, Sendable {
    // Optional metadata keeps pre-group state files decodable.
    public var name: String?
    public var color: TabColor?
    public var collapsed: Bool?
    public var id: GroupID
    public var tabOrder: [TabID]
    public var activeTab: TabID?
    /// Oldest first, most recent last, matching Orca's recentTabIds.
    public var recentTabIDs: [TabID]
    public init(id: GroupID, tabOrder: [TabID] = [], activeTab: TabID? = nil, recentTabIDs: [TabID] = []) {
        self.id = id; self.tabOrder = tabOrder; self.activeTab = activeTab; self.recentTabIDs = recentTabIDs
    }
}
/// Only appearance and placement are retained. A closed session is never adopted on reopen.
public struct ClosedTabSnapshot: Equatable, Codable, Sendable {
    public var tab: TerminalTabRecord
    public var group: GroupID
    public var index: Int
    public var closedAt: Date
    public init(tab: TerminalTabRecord, group: GroupID, index: Int, closedAt: Date) {
        self.tab = tab; self.group = group; self.index = index; self.closedAt = closedAt
    }
}
public struct WorkspaceLayout: Equatable, Codable, Sendable {
    public var key: WorkspaceKey
    public var displayName: String
    public var rootPath: String?
    public var tabs: [TabID: TerminalTabRecord]
    public var groups: [GroupID: TabGroup]
    public var groupLayout: LayoutNode<GroupID>?
    public var activeGroup: GroupID?
    public var panes: [PaneID: PaneRecord]
    public var recentlyClosed: [ClosedTabSnapshot]
    public var nextDefaultTitleNumber: Int
    public init(key: WorkspaceKey, displayName: String, rootPath: String? = nil,
                tabs: [TabID: TerminalTabRecord] = [:], groups: [GroupID: TabGroup] = [:],
                groupLayout: LayoutNode<GroupID>? = nil, activeGroup: GroupID? = nil,
                panes: [PaneID: PaneRecord] = [:], recentlyClosed: [ClosedTabSnapshot] = [], nextDefaultTitleNumber: Int = 1) {
        self.key = key; self.displayName = displayName; self.rootPath = rootPath; self.tabs = tabs
        self.groups = groups; self.groupLayout = groupLayout; self.activeGroup = activeGroup; self.panes = panes
        self.recentlyClosed = recentlyClosed; self.nextDefaultTitleNumber = nextDefaultTitleNumber
    }
}
public struct CGRectCodable: Equatable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(_ rect: CGRect) { self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height) }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
public enum ShellDestination: String, Codable, Sendable, CaseIterable {
    case needsYou, workspaces, tasks, automations, activity, library
}
public struct WindowState: Equatable, Codable, Sendable {
    public var id: WindowID
    public var workspace: WorkspaceKey
    public var frame: CGRectCodable?
    public var sidebarVisible: Bool
    public var sidebarWidth: Double
    public var destination: ShellDestination
    public init(id: WindowID, workspace: WorkspaceKey, frame: CGRectCodable? = nil,
                sidebarVisible: Bool = true, sidebarWidth: Double = 240, destination: ShellDestination = .workspaces) {
        self.id = id; self.workspace = workspace; self.frame = frame; self.sidebarVisible = sidebarVisible
        self.sidebarWidth = sidebarWidth; self.destination = destination
    }
}
public struct ShellState: Equatable, Codable, Sendable {
    public var version: Int
    public var workspaces: [WorkspaceKey: WorkspaceLayout]
    public var windows: [WindowState]
    public var workspaceOrder: [WorkspaceKey]
    public var lastVisited: [WorkspaceKey: Date]
    public init(version: Int = 1, workspaces: [WorkspaceKey: WorkspaceLayout] = [:], windows: [WindowState] = [],
                workspaceOrder: [WorkspaceKey] = [], lastVisited: [WorkspaceKey: Date] = [:]) {
        self.version = version; self.workspaces = workspaces; self.windows = windows
        self.workspaceOrder = workspaceOrder; self.lastVisited = lastVisited
    }
    public static var empty: Self {
        Self(workspaces: [.home: WorkspaceLayout(key: .home, displayName: "Home")], workspaceOrder: [.home])
    }
}
public struct ShellEffects: Equatable, Sendable {
    public var startPanes: [PaneID]
    public var stopSessions: [String]
    public init(startPanes: [PaneID] = [], stopSessions: [String] = []) {
        self.startPanes = startPanes; self.stopSessions = stopSessions
    }
}
public enum ShellRefusal: Error, Equatable, Sendable {
    case workspaceNotFound, tabNotFound, groupNotFound, paneNotFound, lastPane, pinnedTab, invalid(String)
}
public struct ShellApplied: Equatable, Sendable {
    public let state: ShellState
    public let effects: ShellEffects
    public init(state: ShellState, effects: ShellEffects) { self.state = state; self.effects = effects }
}
/// Runtime observations used by the pure process-exit verdict.
public struct ProcessExitFacts: Equatable, Sendable {
    public var code: Int32?
    public var signal: Int32?
    public var local: Bool
    public var attachAbsent: Bool
    public var spawnedFresh: Bool
    public var restored: Bool
    public var inputWritten: Bool
    public var outputReceived: Bool
    public var tabHadPaneAtConnect: Bool
    public init(code: Int32? = nil, signal: Int32? = nil, spawnedFresh: Bool, restored: Bool,
                inputWritten: Bool, outputReceived: Bool, tabHadPaneAtConnect: Bool,
                local: Bool = true, attachAbsent: Bool = false) {
        self.code = code; self.signal = signal; self.local = local; self.attachAbsent = attachAbsent
        self.spawnedFresh = spawnedFresh; self.restored = restored
        self.inputWritten = inputWritten; self.outputReceived = outputReceived; self.tabHadPaneAtConnect = tabHadPaneAtConnect
    }
}
public enum ShellCommand: Equatable, Sendable {
    case openWorkspace(WorkspaceKey, displayName: String, rootPath: String?)
    case closeWorkspace(WorkspaceKey)
    case createTab(WorkspaceKey, group: GroupID?, cwd: String?, title: String?)
    case closeTab(TabID, force: Bool)
    case closeOtherTabs(TabID), closeTabsToRight(TabID), closeTabsToLeft(TabID), closeAllTabs(WorkspaceKey)
    case activateTab(TabID), selectTab(WorkspaceKey, index: Int)
    case nextTab(WorkspaceKey), previousTab(WorkspaceKey), previousRecentTab(WorkspaceKey)
    case renameTab(TabID, String?), setTabColor(TabID, TabColor?), setPinned(TabID, Bool)
    case duplicateTab(TabID)
    case moveTab(TabID, toGroup: GroupID, index: Int)
    case moveTabToSplit(TabID, side: PaneSide)
    case setGroupRatio(WorkspaceKey, path: [SplitBranch], ratio: Double)
    case activateGroup(GroupID)
    case createGroup(TabID, name: String)
    case renameGroup(GroupID, String?), setGroupColor(GroupID, TabColor?)
    case setGroupCollapsed(GroupID, Bool), ungroup(GroupID)
    case reopenClosedTab(WorkspaceKey)
    case splitPane(TabID, pane: PaneID, side: PaneSide)
    case closePane(TabID, PaneID), focusPane(TabID, PaneID)
    case focusNextPane(TabID), focusPreviousPane(TabID), toggleExpandPane(TabID, PaneID), equalizePanes(TabID)
    case setPaneRatio(TabID, path: [SplitBranch], ratio: Double)
    case renamePane(PaneID, String?), setPaneGrid(PaneID, cols: Int, rows: Int)
    case paneStarting(PaneID, requestID: RequestID), bindSession(PaneID, SessionBinding)
    case processExited(PaneID, ProcessExitFacts), hostIncarnationChanged(ProcessIdentity)
    case adoptSession(WorkspaceKey, SessionInfo, host: ProcessIdentity), restartPane(PaneID)
}

public extension ShellState {
    func violations() -> [String] {
        var errors: [String] = []
        var tabIDs = Set<TabID>(), groupIDs = Set<GroupID>(), paneIDs = Set<PaneID>()
        for key in workspaces.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let w = workspaces[key]!
            func fail(_ message: String) { errors.append("\(key.rawValue): \(message)") }
            if w.key != key { fail("workspace key mismatch") }
            let leaves = w.groupLayout?.leaves ?? []
            if Set(leaves) != Set(w.groups.keys) || Set(leaves).count != leaves.count { fail("group layout mismatch") }
            if let active = w.activeGroup {
                if w.groups[active] == nil { fail("dangling active group") }
            } else if !w.groups.isEmpty { fail("missing active group") }
            var ordered: [TabID] = []
            for (id, g) in w.groups {
                if !groupIDs.insert(id).inserted { fail("duplicate group id") }
                if g.id != id { fail("group id mismatch") }
                if g.tabOrder.isEmpty && !(w.groups.count == 1 && w.tabs.isEmpty) { fail("empty group") }
                ordered += g.tabOrder
                if let active = g.activeTab {
                    if !g.tabOrder.contains(active) || w.tabs[active] == nil { fail("dangling active tab") }
                } else if !g.tabOrder.isEmpty { fail("missing active tab") }
                if Set(g.recentTabIDs).count != g.recentTabIDs.count || !Set(g.recentTabIDs).isSubset(of: Set(g.tabOrder)) {
                    fail("invalid MRU")
                }
            }
            if Set(ordered) != Set(w.tabs.keys) || ordered.count != w.tabs.count { fail("tab membership mismatch") }
            var owned: [PaneID] = []
            for (id, tab) in w.tabs {
                if !tabIDs.insert(id).inserted { fail("duplicate tab id") }
                if tab.id != id { fail("tab id mismatch") }
                let panes = tab.panes.leaves
                owned += panes
                if !panes.contains(tab.activePane) { fail("dangling active pane") }
                if let expanded = tab.expandedPane, !panes.contains(expanded) { fail("dangling expanded pane") }
            }
            if Set(owned) != Set(w.panes.keys) || Set(owned).count != owned.count { fail("pane membership mismatch") }
            for (id, p) in w.panes {
                if !paneIDs.insert(id).inserted { fail("duplicate pane id") }
                if id != p.id { fail("pane id mismatch") }
            }
            if w.recentlyClosed.count > 10 { fail("too many closed tabs") }
            if w.nextDefaultTitleNumber < 1 { fail("invalid title counter") }
        }
        if Set(workspaceOrder) != Set(workspaces.keys) || workspaceOrder.count != workspaces.count { errors.append("workspace order mismatch") }
        if !Set(lastVisited.keys).isSubset(of: Set(workspaces.keys)) { errors.append("dangling lastVisited") }
        if Set(windows.map(\.id)).count != windows.count { errors.append("duplicate window id") }
        if windows.contains(where: { workspaces[$0.workspace] == nil }) { errors.append("dangling window workspace") }
        return errors
    }

    /// Salvage deterministically without creating processes or trusting stale active IDs.
    func repaired() -> Self {
        var result = self
        var seenTabs = Set<TabID>(), seenGroups = Set<GroupID>(), seenPanes = Set<PaneID>()
        for key in workspaces.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            var w = workspaces[key]!
            w.key = key
            for id in w.tabs.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                var tab = w.tabs[id]!
                guard seenTabs.insert(id).inserted else { w.tabs.removeValue(forKey: id); continue }
                let tree = tab.panes.filtered { w.panes[$0] != nil && seenPanes.insert($0).inserted }
                guard let tree else { w.tabs.removeValue(forKey: id); continue }
                tab.id = id; tab.panes = tree
                if !tree.contains(tab.activePane) { tab.activePane = tree.leaves[0] }
                if let expanded = tab.expandedPane, !tree.contains(expanded) { tab.expandedPane = nil }
                w.tabs[id] = tab
            }
            let owned = Set(w.tabs.values.flatMap { $0.panes.leaves })
            w.panes = w.panes.filter { owned.contains($0.key) }
            for id in w.panes.keys { w.panes[id]!.id = id }
            var assigned = Set<TabID>()
            let groupOrder = (w.groupLayout?.leaves ?? []) + w.groups.keys.sorted { $0.rawValue < $1.rawValue }
            var handled = Set<GroupID>()
            for id in groupOrder where handled.insert(id).inserted {
                guard var g = w.groups[id] else { continue }
                guard seenGroups.insert(id).inserted else { w.groups.removeValue(forKey: id); continue }
                g.id = id
                g.tabOrder = g.tabOrder.filter { w.tabs[$0] != nil && assigned.insert($0).inserted }
                g.recentTabIDs = g.recentTabIDs.uniqued().filter { g.tabOrder.contains($0) }
                if g.activeTab == nil || !g.tabOrder.contains(g.activeTab!) { g.activeTab = g.recentTabIDs.last ?? g.tabOrder.first }
                w.groups[id] = g
            }
            let orphans = w.tabs.keys.filter { !assigned.contains($0) }.sorted { $0.rawValue < $1.rawValue }
            if !orphans.isEmpty {
                if let id = w.groups.keys.sorted(by: { $0.rawValue < $1.rawValue }).first {
                    w.groups[id]!.tabOrder += orphans
                    if w.groups[id]!.activeTab == nil { w.groups[id]!.activeTab = orphans.first }
                } else {
                    // Stable UUID-shaped repair id, derived from a tab's globally unique id.
                    let id = GroupID(rawValue: w.tabs[orphans[0]]!.id.rawValue)
                    if seenGroups.insert(id).inserted {
                        w.groups[id] = TabGroup(id: id, tabOrder: orphans, activeTab: orphans.first)
                    } else {
                        for tab in orphans { w.tabs.removeValue(forKey: tab) }
                        w.panes = w.panes.filter { id, _ in w.tabs.values.contains { $0.panes.contains(id) } }
                    }
                }
            }
            if w.groups.count > 1 || !w.tabs.isEmpty { w.groups = w.groups.filter { !$0.value.tabOrder.isEmpty } }
            let valid = Set(w.groups.keys)
            var layoutSeen = Set<GroupID>()
            w.groupLayout = w.groupLayout?.filtered { valid.contains($0) && layoutSeen.insert($0).inserted }
            for id in w.groups.keys.sorted(by: { $0.rawValue < $1.rawValue }) where w.groupLayout?.contains(id) != true {
                if let tree = w.groupLayout { w.groupLayout = .split(axis: .horizontal, ratio: 0.5, first: tree, second: .leaf(id)) }
                else { w.groupLayout = .leaf(id) }
            }
            if w.activeGroup == nil || w.groups[w.activeGroup!] == nil { w.activeGroup = w.groupLayout?.leaves.first }
            w.recentlyClosed = Array(w.recentlyClosed.suffix(10))
            let maxTitle = w.tabs.values.compactMap { tab -> Int? in
                guard tab.defaultTitle.hasPrefix("Terminal ") else { return nil }
                return Int(tab.defaultTitle.dropFirst(9))
            }.max() ?? 0
            w.nextDefaultTitleNumber = max(1, w.nextDefaultTitleNumber, maxTitle == Int.max ? Int.max : maxTitle + 1)
            result.workspaces[key] = w
        }
        result.workspaceOrder = workspaceOrder.uniqued().filter { result.workspaces[$0] != nil }
        result.workspaceOrder += result.workspaces.keys.filter { !result.workspaceOrder.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        result.lastVisited = lastVisited.filter { result.workspaces[$0.key] != nil }
        var windowIDs = Set<WindowID>()
        result.windows = windows.filter { result.workspaces[$0.workspace] != nil && windowIDs.insert($0.id).inserted }
        return result
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
extension LayoutNode {
    /// Prunes invalid and repeated leaves, collapsing their parent split.
    func filtered(_ keep: (Leaf) -> Bool) -> Self? {
        switch self {
        case .leaf(let id): return keep(id) ? self : nil
        case .split(let axis, let ratio, let first, let second):
            let a = first.filtered(keep), b = second.filtered(keep)
            guard let a else { return b }
            guard let b else { return a }
            return .split(axis: axis, ratio: ratio.isFinite && ratio > 0 && ratio < 1 ? ratio : 0.5, first: a, second: b)
        }
    }
}
