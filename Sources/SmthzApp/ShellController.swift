import Foundation
import Observation
import SwiftUI
import SmthzCore

@MainActor enum TerminalSizeHint {
    static var latest: (rows: Int, cols: Int)?
}

/// Kept beside shell-state only while a create is pending, so retries preserve
/// the executable, cwd and grid byte-for-byte, including adopted-session restarts.
private struct ShellCreateParameters: Codable, Sendable {
    var executable: String
    var arguments: [String]
    var cwd: String?
    var rows: Int
    var cols: Int
}

/// Owns short-lived RPC connections. Blocking socket work never executes on the UI actor.
private actor ShellEffectExecutor {
    let socketPath: String
    init(socketPath: String) { self.socketPath = socketPath }
    func create(requestID: RequestID, parameters: ShellCreateParameters) throws -> SessionInfo {
        let client = try HostClient(socketPath: socketPath)
        defer { client.disconnect() }
        return try client.createSession(requestID: requestID.rawValue,
            executable: parameters.executable, arguments: parameters.arguments, cwd: parameters.cwd,
            rows: parameters.rows, cols: parameters.cols)
    }
    func close(_ id: String) throws {
        let client = try HostClient(socketPath: socketPath)
        defer { client.disconnect() }
        _ = try client.close(id: id)
    }
    func write(_ id: String, text: String) throws {
        let client = try HostClient(socketPath: socketPath)
        defer { client.disconnect() }
        _ = try client.write(id: id, data: Data(text.utf8))
    }
}

