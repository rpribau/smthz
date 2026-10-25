import SwiftUI

/// Targets are supplied by the shell; no host connection is owned by the palette.
@MainActor @Observable
final class SmthzJumpPaletteModel {
    enum Action: Hashable {
        case selectTab(String), selectWorkspace(String), newTerminal, settings(String)
        case toggleLeftSidebar, toggleRightSidebar
    }

    enum Section: String, CaseIterable, Identifiable {
        case recent = "Recent Chats & Terminals", tabs = "Open Tabs"
        case workspaces = "Workspaces", projects = "Projects & Groups", tasks = "Tasks"
        case actions = "Actions & Settings"
        var id: String { rawValue }
    }

    struct Target: Identifiable {
        let id: String
        let title: String
        var subtitle = ""
        var icon: SmthzIcon.Name = .squareTerminal
        var badge: String? = nil
        var section: Section = .tabs
        var host: String? = "Local"
        var project: String? = nil
        let action: Action
    }

    var query = ""
    var selectedID: String?
    var hostFilter: String?
    var projectFilter: String?
    var isLoading = false
    var targets: [Target]

    // VISUAL-ONLY: stub data until M4 projects/workspaces and M5 tasks backends.
    // No synthetic project/task rows are shown. Default workspace is the existing shell workspace.
    init(openTabs: [Target] = [], includeDefaultWorkspace: Bool = true) {
        targets = openTabs
        if includeDefaultWorkspace {
            targets.append(Target(id: "workspace.default", title: "Default workspace", icon: .folder,
                                  badge: "Current", section: .workspaces,
                                  action: .selectWorkspace("default")))
        }
        targets += Self.standardActions
    }

    static var standardActions: [Target] {
        var rows = [
            Target(id: "action.terminal", title: "New Terminal Tab", icon: .squareTerminal,
                   badge: "Action", section: .actions, host: nil, action: .newTerminal),
            Target(id: "action.left", title: "Toggle Left Sidebar", icon: .panelLeft,
                   badge: "Action", section: .actions, host: nil, action: .toggleLeftSidebar),
            Target(id: "action.right", title: "Toggle Right Sidebar", icon: .panelRight,
                   badge: "Action", section: .actions, host: nil, action: .toggleRightSidebar)
        ]
        rows += SettingsGroup.all.flatMap(\.pages).map { page in
            Target(id: "settings.\(page.id)", title: page.title, subtitle: page.description,
                   icon: page.icon, badge: "Settings", section: .actions, host: nil,
                   action: .settings(page.id))
        }
        return rows
    }

    var hosts: [String] { Array(Set(targets.compactMap(\.host))).sorted() }
    var projects: [String] { Array(Set(targets.compactMap(\.project))).sorted() }
    var filtered: [Target] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return Section.allCases.flatMap { section in
            targets.filter { target in
                target.section == section
                    && (hostFilter == nil || target.host == hostFilter)
                    && (projectFilter == nil || target.project == projectFilter)
                    && words.allSatisfy { word in
                        "\(target.title) \(target.subtitle) \(target.badge ?? "")"
                            .localizedCaseInsensitiveContains(word)
                    }
            }
        }
    }
    var selection: Target? { filtered.first { $0.id == selectedID } ?? filtered.first }
    func resetSelection() { selectedID = filtered.first?.id }
    func move(_ offset: Int) {
        let rows = filtered
        guard !rows.isEmpty else { selectedID = nil; return }
        let index = rows.firstIndex { $0.id == selection?.id } ?? 0
        selectedID = rows[(index + offset + rows.count) % rows.count].id
    }
    func clearFilters() { hostFilter = nil; projectFilter = nil; resetSelection() }
}
