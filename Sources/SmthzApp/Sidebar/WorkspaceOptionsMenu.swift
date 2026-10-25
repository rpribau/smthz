import SwiftUI

/// Persisted "Workspace options" state (UI-DETAIL §2.3), Orca defaults: Recent / Manual / Project.
/// VISUAL-ONLY: stub data until the workspace model (M4); the choices persist locally but sort/filter nothing yet.
enum WorkspaceOptions {
    enum SortBy: String, CaseIterable, Identifiable {
        case name, agentActivity, recent, project, manual
        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: "Name"
            case .agentActivity: "Agent Activity"
            case .recent: "Recent"
            case .project: "Project"
            case .manual: "Manual"
            }
        }
    }

    enum ProjectOrder: String, CaseIterable, Identifiable {
        case manual, recent
        var id: String { rawValue }
        var title: String { self == .manual ? "Manual" : "Recent" }
    }

    enum GroupBy: String, CaseIterable, Identifiable {
        case none, status, pr, project
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "None"
            case .status: "Status"
            case .pr: "PR"
            case .project: "Project"
            }
        }
    }

    enum CardLayout: String, CaseIterable, Identifiable {
        case detailed, compact
        var id: String { rawValue }
        var title: String { self == .detailed ? "Detailed" : "Compact" }
    }

    enum Key {
        static let sortBy = "sidebar.sortBy"
        static let projectOrder = "sidebar.projectOrder"
        static let groupBy = "sidebar.groupBy"
        static let cardLayout = "sidebar.cardLayout"
        static let showTicket = "sidebar.show.githubTicket"
        static let showLinear = "sidebar.show.linearIssue"
        static let showJira = "sidebar.show.jiraIssue"
        static let showPR = "sidebar.show.prLink"
        static let showAutomation = "sidebar.show.automation"
        static let showNotes = "sidebar.show.notes"
        static let showPorts = "sidebar.show.ports"
        static let showAgentActivity = "sidebar.show.agentActivity"
        static let showHost = "sidebar.show.host"
        static let hideSleeping = "sidebar.filter.hideSleeping"
        static let exceptDefaultBranch = "sidebar.filter.exceptDefaultBranch"
        static let hideDefaultBranch = "sidebar.filter.hideDefaultBranch"
        static let hideAutomation = "sidebar.filter.hideAutomation"
        static let hideCLI = "sidebar.filter.hideCLI"
        static let hideDetached = "sidebar.filter.hideDetachedHead"
        static let hideOtherClient = "sidebar.filter.hideOtherClient"
    }
}

/// Dropdown behind the `SlidersHorizontal` header button.
struct WorkspaceOptionsMenu: View {
    @AppStorage(WorkspaceOptions.Key.sortBy) private var sortBy = WorkspaceOptions.SortBy.recent.rawValue
    @AppStorage(WorkspaceOptions.Key.projectOrder) private var projectOrder = WorkspaceOptions.ProjectOrder.manual.rawValue
    @AppStorage(WorkspaceOptions.Key.groupBy) private var groupBy = WorkspaceOptions.GroupBy.project.rawValue
    @AppStorage(WorkspaceOptions.Key.cardLayout) private var cardLayout = WorkspaceOptions.CardLayout.detailed.rawValue

    @AppStorage(WorkspaceOptions.Key.showTicket) private var showTicket = true
    @AppStorage(WorkspaceOptions.Key.showLinear) private var showLinear = true
    @AppStorage(WorkspaceOptions.Key.showJira) private var showJira = true
    @AppStorage(WorkspaceOptions.Key.showPR) private var showPR = true
    @AppStorage(WorkspaceOptions.Key.showAutomation) private var showAutomation = true
    @AppStorage(WorkspaceOptions.Key.showNotes) private var showNotes = true
    @AppStorage(WorkspaceOptions.Key.showPorts) private var showPorts = true
    @AppStorage(WorkspaceOptions.Key.showAgentActivity) private var showAgentActivity = true
    @AppStorage(WorkspaceOptions.Key.showHost) private var showHost = false

    @AppStorage(WorkspaceOptions.Key.hideSleeping) private var hideSleeping = false
    @AppStorage(WorkspaceOptions.Key.exceptDefaultBranch) private var exceptDefaultBranch = false
    @AppStorage(WorkspaceOptions.Key.hideDefaultBranch) private var hideDefaultBranch = false
    @AppStorage(WorkspaceOptions.Key.hideAutomation) private var hideAutomation = false
    @AppStorage(WorkspaceOptions.Key.hideCLI) private var hideCLI = false
    @AppStorage(WorkspaceOptions.Key.hideDetached) private var hideDetached = false
    @AppStorage(WorkspaceOptions.Key.hideOtherClient) private var hideOtherClient = false

    private var activeFilterCount: Int {
        [hideSleeping, hideDefaultBranch, hideAutomation, hideCLI, hideDetached, hideOtherClient]
            .filter { $0 }.count
    }

    private var tooltip: String {
        activeFilterCount == 0 ? "Workspace options" : "Workspace options (\(activeFilterCount) active)"
    }

    var body: some View {
        Menu {
            Section("Sort by") {
                Picker("Sort by", selection: $sortBy) {
                    ForEach(WorkspaceOptions.SortBy.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            }
            Section("Project order") {
                Picker("Project order", selection: $projectOrder) {
                    ForEach(WorkspaceOptions.ProjectOrder.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            }
            Section("Group by") {
                Picker("Group by", selection: $groupBy) {
                    ForEach(WorkspaceOptions.GroupBy.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            }
            Section("Show") {
                Toggle("GitHub ticket", isOn: $showTicket)
                Toggle("Linear issue", isOn: $showLinear)
                Toggle("Jira issue", isOn: $showJira)
                Toggle("PR/MR link", isOn: $showPR)
                Toggle("Automation", isOn: $showAutomation)
                Toggle("Notes", isOn: $showNotes)
                Toggle("Ports", isOn: $showPorts)
                Toggle("Agent activity", isOn: $showAgentActivity)
                Toggle("Host", isOn: $showHost)
            }
            Section("Filters") {
                Toggle("Hide sleeping", isOn: $hideSleeping)
                Toggle("Except default branch", isOn: $exceptDefaultBranch)
                    .disabled(!hideSleeping)
                Toggle("Hide default branch", isOn: $hideDefaultBranch)
                Toggle("Hide automation-created", isOn: $hideAutomation)
                Toggle("Hide CLI-created", isOn: $hideCLI)
                Toggle("Hide detached HEAD", isOn: $hideDetached)
                Toggle("Hide other-client workspaces", isOn: $hideOtherClient)
            }
            Section("Card layout") {
                Picker("Card layout", selection: $cardLayout) {
                    ForEach(WorkspaceOptions.CardLayout.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            }
        } label: {
            SidebarIconLabel(icon: .slidersHorizontal, size: 14, stroke: 2.25,
                             tint: activeFilterCount > 0 ? SmthzTheme.primary : SmthzTheme.mutedForeground)
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .smthzTooltip(tooltip, edge: .bottom)
        .accessibilityLabel(tooltip)
    }
}
