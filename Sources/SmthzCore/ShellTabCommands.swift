import Foundation

public extension ShellState {
    /// A value-only transaction. Refusals never mutate the caller's state or emit effects.
    /// Tab indices are zero-based within the active group. Bulk close commands preserve pinned tabs.
    func applying(_ command: ShellCommand, now: Date = .now,
                  ids: inout some ShellIDSource) -> Result<ShellApplied, ShellRefusal> {
        var state = self
        var effects = ShellEffects()
        do {
            switch command {
            case .openWorkspace(let key, let displayName, let rootPath):
                if var workspace = state.workspaces[key] {
                    workspace.displayName = displayName; workspace.rootPath = rootPath
                    state.workspaces[key] = workspace
                } else {
                    state.workspaces[key] = WorkspaceLayout(key: key, displayName: displayName, rootPath: rootPath)
                    state.workspaceOrder.append(key)
                }
                state.lastVisited[key] = now
            case .closeWorkspace(let key):
                guard let workspace = state.workspaces.removeValue(forKey: key) else { throw ShellRefusal.workspaceNotFound }
                effects.stopSessions = workspace.tabs.keys.sorted { $0.rawValue < $1.rawValue }.flatMap {
                    workspace.tabs[$0]!.panes.leaves.compactMap { workspace.panes[$0]?.binding?.sessionID }
                }.uniqued()
                state.workspaceOrder.removeAll { $0 == key }
                state.lastVisited.removeValue(forKey: key)
                state.windows.removeAll { $0.workspace == key }
            case .hostIncarnationChanged(let host):
                for key in state.workspaceOrder {
                    state.workspaces[key]!.unbindSessions(fromOtherHostsThan: host)
                }
            default:
                let key = try state.workspaceKey(for: command)
                guard var workspace = state.workspaces[key] else { throw ShellRefusal.workspaceNotFound }
                try workspace.applyTabCommand(command, now: now, ids: &ids, effects: &effects)
                state.workspaces[key] = workspace
                state.lastVisited[key] = now
            }
            let errors = state.violations()
            guard errors.isEmpty else { throw ShellRefusal.invalid(errors.joined(separator: "; ")) }
            effects.stopSessions = effects.stopSessions.uniqued()
            return .success(ShellApplied(state: state, effects: effects))
        } catch let refusal as ShellRefusal {
            return .failure(refusal)
        } catch {
            return .failure(.invalid(String(describing: error)))
        }
    }

    private func workspaceKey(for command: ShellCommand) throws -> WorkspaceKey {
        let tab: TabID
        switch command {
        case .createTab(let key, _, _, _), .closeAllTabs(let key), .selectTab(let key, _),
             .nextTab(let key), .previousTab(let key), .previousRecentTab(let key),
             .setGroupRatio(let key, _, _), .reopenClosedTab(let key), .adoptSession(let key, _, _): return key
        case .closeTab(let id, _), .closeOtherTabs(let id), .closeTabsToRight(let id), .closeTabsToLeft(let id),
             .activateTab(let id), .renameTab(let id, _), .setTabColor(let id, _), .setPinned(let id, _),
             .duplicateTab(let id), .moveTab(let id, _, _), .moveTabToSplit(let id, _),
             .splitPane(let id, _, _), .closePane(let id, _), .focusPane(let id, _),
             .focusNextPane(let id), .focusPreviousPane(let id), .toggleExpandPane(let id, _),
             .equalizePanes(let id), .setPaneRatio(let id, _, _): tab = id
        case .renamePane(let pane, _), .setPaneGrid(let pane, _, _), .paneStarting(let pane, _),
             .bindSession(let pane, _), .processExited(let pane, _), .restartPane(let pane):
            guard let key = workspaces.first(where: { $0.value.panes[pane] != nil })?.key else {
                throw ShellRefusal.paneNotFound
            }
            return key
        case .activateGroup(let id):
            guard let key = workspaces.first(where: { $0.value.groups[id] != nil })?.key else { throw ShellRefusal.groupNotFound }
            return key
        default: throw ShellRefusal.invalid("not implemented")
        }
        guard let key = workspaces.first(where: { $0.value.tabs[tab] != nil })?.key else { throw ShellRefusal.tabNotFound }
        return key
    }
}

