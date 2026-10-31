import SwiftUI

/// Full-page settings shell (§11). Routes page ids to panes; unbuilt pages show a placeholder.
struct SettingsView: View {
    let model: ShellController
    @Binding var sidebarOpen: Bool
    @Binding var rightSidebarOpen: Bool
    let onBack: () -> Void
    /// Projects listed in the sidebar's "Projects" group (empty until the M4 project model).
    var projects: [SettingsProjectItem] = []
    /// Conditional pages to list (Linear, Computer Use, Voice, smthz Account, Mobile, Dev Tools).
    var shownConditionalPages: Set<String> = []
    var initialPage = "appearance"
    @State private var selection = "appearance"
    @State private var search = ""
    @State private var loadedProjects: [SettingsProjectItem] = []
    private var allProjects: [SettingsProjectItem] { projects.isEmpty ? loadedProjects : projects }

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var visibleGroups: [SettingsGroup] {
        SettingsGroup.visible(search: search, showConditional: shownConditionalPages)
    }
    private var searchMiss: Bool {
        !query.isEmpty && visibleGroups.isEmpty
            && !allProjects.contains { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 80)
                Text("smthz").font(SmthzFont.ui(size: 12, weight: .semibold))
                Spacer()
                Text("Settings").font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                    .padding(.trailing, 16)
            }
            .frame(height: SmthzMetrics.titleBandHeight)
            .background(WindowDragRegion())
            .background(SmthzTheme.card)
            .overlay(alignment: .bottom) { SmthzTheme.border.frame(height: 1) }
            HStack(spacing: 0) {
                SettingsSidebar(selection: $selection, search: $search, projects: allProjects,
                                shownConditionalPages: shownConditionalPages, onBack: onBack)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if searchMiss {
                            Text("No settings found for \"\(query)\"")
                                .font(SmthzFont.ui(size: 14))
                                .foregroundStyle(SmthzTheme.mutedForeground)
                        } else {
                            content
                        }
                    }
                    .padding(.horizontal, 32)
                    .frame(maxWidth: 896, alignment: .leading)
                    .padding(.top, 40)
                    .padding(.bottom, 96)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .id(selection)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { selection = initialPage }
        .task { if projects.isEmpty { loadedProjects = await settingsLoadProjects(socketPath: model.socketPath) } }
        .background(SmthzTheme.background)
        .foregroundStyle(SmthzTheme.foreground)
    }

    @ViewBuilder private var content: some View {
        if selection.hasPrefix("project:") {
            let project = allProjects.first { "project:\($0.id)" == selection }
            SettingsSectionHeader(title: project?.name ?? "Project", description: "Settings for this project.")
            if let project { RepositorySettingsPane(repoID: project.id, socketPath: model.socketPath) }
        } else if let page = SettingsGroup.page(id: selection) {
            SettingsSectionHeader(title: page.title, badge: page.badge, description: page.description)
            pane(for: page)
        }
    }

    @ViewBuilder private func pane(for page: SettingsPage) -> some View {
        switch page.id {
        case "terminal": TerminalSettingsPane(model: model)
        case "appearance": AppearancePane(sidebarOpen: $sidebarOpen, rightSidebarOpen: $rightSidebarOpen)
        case "shortcuts": ShortcutsPane(settingsSearch: search)
        case "general": GeneralSettingsPane(store: HostSettingsStore(socketPath: model.socketPath))
        case "git": GitSettingsPane(store: HostSettingsStore(socketPath: model.socketPath))
        case "quick-commands": QuickCommandsSettingsPane()
        case "agents": AgentsSettingsPane(socketPath: model.socketPath)
        case "privacy": PrivacySettingsPane()
        case "notifications": NotificationsSettingsPane()
        default: SettingsUnavailableBody()
        }
    }
}
