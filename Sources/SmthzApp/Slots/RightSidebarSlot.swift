import SmthzCore
import SwiftUI

struct RightSidebarSlot: View {
    @Binding var isOpen: Bool
    /// Source of the active session's cwd; nil shows the "Select a workspace" states.
    var model: ShellController?
    @AppStorage("shell.rightSidebarPanel") private var storedPanel = RightSidebarPanel.explorer.rawValue
    @AppStorage("shell.rightSidebarBarPosition") private var storedPosition = RightSidebarBarPosition.top.rawValue
    @State private var isGit = false

    init(isOpen: Binding<Bool>, model: ShellController? = nil) {
        _isOpen = isOpen
        self.model = model
    }

    private var rootURL: URL? {
        model?.rootURL
    }

    var body: some View {
        RightSidebarView(
            isOpen: $isOpen,
            selection: Binding(
                get: { RightSidebarPanel(rawValue: storedPanel) ?? .explorer },
                set: { storedPanel = $0.rawValue }),
            kind: isGit || rootURL == nil ? .git : .folder,
            position: Binding(
                get: { RightSidebarBarPosition(rawValue: storedPosition) ?? .top },
                set: { storedPosition = $0.rawValue })
        ) { panel in
            switch panel {
            case .explorer: AnyView(ExplorerPanel(rootURL: rootURL, isGitRepository: isGit))
            case .sourceControl: AnyView(SourceControlPanel(rootURL: rootURL))
            case .agents: AnyView(AgentsPanel())
            case .checks: AnyView(ChecksPanel(state: rootURL == nil ? .noWorkspace : .unavailable))
            case .ports: AnyView(PortsPanel(hasWorkspace: rootURL != nil))
            default: RightSidebarView<AnyView>.emptyState(panel)
            }
        }
        .task(id: rootURL) {
            guard let rootURL else { isGit = false; return }
            isGit = (try? await GitService().repository(at: rootURL)) != nil
        }
    }
}
