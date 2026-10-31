import SwiftUI
import SmthzCore

/// Setup approval (WP-M4-WORKTREE-APP). Two cases block `worktree.create` before any Git work:
/// the repository asks before running setup (`setupDecisionRequired`: Run or Skip), or a shared
/// `smthz.yaml`/`orca.yaml` command has not been trusted yet (`untrustedCommand`: trusting stores
/// its SHA-256 with `worktree.approveHooks`, so a changed script asks again).
struct SmthzSetupApprovalDialog: View {
    let block: WorkspaceComposerLogic.CreateBlock
    let projectTitle: String
    /// Primary checkout used to preview the shared commands (the host reads the destination ref).
    let repoPath: String?
    let onCancel: () -> Void
    /// Run/skip for a decision; `run` after the hash was trusted.
    let onDecision: (WorkspaceComposerLogic.SetupChoice) -> Void
    var onTrust: (_ kind: String, _ hash: String) async throws -> Void = { _, _ in }

    @State private var working = false
    @State private var error: String?

    private var preview: String? {
        guard case .untrusted(let kind, _) = block, let repoPath,
              let config = SmthzConfigLoader.load(repoRoot: repoPath)?.config else { return nil }
        switch kind {
        case "setup": return config.setupScript
        case "archive": return config.archiveScript
        case "defaultTabs": return config.defaultTabs.compactMap(\.command).joined(separator: "\n")
        case "issueCommand": return config.issueCommand
        default: return nil
        }
    }

    var body: some View {
        switch block {
        case .setupDecision:
            SmthzDialog(title: "Run setup script?",
                        description: "\(projectTitle) asks before running its setup script in new workspaces.",
                        onDismiss: onCancel) {
                EmptyView()
            } footer: {
                Button("Cancel", action: onCancel).buttonStyle(SmthzButtonStyle(.outline, size: .small))
                Button("Skip setup") { onDecision(.skip) }.buttonStyle(SmthzButtonStyle(.outline, size: .small))
                Button("Run setup") { onDecision(.run) }.buttonStyle(SmthzButtonStyle(.primary, size: .small))
                    .keyboardShortcut(.defaultAction)
            }
        case .untrusted(let kind, let hash):
            SmthzDialog(title: "Trust repository commands?",
                        description: "\(projectTitle) defines \(label(kind)) in its shared configuration. smthz runs it only after you trust this exact content.",
                        onDismiss: onCancel) {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView {
                        Text(preview ?? "The command comes from the base branch of the new workspace.")
                            .font(SmthzFont.mono(size: 11)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    .frame(maxHeight: 180)
                    .background(SmthzTheme.muted, in: RoundedRectangle(cornerRadius: 8))
                    Text("SHA-256 \(hash)").font(SmthzFont.mono(size: 10)).foregroundStyle(SmthzTheme.mutedForeground)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    if let error { Text(error).font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.destructive) }
                }
            } footer: {
                Button("Cancel", action: onCancel).buttonStyle(SmthzButtonStyle(.outline, size: .small))
                if kind == "setup" || kind == "defaultTabs" {
                    Button("Skip setup") { onDecision(.skip) }.buttonStyle(SmthzButtonStyle(.outline, size: .small))
                }
                Button("Trust and continue") {
                    working = true
                    Task {
                        do { try await onTrust(kind, hash); onDecision(.run) }
                        catch { self.error = error.localizedDescription }
                        working = false
                    }
                }
                .buttonStyle(SmthzButtonStyle(.primary, size: .small)).disabled(working)
            }
        }
    }

    private func label(_ kind: String) -> String {
        switch kind {
        case "setup": "a setup script"
        case "archive": "an archive script"
        case "defaultTabs": "default tab commands"
        default: "a command"
        }
    }
}
