import AppKit
import SwiftUI

// VISUAL-ONLY: stub data until the M4 workspace model; unsupported operations remain disabled.
struct SmthzWorkspaceActions {
    var rename: ((String) -> Void)?
    var setPinned: ((Bool) -> Void)?
    var setUnread: ((Bool) -> Void)?
    var sleep: (() -> Void)?
    var delete: (() -> Void)?
}

private struct SmthzWorkspaceActionsKey: EnvironmentKey {
    static var defaultValue: [String: SmthzWorkspaceActions] { [:] }
}
private struct SmthzWorkspaceDirectoriesKey: EnvironmentKey {
    static let defaultValue: [String: URL] = [:]
}
extension EnvironmentValues {
    /// UI-29 supplies per-workspace commands and the selected session's cwd here.
    var smthzWorkspaceActions: [String: SmthzWorkspaceActions] {
        get { self[SmthzWorkspaceActionsKey.self] }
        set { self[SmthzWorkspaceActionsKey.self] = newValue }
    }
    var smthzWorkspaceDirectories: [String: URL] {
        get { self[SmthzWorkspaceDirectoriesKey.self] }
        set { self[SmthzWorkspaceDirectoriesKey.self] = newValue }
    }
}

struct SmthzWorkspaceContextMenu: View {
    let data: WorkspaceCardData
    var directory: URL?
    var actions = SmthzWorkspaceActions()
    var update: (() -> Void)?

    var body: some View {
        Text("Workspace").font(SmthzFont.ui(size: 11, weight: .medium))
        item("Update", "pencil", action: update)
        Menu { unavailable("No statuses available") } label: { label("Move to Status", "kanban") }.disabled(true)
        Divider()
        Menu {
            item("Finder", "folder-open", action: directory.map { path in { NSWorkspace.shared.open(path) } })
            Divider()
            unavailable("Customize apps...")
        } label: { label("Open in", "folder-open") }.disabled(directory == nil)
        item("Copy Path", "copy", action: directory.map { path in { copy(path.path) } })
        item("Copy Worktree Name", "copy") { copy(data.title) }
        Divider()
        item(data.isPinned ? "Unpin" : "Pin", data.isPinned ? "pin-off" : "pin",
             action: actions.setPinned.map { callback in { callback(!data.isPinned) } })
        item(data.isUnread ? "Mark Read" : "Mark Unread", data.isUnread ? "bell-off" : "bell",
             action: actions.setUnread.map { callback in { callback(!data.isUnread) } })
        Divider()
        item(data.hasParent ? "Change Parent Worktree..." : "Set Parent Worktree...", "folder-tree")
        if data.hasParent {
            item("Open Parent Worktree", "workflow")
            item("Remove from Parent", "unlink")
        }
        #if DEBUG
        Divider()
        Menu { item("Park terminal", "square-terminal") } label: { label("Developer", "code-xml") }.disabled(true)
        #endif
        Divider()
        item("Sleep", "moon", action: actions.sleep)
            .help("Close all active panels in this workspace to free up memory and CPU.")
        if data.descendantCount > 0 { item("Sleep with Descendants (\(data.descendantCount))", "moon") }
        Divider()
        if data.isPrimary {
            Text("Primary worktree — can't be deleted. Remove the project instead.")
        } else {
            Button(role: .destructive) { actions.delete?() } label: {
                label(data.isDeleting ? "Deleting…" : (data.isFolder ? "Remove Workspace" : "Delete Worktree"), "trash-2")
            }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled(actions.delete == nil || data.isDeleting)
            if data.descendantCount > 0 { item("Delete with Descendants…", "trash-2") }
        }
    }

    private func label(_ title: String, _ icon: String) -> some View {
        Label { Text(title) } icon: {
            if icon == "code-xml" { Image(systemName: "chevron.left.forwardslash.chevron.right") }
            else { SmthzIcon.image(icon).frame(width: 14, height: 14) }
        }
    }
    private func item(_ title: String, _ icon: String, action: (() -> Void)? = nil) -> some View {
        Button { action?() } label: { label(title, icon) }.disabled(action == nil)
    }
    private func unavailable(_ title: String) -> some View { Button(title) {}.disabled(true) }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}
