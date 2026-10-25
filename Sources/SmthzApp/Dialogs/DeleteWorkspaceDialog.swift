import SwiftUI

// VISUAL-ONLY: stub data until M4 projects/worktrees and workspace deletion backend.
// This dialog renders only in DEBUG. UI-29 may present it for the existing Default
// workspace; onConfirm is a preview callback, never a filesystem delete operation.
struct SmthzDeleteWorkspaceDialog: View {
    struct Target: Identifiable {
        let id: String
        let name: String
        var path: String? = nil
        var hasUncommittedChanges = false
    }

    static let preferenceKey = "confirmations.skipDeleteWorkspace"
    let targets: [Target]
    var lineageNotice: String? = nil
    var failureMessage: String? = nil
    let onCancel: () -> Void
    var onConfirm: (_ dontAskAgain: Bool) -> Void = { _ in }
    var onForceDelete: (() -> Void)? = nil
    @State private var dontAskAgain = false
    @AppStorage("confirmations.skipDeleteWorkspace") private var skipConfirmation = false

    var body: some View {
        #if DEBUG
        SmthzDialog(title: targets.count > 1 ? "Delete Workspaces" : "Delete Workspace",
                    description: targets.count > 1
                        ? "Remove the selected workspaces?"
                        : "Remove this workspace?",
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
                Label {
                    Text("Any uncommitted or untracked changes in Git workspaces will be permanently deleted.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    SmthzIcon.image("triangle-alert").resizable().scaledToFit().frame(width: 14, height: 14)
                }
                .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.statusWarning)
            }
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
            Button("Cancel", action: onCancel)
                .buttonStyle(SmthzButtonStyle(.outline, size: .small))
                .keyboardShortcut(.cancelAction)
            if failureMessage != nil, let onForceDelete {
                Button("Force Delete", role: .destructive, action: onForceDelete)
                    .buttonStyle(SmthzDestructiveDialogButtonStyle())
            } else {
                Button("Delete", role: .destructive) {
                    if dontAskAgain { skipConfirmation = true }
                    onConfirm(dontAskAgain)
                }
                .buttonStyle(SmthzDestructiveDialogButtonStyle())
                .disabled(targets.isEmpty)
            }
        }
        #else
        EmptyView()
        #endif
    }
}

#if DEBUG
#Preview("Delete workspace · visual only") {
    SmthzDeleteWorkspaceDialog(
        targets: [.init(id: "default", name: "Default workspace", path: "/projects/smthz", hasUncommittedChanges: true)],
        lineageNotice: "This workspace has 2 descendant workspaces.", onCancel: {})
        .padding(40).frame(width: 680, height: 560).background(SmthzTheme.background)
}
#endif
