import SwiftUI

// VISUAL-ONLY: stub data until the M4 projects/groups model.
struct ProjectHeaderRow: View {
    let title: String
    var subtitle: String?
    var nestingLevel = 0
    @Binding var isCollapsed: Bool
    var projectIcon = "folder"
    var projectColor: Color = SmthzTheme.mutedForeground
    var isGrouped = false
    var showsWorktrees = true
    var pathMissing = false
    var scanFailed = false
    var onRetryScan: (() -> Void)?
    @Environment(\.smthzProjectActions) private var projectActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var chevronHovered = false
    private var actions: SmthzProjectActions { projectActions[title] ?? SmthzProjectActions() }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                SmthzIcon.image(projectIcon).frame(width: 14, height: 14)
                    .foregroundStyle(projectColor).frame(width: 16, height: 16)
                Text(title).font(SmthzFont.ui(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            }
            // Reordering is supplied by the M4 project model; do not advertise a working drag yet.
            if let subtitle { Text(subtitle).font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground).lineLimit(1) }
            if pathMissing { SmthzIcon.image("folder").frame(width: 12, height: 12).foregroundStyle(SmthzTheme.destructive).help("Project folder not found") }
            if scanFailed {
                Button { onRetryScan?() } label: { SmthzIcon.image("triangle-alert").frame(width: 12, height: 12).foregroundStyle(SmthzTheme.destructive) }
                    .buttonStyle(.plain).disabled(onRetryScan == nil).help("Worktree scan failed for \(title)")
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Menu {
                    SmthzProjectActionsMenu(actions: actions, isGrouped: isGrouped, showsWorktrees: showsWorktrees)
                } label: { SmthzIcon.view(.ellipsis, size: 14).frame(width: 20, height: 20) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .smthzTooltip("Project actions", edge: .bottom).accessibilityLabel("Project actions")
                Button { actions.createWorkspace?() } label: { SmthzIcon.view(.plus, size: 12).frame(width: 20, height: 20) }
                    .buttonStyle(.plain).disabled(actions.createWorkspace == nil)
                    .smthzTooltip("Create workspace for \(title)", edge: .bottom).accessibilityLabel("Create workspace for \(title)")
            }
            .frame(width: hovered ? 40 : 0).clipped().opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered).accessibilityHidden(!hovered)
            Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: SmthzMotion.card)) { isCollapsed.toggle() } } label: {
                SmthzIcon.view(.chevronDown, size: 14, stroke: 2)
                    .foregroundStyle(SmthzTheme.mutedForeground)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 20, height: 20)
                    .background(chevronHovered ? SmthzTheme.accent.opacity(0.7) : .clear,
                                in: RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD))
            }
            .buttonStyle(.plain).onHover { chevronHovered = $0 }
            .accessibilityLabel(isCollapsed ? "Expand \(title)" : "Collapse \(title)")
        }
        .padding(.leading, 10 + CGFloat(nestingLevel) * 18).padding(.trailing, 8)
        .frame(height: SmthzMetrics.projectHeaderHeight)
        .foregroundStyle(SmthzTheme.worktreeSidebarForeground).background(SmthzTheme.worktreeSidebar)
        .contentShape(Rectangle()).onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: SmthzMotion.card), value: hovered)
        .contextMenu { SmthzProjectActionsMenu(actions: actions, isGrouped: isGrouped, showsWorktrees: showsWorktrees) }
        .accessibilityElement(children: .contain)
    }
}