extension WorkspaceLayout {
    mutating func applyTabCommand(_ command: ShellCommand, now: Date, ids: inout some ShellIDSource,
                                  effects: inout ShellEffects) throws {
        switch command {
        case .createTab(_, let group, let cwd, let title):
            let target = try targetGroup(group, ids: &ids)
            let index = groups[target]!.activeTab.flatMap { groups[target]!.tabOrder.firstIndex(of: $0) }.map { $0 + 1 }
                ?? groups[target]!.tabOrder.count
            try insertFreshTab(group: target, index: index, cwd: cwd ?? rootPath, title: title,
                               now: now, ids: &ids, effects: &effects)
        case .closeTab(let tab, let force):
            guard let record = tabs[tab] else { throw ShellRefusal.tabNotFound }
            guard force || !record.isPinned else { throw ShellRefusal.pinnedTab }
            closeTabs([tab], now: now, effects: &effects)
        case .closeOtherTabs(let tab), .closeTabsToLeft(let tab), .closeTabsToRight(let tab):
            let group = try groupContaining(tab)
            let order = groups[group]!.tabOrder
            let index = order.firstIndex(of: tab)!
            let candidates: [TabID]
            switch command {
            case .closeTabsToLeft: candidates = Array(order.prefix(index))
            case .closeTabsToRight: candidates = Array(order.dropFirst(index + 1))
            default: candidates = order.filter { $0 != tab }
            }
            closeTabs(candidates.filter { tabs[$0]?.isPinned == false }, now: now, effects: &effects)
        case .closeAllTabs:
            let order = (groupLayout?.leaves ?? []).flatMap { groups[$0]!.tabOrder }
            closeTabs(order.filter { tabs[$0]?.isPinned == false }, now: now, effects: &effects)
        case .activateTab(let id): try activate(id)
        case .selectTab(_, let index):
            guard let group = activeGroup, let g = groups[group], g.tabOrder.indices.contains(index) else {
                throw ShellRefusal.invalid("tab index out of range")
            }
            try activate(g.tabOrder[index])
        case .nextTab, .previousTab, .previousRecentTab:
            guard let group = activeGroup, let g = groups[group], let current = g.activeTab,
                  let index = g.tabOrder.firstIndex(of: current) else { throw ShellRefusal.tabNotFound }
            let target: TabID
            switch command {
            case .previousRecentTab:
                target = g.recentTabIDs.reversed().first { $0 != current } ?? current
            case .previousTab: target = g.tabOrder[(index + g.tabOrder.count - 1) % g.tabOrder.count]
            default: target = g.tabOrder[(index + 1) % g.tabOrder.count]
            }
            try activate(target)
        case .renameTab(let id, let title):
            guard tabs[id] != nil else { throw ShellRefusal.tabNotFound }
            tabs[id]!.customTitle = Self.normalizedTitle(title)
        case .setTabColor(let id, let color):
            guard tabs[id] != nil else { throw ShellRefusal.tabNotFound }
            tabs[id]!.color = color
        case .setPinned(let id, let pinned):
            guard tabs[id] != nil else { throw ShellRefusal.tabNotFound }
            tabs[id]!.isPinned = pinned
        case .duplicateTab(let id):
            let group = try groupContaining(id)
            let original = tabs[id]!
            let cwd = original.startupCwd ?? panes[original.activePane]?.startupCwd
            try insertFreshTab(group: group, index: groups[group]!.tabOrder.firstIndex(of: id)! + 1,
                               cwd: cwd, title: original.customTitle, color: original.color,
                               now: now, ids: &ids, effects: &effects)
        case .moveTab(let id, let target, let index):
            let source = try groupContaining(id)
            guard groups[target] != nil else { throw ShellRefusal.groupNotFound }
            removeFromGroup([id], group: source)
            if source != target { collapseEmptyGroup(source) }
            let insertion = min(max(0, index), groups[target]!.tabOrder.count)
            groups[target]!.tabOrder.insert(id, at: insertion)
            try activate(id)
        case .moveTabToSplit(let id, let side):
            let source = try groupContaining(id)
            guard groups[source]!.tabOrder.count > 1 else {
                throw ShellRefusal.invalid("cannot split a group's only tab off itself")
            }
            let target = GroupID(rawValue: ids.next())
            guard groups[target] == nil, let tree = groupLayout?.inserting(target, beside: source, side: side) else {
                throw ShellRefusal.invalid("invalid group id or layout")
            }
            removeFromGroup([id], group: source)
            groups[target] = TabGroup(id: target, tabOrder: [id], activeTab: id, recentTabIDs: [id])
            groupLayout = tree
            activeGroup = target
        case .setGroupRatio(_, let path, let ratio):
            guard ratio.isFinite else { throw ShellRefusal.invalid("nonfinite ratio") }
            guard var node = groupLayout else { throw ShellRefusal.groupNotFound }
            for branch in path {
                guard case .split(_, _, let first, let second) = node else { throw ShellRefusal.invalid("invalid split path") }
                node = branch == .first ? first : second
            }
            guard case .split = node else { throw ShellRefusal.invalid("path does not identify a split") }
            groupLayout = groupLayout?.settingRatio(ratio, at: path)
        case .activateGroup(let id):
            guard groups[id] != nil else { throw ShellRefusal.groupNotFound }
            activeGroup = id
        case .reopenClosedTab:
            guard let snapshot = recentlyClosed.popLast() else { throw ShellRefusal.invalid("no closed tab") }
            let group = try targetGroup(groups[snapshot.group] == nil ? nil : snapshot.group, ids: &ids)
            try insertFreshTab(group: group, index: min(max(0, snapshot.index), groups[group]!.tabOrder.count),
                               cwd: snapshot.tab.startupCwd, title: snapshot.tab.customTitle, color: snapshot.tab.color,
                               defaultTitle: snapshot.tab.defaultTitle, pinned: snapshot.tab.isPinned,
                               now: now, ids: &ids, effects: &effects)
        default: try applyPaneCommand(command, now: now, ids: &ids, effects: &effects)
        }
    }

