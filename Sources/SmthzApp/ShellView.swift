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
    @State private var lifecycle = WorktreeLifecycleModel()
    @State private var composerProjectID: String?
    @State private var deleteFailure: (message: String, force: String, options: WorkspaceComposerLogic.RemoveOptions)?
    @State private var deleteWorking = false
    @State private var deleteTargets: [SmthzDeleteWorkspaceDialog.Target] = []
    /// A create blocked on a setup decision or untrusted shared command (Setup approval dialog).
    private struct SetupPending { let block: WorkspaceComposerLogic.CreateBlock; let params: [String: HostJSON]; let title: String }
    private enum Surface {
        case jump, files, newWorkspace, addProject, deleteWorkspace, onboarding
        case deleteWorktree(String), editWorkspace(String), setupApproval(SetupPending), preservedBranches(String), repositorySettings(String)
    }
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
        .environment(\.smthzWorkspaceActions, workspaceActions)
        .background(SmthzRegistryShortcutMonitor(actions: SmthzShellActions(canPerform: canPerform, perform: perform), enabled: overlay == nil && renameID == nil))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUpdateNotification)) { _ in SmthzKeybindings.shared.updateFocus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in SmthzKeybindings.shared.reload() }
        .onReceive(NotificationCenter.default.publisher(for: AttentionModel.openSession)) { note in
            if let id = note.object as? String { overlay = nil; select(id) }
        }
        .onChange(of: onboardingCompleted && settingsPage == nil && overlay == nil && renameID == nil, initial: true) { _, visible in
            AttentionModel.shared.surfaceVisible = visible
        }
        .onChange(of: SmthzKeybindings.shared.diagnostics, initial: true) { _, diagnostics in
            if !diagnostics.isEmpty { toast = SmthzToastMessage(title: "Keybinding configuration", description: diagnostics.map(\.message).joined(separator: "\n"), kind: .error) }
        }
        .background(SmthzShellEscapeKey(perform: dismissTopSurface))
        .background(WindowChrome()).ignoresSafeArea().tint(SmthzTheme.foreground)
        .allowsWindowActivationEvents()
        .task(id: monitorGeneration) { await model.observeHost() }
        .task(id: monitorGeneration) { await catalog.observe() }
        .task(id: monitorGeneration) {
            lifecycle.onCreated = worktreeCreated
            lifecycle.onWarning = { title, detail in toast = SmthzToastMessage(title: title, description: detail, kind: .warning) }
            await lifecycle.observe()
        }
        .onChange(of: lifecycle.rows) { _, rows in
            // `smthz worktree create --activate` asks the app to reveal the new workspace once.
            for row in rows.values where row.revealRequested && row.state == "ready" {
                Task {
                    try? await lifecycle.set(row.id, ["revealRequested": .bool(false)])
                    await catalog.refresh()
                    selectWorkspace("worktree:" + row.id)
                }
            }
        }
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
                onNewWorkspace: { openComposer() }, onAddProject: { overlay = .addProject },
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
        let row = lifecycle.row(workspace.key), job = lifecycle.job(workspace.key)
        var data = WorkspaceCardData(id: workspace.id, title: workspace.title, branch: row?.branch,
            detail: count == 1 ? "1 session" : "\(count) sessions", status: count > 0 ? .live : .idle,
            isActive: appModel.destination == .workspaces && model.activeKey == workspace.key,
            isUnread: workspace.isUnread, isPinned: workspace.isPinned, isSleeping: !model.hostIsRunning,
            directory: URL(fileURLWithPath: workspace.path, isDirectory: true),
            isPrimary: workspace.isMain, isSparse: row?.isSparse == true,
            notes: row?.comment.isEmpty == false ? row?.comment : nil, isFolder: workspace.isFolder)
        if let row, lifecycle.removing.contains(row.id) { data.isDeleting = true }
        if let job, job.failure == nil {
            data.creation = .init(phase: WorkspaceComposerLogic.phaseLabel(job.phase), fraction: job.fraction, cancelling: job.cancelling)
            data.status = .working
        } else if let failure = job?.failure {
            data.creationFailure = failure; data.status = .error
        } else if let row {
            switch row.state {
            case "creating": data.creation = .init(phase: "Creating", fraction: 0); data.status = .working
            case "failed": data.creationFailure = WorkspaceComposerLogic.message(code: row.lastError ?? "gitFailed", detail: nil); data.status = .error
            case "removing": data.isDeleting = true
            case "remove_failed": data.deletionFailure = WorkspaceComposerLogic.message(code: row.lastError ?? "gitFailed", detail: nil)
            default: break
            }
        }
        return data
    }
    /// Per-card commands: the Default workspace keeps its local flags; project workspaces go to the host.
    private var workspaceActions: [String: SmthzWorkspaceActions] {
        var result = ["default": SmthzWorkspaceActions(
            rename: { model.workspaceTitle = $0 }, setPinned: { model.workspacePinned = $0 },
            setUnread: { model.workspaceUnread = $0 }, delete: { overlay = .deleteWorkspace })]
        for group in catalog.groups {
            for folder in group.folders {
                let id = String(folder.key.rawValue.dropFirst(7))
                result[folder.id] = SmthzWorkspaceActions(setPinned: { pinned in Task { await catalog.setFolderFlags(id, pinned: pinned) } },
                    setUnread: { unread in Task { await catalog.setFolderFlags(id, unread: unread) } })
            }
        }
        for project in catalog.projects {
            for workspace in project.workspaces where !workspace.isFolder {
                let id = String(workspace.key.rawValue.dropFirst(9))
                let job = lifecycle.jobs[id], row = lifecycle.rows[id]
                let failed = job?.failure != nil || row?.state == "failed"
                let creating = (job != nil && job?.failure == nil) || row?.state == "creating"
                var actions = SmthzWorkspaceActions(
                    rename: { name in setWorktree(id, ["displayName": .string(name)]) },
                    setPinned: { pinned in setWorktree(id, ["pinned": .bool(pinned)]) },
                    setUnread: { unread in setWorktree(id, ["unread": .bool(unread)]) },
                    delete: workspace.isMain ? nil : { failed ? discardFailed(id) : openDelete(workspace) },
                    edit: creating ? nil : { overlay = .editWorkspace(id) },
                    repositorySettings: { overlay = .repositorySettings(project.id) },
                    removeParent: { setWorktree(id, ["noParent": .bool(true)]) },
                    reviewBranches: { overlay = .preservedBranches(project.id) })
                if job != nil && job?.failure == nil { actions.cancelCreate = { lifecycle.cancel(id) } }
                if failed { actions.retryCreate = { retryCreate(id) } }
                result[workspace.id] = actions
            }
        }
        return result
    }
    private func setWorktree(_ id: String, _ fields: [String: HostJSON]) {
        Task {
            do { try await lifecycle.set(id, fields); await catalog.refresh() }
            catch { toast = SmthzToastMessage(title: "Could not update workspace", description: error.localizedDescription, kind: .error) }
        }
    }
    private var composerProjects: [SmthzComposerProject] {
        catalog.projects.filter { $0.kind == "git" }.map { project in
            SmthzComposerProject(id: project.id, title: project.title, path: project.path,
                parents: project.workspaces.filter { lifecycle.row($0.key)?.state ?? "ready" == "ready" }
                    .map { .init(id: String($0.key.rawValue.dropFirst(9)), title: $0.title) })
        }
    }
    private func openComposer(project: String? = nil) {
        composerProjectID = project ?? catalog.project(containing: model.activeKey)?.id
        overlay = .newWorkspace
    }
    /// Composer submit: a job start closes it; a setup block hands off to the approval dialog.
    private func submitCreate(_ params: [String: HostJSON], _ title: String) async -> SmthzNewWorkspaceComposer.SubmitResult {
        switch await lifecycle.create(params, title: title) {
        case .started(let id):
            await catalog.refresh()
            appModel.destination = .workspaces
            if let workspace = catalog.workspace(WorkspaceKey(rawValue: "worktree:" + id)) {
                model.activateWorkspace(workspace.key, displayName: title, rootPath: workspace.path)
            }
            return .started
        case .blocked(let block, let params):
            overlay = .setupApproval(SetupPending(block: block, params: params, title: title))
            return .handedOff
        case .failed(let message): return .failed(message)
        }
    }
    private func resumeCreate(_ pending: SetupPending, _ choice: WorkspaceComposerLogic.SetupChoice) {
        dismiss()
        Task {
            let params = choice == .skip || pending.block == .setupDecision ? WorkspaceComposerLogic.withSetup(pending.params, choice) : pending.params
            switch await submitCreate(params, pending.title) {
            case .failed(let message): toast = SmthzToastMessage(title: "Could not create workspace", description: message, kind: .error)
            default: break
            }
        }
    }
    private func retryCreate(_ id: String) {
        Task {
            switch await lifecycle.retry(id) {
            case .started: await catalog.refresh()
            case .blocked(let block, let params):
                overlay = .setupApproval(SetupPending(block: block, params: params, title: lifecycle.rows[id]?.displayName ?? "Workspace"))
            case .failed(let message): toast = SmthzToastMessage(title: "Retry failed", description: message, kind: .error)
            }
        }
    }
    private func discardFailed(_ id: String) {
        Task {
            await lifecycle.discardFailed(id)
            model.forgetWorkspace(WorkspaceKey(rawValue: "worktree:" + id))
            await catalog.refresh()
        }
    }
    /// The job finished: the worktree becomes the active workspace and its terminal opens in the new path.
    private func worktreeCreated(_ result: WorktreeLifecycleModel.CreateResult) {
        Task {
            await catalog.refresh()
            let key = WorkspaceKey(rawValue: "worktree:" + result.worktreeID)
            // Only steal focus when the user is still looking at this workspace (or nothing else).
            guard model.activeKey == key || model.workspace.tabs.isEmpty else {
                toast = SmthzToastMessage(title: "Workspace ready", description: result.title, kind: .success); return
            }
            appModel.destination = .workspaces
            await model.openWorktree(key, title: result.title, path: result.path,
                                     defaultTabs: result.defaultTabs, setupSessionID: result.setupSessionID)
        }
    }
    private func openDelete(_ workspace: WorkspaceCatalogModel.Workspace) {
        let id = String(workspace.key.rawValue.dropFirst(9))
        deleteTargets = [.init(id: id, name: workspace.title, path: workspace.path, sessionCount: hostSessions(inside: workspace.path))]
        deleteFailure = nil
        if UserDefaults.standard.bool(forKey: SmthzDeleteWorkspaceDialog.preferenceKey) {
            runDelete(id, options: .init()); return
        }
        overlay = .deleteWorktree(id)
        Task {
            if let clean = await lifecycle.details(id).clean, !clean, deleteTargets.first?.id == id {
                deleteTargets[0].hasUncommittedChanges = true
            }
        }
    }
    private func hostSessions(inside path: String) -> Int {
        model.sessions.filter { $0.running && $0.cwd.map { WorkspaceSelectors.contains(root: path, path: $0) } == true }.count
    }
    private func runDelete(_ id: String, options: WorkspaceComposerLogic.RemoveOptions) {
        deleteWorking = true
        let repoID = lifecycle.rows[id]?.repoID
        Task {
            defer { deleteWorking = false }
            do {
                let preserved = try await lifecycle.remove(id, options: options)
                model.forgetWorkspace(WorkspaceKey(rawValue: "worktree:" + id))
                await catalog.refresh()
                if preserved != nil, let repoID { overlay = .preservedBranches(repoID) }
                else if case .deleteWorktree = overlay { dismiss() }
            } catch let failure as WorktreeLifecycleModel.Failure {
                var next = options
                switch failure.code {
                case "worktreeDirty": next.force = true; deleteFailure = (failure.localizedDescription, "Force Delete", next)
                case "archiveHookFailed": next.allowFailedArchiveHook = true; deleteFailure = (failure.localizedDescription + " Delete anyway?", "Delete Anyway", next)
                default: deleteFailure = (failure.localizedDescription, "Force Delete", { var o = options; o.force = true; return o }())
                }
                if case .deleteWorktree = overlay {} else { overlay = .deleteWorktree(id) }
            } catch {
                deleteFailure = (error.localizedDescription, "Force Delete", options)
            }
        }
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
            selectWorkspace("default"); openComposer() })]
        for project in catalog.projects {
            result[project.title] = SmthzProjectActions(
                remove: { removeProject(project) },
                createWorkspace: { openComposer(project: project.kind == "git" ? project.id : nil) })
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
        let pending = lifecycle.job(workspace.key) != nil || ["creating", "failed"].contains(lifecycle.row(workspace.key)?.state ?? "ready")
        if !pending, model.workspace.tabs.isEmpty, model.hostIsRunning { Task { await model.newShell() } }
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
        TabStripView(tabs: BrowserTabStore.shared.merge(model.tabs), select: select, close: close,
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
                TabCreateAction(id: id, title: title, icon: .init(rawValue: icon), enabled: id == "browser",
                                shortcut: SmthzKeybindings.shared.label(action), unavailableReason: id == "browser" ? nil : "Not available yet",
                                perform: id == "browser" ? { settingsPage = nil; returnToWorkspace(); BrowserTabStore.shared.newTab() } : {})
            }
    }
    @ViewBuilder private var workspace: some View {
        switch appModel.destination ?? .workspaces {
        case .tasks: SmthzTasksPage(onClose: returnToWorkspace)
        case .automations: SmthzAutomationsPage(onClose: returnToWorkspace)
        case .activity: SmthzMobilePage(onClose: returnToWorkspace)
        case .workspaces:
            if let browser = BrowserTabStore.shared.activeTab { BrowserPaneView(store: .shared, tab: browser) } else if !model.hostIsRunning {
                LandingView(variant: .hostNotRunning, bindings: SmthzKeybindings.shared.registry,
                    onStartHost: { HostController.shared.start(); monitorGeneration += 1 },
                    onRetry: { HostController.shared.start(); monitorGeneration += 1 })
            } else if model.activeTab == nil, let pending = pendingCreation {
                pending
            } else if model.activeTab != nil {
                LayoutSplitView(model: model, close: closePane)
                    .accessibilityLabel("Terminal panes")
            } else {
                LandingView(hasProjects: !catalog.projects.isEmpty, bindings: SmthzKeybindings.shared.registry, onAddProject: { overlay = .addProject },
                            onCreateWorkspace: { openComposer() })
            }
        }
    }
    @ViewBuilder private var surfaces: some View {
        if let overlay {
            switch overlay {
            case .jump: SmthzJumpPalette(model: palette, onAction: paletteAction, onDismiss: dismiss)
            case .files: SmthzGoToFilePalette(root: model.rootURL, onOpen: { InterimFileOpener.open($0) }, onDismiss: dismiss)
            case .newWorkspace:
                modal { SmthzNewWorkspaceComposer(projects: composerProjects, initialProjectID: composerProjectID, lifecycle: lifecycle,
                    onDismiss: dismiss, onAddProject: { self.overlay = .addProject },
                    onCreateShell: newShell, onAgentSettings: { dismiss(); openSettings("agents") }, onSubmit: submitCreate) }
            case .addProject:
                modal { SmthzAddProjectDialog(catalog: catalog, onDismiss: dismiss, onAdded: { key in
                    if let key { selectWorkspace(key.rawValue) } }) }
            case .deleteWorkspace:
                modal { SmthzDeleteWorkspaceDialog(targets: [.init(id: "default", name: model.workspaceTitle, path: model.rootURL?.path)],
                    onCancel: dismiss, onConfirm: { _, _ in dismiss(); unavailable("Deleting the Default workspace") }) }
            case .deleteWorktree(let id):
                modal { SmthzDeleteWorkspaceDialog(targets: deleteTargets, failureMessage: deleteFailure?.message,
                    forceTitle: deleteFailure?.force ?? "Force Delete", working: deleteWorking, onCancel: dismiss,
                    onConfirm: { _, choice in runDelete(id, options: removeOptions(choice)) },
                    onForceDelete: { choice in
                        var options = deleteFailure?.options ?? removeOptions(choice)
                        options.deleteBranch = choice.deleteBranch; options.runHooks = choice.runHooks || options.allowFailedArchiveHook
                        runDelete(id, options: options)
                    }) }
            case .editWorkspace(let id):
                modal { SmthzEditWorkspaceDialog(worktreeID: id, initialName: lifecycle.rows[id]?.displayName ?? "",
                    initialNote: lifecycle.rows[id]?.comment ?? "",
                    parents: composerProjects.first { $0.id == lifecycle.rows[id]?.repoID }?.parents ?? [],
                    lifecycle: lifecycle, onDismiss: dismiss, onSaved: { Task { await catalog.refresh() } }) }
            case .setupApproval(let pending):
                let repoID = pending.params["repoId"]?.string
                let project = catalog.projects.first { $0.id == repoID }
                modal { SmthzSetupApprovalDialog(block: pending.block, projectTitle: project?.title ?? "This project",
                    repoPath: project?.path, onCancel: dismiss, onDecision: { resumeCreate(pending, $0) },
                    onTrust: { kind, hash in try await lifecycle.approveHooks(repoID: repoID ?? "", kind: kind, hash: hash) }) }
            case .preservedBranches(let repoID):
                modal { SmthzPreservedBranchesDialog(repoID: repoID, projectTitle: catalog.projects.first { $0.id == repoID }?.title ?? "this project",
                    lifecycle: lifecycle, onDismiss: dismiss) }
            case .repositorySettings(let repoID):
                modal { SmthzRepositorySettingsSheet(repoID: repoID, lifecycle: lifecycle, onDismiss: dismiss,
                    onSaved: { Task { await catalog.refresh() } }) }
            case .onboarding: SmthzOnboardingView(onFinish: dismiss, onAddProject: { self.overlay = .addProject })
            }
        }
    }
    private func removeOptions(_ choice: SmthzDeleteWorkspaceDialog.Choice) -> WorkspaceComposerLogic.RemoveOptions {
        var options = WorkspaceComposerLogic.RemoveOptions()
        options.deleteBranch = choice.deleteBranch; options.runHooks = choice.runHooks
        return options
    }
    /// Shown in place of the terminal while the active worktree is being created or failed to create.
    private var pendingCreation: AnyView? {
        let key = model.activeKey
        guard let id = key.rawValue.hasPrefix("worktree:") ? String(key.rawValue.dropFirst(9)) : nil else { return nil }
        let job = lifecycle.jobs[id], row = lifecycle.rows[id]
        guard job != nil || row?.state == "creating" || row?.state == "failed" else { return nil }
        let failure = job?.failure ?? (row?.state == "failed" ? WorkspaceComposerLogic.message(code: row?.lastError ?? "gitFailed", detail: nil) : nil)
        return AnyView(VStack(spacing: 12) {
            Text(model.workspace.displayName).font(SmthzFont.ui(size: 16, weight: .semibold))
            if let failure {
                Text("Could not create this workspace").font(SmthzFont.ui(size: 13)).foregroundStyle(SmthzTheme.destructive)
                Text(failure).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground).multilineTextAlignment(.center)
                HStack {
                    Button("Retry") { retryCreate(id) }.buttonStyle(SmthzButtonStyle(.primary, size: .small))
                    Button("Delete") { discardFailed(id) }.buttonStyle(SmthzButtonStyle(.outline, size: .small))
                }
            } else {
                Text(job.map { WorkspaceComposerLogic.phaseLabel($0.phase) } ?? "Creating").font(SmthzFont.ui(size: 13))
                    .foregroundStyle(SmthzTheme.mutedForeground)
                ProgressView(value: job?.fraction ?? 0).frame(width: 240)
                if job != nil {
                    Button(job?.cancelling == true ? "Cancelling…" : "Cancel") { lifecycle.cancel(id) }
                        .buttonStyle(SmthzButtonStyle(.outline, size: .small)).disabled(job?.cancelling == true)
                }
            }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityElement(children: .contain)
            .accessibilityLabel("Workspace creation"))
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
        if BrowserTabStore.shared.select(id) { settingsPage = nil; returnToWorkspace(); return } else { BrowserTabStore.shared.deactivate() }
        model.selectedSessionID = id; settingsPage = nil; returnToWorkspace()
    }
    private func newShell() {
        BrowserTabStore.shared.deactivate(); settingsPage = nil; returnToWorkspace(); Task { await model.newShell() }
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
        if BrowserTabStore.shared.close(id) { return }
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
        case .workspaceCreate: openComposer()
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
