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
                    status: StatusBarSlot(model: model, goToSession: { select($0) }))
            }
            }
            .disabled(overlay != nil)
            .accessibilityHidden(overlay != nil)
            surfaces
        }
        .environment(\.openShellSettings, { openSettings("appearance") })
        .environment(\.smthzShellActions, SmthzShellActions(perform: perform))
        .focusedSceneValue(\.smthzShellActions, SmthzShellActions(perform: perform))
        .environment(\.smthzProjectActions, ["Local host": SmthzProjectActions(
            createWorkspace: { overlay = .newWorkspace })])
        .environment(\.smthzWorkspaceDirectories, model.rootURL.map { ["default": $0] } ?? [:])
        .environment(\.smthzWorkspaceActions, ["default": SmthzWorkspaceActions(
            rename: { model.workspaceTitle = $0 }, setPinned: { model.workspacePinned = $0 },
            setUnread: { model.workspaceUnread = $0 }, delete: { overlay = .deleteWorkspace })])
        .background(SmthzShellEscapeKey(perform: dismissTopSurface))
        .background(WindowChrome()).ignoresSafeArea().tint(SmthzTheme.foreground)
        .allowsWindowActivationEvents()
        .task(id: monitorGeneration) { await model.observeHost() }
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
            Button("Create workspace") { overlay = .newWorkspace }.keyboardShortcut("n").hidden()
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
                onSelectWorkspace: { _ in appModel.destination = .workspaces },
                onNewWorkspace: { overlay = .newWorkspace }, onAddProject: { overlay = .addProject },
                onOpenSettings: { openSettings("appearance") },
                onScrollToCurrent: { appModel.destination = .workspaces },
                onOpenTaskProvider: { _ in appModel.destination = .tasks },
                onKeyboardShortcuts: { openSettings("shortcuts") },
                onSendFeedback: { unavailable("Feedback") }, onOnboarding: { overlay = .onboarding },
                onCheckForUpdates: { unavailable("Update checking") })
        }.background(SmthzTheme.worktreeSidebar)
    }
    private var projects: [SidebarProject] {
        let count = model.visibleIDs.count
        let card = WorkspaceCardData(id: "default", title: model.workspaceTitle,
            detail: count == 1 ? "1 session" : "\(count) sessions", status: count > 0 ? .live : .idle,
            isActive: appModel.destination == .workspaces, isUnread: model.workspaceUnread,
            isPinned: model.workspacePinned, isSleeping: !model.hostIsRunning, directory: model.rootURL)
        return [SidebarProject(id: "local", title: "Local host", subtitle: nil, workspaces: [card])]
    }
    private var tabs: some View {
        TabStripView(tabs: model.tabs, select: select, close: close,
            rename: { model.rename($0, title: $1) }, togglePin: model.togglePin, reorder: model.reorder,
            command: { quickCommandsOpen.toggle() }, createActions: createActions,
            closeOthers: closeOthers, colourChange: { model.setColor($0, color: $1) },
            copyResult: { success in toast = SmthzToastMessage(title: success ? "Tab ID copied" : "Could not copy Tab ID", kind: success ? .success : .error) })
            .padding(.trailing, 32)
            .popover(isPresented: $quickCommandsOpen) {
                QuickCommandsMenu(canRun: model.selectedSessionID != nil && model.hostIsRunning,
                    dismiss: { quickCommandsOpen = false }, run: { text in Task { await model.write(text) } })
            }
    }
    private var createActions: [TabCreateAction] {
        [TabCreateAction(id: "shell", title: "New Terminal", icon: .squareTerminal,
                         enabled: model.hostIsRunning && !model.creatingShell, shortcut: "⌘T", perform: newShell)]
        + [("agent", "Launch agent", "bot", "⌥⌘T"), ("browser", "New Browser Tab", "globe", "⌘⇧B"),
           ("emulator", "New Mobile Emulator", "smartphone", "⌥⌘⇧E"),
           ("markdown", "New Markdown", "file-plus", "⌘⇧M"), ("open-markdown", "Open Markdown...", "file-text", "⌘⇧O")]
            .map { id, title, icon, shortcut in
                TabCreateAction(id: id, title: title, icon: .init(rawValue: icon), enabled: false,
                                shortcut: shortcut, unavailableReason: "Not available yet", perform: {})
            }
    }
    @ViewBuilder private var workspace: some View {
        switch appModel.destination ?? .workspaces {
        case .tasks: SmthzTasksPage(onClose: returnToWorkspace)
        case .automations: SmthzAutomationsPage(onClose: returnToWorkspace)
        case .activity: SmthzMobilePage(onClose: returnToWorkspace)
        case .workspaces:
            if !model.hostIsRunning {
                LandingView(variant: .hostNotRunning, onRetry: { monitorGeneration += 1 })
            } else if let id = model.selectedSessionID {
                TerminalSessionView(sessionID: id, socketPath: model.socketPath, fontSize: model.terminalFontSize,
                    onTitleChange: { model.oscTitle(id, title: $0) },
                    onDirectoryChange: { model.directories[id] = $0 },
                    restartSession: { await model.restart(id) }, onClose: { close(id) })
                    .id(id).accessibilityLabel("Terminal")
            } else {
                LandingView(hasProjects: false, onAddProject: { overlay = .addProject },
                            onCreateWorkspace: { overlay = .newWorkspace })
            }
        }
    }
    @ViewBuilder private var surfaces: some View {
        if let overlay {
            switch overlay {
            case .jump: SmthzJumpPalette(model: palette, onAction: paletteAction, onDismiss: dismiss)
            case .files: SmthzGoToFilePalette(root: model.rootURL, onOpen: { _ in unavailable("File editor") }, onDismiss: dismiss)
            case .newWorkspace:
                modal { SmthzNewWorkspaceComposer(onDismiss: dismiss, onAddProject: { self.overlay = .addProject },
                    onCreateShell: newShell, onAgentSettings: { dismiss(); openSettings("agents") }) }
            case .addProject: modal { SmthzAddProjectDialog(onDismiss: dismiss) }
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
        case .newTerminal: newShell()
        case .closeTab: if let id = model.selectedSessionID { close(id) }
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
