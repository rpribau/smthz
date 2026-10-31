import SwiftUI

/// Review N Branches (WP-M4-WORKTREE-APP): branches Git refused to delete because they hold
/// unmerged commits (`worktree.preservedBranches`). Deleting one runs `git branch -D`
/// (`worktree.deletePreservedBranch`), an explicit user choice; Keep leaves them in place.
struct SmthzPreservedBranchesDialog: View {
    let repoID: String
    let projectTitle: String
    let lifecycle: WorktreeLifecycleModel
    let onDismiss: () -> Void

    @State private var branches: [(branch: String, head: String, formerPath: String)] = []
    @State private var selected: Set<String> = []
    @State private var working = false
    @State private var error: String?

    var body: some View {
        SmthzDialog(title: branches.count == 1 ? "Review 1 Branch" : "Review \(branches.count) Branches",
                    description: "These branches in \(projectTitle) have commits that are not merged. Delete the ones you no longer need.",
                    onDismiss: onDismiss) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(branches, id: \.branch) { item in
                        Toggle(isOn: Binding(get: { selected.contains(item.branch) },
                                             set: { if $0 { selected.insert(item.branch) } else { selected.remove(item.branch) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.branch).font(SmthzFont.mono(size: 12))
                                Text("\(item.head.prefix(8)) · was \(item.formerPath)").font(SmthzFont.ui(size: 11))
                                    .foregroundStyle(SmthzTheme.mutedForeground).lineLimit(1).truncationMode(.middle)
                            }
                        }.toggleStyle(SmthzCheckboxStyle())
                    }
                    if branches.isEmpty {
                        Text("No preserved branches.").font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220).fixedSize(horizontal: false, vertical: true)
            .background(SmthzTheme.muted, in: RoundedRectangle(cornerRadius: 8))
            if let error { Text(error).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.destructive) }
        } footer: {
            Button("Keep All", action: onDismiss).buttonStyle(SmthzButtonStyle(.outline, size: .small))
            Button(selected.count > 1 ? "Delete \(selected.count) Branches" : "Delete Branch", role: .destructive, action: delete)
                .buttonStyle(SmthzDestructiveDialogButtonStyle()).disabled(selected.isEmpty || working)
        }
        .task { await reload() }
    }

    private func reload() async {
        branches = await lifecycle.preservedBranches(repoID: repoID)
        selected = selected.filter { name in branches.contains { $0.branch == name } }
    }

    private func delete() {
        working = true; error = nil
        Task {
            for branch in selected.sorted() {
                do { try await lifecycle.deletePreservedBranch(repoID: repoID, branch: branch) }
                catch { self.error = "\(branch): \(error.localizedDescription)" }
            }
            await reload()
            working = false
            if branches.isEmpty, error == nil { onDismiss() }
        }
    }
}