    func groupContaining(_ tab: TabID) throws -> GroupID {
        guard tabs[tab] != nil else { throw ShellRefusal.tabNotFound }
        guard let id = groups.first(where: { $0.value.tabOrder.contains(tab) })?.key else { throw ShellRefusal.groupNotFound }
        return id
    }

    mutating func activate(_ tab: TabID) throws {
        let group = try groupContaining(tab)
        activeGroup = group
        groups[group]!.activeTab = tab
        groups[group]!.recentTabIDs.removeAll { $0 == tab }
        groups[group]!.recentTabIDs.append(tab)
    }

    private mutating func targetGroup(_ requested: GroupID?, ids: inout some ShellIDSource) throws -> GroupID {
        if let requested {
            guard groups[requested] != nil else { throw ShellRefusal.groupNotFound }
            return requested
        }
        if let activeGroup { return activeGroup }
        let id = GroupID(rawValue: ids.next())
        groups[id] = TabGroup(id: id)
        groupLayout = .leaf(id)
        activeGroup = id
        return id
    }

    private mutating func insertFreshTab(group: GroupID, index: Int, cwd: String?, title: String?, color: TabColor? = nil,
                                         defaultTitle: String? = nil, pinned: Bool = false,
                                         now: Date, ids: inout some ShellIDSource, effects: inout ShellEffects) throws {
        let tab = TabID(rawValue: ids.next()), pane = PaneID(rawValue: ids.next())
        guard tabs[tab] == nil, panes[pane] == nil else { throw ShellRefusal.invalid("id source returned an existing id") }
        let defaultName: String
        if let defaultTitle { defaultName = defaultTitle }
        else {
            guard nextDefaultTitleNumber < Int.max else { throw ShellRefusal.invalid("title counter exhausted") }
            defaultName = "Terminal \(nextDefaultTitleNumber)"
            nextDefaultTitleNumber += 1
        }
        tabs[tab] = TerminalTabRecord(id: tab, createdAt: now, defaultTitle: defaultName,
                                      customTitle: Self.normalizedTitle(title), color: color, isPinned: pinned,
                                      panes: .leaf(pane), activePane: pane, startupCwd: cwd)
        panes[pane] = PaneRecord(id: pane, startupCwd: cwd)
        groups[group]!.tabOrder.insert(tab, at: min(max(0, index), groups[group]!.tabOrder.count))
        try activate(tab)
        effects.startPanes.append(pane)
    }

    /// Closing multiple tabs uses the original order/MRU once, so neighbour fallback is stable.
    mutating func closeTabs(_ closing: [TabID], now: Date, effects: inout ShellEffects) {
        let closingSet = Set(closing)
        for id in closing {
            guard let tab = tabs[id], let group = groups.first(where: { $0.value.tabOrder.contains(id) })?.key else { continue }
            recentlyClosed.append(ClosedTabSnapshot(tab: tab, group: group,
                                                   index: groups[group]!.tabOrder.firstIndex(of: id)!, closedAt: now))
            for pane in tab.panes.leaves {
                if let binding = panes[pane]?.binding { effects.stopSessions.append(binding.sessionID) }
                panes.removeValue(forKey: pane)
            }
            tabs.removeValue(forKey: id)
        }
        recentlyClosed = Array(recentlyClosed.suffix(10))
        let order = groupLayout?.leaves ?? []
        for group in order {
            removeFromGroup(closingSet, group: group)
            collapseEmptyGroup(group)
        }
    }

    private mutating func removeFromGroup(_ closing: Set<TabID>, group: GroupID) {
        guard var g = groups[group] else { return }
        let original = g.tabOrder
        g.tabOrder.removeAll { closing.contains($0) }
        g.recentTabIDs.removeAll { closing.contains($0) }
        if let active = g.activeTab, closing.contains(active) {
            let closingIndex = original.firstIndex { closing.contains($0) } ?? -1
            g.activeTab = g.recentTabIDs.last ?? g.tabOrder.first(where: { original.firstIndex(of: $0)! > closingIndex }) ?? g.tabOrder.last
        }
        groups[group] = g
    }

    private mutating func collapseEmptyGroup(_ id: GroupID) {
        guard groups[id]?.tabOrder.isEmpty == true else { return }
        let sibling = groupLayout?.sibling(of: id)
        groups.removeValue(forKey: id)
        groupLayout = groupLayout?.removing(id)
        if activeGroup == id { activeGroup = sibling ?? groupLayout?.leaves.first }
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
