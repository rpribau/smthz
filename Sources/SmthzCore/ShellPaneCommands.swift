import Foundation

public enum ExitVerdict: Equatable, Sendable { case keep, unbind, retire }

/// Port of Orca's workspace-layout-process-exit.ts. Absence is not proof of exit.
/// A positive signal is also proof; a local signal death keeps the failure visible.
public func exitVerdict(_ facts: ProcessExitFacts, paneCount: Int) -> ExitVerdict {
    let signalled = facts.signal.map { $0 > 0 } ?? false
    let provenCode = facts.code.map { $0 >= 0 } ?? false
    guard !facts.attachAbsent, signalled || provenCode else { return .unbind }
    if facts.local && (signalled || facts.code != 0) { return .keep }
    if facts.inputWritten { return .retire }
    if paneCount <= 1 { return facts.spawnedFresh ? .keep : .retire }
    let freshSplit = facts.tabHadPaneAtConnect && !facts.restored && !facts.outputReceived
    return freshSplit ? .keep : .retire
}

extension WorkspaceLayout {
    mutating func unbindSessions(fromOtherHostsThan host: ProcessIdentity) {
        for id in panes.keys {
            guard let binding = panes[id]!.binding, binding.hostIncarnation != host else { continue }
            panes[id]!.binding = nil
            panes[id]!.pendingCreateRequestID = nil
            panes[id]!.state = .ended(reason: .hostRestarted)
        }
    }

