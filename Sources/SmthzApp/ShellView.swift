import AppKit
import SwiftUI
import SmthzCore

// VISUAL-ONLY: stub data until M4 workspaces/projects and the destination backends.
enum Destination: String, CaseIterable, Identifiable {
    case workspaces = "Workspaces", tasks = "Tasks", automations = "Automations", activity = "smthz Mobile"
    var id: Self { self }
}

private struct OpenShellSettingsKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> Void = {}
}
extension EnvironmentValues {
    var openShellSettings: @MainActor @Sendable () -> Void {
        get { self[OpenShellSettingsKey.self] }
        set { self[OpenShellSettingsKey.self] = newValue }
    }
}

struct ShellView: View {
    let appModel: AppModel
    @AppStorage("shell.sidebarOpen") private var sidebarOpen = true
    @AppStorage("shell.rightSidebarOpen") private var rightSidebarOpen = true
    @AppStorage("shell.rightSidebarPanel") private var rightPanel = "explorer"
    @AppStorage("onboarding.completed") private var onboardingCompleted = false
    @State private var settingsPage: String?
    @State private var monitorGeneration = 0
    @State private var toast: SmthzToastMessage?
    @State private var overlay: Surface?
    @State private var palette = SmthzJumpPaletteModel()
    @State private var catalog = WorkspaceCatalogModel()
    @State private var confirmations = SmthzCloseConfirmationCoordinator()
    @State private var quickCommandsOpen = false
    @State private var renameID: String?
    @State private var renameDraft = ""
    private enum Surface { case jump, files, newWorkspace, addProject, deleteWorkspace, onboarding }
    private var model: ShellController { appModel.workspace }

