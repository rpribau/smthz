import SwiftUI

/// One navigation row (UI-SPEC §4.1): 13 pt / 500, tight tracking, 16 pt icon, radius 8.
/// Inactive text fg/60 + icon fg/30 (stroke 1.75); hover fg/8; active accent fill, full colour, stroke 2.25.
struct SidebarNavRow<Trailing: View>: View {
    let title: String
    let icon: SmthzIcon.Name
    var isActive = false
    let action: () -> Void
    /// "Hide from sidebar" handler; nil means the row is not hideable.
    var onHide: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SmthzIcon.view(icon, size: 16, stroke: isActive ? 2.25 : 1.75)
                    .foregroundStyle(isActive ? SmthzTheme.worktreeSidebarForeground : SmthzTheme.sidebarNavInactiveIcon)
                Text(title)
                    .font(SmthzFont.ui(size: 13, weight: .medium))
                    .tracking(13 * SmthzFont.tightTrackingEm)
                    .lineLimit(1)
                    .foregroundStyle(isActive ? SmthzTheme.worktreeSidebarForeground : SmthzTheme.sidebarNavInactiveText)
                Spacer(minLength: 0)
                if hovered { trailing() }
            }
            .padding(.horizontal, 8)
            .frame(height: SmthzMetrics.navRowHeight)
            .frame(maxWidth: .infinity)
            .background(fill, in: RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD))
            .contentShape(RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            if let onHide {
                Button { onHide() } label: {
                    Label { Text("Hide from sidebar") } icon: { SmthzIcon.view(.eyeOff, size: 14) }
                }
            }
        }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var fill: Color {
        if isActive { return SmthzTheme.worktreeSidebarAccent }
        return hovered ? SmthzTheme.sidebarNavHover : .clear
    }
}

extension SidebarNavRow where Trailing == EmptyView {
    init(title: String, icon: SmthzIcon.Name, isActive: Bool = false,
         onHide: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.init(title: title, icon: icon, isActive: isActive, action: action, onHide: onHide) { EmptyView() }
    }
}

/// Search field row (§4.1): fill fg/5, hover fg/8, text fg/60, shortcut keycaps on hover.
struct SidebarSearchRow: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SmthzIcon.view(.search, size: 16, stroke: 1.75)
                    .foregroundStyle(SmthzTheme.sidebarNavInactiveIcon)
                Text("Search")
                    .font(SmthzFont.ui(size: 13, weight: .medium))
                    .tracking(13 * SmthzFont.tightTrackingEm)
                    .foregroundStyle(SmthzTheme.sidebarNavInactiveText)
                Spacer(minLength: 0)
                if hovered {
                    HStack(spacing: 2) {
                        ForEach(["⌘", "J"], id: \.self) { key in
                            Text(key)
                                .font(SmthzFont.ui(size: 9, weight: .medium))
                                .foregroundStyle(SmthzTheme.mutedForeground)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(SmthzTheme.worktreeSidebarForeground.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 4))
                                .overlay { RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(SmthzTheme.border.opacity(0.8), lineWidth: 1) }
                        }
                    }
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: SmthzMetrics.navRowHeight)
            .frame(maxWidth: .infinity)
            .background(hovered ? SmthzTheme.sidebarNavHover : SmthzTheme.sidebarSearchFill,
                        in: RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD))
            .contentShape(RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("Search")
    }
}

/// Icon-only label shared by `SidebarIconButton` and the sidebar `Menu` triggers (24² box, hover fill).
struct SidebarIconLabel: View {
    let icon: SmthzIcon.Name
    var size: CGFloat = 14
    var stroke: Double = 2.25
    var pressed = false
    var tint: Color = SmthzTheme.mutedForeground
    var pressedFill: Color = SmthzTheme.primary.opacity(0.15)
    var pressedTint: Color = SmthzTheme.primary
    var hoverable = true
    @State private var hovered = false

    var body: some View {
        SmthzIcon.view(icon, size: size, stroke: stroke)
            .foregroundStyle(pressed ? pressedTint : tint)
            .frame(width: SmthzMetrics.iconButtonXS, height: SmthzMetrics.iconButtonXS)
            .background(pressed ? pressedFill
                        : (hovered && hoverable ? SmthzTheme.accent.opacity(0.5) : .clear),
                        in: RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD))
            .contentShape(RoundedRectangle(cornerRadius: SmthzMetrics.radiusMD))
            .onHover { hovered = $0 }
    }
}

/// 24² ghost icon button used by the section header and toolbar (`icon-xs`, glyph 14, radius 8).
/// `shortcut` is appended to the tooltip only (muted keycap text in Orca), not to the accessibility label.
struct SidebarIconButton: View {
    let icon: SmthzIcon.Name
    let label: String
    var shortcut: String? = nil
    var size: CGFloat = 14
    var stroke: Double = 2.25
    var pressed = false
    var secondaryPressed = false
    var tooltipEdge: Edge = .bottom
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SidebarIconLabel(icon: icon, size: size, stroke: stroke, pressed: pressed || secondaryPressed,
                             pressedFill: secondaryPressed ? SmthzTheme.secondary : SmthzTheme.primary.opacity(0.15),
                             pressedTint: secondaryPressed ? SmthzTheme.foreground : SmthzTheme.primary,
                             hoverable: isEnabled)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .smthzTooltip(shortcut.map { "\(label)  \($0)" } ?? label, edge: tooltipEdge)
        .accessibilityLabel(label)
    }
}

/// Task providers shown as glyphs on the Tasks row hover (UI-DETAIL §2.1).
enum TaskProvider: CaseIterable, Identifiable {
    case github, gitlab, linear, jira
    var id: Self { self }
    var tooltip: String {
        switch self {
        case .github: "Open GitHub tasks"
        case .gitlab: "Open GitLab tasks"
        case .linear: "Open Linear tasks"
        case .jira: "Open Jira tasks"
        }
    }
    /// Monochrome glyphs only (trademark rule): Lucide brand icons, Linear/Jira as simple custom marks.
    var icon: SmthzIcon.Name {
        switch self {
        case .github: "github"
        case .gitlab: "gitlab"
        case .linear: "linear"
        case .jira: "jira"
        }
    }
}

/// Provider glyph buttons shown inside the Tasks row on hover (14 pt).
struct TaskProviderGlyphs: View {
    let onOpen: (TaskProvider) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TaskProvider.allCases) { provider in
                Button { onOpen(provider) } label: {
                    SmthzIcon.view(provider.icon, size: 14, stroke: 2)
                        .foregroundStyle(SmthzTheme.sidebarNavInactiveIcon)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .smthzTooltip(provider.tooltip, edge: .bottom)
                .accessibilityLabel(provider.tooltip)
            }
        }
    }
}
