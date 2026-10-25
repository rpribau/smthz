import AppKit
import SwiftUI

// VISUAL-ONLY: stub data until M4 projects/worktrees and remote execution hosts.
// Browsing is real, but the selected URL stays in this dialog and is not added
// to a project store, scanned, cloned or persisted. UI-29 owns presentation.
struct SmthzAddProjectDialog: View {
    let onDismiss: () -> Void
    @State private var selectedFolder: URL? = nil
    @State private var browsing = false
    @State private var hostPickerOpen = false
    @FocusState private var browseFocused: Bool

    var body: some View {
        SmthzProjectDialogPanel(title: "Add a project",
                                subtitle: "Add a project to get started with smthz.",
                                onDismiss: onDismiss) {
            VStack(alignment: .leading, spacing: 12) {
                hostSelector
                Button(action: browse) {
                    actionLabel("Browse folder", description: "Local project, Git repo, or folder with many repos",
                                icon: "folder-open", primary: true)
                }
                .buttonStyle(SmthzAddProjectCardStyle())
                .focused($browseFocused)
                .disabled(browsing)
                .keyboardShortcut(.return, modifiers: [])
                VStack(alignment: .leading, spacing: 6) {
                    Text("Other ways to add").textCase(.uppercase)
                        .font(SmthzFont.ui(size: 12, weight: .medium)).tracking(0.6)
                        .foregroundStyle(SmthzTheme.mutedForeground)
                    VStack(spacing: 0) {
                        unavailableAction("Create new project", description: "Start from an empty folder", icon: "plus")
                        Divider().overlay(SmthzTheme.border.opacity(0.7))
                        unavailableAction("Clone from URL", description: "Clone a remote Git repository", icon: "globe")
                        Divider().overlay(SmthzTheme.border.opacity(0.7))
                        unavailableAction("SSH", description: "Open a project from an SSH target", icon: nil)
                    }
                    .background(SmthzTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.input))
                }
                if let selectedFolder {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selectedFolder.path)
                            .font(SmthzFont.mono(size: 12)).textSelection(.enabled)
                            .lineLimit(3).truncationMode(.middle)
                            .accessibilityLabel("Selected folder: \(selectedFolder.path)")
                        Text("Project saving is not available yet.")
                            .font(SmthzFont.ui(size: 12)).foregroundStyle(SmthzTheme.mutedForeground)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(SmthzTheme.muted, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.top, 8)
        } footer: {
            EmptyView()
        }
        .onAppear { browseFocused = true }
    }

    private var hostSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Host").font(SmthzFont.ui(size: 12, weight: .medium))
                .foregroundStyle(SmthzTheme.mutedForeground)
            Button { hostPickerOpen.toggle() } label: {
                HStack(spacing: 8) {
                    SmthzIcon.image("server").scaledToFit().frame(width: 14, height: 14)
                    Text("Local").font(SmthzFont.ui(size: 14))
                    Spacer()
                    SmthzIcon.image("chevron-down").scaledToFit().frame(width: 12, height: 12)
                }
                .padding(.horizontal, 12).frame(height: 36)
                .background(SmthzTheme.input.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SmthzTheme.input))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $hostPickerOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Local").font(SmthzFont.ui(size: 12, weight: .medium))
                    Divider()
                    Text("Add remote host").font(SmthzFont.ui(size: 11, weight: .semibold))
                        .foregroundStyle(SmthzTheme.mutedForeground)
                    Button("SSH host") {}.disabled(true)
                    Button("remote server") {}.disabled(true)
                    Button("WSL distro") {}.disabled(true)
                    Text("Not available yet").font(SmthzFont.ui(size: 11))
                        .foregroundStyle(SmthzTheme.mutedForeground)
                }.padding(12).frame(width: 240, alignment: .leading)
            }
        }
    }

    private func unavailableAction(_ title: String, description: String, icon: String?) -> some View {
        Button {} label: {
            actionLabel(title, description: description, icon: icon)
        }
        .buttonStyle(.plain).disabled(true).opacity(0.7)
        .help("Not available yet")
        .accessibilityHint("Not available yet")
    }

    private func actionLabel(_ title: String, description: String, icon: String?, primary: Bool = false) -> some View {
        HStack(spacing: 12) {
            Group {
                if let icon {
                    SmthzIcon.image(icon).scaledToFit()
                } else {
                    // Monitor is not in UI-24's allowed SVG scope; use its native equivalent.
                    Image(systemName: "display").resizable().scaledToFit()
                }
            }
            .frame(width: 16, height: 16).frame(width: 28, height: 28)
            .background(primary ? SmthzTheme.background.opacity(0.7) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(SmthzFont.ui(size: 14, weight: .medium))
                Text(description).font(SmthzFont.ui(size: 12))
                    .foregroundStyle(SmthzTheme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if primary && browseFocused {
                Text("⏎").font(SmthzFont.ui(size: 12, weight: .medium))
                    .foregroundStyle(SmthzTheme.mutedForeground)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(SmthzTheme.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(SmthzTheme.border.opacity(0.8)))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(SmthzTheme.foreground)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: primary ? 60 : 52, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func browse() {
        guard !browsing else { return }
        browsing = true
        let panel = NSOpenPanel()
        panel.title = "Browse folder"
        panel.prompt = "Choose folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        // Modal presentation keeps keyboard input in the folder picker. Returning
        // a URL changes this view's local state only; cancellation retains it.
        let response = panel.runModal()
        if response == .OK { selectedFolder = panel.url }
        browsing = false
        browseFocused = true
    }
}

private struct SmthzAddProjectCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Card(configuration: configuration)
    }

    private struct Card: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(focused || hovered || configuration.isPressed ? SmthzTheme.accent : SmthzTheme.background,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(focused ? SmthzTheme.ring : SmthzTheme.border)
                }
                .opacity(enabled ? 1 : 0.5)
                .onHover { hovered = $0 }
        }
    }
}

#if DEBUG
#Preview("Add project · light") {
    SmthzAddProjectDialog(onDismiss: {})
        .padding(40).frame(width: 650, height: 620).background(SmthzTheme.background)
        .preferredColorScheme(.light)
}
#Preview("Add project · dark") {
    SmthzAddProjectDialog(onDismiss: {})
        .padding(40).frame(width: 650, height: 620).background(SmthzTheme.background)
        .preferredColorScheme(.dark)
}
#endif