    var body: some View {
        ZStack {
            Group {
            if !onboardingCompleted {
                SmthzOnboardingView(onFinish: { onboardingCompleted = true },
                                    onAddProject: { overlay = .addProject })
            } else if let settingsPage {
                SettingsView(model: model, sidebarOpen: $sidebarOpen, rightSidebarOpen: $rightSidebarOpen,
                             onBack: { self.settingsPage = nil }, initialPage: settingsPage)
                    .id(settingsPage)
            } else {
                ShellLayout(sidebarOpen: $sidebarOpen, rightSidebarOpen: $rightSidebarOpen,
                    sidebar: sidebar, tabs: tabs, content: workspace,
                    right: RightSidebarSlot(isOpen: $rightSidebarOpen, model: model),
                    status: StatusBarSlot(model: model, host: HostController.shared, goToSession: { select($0) }))
            }
            }
            .disabled(overlay != nil)
            .accessibilityHidden(overlay != nil)
            surfaces
        }
        .environment(\.openShellSettings, { openSettings("appearance") })
        .environment(\.smthzShellActions, SmthzShellActions(canPerform: canPerform, perform: perform))
        .focusedSceneValue(\.smthzShellActions, SmthzShellActions(canPerform: canPerform, perform: perform))
        .environment(\.smthzProjectActions, projectActions)
        .environment(\.smthzWorkspaceDirectories, workspaceDirectories)
        .environment(\.smthzWorkspaceActions, ["default": SmthzWorkspaceActions(
            rename: { model.workspaceTitle = $0 }, setPinned: { model.workspacePinned = $0 },
            setUnread: { model.workspaceUnread = $0 }, delete: { overlay = .deleteWorkspace })])
        .background(SmthzRegistryShortcutMonitor(actions: SmthzShellActions(canPerform: canPerform, perform: perform), enabled: overlay == nil && renameID == nil))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUpdateNotification)) { _ in SmthzKeybindings.shared.updateFocus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in SmthzKeybindings.shared.reload() }
        .onChange(of: SmthzKeybindings.shared.diagnostics, initial: true) { _, diagnostics in
            if !diagnostics.isEmpty { toast = SmthzToastMessage(title: "Keybinding configuration", description: diagnostics.map(\.message).joined(separator: "\n"), kind: .error) }
        }
        .background(SmthzShellEscapeKey(perform: dismissTopSurface))
        .background(WindowChrome()).ignoresSafeArea().tint(SmthzTheme.foreground)
        .allowsWindowActivationEvents()
        .task(id: monitorGeneration) { await model.observeHost() }
        .task(id: monitorGeneration) { await catalog.observe() }
        .onChange(of: model.actionError) { _, message in
            if let message { toast = SmthzToastMessage(title: "Terminal action failed", description: message, kind: .error); model.actionError = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("smthz.terminal.quickCommands"))) { note in
            guard note.object as? String == model.selectedSessionID else { return }
            SmthzQuickCommandStore.shared.editor = SmthzQuickCommand()
        }
        .smthzToast($toast)
        .smthzCloseConfirmations(confirmations)
        .smthzQuickCommandDialogs()
        .smthzDialog(isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } }),
                     title: "Rename Tab", compact: true) {
            TextField("Tab title", text: $renameDraft).textFieldStyle(.roundedBorder).onSubmit(commitRename)
        } footer: {
            Button("Cancel") { renameID = nil }.buttonStyle(SmthzButtonStyle(.outline))
            Button("Rename", action: commitRename).buttonStyle(SmthzButtonStyle())
        }
        .background {
            if overlay != nil {
                Button("Dismiss overlay", action: dismiss).keyboardShortcut(.cancelAction).hidden()
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ShellTitleControls(sidebarOpen: $sidebarOpen).frame(height: SmthzMetrics.titleBandHeight)
                .overlay(alignment: .bottom) { SmthzTheme.border.frame(height: 1) }
            SidebarView(destination: appModel.destination, projects: projects,
                canCreateWorkspace: model.hostIsRunning && !model.creatingShell,
                onSelectDestination: { appModel.destination = $0 }, onSearch: showJump,
                onSelectWorkspace: selectWorkspace,
                onNewWorkspace: { overlay = .newWorkspace }, onAddProject: { overlay = .addProject },
                onOpenSettings: { openSettings("appearance") },
                onScrollToCurrent: { appModel.destination = .workspaces },
                onOpenTaskProvider: { _ in appModel.destination = .tasks },
                onKeyboardShortcuts: { openSettings("shortcuts") },
                onSendFeedback: { unavailable("Feedback") }, onOnboarding: { overlay = .onboarding },
                onCheckForUpdates: { unavailable("Update checking") })
        }.background(SmthzTheme.worktreeSidebar)
    }
    /// "Local host" keeps the default workspace; each registered project lists its main checkout
    /// (and linked worktrees once WP-M4-WORKTREE-HOST lands); project groups list folder workspaces.
    private var projects: [SidebarProject] {
        let count = model.sessionCount(.home)
        let card = WorkspaceCardData(id: "default", title: model.state.workspaces[.home]?.displayName == "Home" ? "Default workspace"
                                        : model.state.workspaces[.home]?.displayName ?? "Default workspace",
            detail: count == 1 ? "1 session" : "\(count) sessions", status: count > 0 ? .live : .idle,
            isActive: appModel.destination == .workspaces && model.activeKey == .home, isUnread: model.workspaceUnread,
            isPinned: model.workspacePinned, isSleeping: !model.hostIsRunning, directory: model.activeKey == .home ? model.rootURL : nil)
        let groupNames = Dictionary(uniqueKeysWithValues: catalog.groups.map { ($0.id, $0.name) })
        return [SidebarProject(id: "local", title: "Local host", subtitle: nil, workspaces: [card])]
            + catalog.projects.map { project in
                SidebarProject(id: project.id, title: project.title, subtitle: project.groupID.flatMap { groupNames[$0] },
                               workspaces: project.workspaces.map(card(for:)))
            }
            + catalog.groups.filter { !$0.folders.isEmpty }.map { group in
                SidebarProject(id: "group:" + group.id, title: group.name, subtitle: "Folders", workspaces: group.folders.map(card(for:)))
            }
    }
    private func card(for workspace: WorkspaceCatalogModel.Workspace) -> WorkspaceCardData {
        let count = model.sessionCount(workspace.key)
        return WorkspaceCardData(id: workspace.id, title: workspace.title,
            detail: count == 1 ? "1 session" : "\(count) sessions", status: count > 0 ? .live : .idle,
            isActive: appModel.destination == .workspaces && model.activeKey == workspace.key,
            isUnread: workspace.isUnread, isPinned: workspace.isPinned, isSleeping: !model.hostIsRunning,
            directory: URL(fileURLWithPath: workspace.path, isDirectory: true),
            isPrimary: workspace.isMain, isFolder: workspace.isFolder)
    }
    private var workspaceDirectories: [String: URL] {
        var result = Dictionary(catalog.allWorkspaces.map { ($0.id, URL(fileURLWithPath: $0.path, isDirectory: true)) },
                                uniquingKeysWith: { a, _ in a })
        if model.activeKey == .home, let root = model.rootURL { result["default"] = root }
        return result
    }
    /// Keyed by project title (the header's lookup key).
    private var projectActions: [String: SmthzProjectActions] {
        var result: [String: SmthzProjectActions] = ["Local host": SmthzProjectActions(createWorkspace: {
            selectWorkspace("default"); overlay = .newWorkspace })]
        for project in catalog.projects {
            result[project.title] = SmthzProjectActions(
                remove: { removeProject(project) },
                createWorkspace: project.workspaces.first.map { main in { selectWorkspace(main.id); overlay = .newWorkspace } })
        }
        return result
    }
    /// Switching cards swaps the tab strip, panes and the right sidebar root; an empty project workspace opens a shell there.
    private func selectWorkspace(_ id: String) {
        appModel.destination = .workspaces
        if id == "default" {
            model.activateWorkspace(.home, displayName: model.state.workspaces[.home]?.displayName ?? "Default workspace", rootPath: nil)
            return
        }
        guard let workspace = catalog.workspace(WorkspaceKey(rawValue: id)) else { return }
        model.activateWorkspace(workspace.key, displayName: workspace.title, rootPath: workspace.path)
        if model.workspace.tabs.isEmpty, model.hostIsRunning { Task { await model.newShell() } }
    }
    private func removeProject(_ project: WorkspaceCatalogModel.Project) {
        Task {
            do {
                try await catalog.removeRepo(project.id)
                if catalog.project(containing: model.activeKey) == nil, model.activeKey != .home,
                   model.activeKey.rawValue.hasPrefix("worktree:") { selectWorkspace("default") }
                toast = SmthzToastMessage(title: "Project removed", description: "\(project.title) was removed from smthz. No files were deleted.", kind: .info)
            } catch let failure as WorkspaceCatalogModel.HostFailure where failure.code == "hasLiveSessions" {
                toast = SmthzToastMessage(title: "Project has running terminals", description: "Close the terminals inside \(project.title) first.", kind: .error)
            } catch {
                toast = SmthzToastMessage(title: "Could not remove project", description: error.localizedDescription, kind: .error)
            }
        }
    }
    private var tabs: some View {
        TabStripView(tabs: model.tabs, select: select, close: close,
            rename: { model.rename($0, title: $1) }, togglePin: model.togglePin, reorder: model.reorder,
            split: { id, down in model.splitSession(id, side: down ? .bottom : .right) },
            moveToPane: { id, side in if let side = PaneSide(rawValue: side) { model.moveSession(id, side: side) } },
            equalize: { id in
                model.selectedSessionID = id
                if let tab = model.activeTab { model.paneCommand(.equalizePanes(tab.id)) }
            },
            collapsePane: { id in model.selectedSessionID = id; if let tab = model.activeTab { model.paneCommand(.toggleExpandPane(tab.id, tab.activePane)) } },
            closeSplitPane: { id in model.selectedSessionID = id; if let tab = model.activeTab { closePane(tab.activePane, tab.id) } },
            command: { quickCommandsOpen.toggle() }, createActions: createActions,
            closeOthers: closeOthers, colourChange: { model.setColor($0, color: $1) },
            copyResult: { success in toast = SmthzToastMessage(title: success ? "Tab ID copied" : "Could not copy Tab ID", kind: success ? .success : .error) }, groups: model.tabGroups, groupAction: model.groupAction)
            .padding(.trailing, 32)
            .popover(isPresented: $quickCommandsOpen) {
                QuickCommandsMenu(canRun: model.selectedSessionID != nil && model.hostIsRunning,
                    dismiss: { quickCommandsOpen = false }, run: { text in Task { await model.write(text) } })
            }
    }
    private var createActions: [TabCreateAction] {
        [TabCreateAction(id: "shell", title: "New Terminal", icon: .squareTerminal,
                         enabled: model.hostIsRunning && !model.creatingShell, shortcut: SmthzKeybindings.shared.label(.tabNewTerminal), perform: newShell)]
        + [("agent", "Launch agent", "bot", KeybindingAction.tabNewAgent), ("browser", "New Browser Tab", "globe", .tabNewBrowser),
           ("emulator", "New Mobile Emulator", "smartphone", .tabNewSimulator),
           ("markdown", "New Markdown", "file-plus", .tabNewMarkdown), ("open-markdown", "Open Markdown...", "file-text", .tabOpenMarkdown)]
            .map { id, title, icon, action in
                TabCreateAction(id: id, title: title, icon: .init(rawValue: icon), enabled: false,
                                shortcut: SmthzKeybindings.shared.label(action), unavailableReason: "Not available yet", perform: {})
            }
    }
    @ViewBuilder private var workspace: some View {
        switch appModel.destination ?? .workspaces {
        case .tasks: SmthzTasksPage(onClose: returnToWorkspace)
        case .automations: SmthzAutomationsPage(onClose: returnToWorkspace)
        case .activity: SmthzMobilePage(onClose: returnToWorkspace)
        case .workspaces:
            if !model.hostIsRunning {
                LandingView(variant: .hostNotRunning, bindings: SmthzKeybindings.shared.registry,
                    onStartHost: { HostController.shared.start(); monitorGeneration += 1 },
                    onRetry: { HostController.shared.start(); monitorGeneration += 1 })
            } else if model.activeTab != nil {
                LayoutSplitView(model: model, close: closePane)
                    .accessibilityLabel("Terminal panes")
            } else {
                LandingView(hasProjects: !catalog.projects.isEmpty, bindings: SmthzKeybindings.shared.registry, onAddProject: { overlay = .addProject },
                            onCreateWorkspace: { overlay = .newWorkspace })
            }
        }
    }
    @ViewBuilder private var surfaces: some View {
        if let overlay {
            switch overlay {
            case .jump: SmthzJumpPalette(model: palette, onAction: paletteAction, onDismiss: dismiss)
            case .files: SmthzGoToFilePalette(root: model.rootURL, onOpen: { InterimFileOpener.open($0) }, onDismiss: dismiss)
            case .newWorkspace:
                modal { SmthzNewWorkspaceComposer(onDismiss: dismiss, onAddProject: { self.overlay = .addProject },
                    onCreateShell: newShell, onAgentSettings: { dismiss(); openSettings("agents") }) }
            case .addProject:
                modal { SmthzAddProjectDialog(catalog: catalog, onDismiss: dismiss, onAdded: { key in
                    if let key { selectWorkspace(key.rawValue) } }) }
            case .deleteWorkspace:
                modal { SmthzDeleteWorkspaceDialog(targets: [.init(id: "default", name: model.workspaceTitle, path: model.rootURL?.path)],
                    onCancel: dismiss, onConfirm: { _ in dismiss(); unavailable("Workspace deletion") }) }
            case .onboarding: SmthzOnboardingView(onFinish: dismiss, onAddProject: { self.overlay = .addProject })
            }
        }
    }
    private func modal<V: View>(@ViewBuilder content: () -> V) -> some View {
        ZStack { Color.black.opacity(0.55).ignoresSafeArea().onTapGesture(perform: dismiss); content().padding(24) }
    }
    private func dismissTopSurface() -> Bool {
        let store = SmthzQuickCommandStore.shared
        if store.pendingDeletion != nil { store.pendingDeletion = nil; return true }
        if store.editor != nil { store.editor = nil; return true }
        if confirmations.prompt != nil { confirmations.cancel(); return true }
        if renameID != nil { renameID = nil; return true }
        if overlay != nil { overlay = nil; return true }
        if settingsPage != nil { settingsPage = nil; return true }
        if appModel.destination != .workspaces { returnToWorkspace(); return true }
        return false
    }
    private func dismiss() { overlay = nil }
    private func returnToWorkspace() { appModel.destination = .workspaces }
    private func select(_ id: String) {
        model.selectedSessionID = id; settingsPage = nil; returnToWorkspace()
    }
    private func newShell() {
        settingsPage = nil; returnToWorkspace(); Task { await model.newShell() }
    }
    private func closePane(_ pane: PaneID, _ tab: TabID) {
        guard let record = model.workspace.panes[pane], let session = record.binding?.sessionID else { return }
        Task {
            await confirmations.confirmClose(sessionID: session, socketPath: model.socketPath,
                tabLabel: record.title ?? model.title(session), isPinned: model.workspace.tabs[tab]?.isPinned == true) {
                    Task { await model.closePane(pane, tab: tab) }
                }
        }
    }
    private func close(_ id: String) {
        Task {
            await confirmations.confirmClose(sessionID: id, socketPath: model.socketPath,
                tabLabel: model.title(id), isPinned: model.pinned.contains(id)) {
                    Task { await model.close(id) }
                }
        }
    }
    private func closeOthers(_ id: String) {
        confirmations.confirmClose(.otherTabs, tabIDs: model.visibleIDs.filter { $0 != id }, pinnedTabIDs: model.pinned) { ids in
            Task { for id in ids { await model.close(id) } }
        }
    }
    private func commitRename() {
        if let renameID, !renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.rename(renameID, title: renameDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        renameID = nil
    }
    private func openSettings(_ page: String) { overlay = nil; settingsPage = page }
    private func unavailable(_ title: String) { toast = SmthzToastMessage(title: title, description: "Not available yet", kind: .info) }
    private func showJump() {
        palette = SmthzJumpPaletteModel(openTabs: model.tabs.map {
            .init(id: $0.id, title: $0.title, subtitle: $0.cwd ?? "", action: .selectTab($0.id))
        }); overlay = .jump
    }
    private func paletteAction(_ action: SmthzJumpPaletteModel.Action) {
        switch action {
        case .selectTab(let id): select(id)
        case .selectWorkspace: returnToWorkspace()
        case .newTerminal: newShell()
        case .settings(let page): openSettings(page)
        case .toggleLeftSidebar: sidebarOpen.toggle()
        case .toggleRightSidebar: rightSidebarOpen.toggle()
        }
    }
    private func perform(_ action: SmthzShellActions.Action) {
        switch action {
        case .keybinding(let action, let index): performKeybinding(action, index: index)
        case .newTerminal: newShell()
        case .closeTab: if let tab = model.activeTab { closePane(tab.activePane, tab.id) }
        case .renameTab:
            if let id = model.selectedSessionID { renameDraft = model.title(id); renameID = id }
        case .clearTerminal:
            NotificationCenter.default.post(name: .init("smthz.terminal.clear"), object: model.selectedSessionID)
        case .recentTab: if let id = model.recentIDs.dropFirst().first(where: { model.visibleIDs.contains($0) }) { select(id) }
        case .selectTab(let index): if model.visibleIDs.indices.contains(index - 1) { select(model.visibleIDs[index - 1]) }
        case .jumpPalette: showJump()
        case .quickOpen: overlay = .files
        case .settings: openSettings("appearance")
        case .keyboardShortcuts: openSettings("shortcuts")
        case .showExplorer: showPanel(.explorer)
        case .showSourceControl: showPanel(.sourceControl)
        case .showPorts: showPanel(.ports)
        case .explore: settingsPage = nil; returnToWorkspace(); model.selectedSessionID = nil
        case .gettingStarted: overlay = .onboarding
        }
    }
    private func canPerform(_ action: KeybindingAction) -> Bool {
        guard action.available, overlay == nil, renameID == nil else { return false }
        if action == .tabNewTerminal { return model.hostIsRunning && !model.creatingShell }
        if action == .tabReopenClosed { return model.hostIsRunning && !model.workspace.recentlyClosed.isEmpty }
        if action.scope == .terminal || action.scope == .tabs {
            return settingsPage == nil && appModel.destination == .workspaces && model.activeTab != nil
                && !(NSApp.keyWindow?.firstResponder is NSTextView)
        }
        return true
    }
    private func performKeybinding(_ action: KeybindingAction, index: Int?) {
        guard canPerform(action) else { return }
        switch action {
        case .tabNewTerminal: newShell()
        case .tabClose, .terminalClosePane: perform(.closeTab)
        case .tabCloseAll:
            confirmations.confirmClose(.otherTabs, tabIDs: model.visibleIDs, pinnedTabIDs: model.pinned) { ids in
                Task { for id in ids { await model.close(id) } }
            }
        case .tabRename: perform(.renameTab)
        case .tabReopenClosed: Task { await model.reopenClosedTab() }
        case .tabNextAllTypes, .tabNextSameType, .tabNextTerminal: model.cycleTab(forward: true)
        case .tabPreviousAllTypes, .tabPreviousSameType, .tabPreviousTerminal: model.cycleTab(forward: false)
        case .tabPreviousRecent: model.paneCommand(.previousRecentTab(.home))
        case .tabSelectByIndex: if let index { model.paneCommand(.selectTab(.home, index: index)) }
        case .tabOpenQuickCommandsMenu: quickCommandsOpen.toggle()
        case .terminalSplitRight, .terminalSplitDown:
            if let tab = model.activeTab { Task { await model.split(tab.id, pane: tab.activePane, side: action == .terminalSplitRight ? .right : .bottom) } }
        case .terminalFocusNextPane, .terminalFocusPreviousPane:
            if let tab = model.activeTab { model.paneCommand(action == .terminalFocusNextPane ? .focusNextPane(tab.id) : .focusPreviousPane(tab.id)) }
        case .terminalExpandPane: if let tab = model.activeTab { model.paneCommand(.toggleExpandPane(tab.id, tab.activePane)) }
        case .terminalEqualizePaneSizes: if let tab = model.activeTab { model.paneCommand(.equalizePanes(tab.id)) }
        case .terminalSetTitle:
            if let tab = model.activeTab {
                let alert = NSAlert(); alert.messageText = "Set Pane Title"
                let field = NSTextField(string: model.workspace.panes[tab.activePane]?.title ?? "")
                field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
                alert.accessoryView = field; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { model.paneCommand(.renamePane(tab.activePane, field.stringValue)) }
            }
        case .terminalClearPaneTitle: if let tab = model.activeTab { model.paneCommand(.renamePane(tab.activePane, nil)) }
        case .terminalCopySelection, .terminalPaste, .terminalSelectAll, .terminalSearch:
            let selector = action == .terminalCopySelection ? "copy:" : action == .terminalPaste ? "paste:" : action == .terminalSelectAll ? "selectAll:" : "performTextFinderAction:"
            NSApp.sendAction(Selector(selector), to: NSApp.keyWindow?.firstResponder, from: nil)
        case .terminalClear: perform(.clearTerminal)
        case .appSettings: perform(.settings)
        case .appForceReload: monitorGeneration += 1
        case .worktreePalette: showJump()
        case .worktreeQuickOpen: overlay = .files
        case .workspaceCreate: overlay = .newWorkspace
        case .viewTasks: appModel.destination = .tasks
        case .sidebarLeftToggle: sidebarOpen.toggle()
        case .sidebarRightToggle: rightSidebarOpen.toggle()
        case .sidebarExplorerToggle: showPanel(.explorer)
        case .sidebarSearchToggle: showPanel(.search)
        case .sidebarSourceControlToggle: showPanel(.sourceControl)
        case .sidebarChecksToggle: showPanel(.checks)
        case .sidebarPortsToggle: showPanel(.ports)
        case .zoomIn: model.terminalFontSize = min(40, model.terminalFontSize + 1)
        case .zoomOut: model.terminalFontSize = max(8, model.terminalFontSize - 1)
        case .zoomReset: model.terminalFontSize = 14
        default: break // Registry unavailable actions never enter this dispatcher.
        }
    }
    private func showPanel(_ panel: RightSidebarPanel) { rightPanel = panel.rawValue; rightSidebarOpen = true }
}

/// Escape remains window-scoped when an AppKit terminal is the first responder.
private struct SmthzShellEscapeKey: NSViewRepresentable {
    let perform: () -> Bool
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) { view.perform = perform }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.removeMonitor() }
    final class KeyView: NSView {
        var perform: () -> Bool = { false }
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, event.window === self.window, event.keyCode == 53 else { return false }
                    return self.perform()
                }
                return handled ? nil : event
            }
        }
        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
