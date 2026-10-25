import SwiftUI

/// One project section and its workspace cards.
struct SidebarProject: Identifiable {
    let id: String
    var title: String
    var subtitle: String?
    var workspaces: [WorkspaceCardData]
}

/// Left sidebar body below the title band (UI-SPEC §4): nav block, Projects header,
/// scrolling project/workspace list, bottom toolbar. Pure view: data and actions arrive as parameters.
struct SidebarView: View {
    var destination: Destination?
    var projects: [SidebarProject]
    var canCreateWorkspace = true
    var onSelectDestination: (Destination) -> Void
    var onSearch: () -> Void = {}
    var onSelectWorkspace: (String) -> Void
    var onNewWorkspace: () -> Void
    var onAddProject: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onScrollToCurrent: () -> Void = {}
    var onOpenTaskProvider: (TaskProvider) -> Void = { _ in }
    /// Settings › Shortcuts (wired by UI-29).
    var onKeyboardShortcuts: () -> Void = {}
    var onSendFeedback: () -> Void = {}
    var onOnboarding: () -> Void = {}
    var onCheckForUpdates: () -> Void = {}
    var onRestart: (() -> Void)? = nil
    var onToggleBoard: (Bool) -> Void = { _ in }
    /// True once a mobile device is paired (shows the EyeOff button on the Mobile row).
    var mobilePaired = false

    // Shared keys with UI-18 (Settings › Appearance › Window & Sidebar).
    @AppStorage("sidebar.showTasksButton") private var showTasks = true
    @AppStorage("sidebar.showAutomationsButton") private var showAutomations = true
    @AppStorage("sidebar.showMobileButton") private var showMobile = true
    @AppStorage("sidebar.mobileVisited") private var mobileVisited = false
    @AppStorage(WorkspaceOptions.Key.groupBy) private var groupBy = WorkspaceOptions.GroupBy.project.rawValue

    @State private var activityBodyShown = false
    @State private var boardOpen = false
    @State private var collapsed: Set<String> = []
    @State private var sidebarHovered = false

    var body: some View {
        VStack(spacing: 0) {
            nav
            header
            if activityBodyShown { agentsBody } else { list }
            toolbar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SmthzTheme.worktreeSidebar)
        .foregroundStyle(SmthzTheme.worktreeSidebarForeground)
        .onHover { sidebarHovered = $0 }
    }

    private var nav: some View {
        VStack(spacing: 2) {
            SidebarSearchRow(action: onSearch)
            if showTasks {
                SidebarNavRow(title: "Tasks", icon: .list, isActive: destination == .tasks,
                              action: { onSelectDestination(.tasks) },
                              onHide: { showTasks = false }) {
                    TaskProviderGlyphs(onOpen: onOpenTaskProvider)
                }
            }
            if showAutomations {
                SidebarNavRow(title: "Automations", icon: .calendarClock, isActive: destination == .automations,
                              onHide: { showAutomations = false },
                              action: { onSelectDestination(.automations) })
            }
            if showMobile {
                SidebarNavRow(title: "smthz Mobile", icon: .smartphone, isActive: destination == .activity,
                              action: {
                                  mobileVisited = true
                                  onSelectDestination(.activity)
                              },
                              onHide: { showMobile = false }) {
                    if mobilePaired {
                        Button { showMobile = false } label: {
                            SmthzIcon.view(.eyeOff, size: 14)
                                .foregroundStyle(SmthzTheme.mutedForeground)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .smthzTooltip("Hide from sidebar", edge: .top)
                        .accessibilityLabel("Hide from sidebar")
                    }
                }
                .overlay(alignment: .trailing) {
                    if !mobileVisited {
                        Text("New")
                            .font(SmthzFont.ui(size: 10, weight: .semibold))
                            .foregroundStyle(SmthzTheme.primaryForeground)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(SmthzTheme.primary, in: Capsule())
                            .padding(.trailing, 8)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .padding(.init(top: 8, leading: 8, bottom: 4, trailing: 8))
    }

    private var header: some View {
        HStack(spacing: 4) {
            Text(groupBy == WorkspaceOptions.GroupBy.project.rawValue ? "Projects" : "Workspaces")
                .font(SmthzFont.ui(size: 12, weight: .semibold))
                .foregroundStyle(SmthzTheme.mutedForeground.opacity(0.8))
                .lineLimit(1)
                .padding(.leading, 8)
            Spacer(minLength: 0)
            SidebarIconButton(icon: .bell,
                              label: activityBodyShown ? "Turn off activity view" : "View activity",
                              pressed: activityBodyShown) {
                activityBodyShown.toggle()
            }
            if !activityBodyShown { WorkspaceOptionsMenu() }
            SidebarIconButton(icon: .folderPlus, label: "Add project", action: onAddProject)
            SidebarIconButton(icon: .plus, label: "New workspace", shortcut: "⌘N",
                              isEnabled: canCreateWorkspace, action: onNewWorkspace)
        }
        .padding(.top, 8).padding(.horizontal, 8)
        .frame(height: 32 + 8, alignment: .bottom)
    }

    /// VISUAL-ONLY: stub data until the agents backend (activity list, filters, per-workspace agent rows).
    private var agentsBody: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            SmthzIcon.view(.bell, size: 20, stroke: 1.75)
                .foregroundStyle(SmthzTheme.mutedForeground.opacity(0.6))
            Text("No agent activity")
                .font(SmthzFont.ui(size: 12, weight: .medium))
                .foregroundStyle(SmthzTheme.mutedForeground)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(projects) { project in
                    Section {
                        if !collapsed.contains(project.id) {
                            VStack(spacing: 2) {
                                ForEach(project.workspaces) { workspace in
                                    WorkspaceCardView(data: workspace) { onSelectWorkspace(workspace.id) }
                                }
                            }
                            .padding(.bottom, 4)
                        }
                    } header: {
                        ProjectHeaderRow(title: project.title, subtitle: project.subtitle,
                                         isCollapsed: Binding(
                                            get: { collapsed.contains(project.id) },
                                            set: { if $0 { collapsed.insert(project.id) } else { collapsed.remove(project.id) } }))
                    }
                }
            }
            .padding(.trailing, 6)
        }
        .scrollIndicators(sidebarHovered ? .automatic : .hidden)
        .frame(maxHeight: .infinity)
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            SidebarIconButton(icon: .settings, label: "Settings", size: 14, stroke: 2.25,
                              tooltipEdge: .top, action: onOpenSettings)
            SidebarHelpMenu(onKeyboardShortcuts: onKeyboardShortcuts, onSendFeedback: onSendFeedback,
                            onOnboarding: onOnboarding, onCheckForUpdates: onCheckForUpdates,
                            onRestart: onRestart)
            Spacer(minLength: 0)
            SidebarIconButton(icon: .crosshair, label: "Reveal active workspace", size: 14, stroke: 2.25,
                              tooltipEdge: .top, action: onScrollToCurrent)
            // VISUAL-ONLY: stub data until the workspace board (Kanban drawer, M4).
            SidebarIconButton(icon: "kanban", label: boardOpen ? "Close workspace board" : "Workspace board",
                              size: 14, stroke: 2.25, secondaryPressed: boardOpen, tooltipEdge: .top) {
                boardOpen.toggle()
                onToggleBoard(boardOpen)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(height: 36)
        .overlay(alignment: .top) { SmthzTheme.worktreeSidebarBorder.frame(height: 1) }
    }
}
