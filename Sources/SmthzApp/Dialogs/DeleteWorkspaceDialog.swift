import SwiftUI

/// Delete Workspace confirmation (WP-M4-WORKTREE-APP). The caller runs `worktree.remove` with the
/// chosen options: delete the branch (unmerged branches are preserved by the host and offered in
/// Review Branches), run the archive script, and close the terminals running inside the worktree.
/// A dirty checkout or a failed archive script comes back as `failureMessage` with a force action.
struct SmthzDeleteWorkspaceDialog: View {
    struct Target: Identifiable {
        let id: String
        let name: String
        var path: String? = nil
        var hasUncommittedChanges = false
        var sessionCount = 0
    }
    struct Choice {
        var deleteBranch = true
        var runHooks = true
    }

    static let preferenceKey = "confirmations.skipDeleteWorkspace"
    let targets: [Target]
    var lineageNotice: String? = nil
    var failureMessage: String? = nil
    var forceTitle = "Force Delete"
    var working = false
    let onCancel: () -> Void
    var onConfirm: (_ dontAskAgain: Bool, _ choice: Choice) -> Void = { _, _ in }
    var onForceDelete: ((Choice) -> Void)? = nil
    @State private var dontAskAgain = false
    @State private var deleteBranch = true
    @State private var runHooks = true
    @AppStorage("confirmations.skipDeleteWorkspace") private var skipConfirmation = false

    private var choice: Choice { Choice(deleteBranch: deleteBranch, runHooks: runHooks) }
    private var sessions: Int { targets.reduce(0) { $0 + $1.sessionCount } }

    var body: some View {
        SmthzDialog(title: targets.count > 1 ? "Delete Workspaces" : "Delete Workspace",
                    description: targets.count > 1
                        ? "Remove the selected worktrees from disk?"
                        : "Remove this worktree from disk?",
                    onDismiss: onCancel) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(targets) { target in
                        HStack(alignment: .top, spacing: 8) {
                            SmthzIcon.image("folder").resizable().scaledToFit().frame(width: 16, height: 16)
                                .foregroundStyle(SmthzTheme.mutedForeground)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(target.name).font(SmthzFont.ui(size: 12, weight: .medium))
                                if let path = target.path {
                                    Text(path).font(SmthzFont.mono(size: 11))
                                        .foregroundStyle(SmthzTheme.mutedForeground)
                                        .lineLimit(2).truncationMode(.middle)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            .background(SmthzTheme.muted, in: RoundedRectangle(cornerRadius: 8))
            if targets.contains(where: \.hasUncommittedChanges) {
                warning("Any uncommitted or untracked changes in Git workspaces will be permanently deleted.")
            }
            if sessions > 0 {
                warning(sessions == 1 ? "1 terminal running inside this workspace will be closed."
                        : "\(sessions) terminals running inside these workspaces will be closed.")
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Also delete the branch", isOn: $deleteBranch).toggleStyle(SmthzCheckboxStyle())
                Text("Branches with unmerged commits are kept and listed for review.")
                    .font(SmthzFont.ui(size: 11)).foregroundStyle(SmthzTheme.mutedForeground)
                Toggle("Run the archive script", isOn: $runHooks).toggleStyle(SmthzCheckboxStyle())
            }
            .font(SmthzFont.ui(size: 12))
            if let lineageNotice {
                Text(lineageNotice).font(SmthzFont.ui(size: 12))
                    .foregroundStyle(SmthzTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failureMessage {
                Label {
                    Text(failureMessage).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    SmthzIcon.image("octagon-x").resizable().scaledToFit().frame(width: 14, height: 14)
                }
                .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.destructive)
            }
            VStack(alignment: .leading, spacing: 4) {
                SmthzConfirmationCheckbox(title: "Don't ask again", isOn: $dontAskAgain)
                Text("We'll skip this confirmation next time. You can change this in Settings.")
                    .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            if working { ProgressView().controlSize(.small) }
            Button("Cancel", action: onCancel)
                .buttonStyle(SmthzButtonStyle(.outline, size: .small))
                .keyboardShortcut(.cancelAction)
            if failureMessage != nil, let onForceDelete {
                Button(forceTitle, role: .destructive) { onForceDelete(choice) }
                    .buttonStyle(SmthzDestructiveDialogButtonStyle())
                    .disabled(working)
            } else {
                Button("Delete", role: .destructive) {
                    if dontAskAgain { skipConfirmation = true }
                    onConfirm(dontAskAgain, choice)
                }
                .buttonStyle(SmthzDestructiveDialogButtonStyle())
                .disabled(targets.isEmpty || working)
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            SmthzIcon.image("triangle-alert").resizable().scaledToFit().frame(width: 14, height: 14)
        }
        .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.statusWarning)
    }
}

#if DEBUG
#Preview("Delete workspace") {
    SmthzDeleteWorkspaceDialog(
        targets: [.init(id: "w", name: "fix-login", path: "~/smthz/workspaces/app/fix-login", hasUncommittedChanges: true, sessionCount: 2)],
        lineageNotice: "This workspace has 2 descendant workspaces.", onCancel: {})
        .padding(40).frame(width: 680, height: 620).background(SmthzTheme.background)
}
#endif
