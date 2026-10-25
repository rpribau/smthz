import SwiftUI

// VISUAL-ONLY: stub data until the M4 projects/groups model.
struct SmthzProjectActions {
    var settings: (() -> Void)?
    var changeIcon: (() -> Void)?
    var toggleVisibility: (() -> Void)?
    var newGroup: (() -> Void)?
    var removeFromGroup: (() -> Void)?
    var remove: (() -> Void)?
    var createWorkspace: (() -> Void)?
}
private struct SmthzProjectActionsKey: EnvironmentKey {
    static var defaultValue: [String: SmthzProjectActions] { [:] }
}
extension EnvironmentValues {
    /// Keyed by project title until the M4 model supplies stable project identity.
    var smthzProjectActions: [String: SmthzProjectActions] {
        get { self[SmthzProjectActionsKey.self] }
        set { self[SmthzProjectActionsKey.self] = newValue }
    }
}
struct SmthzProjectActionsMenu: View {
    var actions = SmthzProjectActions()
    var isGrouped = false
    var showsWorktrees = true
    var body: some View {
        item("Project Settings", "sliders-horizontal", actions.settings)
        item("Change Project Icon", "shapes", actions.changeIcon)
        item(showsWorktrees ? "Hide Worktrees" : "Show Worktrees", "eye", actions.toggleVisibility)
        item("New group from project", "folder-tree", actions.newGroup)
        Menu { Button("No groups") {}.disabled(true) } label: {
            Label { Text("Move to group") } icon: { SmthzIcon.image("folder-input").frame(width: 14, height: 14) }
        }.disabled(true)
        if isGrouped { item("Remove from group", "circle-x", actions.removeFromGroup) }
        Divider()
        Button(role: .destructive) { actions.remove?() } label: {
            Label { Text("Remove Project") } icon: { SmthzIcon.image("trash-2").frame(width: 14, height: 14) }
        }.disabled(actions.remove == nil)
    }
    private func item(_ title: String, _ icon: String, _ action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            Label { Text(title) } icon: { SmthzIcon.image(icon).frame(width: 14, height: 14) }
        }.disabled(action == nil)
    }
}
