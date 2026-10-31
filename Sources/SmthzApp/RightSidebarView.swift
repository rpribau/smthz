import SwiftUI

/// Which activity set the bar shows (UI-DETAIL §5.1).
enum RightSidebarWorkspaceKind { case git, folder }

/// Activity bar placement (right-click "Activity Bar Position").
enum RightSidebarBarPosition: String { case top, side }

/// Right sidebar panels (UI-SPEC §7, UI-DETAIL §5).
enum RightSidebarPanel: String, CaseIterable, Identifiable {
    case explorer, search, agents, workspaces, checks, sourceControl, ports

    var id: String { rawValue }

    /// Items in Orca's order; `workspaces` and the folder-flavoured `checks` are folder-workspace only.
    static func items(for kind: RightSidebarWorkspaceKind) -> [RightSidebarPanel] {
        switch kind {
        case .git: [.explorer, .search, .agents, .sourceControl, .checks, .ports]
        case .folder: [.explorer, .search, .agents, .workspaces, .checks, .ports]
        }
    }

    func title(for kind: RightSidebarWorkspaceKind) -> String {
        if self == .checks && kind == .folder { return "PR Checks" }
        return title
    }

    var title: String {
        switch self {
        case .explorer: "Explorer"
        case .search: "Search"
        case .agents: "Agents"
        case .workspaces: "Attached worktrees"
        case .checks: "Checks"
        case .sourceControl: "Source Control"
        case .ports: "Ports"
        }
    }

    var shortcut: String? {
        switch self {
        case .explorer: "⌘⇧E"
        case .search: "⌘⇧F"
        case .sourceControl: "⌘⇧G"
        case .ports: "⌘⇧I"
        default: nil
        }
    }

    var tooltip: String { shortcut.map { "\(title) (\($0))" } ?? title }

    var icon: SmthzIcon.Name {
        switch self {
        case .explorer: .files
        case .search: .search
        case .agents: .history
        case .workspaces: .workflow
        case .checks: .listChecks
        case .sourceControl: .gitBranch
        case .ports: .plug
        }
    }

    // VISUAL-ONLY: stub data until agents history, PR provider and port scanner exist
    var emptyTitle: String {
        switch self {
        case .explorer: "Select a workspace to browse files"
        case .search: "Select a workspace to search files"
        case .agents: "No agent sessions"
        case .workspaces: "No attached worktrees yet"
        case .checks: "No workspace selected"
        case .sourceControl: "Select a workspace to view changes"
        case .ports: "No workspace selected"
        }
    }

    var emptyDetail: String? {
        switch self {
        case .agents: "Resume past sessions"
        case .workspaces: "Worktrees created from this workspace will show up here."
        case .checks: "Select a workspace to view checks"
        default: nil
        }
    }
}

struct RightSidebarView<Content: View>: View {
    @Binding var isOpen: Bool
    @Binding var selection: RightSidebarPanel
    var kind: RightSidebarWorkspaceKind = .git
    @Binding var position: RightSidebarBarPosition
    /// Panels showing a status dot (7 pt, top-right). Empty until panels report real state.
    var statusDots: [RightSidebarPanel: Color] = [:]
    /// Body for a panel; return `nil`-like empty views to fall back to the stub empty state.
    @ViewBuilder var content: (RightSidebarPanel) -> Content

    private static var buttonSize: CGFloat { 36 }
    private var items: [RightSidebarPanel] { RightSidebarPanel.items(for: kind) }
    private var active: RightSidebarPanel { items.contains(selection) ? selection : .explorer }

