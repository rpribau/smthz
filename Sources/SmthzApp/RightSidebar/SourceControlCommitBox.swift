import SmthzCore
import SwiftUI

/// The single primary Source Control action for the current state (Orca commit-push.mdx):
/// stage while nothing is staged, commit once something is, then publish/push/pull/sync.
enum SourceControlPrimaryAction: Equatable {
    case stageAll, commit, publish, push, pull, sync

    var label: String {
        switch self {
        case .stageAll: "Stage All Changes"
        case .commit: "Commit"
        case .publish: "Publish Branch"
        case .push: "Push"
        case .pull: "Pull"
        case .sync: "Sync"
        }
    }

    static func resolve(_ status: HostGitStatus?, staged: Int, unstaged: Int) -> SourceControlPrimaryAction {
        guard let status else { return .commit }
        if staged > 0 { return .commit }
        if unstaged > 0 { return .stageAll }
        if status.head != nil && status.head != "(initial)", status.branch != nil, status.branch != "(detached)", status.upstream == nil {
            return .publish
        }
        if status.ahead > 0 && status.behind > 0 { return .sync }
        if status.ahead > 0 { return .push }
        if status.behind > 0 { return .pull }
        return .commit
    }
}

/// Multi-line message editor plus the primary button. ⌘↩ commits while the editor has focus.
struct SourceControlCommitBox: View {
    @Binding var message: String
    let action: SourceControlPrimaryAction
    let busy: Bool
    let onPrimary: () -> Void
    @FocusState private var focused: Bool

    private var enabled: Bool {
        !busy && (action != .commit || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                if message.isEmpty {
                    Text("Message (⌘↩ to commit)")
                        .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $message)
                    .font(SmthzFont.ui(size: 12))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 36, maxHeight: 96)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Commit message")
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        if enabled && action == .commit { onPrimary() }
                        return .handled
                    }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? SmthzTheme.ring : SmthzTheme.input))
            Button(action: onPrimary) {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(action.label)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(SmthzButtonStyle(.primary, size: .small))
            .disabled(!enabled)
            .accessibilityIdentifier("sourceControl.primary")
        }
        .padding(.horizontal, 8).padding(.bottom, 8)
    }
}
