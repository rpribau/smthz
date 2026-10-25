import SwiftUI

struct ShellTitleControls: View {
    @Binding var sidebarOpen: Bool
    @AppStorage("shell.showTitlebarAppName") private var showAppName = true

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: 80).allowsHitTesting(false)
            if showAppName {
                Text("smthz")
                    .font(SmthzFont.ui(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Application menu")
                    .contextMenu { Button("Hide App Name") { showAppName = false } }
            }
            Button { sidebarOpen.toggle() } label: {
                SmthzIcon.view(.panelLeft).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .smthzTooltip("Toggle sidebar (⌘B)")
            .accessibilityLabel("Toggle sidebar")
            Spacer(minLength: 0)
            // VISUAL-ONLY: stub data until workspace navigation history (M4).
            HStack(spacing: 0) {
                Button {} label: {
                    SmthzIcon.view(.arrowLeft, size: 12).frame(width: 22, height: 24)
                }
                .smthzTooltip("Go back (⌥⌘←)")
                .accessibilityLabel("Go back")
                Button {} label: {
                    SmthzIcon.view(.arrowRight, size: 12).frame(width: 22, height: 24)
                }
                .smthzTooltip("Go forward (⌥⌘→)")
                .accessibilityLabel("Go forward")
            }
            .buttonStyle(.plain)
            .disabled(true)
            .opacity(0.45)
            .padding(.trailing, 8)
        }
        .foregroundStyle(SmthzTheme.worktreeSidebarForeground)
        .background(WindowDragRegion())
    }
}

/// Composes the title band and `SidebarView`. Data comes from the existing models:
/// host sessions are shown as the single default workspace.
struct SidebarSlot: View {
    let appModel: AppModel
    @Binding var sidebarOpen: Bool
    private var model: WorkspaceModel { appModel.workspace }

    var body: some View {
        VStack(spacing: 0) {
            ShellTitleControls(sidebarOpen: $sidebarOpen)
                .frame(height: SmthzMetrics.titleBandHeight)
                .overlay(alignment: .bottom) { SmthzTheme.border.frame(height: 1) }
            SidebarView(
                destination: appModel.destination,
                projects: projects,
                canCreateWorkspace: model.hostIsRunning && !model.creatingShell,
                onSelectDestination: { appModel.destination = $0 },
                onSelectWorkspace: { _ in
                    appModel.destination = .workspaces
                    if model.selectedSessionID == nil { model.selectedSessionID = model.sessions.first?.id }
                },
                onNewWorkspace: {
                    appModel.destination = .workspaces
                    Task { await model.newShell() }
                })
        }
        .frame(maxHeight: .infinity)
        .background(SmthzTheme.worktreeSidebar)
        .foregroundStyle(SmthzTheme.worktreeSidebarForeground)
    }

    private var projects: [SidebarProject] {
        let count = model.sessions.count
        let card = WorkspaceCardData(
            id: "default",
            title: "Default workspace",
            detail: count == 1 ? "1 session" : "\(count) sessions",
            status: !model.hostIsRunning ? .idle : (count > 0 ? .live : .idle),
            isActive: appModel.destination == .workspaces,
            isSleeping: !model.hostIsRunning,
            isDisconnected: false)
        return [SidebarProject(id: "local", title: "Local host", subtitle: nil, workspaces: [card])]
    }
}