    mutating func applyPaneCommand(_ command: ShellCommand, now: Date, ids: inout some ShellIDSource,
                                   effects: inout ShellEffects) throws {
        switch command {
        case .splitPane(let tabID, let pane, let side):
            var tab = try paneTab(tabID, containing: pane)
            let new = PaneID(rawValue: ids.next())
            guard panes[new] == nil, let tree = tab.panes.inserting(new, beside: pane, side: side) else {
                throw ShellRefusal.invalid("id source returned an existing pane id")
            }
            panes[new] = PaneRecord(id: new, startupCwd: panes[pane]!.startupCwd ?? tab.startupCwd)
            tab.panes = tree; tab.activePane = new; tab.expandedPane = nil
            tabs[tabID] = tab
            effects.startPanes.append(new)
        case .closePane(let tab, let pane):
            let record = try paneTab(tab, containing: pane)
            guard record.panes.leaves.count > 1 else { throw ShellRefusal.lastPane }
            removePane(pane, from: tab, stop: true, effects: &effects)
        case .focusPane(let tabID, let pane):
            var tab = try paneTab(tabID, containing: pane)
            tab.activePane = pane
            if tab.expandedPane != nil { tab.expandedPane = pane }
            tabs[tabID] = tab
        case .focusNextPane(let tabID), .focusPreviousPane(let tabID):
            guard var tab = tabs[tabID] else { throw ShellRefusal.tabNotFound }
            if case .focusNextPane = command { tab.activePane = tab.panes.leaf(after: tab.activePane)! }
            else { tab.activePane = tab.panes.leaf(before: tab.activePane)! }
            if tab.expandedPane != nil { tab.expandedPane = tab.activePane }
            tabs[tabID] = tab
        case .toggleExpandPane(let tabID, let pane):
            var tab = try paneTab(tabID, containing: pane)
            tab.activePane = pane
            tab.expandedPane = tab.expandedPane == pane ? nil : pane
            tabs[tabID] = tab
        case .equalizePanes(let tabID):
            guard tabs[tabID] != nil else { throw ShellRefusal.tabNotFound }
            tabs[tabID]!.panes = tabs[tabID]!.panes.equalized()
        case .setPaneRatio(let tabID, let path, let ratio):
            guard let tab = tabs[tabID] else { throw ShellRefusal.tabNotFound }
            guard ratio.isFinite else { throw ShellRefusal.invalid("nonfinite ratio") }
            var node = tab.panes
            for branch in path {
                guard case .split(_, _, let a, let b) = node else { throw ShellRefusal.invalid("invalid split path") }
                node = branch == .first ? a : b
            }
            guard case .split = node else { throw ShellRefusal.invalid("path does not identify a split") }
            tabs[tabID]!.panes = tab.panes.settingRatio(ratio, at: path)
        case .renamePane(let pane, let title):
            try requirePane(pane)
            let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            panes[pane]!.title = trimmed?.isEmpty == true ? nil : trimmed
        case .setPaneGrid(let pane, let cols, let rows):
            try requirePane(pane)
            guard (1...65535).contains(cols), (1...65535).contains(rows) else {
                throw ShellRefusal.invalid("invalid pane grid")
            }
            panes[pane]!.lastGrid = PaneGrid(cols: cols, rows: rows)
        case .paneStarting(let pane, let request):
            try requirePane(pane)
            if panes[pane]!.pendingCreateRequestID == request { return }
            guard panes[pane]!.binding == nil, panes[pane]!.pendingCreateRequestID == nil else {
                throw ShellRefusal.invalid("pane already bound or starting")
            }
            panes[pane]!.pendingCreateRequestID = request
            panes[pane]!.state = .starting
        case .bindSession(let pane, let binding):
            try requirePane(pane)
            guard !binding.sessionID.isEmpty else { throw ShellRefusal.invalid("empty session id") }
            if let old = panes[pane]!.binding, old != binding {
                throw ShellRefusal.invalid("pane already bound")
            }
            panes[pane]!.binding = binding
            panes[pane]!.pendingCreateRequestID = nil
            panes[pane]!.state = .live
        case .processExited(let pane, let facts):
            try requirePane(pane)
            guard let tabID = tabs.first(where: { $0.value.panes.contains(pane) })?.key else {
                throw ShellRefusal.paneNotFound
            }
            switch exitVerdict(facts, paneCount: tabs[tabID]!.panes.leaves.count) {
            case .keep:
                panes[pane]!.pendingCreateRequestID = nil
                panes[pane]!.state = .exited(code: facts.code, signal: facts.signal)
            case .unbind:
                panes[pane]!.binding = nil
                panes[pane]!.pendingCreateRequestID = nil
                panes[pane]!.state = .ended(reason: .sessionMissing)
            case .retire:
                // Exit is already proven: never emit a stop for a dead process.
                panes[pane]!.binding = nil
                if tabs[tabID]!.panes.leaves.count == 1 { closeTabs([tabID], now: now, effects: &effects) }
                else { removePane(pane, from: tabID, stop: false, effects: &effects) }
            }
        case .adoptSession(_, let session, let host):
            guard !session.id.isEmpty else { throw ShellRefusal.invalid("empty session id") }
            let binding = SessionBinding(hostIncarnation: host, sessionID: session.id,
                                         process: ProcessIdentity(pid: session.pid, startSeconds: session.startSeconds,
                                                                  startMicroseconds: session.startMicroseconds))
            if let existing = panes.values.first(where: { $0.binding == binding }),
               let tab = tabs.first(where: { $0.value.panes.contains(existing.id) })?.key {
                try activate(tab)
                tabs[tab]!.activePane = existing.id
                return
            }
            let previousStarts = effects.startPanes
            try applyTabCommand(.createTab(key, group: nil, cwd: session.cwd, title: nil),
                                now: now, ids: &ids, effects: &effects)
            let pane = tabs[groups[activeGroup!]!.activeTab!]!.activePane
            effects.startPanes = previousStarts
            panes[pane]!.binding = binding
            panes[pane]!.state = session.running ? .live : .ended(reason: .sessionMissing)
        case .restartPane(let pane):
            try requirePane(pane)
            if let binding = panes[pane]!.binding { effects.stopSessions.append(binding.sessionID) }
            panes[pane]!.binding = nil
            panes[pane]!.pendingCreateRequestID = nil
            panes[pane]!.state = .unstarted
            effects.startPanes.append(pane)
        default: throw ShellRefusal.invalid("not a pane command")
        }
    }

    private func requirePane(_ pane: PaneID) throws {
        guard panes[pane] != nil else { throw ShellRefusal.paneNotFound }
    }

    private func paneTab(_ tab: TabID, containing pane: PaneID) throws -> TerminalTabRecord {
        guard let record = tabs[tab] else { throw ShellRefusal.tabNotFound }
        guard record.panes.contains(pane), panes[pane] != nil else { throw ShellRefusal.paneNotFound }
        return record
    }

    private mutating func removePane(_ pane: PaneID, from tabID: TabID, stop: Bool,
                                     effects: inout ShellEffects) {
        var tab = tabs[tabID]!
        let sibling = tab.panes.sibling(of: pane)
        tab.panes = tab.panes.removing(pane)!
        if tab.activePane == pane { tab.activePane = sibling ?? tab.panes.leaves[0] }
        if tab.expandedPane == pane { tab.expandedPane = nil }
        if stop, let binding = panes[pane]!.binding { effects.stopSessions.append(binding.sessionID) }
        panes.removeValue(forKey: pane)
        tabs[tabID] = tab
    }
}