@MainActor @Observable
final class ShellController {
    private(set) var state: ShellState
    private(set) var snapshot: HostSnapshot?
    var actionError: String?
    var workspacePinned = false
    var workspaceUnread = false
    var terminalFontSize: Double = 14
    private(set) var creatingShell = false
    private var ids = UUIDShellIDSource()
    private let executor: ShellEffectExecutor
    let socketPath: String
    let stateURL: URL
    private var saveTask: Task<Void, Never>?
    private var starting: Set<PaneID> = []
    private var restartParameters: [PaneID: ShellCreateParameters] = [:]
    private var stopping: Set<String> = []
    private var retiredSessions: Set<String> = []
    private var awaitingSnapshot: [String: Date] = [:]
    // OSC directories are runtime observations, rather than startup parameters.
    var directories: [String: String] = [:]

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = ApplicationIdentity.applicationSupportDirectory(home: home)
        socketPath = HostController.socketPath
        let arguments = ProcessInfo.processInfo.arguments
        let directory = arguments.firstIndex(of: "-SmthzStateDirectory").flatMap {
            arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
        }
        stateURL = (directory.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? support)
            .appending(path: "shell-state.json")
        let (loaded, report) = ShellStateStore.load(from: stateURL)
        state = loaded
        executor = ShellEffectExecutor(socketPath: socketPath)
        if state.workspaces[.home] == nil {
            state.workspaces[.home] = WorkspaceLayout(key: .home, displayName: "Default workspace")
            state.workspaceOrder.append(.home)
        }
        if !report.salvaged.isEmpty || report.backupPath != nil {
            actionError = "Shell state recovered. " + report.salvaged.joined(separator: "; ")
                + (report.backupPath.map { " Backup: \($0)" } ?? "")
        }
    }

    var workspace: WorkspaceLayout { state.workspaces[.home]! }
    var workspaceTitle: String {
        get { workspace.displayName == "Home" ? "Default workspace" : workspace.displayName }
        set { _ = apply(.openWorkspace(.home, displayName: newValue, rootPath: workspace.rootPath)) }
    }
    var sessions: [SessionInfo] { snapshot?.sessions ?? [] }
    private var orderedTabs: [TerminalTabRecord] {
        (workspace.groupLayout?.leaves ?? []).flatMap { workspace.groups[$0]?.tabOrder ?? [] }
            .compactMap { workspace.tabs[$0] }
    }
    private func tab(_ session: String) -> TerminalTabRecord? {
        orderedTabs.first { tab in tab.panes.leaves.contains { workspace.panes[$0]?.binding?.sessionID == session } }
    }
    private func session(_ tab: TerminalTabRecord) -> String? { workspace.panes[tab.activePane]?.binding?.sessionID }
    var selectedSessionID: String? {
        get {
            guard let group = workspace.activeGroup, let id = workspace.groups[group]?.activeTab,
                  let tab = workspace.tabs[id] else { return nil }
            return session(tab)
        }
        set {
            guard let newValue else { return }
            if let tab = tab(newValue) {
                _ = apply(.activateTab(tab.id))
                if let pane = tab.panes.leaves.first(where: { workspace.panes[$0]?.binding?.sessionID == newValue }) {
                    _ = apply(.focusPane(tab.id, pane))
                }
            }
            else if let session = sessions.first(where: { $0.id == newValue }),
                    case .running(let host, _) = snapshot?.state {
                // Explicit Resource Manager navigation may reopen an exited record;
                // background reconciliation only adopts running, unattached sessions.
                _ = apply(.adoptSession(.home, session, host: host))
            }
        }
    }
    var visibleIDs: [String] { orderedTabs.compactMap { session($0) } }
    var recentIDs: [String] {
        guard let group = workspace.activeGroup else { return [] }
        return (workspace.groups[group]?.recentTabIDs.reversed() ?? []).compactMap { workspace.tabs[$0].flatMap { session($0) } }
    }
    var pinned: Set<String> { Set(orderedTabs.filter(\.isPinned).compactMap { session($0) }) }
    func title(_ id: String) -> String {
        guard let tab = tab(id) else { return "Terminal" }
        return tab.customTitle ?? workspace.panes[tab.activePane]?.title
            ?? tab.defaultTitle.replacingOccurrences(of: "Terminal ", with: "Shell ")
    }
    var tabs: [ShellTabItem] {
        visibleIDs.map { id in ShellTabItem(id: id, title: title(id), colour: tab(id)?.color.map(Self.color),
            pinned: pinned.contains(id), active: selectedSessionID == id,
            expanded: tab(id)?.expandedPane != nil, cwd: directory(id),
            groupID: workspace.groups.values.first { $0.tabOrder.contains(tab(id)!.id) }?.id.rawValue,
            hasSplitGroups: (workspace.groupLayout?.leaves.count ?? 0) > 1) }
    }
    var tabGroups: [ShellTabGroupItem] {
        (workspace.groupLayout?.leaves ?? []).compactMap { id in
            guard let group = workspace.groups[id], workspace.groups.count > 1 || group.name != nil else { return nil }
            return ShellTabGroupItem(id: id.rawValue, title: group.name ?? "Group", color: group.color.map(Self.color), collapsed: group.collapsed == true)
        }
    }
    func groupAction(_ action: ShellGroupAction) {
        switch action {
        case .create(let session): if let tab = tab(session) { _ = apply(.createGroup(tab.id, name: "Group")) }
        case .rename(let id, let name): _ = apply(.renameGroup(GroupID(rawValue: id), name))
        case .color(let id, let color): _ = apply(.setGroupColor(GroupID(rawValue: id), color))
        case .collapse(let id, let collapsed): _ = apply(.setGroupCollapsed(GroupID(rawValue: id), collapsed))
        case .ungroup(let id): _ = apply(.ungroup(GroupID(rawValue: id)))
        case .move(let session, let id):
            if let tab = tab(session), let group = workspace.groups[GroupID(rawValue: id)] {
                _ = apply(.moveTab(tab.id, toGroup: group.id, index: group.tabOrder.count))
            }
        }
        flush()
    }
    func reopenClosedTab() async { await execute(apply(.reopenClosedTab(.home))) }
    func cycleTab(forward: Bool) { _ = apply(forward ? .nextTab(.home) : .previousTab(.home)) }

    func directory(_ id: String) -> String? { directories[id] ?? sessions.first { $0.id == id }?.cwd ?? tab(id)?.startupCwd }
    var rootURL: URL? { selectedSessionID.flatMap { directory($0) }.map { URL(fileURLWithPath: $0) } }
    func rename(_ id: String, title: String?) { if let tab = tab(id) { _ = apply(.renameTab(tab.id, title)) } }
    func oscTitle(_ id: String, title: String) {
        if let pane = workspace.panes.values.first(where: { $0.binding?.sessionID == id }) {
            _ = apply(.renamePane(pane.id, title))
        }
    }
    var activeTab: TerminalTabRecord? {
        guard let group = workspace.activeGroup, let id = workspace.groups[group]?.activeTab else { return nil }
        return workspace.tabs[id]
    }
    func paneCommand(_ command: ShellCommand) { _ = apply(command) }
    func focus(_ pane: PaneID, tab: TabID) {
        _ = apply(.activateTab(tab)); _ = apply(.focusPane(tab, pane))
    }
    func paneDirectory(_ pane: PaneID, path: String?) {
        guard let path, var record = workspace.panes[pane] else { return }
        if let session = record.binding?.sessionID { directories[session] = path }
        guard record.startupCwd != path else { return }
        record.startupCwd = path
        state.workspaces[.home]?.panes[pane] = record
        scheduleSave()
    }
    func split(_ tab: TabID, pane: PaneID, side: PaneSide) async {
        guard hostIsRunning, !creatingShell else { return }
        creatingShell = true
        defer { creatingShell = false }
        let grid = workspace.panes[pane]?.lastGrid
        let effects = apply(.splitPane(tab, pane: pane, side: side))
        // Seed the new PTY near its eventual grid before the first prompt. The
        // native terminal reports the exact cell count after AppKit lays it out.
        if let grid {
            let horizontal = side == .left || side == .right
            for id in effects.startPanes {
                _ = apply(.setPaneGrid(id, cols: horizontal ? max(1, (grid.cols - 1) / 2) : grid.cols,
                    rows: horizontal ? grid.rows : max(1, (grid.rows - 1) / 2)))
            }
        }
        await execute(effects)
    }
    func splitSession(_ id: String, side: PaneSide) {
        guard let tab = tab(id) else { return }
        Task { await split(tab.id, pane: tab.activePane, side: side) }
    }
    func moveSession(_ id: String, side: PaneSide) {
        if let tab = tab(id) { _ = apply(.moveTabToSplit(tab.id, side: side)) }
    }
    func closePane(_ pane: PaneID, tab: TabID) async {
        guard let record = workspace.tabs[tab] else { return }
        let command: ShellCommand = record.panes.leaves.count == 1 ? .closeTab(tab, force: true) : .closePane(tab, pane)
        guard case .success(let preview) = state.applying(command, ids: &ids) else { return }
        guard await execute(preview.effects) else { return }
        _ = apply(command); flush()
    }
    func closeActivePane() async {
        guard let tab = activeTab else { return }
        await closePane(tab.activePane, tab: tab.id)
    }

    func setColor(_ id: String, color: Color?) {
        if let tab = tab(id) { _ = apply(.setTabColor(tab.id, TabColor.allCases.first { Self.color($0) == color })) }
    }
    func togglePin(_ id: String) { if let tab = tab(id) { _ = apply(.setPinned(tab.id, !tab.isPinned)) } }
    func reorder(_ source: String, _ target: String, _ after: Bool) {
        guard let sourceTab = tab(source), let targetTab = tab(target),
              let group = workspace.groups.values.first(where: { $0.tabOrder.contains(targetTab.id) }) else { return }
        let remaining = group.tabOrder.filter { $0 != sourceTab.id }
        guard let index = remaining.firstIndex(of: targetTab.id) else { return }
        let selected = selectedSessionID
        _ = apply(.moveTab(sourceTab.id, toGroup: group.id, index: index + (after ? 1 : 0)))
        if let selected, selected != source { selectedSessionID = selected }
    }

    /// Commands are pure transactions; the caller awaits emitted host effects where necessary.
    @discardableResult private func apply(_ command: ShellCommand) -> ShellEffects {
        switch state.applying(command, ids: &ids) {
        case .success(let applied):
            if state != applied.state { state = applied.state; scheduleSave() }
            return applied.effects
        case .failure(let error): actionError = "Shell command refused: \(error)"; return ShellEffects()
        }
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.flush()
        }
    }
    /// Also called synchronously by the app delegate at termination.
    @discardableResult func flush() -> Bool {
        saveTask?.cancel()
        do { try ShellStateStore.save(state, to: stateURL); return true }
        catch { actionError = "Could not save shell state: \(error)"; return false }
    }
    @discardableResult private func execute(_ effects: ShellEffects) async -> Bool {
        for id in effects.stopSessions {
            stopping.insert(id)
            do { try await executor.close(id); retiredSessions.insert(id) }
            catch {
                stopping.remove(id)
                actionError = "Could not close terminal: \(error)"
                return false
            }
            stopping.remove(id)
        }
        for pane in effects.startPanes { await start(pane) }
        return true
    }
    private func start(_ id: PaneID) async {
        guard !starting.contains(id), var pane = workspace.panes[id], pane.binding == nil,
              case .running(let host, _) = snapshot?.state else { return }
        starting.insert(id)
        defer { starting.remove(id) }
        if pane.pendingCreateRequestID == nil {
            _ = apply(.paneStarting(id, requestID: .generate()))
            pane = workspace.panes[id]!
        }
        let requestID = pane.pendingCreateRequestID!
        let recordURL = stateURL.deletingLastPathComponent().appendingPathComponent(
            "shell-create-" + Data(requestID.rawValue.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") + ".json")
        do {
            let parameters: ShellCreateParameters
            if FileManager.default.fileExists(atPath: recordURL.path) {
                parameters = try JSONDecoder().decode(ShellCreateParameters.self, from: Data(contentsOf: recordURL))
            } else {
                if let pendingRestart = restartParameters[id] { parameters = pendingRestart }
                else if FileManager.default.fileExists(atPath: restartURL(id).path) {
                    parameters = try JSONDecoder().decode(ShellCreateParameters.self, from: Data(contentsOf: restartURL(id)))
                } else {
                    parameters = ShellCreateParameters(executable: "/bin/zsh", arguments: ["-l"],
                        cwd: pane.startupCwd, rows: pane.lastGrid?.rows ?? 24, cols: pane.lastGrid?.cols ?? 80)
                }
                // Persist exact parameters before the pending shell state and before RPC.
                try saveParameters(parameters, to: recordURL)
            }
            guard flush() else { return }
            let created = try await executor.create(requestID: requestID, parameters: parameters)
            guard workspace.panes[id] != nil else { try? await executor.close(created.id); return }
            _ = apply(.bindSession(id, Self.binding(created, host: host)))
            awaitingSnapshot[created.id] = Date()
            if let snapshot { self.snapshot = HostSnapshot(state: snapshot.state,
                sessions: snapshot.sessions.filter { $0.id != created.id } + [created]) }
            if flush() {
                try? FileManager.default.removeItem(at: recordURL)
                try? FileManager.default.removeItem(at: restartURL(id))
            }
            restartParameters.removeValue(forKey: id)
        } catch { actionError = "Could not start terminal: \(error)" }
    }
    private func restartURL(_ pane: PaneID) -> URL {
        let name = Data(pane.rawValue.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return stateURL.deletingLastPathComponent().appendingPathComponent("shell-restart-" + name + ".json")
    }
    private func saveParameters(_ parameters: ShellCreateParameters, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(parameters).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }
    func newShell() async {
        guard hostIsRunning, !creatingShell else { return }
        creatingShell = true
        defer { creatingShell = false }
        let effects = apply(.createTab(.home, group: nil,
            cwd: FileManager.default.homeDirectoryForCurrentUser.path, title: nil))
        if let size = TerminalSizeHint.latest {
            for pane in effects.startPanes { _ = apply(.setPaneGrid(pane, cols: size.cols, rows: size.rows)) }
        }
        await execute(effects)
    }
    func restart(_ id: String) async {
        guard let tab = tab(id), let pane = tab.panes.leaves.first(where: { workspace.panes[$0]?.binding?.sessionID == id }) else { return }
        let original = sessions.first { $0.id == id }
        let grid = TerminalSizeHint.latest
        restartParameters[pane] = ShellCreateParameters(executable: original?.executable ?? "/bin/zsh",
            arguments: original?.arguments ?? ["-l"], cwd: directory(id),
            rows: grid?.rows ?? workspace.panes[pane]?.lastGrid?.rows ?? 24,
            cols: grid?.cols ?? workspace.panes[pane]?.lastGrid?.cols ?? 80)
        do { try saveParameters(restartParameters[pane]!, to: restartURL(pane)) }
        catch { actionError = "Could not save restart request: \(error)"; return }
        await execute(apply(.restartPane(pane)))
    }
    func close(_ id: String) async {
        guard let tab = tab(id) else { return }
        // Preview to obtain the model's effects, but retain the binding until every
        // close succeeds. A failed host call leaves the visible tab available for retry.
        guard case .success(let preview) = state.applying(.closeTab(tab.id, force: true), ids: &ids) else { return }
        guard await execute(preview.effects) else { return }
        _ = apply(.closeTab(tab.id, force: true))
        flush()
    }

    func write(_ text: String) async {
        guard let id = selectedSessionID else { return }
        do { try await executor.write(id, text: text) }
        catch { actionError = "Could not write to terminal: \(error)" }
    }
    var hostIsRunning: Bool { if case .running = snapshot?.state { true } else { false } }
    var hostLabel: String {
        switch snapshot?.state {
        case .none: "Connecting to host"
        case .notRunning: "Host not running"
        case .running: "Local host connected"
        case .error: "Host connection error"
        }
    }
    var hostDetail: String {
        switch snapshot?.state {
        case .running(let identity, let version): "smthzd \(version) · PID \(identity.pid)"
        case .error(let message): message
        case .notRunning: "Start smthzd to connect. This window reconnects automatically."
        case .none: "Checking the local host."
        }
    }
    func observeHost() async {
        let monitor = HostMonitor(socketPath: socketPath)
        await monitor.start()
        for await value in monitor.snapshots {
            guard !Task.isCancelled else { break }
            snapshot = value
            guard case .running(let host, _) = value.state else { continue }
            _ = apply(.hostIncarnationChanged(host))
            // Recover an interrupted create before adopting unattached sessions. Idempotency
            // returns the original host session even if the reply was lost before app termination.
            for pane in workspace.panes.values where pane.pendingCreateRequestID != nil || pane.state == .unstarted {
                await start(pane.id)
            }
            guard starting.isEmpty else { continue }
            retiredSessions = retiredSessions.filter { id in value.sessions.contains { $0.id == id && $0.running } }
            let live = Set(value.sessions.map(\.id))
            awaitingSnapshot = awaitingSnapshot.filter { !live.contains($0.key) && Date().timeIntervalSince($0.value) < 10 }
            for pane in workspace.panes.values {
                if let binding = pane.binding, !live.contains(binding.sessionID),
                   !stopping.contains(binding.sessionID), awaitingSnapshot[binding.sessionID] == nil,
                   !(snapshot?.sessions.contains { $0.id == binding.sessionID } ?? false) {
                    _ = apply(.processExited(pane.id, .init(spawnedFresh: false, restored: true,
                        inputWritten: false, outputReceived: false, tabHadPaneAtConnect: true, attachAbsent: true)))
                }
            }
            let attached = Set(workspace.panes.values.compactMap { $0.binding?.sessionID })
            let selected = selectedSessionID
            for session in value.sessions where session.running && !attached.contains(session.id) && !stopping.contains(session.id) && !retiredSessions.contains(session.id) {
                _ = apply(.adoptSession(.home, session, host: host))
            }
            if let selected, selectedSessionID != selected, visibleIDs.contains(selected) { selectedSessionID = selected }
        }
        await monitor.stop()
    }
    private static func binding(_ session: SessionInfo, host: ProcessIdentity) -> SessionBinding {
        SessionBinding(hostIncarnation: host, sessionID: session.id,
            process: ProcessIdentity(pid: session.pid, startSeconds: session.startSeconds, startMicroseconds: session.startMicroseconds))
    }
    private static func color(_ value: TabColor) -> Color {
        let rgb: (Double, Double, Double)
        switch value {
        case .blue: rgb = (59,130,246)
        case .purple: rgb = (168,85,247)
        case .pink: rgb = (236,72,153)
        case .red: rgb = (239,68,68)
        case .orange: rgb = (249,115,22)
        case .yellow: rgb = (234,179,8)
        case .green: rgb = (34,197,94)
        case .teal: rgb = (20,184,166)
        case .gray: rgb = (156,163,175)
        }
        return Color(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255)
    }
}