    var body: some View {
        Group {
            if position == .top {
                VStack(spacing: 0) {
                    header
                    content(active)
                }
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: SmthzMetrics.titleBandHeight)
                        content(active)
                    }
                    sideBar
                }
            }
        }
        .background(SmthzTheme.sidebar)
        .overlay(alignment: .leading) { SmthzTheme.border.frame(width: 1).allowsHitTesting(false) }
    }

    private var positionMenu: some View {
        Menu("Activity Bar Position") {
            Button { position = .top } label: { Label("Top", systemImage: position == .top ? "checkmark" : "") }
            Button { position = .side } label: { Label("Side", systemImage: position == .side ? "checkmark" : "") }
        }
    }

    private var sideBar: some View {
        VStack(spacing: 0) {
            ForEach(items) { panel in
                ActivityButton(panel: panel, kind: kind, isActive: panel == active, dot: statusDots[panel], vertical: true) {
                    selection = panel
                }
            }
            Spacer(minLength: 0)
            closeButton
        }
        .frame(width: Self.buttonSize)
        .overlay(alignment: .leading) { SmthzTheme.border.frame(width: 1) }
        .contextMenu { positionMenu }
    }

    private var closeButton: some View {
        Button { isOpen = false } label: {
            SmthzIcon.view(.panelRight).frame(width: Self.buttonSize, height: Self.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(SmthzTheme.mutedForeground)
        .help("Toggle right sidebar (⌘L)")
        .accessibilityLabel("Toggle right sidebar")
    }

    private var header: some View {
        GeometryReader { proxy in
            // Reserve room for the overflow and toggle buttons; the rest holds activity buttons.
            let fit = max(1, Int((proxy.size.width - Self.buttonSize * 2) / Self.buttonSize))
            let visible = Array(items.prefix(fit))
            let hidden = Array(items.dropFirst(fit))
            HStack(spacing: 0) {
                ForEach(visible) { panel in
                    ActivityButton(panel: panel, kind: kind, isActive: panel == active, dot: statusDots[panel], vertical: false) {
                        selection = panel
                    }
                }
                if !hidden.isEmpty { overflowMenu(hidden) }
                Spacer(minLength: 0)
                closeButton
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: SmthzMetrics.titleBandHeight)
        .background(WindowDragRegion())
        .overlay(alignment: .bottom) { SmthzTheme.border.frame(height: 1) }
        .contextMenu { positionMenu }
    }

    private func overflowMenu(_ panels: [RightSidebarPanel]) -> some View {
        Menu {
            ForEach(panels) { panel in
                Button { selection = panel } label: {
                    Label { Text(panel.title(for: kind)) } icon: { SmthzIcon.image(panel.icon) }
                }
            }
        } label: {
            SmthzIcon.view(.ellipsis)
                .foregroundStyle(panels.contains(active) ? SmthzTheme.foreground : SmthzTheme.mutedForeground.opacity(0.6))
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More sidebar tabs")
        .accessibilityLabel("More sidebar tabs")
    }
}

extension RightSidebarView where Content == AnyView {
    /// Stub empty state shared by panels without a real body yet (UI-20 replaces Agents/Checks/Ports by name).
    static func emptyState(_ panel: RightSidebarPanel) -> AnyView {
        AnyView(PanelEmptyState(icon: panel.icon, title: panel.emptyTitle, detail: panel.emptyDetail))
    }
}

private struct ActivityButton: View {
    let panel: RightSidebarPanel
    let kind: RightSidebarWorkspaceKind
    let isActive: Bool
    let dot: Color?
    var vertical = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SmthzIcon.view(panel.icon)
                .foregroundStyle(isActive ? SmthzTheme.foreground
                                 : hovering ? SmthzTheme.mutedForeground : SmthzTheme.mutedForeground.opacity(0.6))
                .frame(width: 36, height: 36)
                .overlay(alignment: vertical ? .trailing : .bottom) {
                    if isActive {
                        Capsule().fill(SmthzTheme.foreground)
                            .frame(width: vertical ? 2 : 18, height: vertical ? 18 : 2)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let dot {
                        Circle().fill(dot).frame(width: 7, height: 7).padding(.top, 6).padding(.trailing, 6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(panel.tooltip)
        .accessibilityLabel(panel.title(for: kind))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
