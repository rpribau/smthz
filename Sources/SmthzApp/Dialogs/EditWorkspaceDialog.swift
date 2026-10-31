import SwiftUI
import SmthzCore

/// Edit Workspace Details (WP-M4-WORKTREE-APP): display name, note and parent worktree,
/// saved with `worktree.set` (the host rejects lineage cycles with `badRequest`).
struct SmthzEditWorkspaceDialog: View {
    let worktreeID: String
    let initialName: String
    let initialNote: String
    /// Other worktrees of the same project (id, title).
    let parents: [SmthzComposerProject.Parent]
    let lifecycle: WorktreeLifecycleModel
    let onDismiss: () -> Void
    var onSaved: () -> Void = {}

    @State private var name = ""
    @State private var note = ""
    @State private var parentID: String?
    @State private var loadedParent: String?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        SmthzDialog(title: "Edit Workspace Details", onDismiss: onDismiss) {
            VStack(alignment: .leading, spacing: 12) {
                label("Name")
                SmthzComposerTextField(placeholder: "Workspace name", text: $name)
                label("Note")
                TextEditor(text: $note).font(SmthzFont.ui(size: 13)).frame(height: 80)
                    .scrollContentBackground(.hidden).padding(6)
                    .background(SmthzTheme.input.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.input))
                    .accessibilityLabel("Note")
                label("Parent worktree")
                Picker("Parent worktree", selection: $parentID) {
                    Text("No parent").tag(String?.none)
                    ForEach(parents.filter { $0.id != worktreeID }) { Text($0.title).tag(Optional($0.id)) }
                }.labelsHidden()
                if let error {
                    Text(error).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.destructive)
                }
            }
        } footer: {
            Button("Cancel", action: onDismiss).buttonStyle(SmthzButtonStyle(.outline, size: .small))
            Button("Save", action: save).buttonStyle(SmthzButtonStyle(.primary, size: .small))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .task {
            name = initialName; note = initialNote
            let parent = await lifecycle.details(worktreeID).parent
            loadedParent = parent.map { $0.hasPrefix("worktree:") ? String($0.dropFirst(9)) : $0 }
            parentID = loadedParent
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(SmthzFont.ui(size: 12, weight: .medium)).foregroundStyle(SmthzTheme.mutedForeground)
    }

    private func save() {
        var fields: [String: HostJSON] = [:]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != initialName { fields["displayName"] = .string(trimmed) }
        if note != initialNote { fields["comment"] = .string(note) }
        if parentID != loadedParent {
            if let parentID { fields["parentId"] = .string(parentID) } else { fields["noParent"] = .bool(true) }
        }
        guard !fields.isEmpty else { onDismiss(); return }
        saving = true
        Task {
            do { try await lifecycle.set(worktreeID, fields); onSaved(); onDismiss() }
            catch let failure as WorktreeLifecycleModel.Failure where failure.code == "badRequest" {
                error = "That parent would create a cycle or belongs to another project."
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }
}
